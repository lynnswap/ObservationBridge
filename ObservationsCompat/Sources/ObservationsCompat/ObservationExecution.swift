import AsyncAlgorithms
import Observation
import ObservationsCompatLegacy
import Synchronization

private enum OwnerValueEmission<Value: Sendable>: Sendable {
    case value(Value)
    case ownerGone
}

private struct ObservedValueChannel<Value: Sendable>: Sendable {
    let channel: AsyncChannel<Value>
    let producerTask: Task<Void, Never>
}

private struct ObserveTaskExecutionState<Value: Sendable>: Sendable {
    var activeOperationTask: Task<Void, Never>? = nil
    var activeOperationID: UInt64? = nil
    var nextOperationID: UInt64 = 0
    var pendingLatestValue: Value? = nil
    var isCancelled = false
}

private struct DuplicateEmissionState<Value: Sendable>: Sendable {
    private enum Previous: Sendable {
        case none
        case value(Value)
    }

    private var previous: Previous = .none
    let isDuplicate: (@Sendable (Value, Value) -> Bool)?

    init(isDuplicate: (@Sendable (Value, Value) -> Bool)?) {
        self.isDuplicate = isDuplicate
    }

    mutating func shouldEmit(_ value: Value) -> Bool {
        if case let .value(previousValue) = previous,
           let isDuplicate,
           isDuplicate(previousValue, value)
        {
            return false
        }
        previous = .value(value)
        return true
    }
}

func observeImpl<Owner: AnyObject, Value: Sendable>(
    owner: Owner,
    options: ObservationOptions,
    duplicateFilter: (@Sendable (Value, Value) -> Bool)?,
    debounce: ObservationDebounce?,
    debounceClock: any Clock<Duration>,
    isolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending Value) async -> Void
) -> ObservationHandle {
    let ownerToken = WeakOwnerRegistry.createToken(owner: owner)
    let monitorTask = Task {
        let observedValues = makeObservedValueChannel(
            ownerToken: ownerToken,
            options: options,
            isolation: isolation,
            of: value
        )
        defer {
            observedValues.producerTask.cancel()
            observedValues.channel.finish()
        }

        var duplicateState = DuplicateEmissionState(isDuplicate: duplicateFilter)

        if let debounce {
            let debouncedValues = makeDebouncedValueStream(
                observedValues.channel,
                debounce: debounce,
                debounceClock: debounceClock
            )
            for await observedValue in debouncedValues {
                guard !Task.isCancelled else {
                    break
                }
                guard duplicateState.shouldEmit(observedValue) else {
                    continue
                }
                await onChange(observedValue)
            }
        } else {
            for await observedValue in observedValues.channel {
                guard !Task.isCancelled else {
                    break
                }
                guard duplicateState.shouldEmit(observedValue) else {
                    continue
                }
                await onChange(observedValue)
            }
        }
    }

    let handle = ObservationHandle {
        monitorTask.cancel()
    }
    handle.box.addCancellationHandler {
        WeakOwnerRegistry.removeToken(ownerToken)
    }

    AutomaticRetentionRegistry.retain(handle.box, owner: owner)
    return handle
}

func observeTaskImpl<Owner: AnyObject, Value: Sendable>(
    owner: Owner,
    options: ObservationOptions,
    duplicateFilter: (@Sendable (Value, Value) -> Bool)?,
    debounce: ObservationDebounce?,
    debounceClock: any Clock<Duration>,
    isolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    @_inheritActorContext task: @escaping @isolated(any) @Sendable (sending Value) async -> Void
) -> ObservationHandle {
    let ownerToken = WeakOwnerRegistry.createToken(owner: owner)
    let observeTaskState = Mutex(ObserveTaskExecutionState<Value>())
    let (operationWakeStream, operationWakeSignal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    let operationDidFinish: @Sendable (UInt64) -> Void = { operationID in
        let shouldWake = observeTaskState.withLock { state in
            guard state.activeOperationID == operationID else {
                return false
            }

            state.activeOperationTask = nil
            state.activeOperationID = nil
            guard !state.isCancelled else {
                return false
            }
            return state.pendingLatestValue != nil
        }

        if shouldWake {
            operationWakeSignal.yield(())
        }
    }

    let shutdownObserveTaskExecution: @Sendable () -> Void = {
        let activeTask: Task<Void, Never>? = observeTaskState.withLock { state -> Task<Void, Never>? in
            guard !state.isCancelled else {
                return nil
            }

            state.isCancelled = true
            state.pendingLatestValue = nil
            state.activeOperationID = nil
            let activeTask = state.activeOperationTask
            state.activeOperationTask = nil
            return activeTask
        }

        activeTask?.cancel()
        operationWakeSignal.finish()
    }

    let enqueueLatestValue: @Sendable (Value) -> Bool = { observedValue in
        let transition: (accepted: Bool, activeTask: Task<Void, Never>?) = observeTaskState.withLock { state -> (accepted: Bool, activeTask: Task<Void, Never>?) in
            guard !state.isCancelled else {
                return (accepted: false, activeTask: nil)
            }

            state.pendingLatestValue = observedValue
            let activeTask = state.activeOperationTask
            if activeTask != nil {
                state.activeOperationTask = nil
                state.activeOperationID = nil
            }
            return (accepted: true, activeTask: activeTask)
        }

        guard transition.accepted else {
            return false
        }

        transition.activeTask?.cancel()
        operationWakeSignal.yield(())
        return true
    }

    let drainTask = Task {
        for await _ in operationWakeStream {
            guard !Task.isCancelled else {
                break
            }

            while true {
                let startedOperation: Bool = observeTaskState.withLock { state -> Bool in
                    guard !state.isCancelled else {
                        return false
                    }
                    guard state.activeOperationTask == nil, let nextValue = state.pendingLatestValue else {
                        return false
                    }

                    state.pendingLatestValue = nil
                    let operationID = state.nextOperationID
                    state.nextOperationID &+= 1
                    let operation = Task {
                        await task(nextValue)
                        operationDidFinish(operationID)
                    }
                    state.activeOperationID = operationID
                    state.activeOperationTask = operation
                    return true
                }

                guard startedOperation else {
                    break
                }
            }
        }

        let remainingTask: Task<Void, Never>? = observeTaskState.withLock { state -> Task<Void, Never>? in
            let remainingTask = state.activeOperationTask
            state.activeOperationTask = nil
            state.activeOperationID = nil
            return remainingTask
        }
        remainingTask?.cancel()
    }

    let monitorTask = Task {
        let observedValues = makeObservedValueChannel(
            ownerToken: ownerToken,
            options: options,
            isolation: isolation,
            of: value
        )
        defer {
            observedValues.producerTask.cancel()
            observedValues.channel.finish()
        }

        var duplicateState = DuplicateEmissionState(isDuplicate: duplicateFilter)

        if let debounce {
            let debouncedValues = makeDebouncedValueStream(
                observedValues.channel,
                debounce: debounce,
                debounceClock: debounceClock
            )
            for await observedValue in debouncedValues {
                guard !Task.isCancelled else {
                    break
                }
                guard duplicateState.shouldEmit(observedValue) else {
                    continue
                }
                guard enqueueLatestValue(observedValue) else {
                    break
                }
            }
        } else {
            for await observedValue in observedValues.channel {
                guard !Task.isCancelled else {
                    break
                }
                guard duplicateState.shouldEmit(observedValue) else {
                    continue
                }
                guard enqueueLatestValue(observedValue) else {
                    break
                }
            }
        }

        shutdownObserveTaskExecution()
    }

    let handle = ObservationHandle {
        monitorTask.cancel()
        drainTask.cancel()
        shutdownObserveTaskExecution()
    }
    handle.box.addCancellationHandler {
        WeakOwnerRegistry.removeToken(ownerToken)
    }

    AutomaticRetentionRegistry.retain(handle.box, owner: owner)
    return handle
}

private func makeObservedValueChannel<Owner: AnyObject, Value: Sendable>(
    ownerToken: UInt64,
    options: ObservationOptions,
    isolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value
) -> ObservedValueChannel<Value> {
    let channel = AsyncChannel<Value>()
    let producerTask = Task {
        await forEachOwnerValueEmission(
            ownerToken: ownerToken,
            options: options,
            isolation: isolation,
            of: value
        ) { emission in
            switch emission {
            case .ownerGone:
                return false
            case .value(let observedValue):
                guard !Task.isCancelled else {
                    return false
                }
                await channel.send(observedValue)
                return !Task.isCancelled
            }
        }

        channel.finish()
    }

    return ObservedValueChannel(
        channel: channel,
        producerTask: producerTask
    )
}

func makeDebouncedValueStream<S: AsyncSequence & Sendable>(
    _ source: S,
    debounce: ObservationDebounce,
    debounceClock: any Clock<Duration>
) -> AsyncStream<S.Element> where S.Element: Sendable {
    makeDebouncedValueStream(
        source,
        debounce: debounce,
        clock: debounceClock
    )
}

func makeDebouncedValueStream<S: AsyncSequence & Sendable, C: Clock<Duration>>(
    _ source: S,
    debounce: ObservationDebounce,
    clock: C
) -> AsyncStream<S.Element> where S.Element: Sendable {
    switch debounce.mode {
    case .delayedFirst:
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in source.debounce(
                        for: debounce.interval,
                        tolerance: debounce.tolerance,
                        clock: clock
                    ) {
                        guard !Task.isCancelled else {
                            break
                        }
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    preconditionFailure("debounce source unexpectedly threw")
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    case .immediateFirst:
        return AsyncStream { continuation in
            let task = Task {
                let (remainingStream, remainingContinuation) = AsyncStream<S.Element>.makeStream(
                    bufferingPolicy: .bufferingNewest(1)
                )
                let producerTask = Task {
                    do {
                        var iterator = source.makeAsyncIterator()
                        guard let firstValue = try await iterator.next() else {
                            remainingContinuation.finish()
                            return
                        }

                        guard !Task.isCancelled else {
                            remainingContinuation.finish()
                            return
                        }

                        continuation.yield(firstValue)

                        while let nextValue = try await iterator.next() {
                            guard !Task.isCancelled else {
                                break
                            }
                            remainingContinuation.yield(nextValue)
                        }

                        remainingContinuation.finish()
                    } catch {
                        remainingContinuation.finish()
                        preconditionFailure("debounce source unexpectedly threw")
                    }
                }

                for await value in remainingStream.debounce(
                    for: debounce.interval,
                    tolerance: debounce.tolerance,
                    clock: clock
                ) {
                    guard !Task.isCancelled else {
                        break
                    }
                    continuation.yield(value)
                }

                producerTask.cancel()
                await producerTask.value
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private func forEachOwnerValueEmission<Owner: AnyObject, Value: Sendable>(
    ownerToken: UInt64,
    options: ObservationOptions,
    isolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    consume: @escaping @Sendable (OwnerValueEmission<Value>) async -> Bool
) async {
    let resolvedIsolation = value.isolation ?? isolation
    // NOTE:
    // `Observations.Iterator.next(isolation:)` does not rebind `emit` closure isolation.
    // If the projected closure lost actor metadata (e.g. key path getter composition),
    // native Observations can evaluate it off-actor and trip dynamic isolation checks.
    // Legacy path can still execute under `resolvedIsolation`, so bridge there.
    let requiresLegacyIsolationBridge = resolvedIsolation != nil && value.isolation == nil

    let observeOwnerValue: @isolated(any) @Sendable () -> OwnerValueEmission<Value> = {
        guard let owner = WeakOwnerRegistry.owner(token: ownerToken) as? Owner else {
            return .ownerGone
        }
        switch ObservationsCompatLegacy.legacyEvaluateObservedOwnerValue(owner: owner, value: value) {
        case .ownerGone:
            return .ownerGone
        case .value(let observedValue):
            return .value(observedValue)
        }
    }

    switch resolveBackend(options: options) {
    case .native:
        if #available(iOS 26.0, macOS 26.0, *),
           !requiresLegacyIsolationBridge {
            await forEachNativeEmission(
                observeOwnerValue,
                isolation: resolvedIsolation,
                consume: consume
            )
            return
        }
        fallthrough
    case .legacy:
        let stream = makeLegacyObservationStream(
            observeOwnerValue,
            isDuplicate: nil,
            isolation: resolvedIsolation
        )
        for await emission in stream {
            guard !Task.isCancelled else {
                break
            }
            guard await consume(emission) else {
                break
            }
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
private func forEachNativeEmission<Value: Sendable>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> OwnerValueEmission<Value>,
    isolation: (any Actor)?,
    consume: @escaping @Sendable (OwnerValueEmission<Value>) async -> Bool
) async {
    await drainNativeOwnerValueEmissions(
        observe: observe,
        isolation: isolation,
        consume: consume
    )
}

@available(iOS 26.0, macOS 26.0, *)
private func drainNativeOwnerValueEmissions<Value: Sendable>(
    observe: @escaping @isolated(any) @Sendable () -> OwnerValueEmission<Value>,
    isolation: isolated (any Actor)?,
    consume: @escaping @Sendable (OwnerValueEmission<Value>) async -> Bool
) async {
    let observations = Observations(observe)
    var iterator = observations.makeAsyncIterator()

    while let value = await iterator.next(isolation: isolation) {
        guard !Task.isCancelled else {
            break
        }
        guard await consume(value) else {
            break
        }
    }
}
