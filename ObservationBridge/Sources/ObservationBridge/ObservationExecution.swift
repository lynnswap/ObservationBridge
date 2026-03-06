import AsyncAlgorithms
import Observation
import Synchronization
internal import _ObservationBridgeLegacy

private enum OwnerValueEmission<Value> {
    case value(Value)
    case ownerGone
}

extension OwnerValueEmission: Sendable where Value: Sendable {}

private struct ObservedValueChannel<Value: Sendable>: Sendable {
    let channel: AsyncChannel<Value>
    let producerTask: Task<Void, Never>
}

private struct ObserveTaskExecutionState: Sendable {
    var activeOperationTask: Task<Void, Never>? = nil
    var activeOperationCompletion: AsyncStream<Void>.Continuation? = nil
    var activeOperationID: UInt64? = nil
    var nextOperationID: UInt64 = 0
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

private struct DuplicateEmissionStateNonSendable<Value> {
    private enum Previous {
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

final class _UncheckedSendableValueBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
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
        defer {
            WeakOwnerRegistry.removeToken(ownerToken)
        }

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

    OwnerCancellationRegistry.register(handle.box, owner: owner)
    return handle
}

func observeImplNonSendable<Owner: AnyObject, Value>(
    owner: Owner,
    options: ObservationOptions,
    duplicateFilter: (@Sendable (Value, Value) -> Bool)?,
    debounce: ObservationDebounce?,
    debounceClock: any Clock<Duration>,
    isolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending _UncheckedSendableValueBox<Value>) async -> Void
) -> ObservationHandle {
    _ = options

    let ownerToken = WeakOwnerRegistry.createToken(owner: owner)
    let monitorTask = Task {
        defer {
            WeakOwnerRegistry.removeToken(ownerToken)
        }

        let observedValues = makeObservedValueStreamNonSendable(
            ownerToken: ownerToken,
            isolation: isolation,
            of: value
        )

        var duplicateState = DuplicateEmissionStateNonSendable(isDuplicate: duplicateFilter)

        if let debounce {
            let debouncedValues = makeDebouncedValueStreamNonSendable(
                observedValues,
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
                await onChange(_UncheckedSendableValueBox(observedValue))
            }
        } else {
            for await observedValue in observedValues {
                guard !Task.isCancelled else {
                    break
                }
                guard duplicateState.shouldEmit(observedValue) else {
                    continue
                }
                await onChange(_UncheckedSendableValueBox(observedValue))
            }
        }
    }

    let handle = ObservationHandle {
        monitorTask.cancel()
    }
    handle.box.addCancellationHandler {
        WeakOwnerRegistry.removeToken(ownerToken)
    }

    OwnerCancellationRegistry.register(handle.box, owner: owner)
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
    let observeTaskState = Mutex(ObserveTaskExecutionState())
    let operationChannel = AsyncChannel<Value>()

    let shutdownObserveTaskExecution: @Sendable () -> Void = {
        let activeOperation = observeTaskState.withLock { state -> (task: Task<Void, Never>?, completion: AsyncStream<Void>.Continuation?) in
            guard !state.isCancelled else {
                return (nil, nil)
            }

            state.isCancelled = true
            state.activeOperationID = nil
            let activeTask = state.activeOperationTask
            state.activeOperationTask = nil
            let activeCompletion = state.activeOperationCompletion
            state.activeOperationCompletion = nil
            return (activeTask, activeCompletion)
        }

        activeOperation.task?.cancel()
        activeOperation.completion?.finish()
        operationChannel.finish()
    }

    let runObservedTask: @Sendable (Value) async -> Bool = { observedValue in
        let (completionStream, completionContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let startedOperation = observeTaskState.withLock { state -> (id: UInt64, task: Task<Void, Never>)? in
            guard !state.isCancelled else {
                return nil
            }

            let operationID = state.nextOperationID
            state.nextOperationID &+= 1
            let operationTask = Task {
                await task(observedValue)
                completionContinuation.finish()
            }
            state.activeOperationID = operationID
            state.activeOperationTask = operationTask
            state.activeOperationCompletion = completionContinuation
            return (operationID, operationTask)
        }

        guard let startedOperation else {
            completionContinuation.finish()
            return false
        }

        await withTaskCancellationHandler {
            var iterator = completionStream.makeAsyncIterator()
            _ = await iterator.next()
        } onCancel: {
            completionContinuation.finish()
            startedOperation.task.cancel()
        }

        return observeTaskState.withLock { state in
            if state.activeOperationID == startedOperation.id {
                state.activeOperationTask = nil
                state.activeOperationID = nil
                state.activeOperationCompletion = nil
            }
            return !state.isCancelled
        }
    }

    let drainTask = Task {
        for await observedValue in operationChannel {
            guard !Task.isCancelled else {
                break
            }
            guard await runObservedTask(observedValue) else {
                break
            }
        }

        let remainingTask: Task<Void, Never>? = observeTaskState.withLock { state -> Task<Void, Never>? in
            let remainingTask = state.activeOperationTask
            state.activeOperationTask = nil
            state.activeOperationID = nil
            state.activeOperationCompletion = nil
            return remainingTask
        }
        remainingTask?.cancel()
    }

    let monitorTask = Task {
        defer {
            WeakOwnerRegistry.removeToken(ownerToken)
        }

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
                await operationChannel.send(observedValue)
            }
        } else {
            for await observedValue in observedValues.channel {
                guard !Task.isCancelled else {
                    break
                }
                guard duplicateState.shouldEmit(observedValue) else {
                    continue
                }
                await operationChannel.send(observedValue)
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

    OwnerCancellationRegistry.register(handle.box, owner: owner)
    return handle
}

func observeTaskImplNonSendable<Owner: AnyObject, Value>(
    owner: Owner,
    options: ObservationOptions,
    duplicateFilter: (@Sendable (Value, Value) -> Bool)?,
    debounce: ObservationDebounce?,
    debounceClock: any Clock<Duration>,
    isolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    @_inheritActorContext task: @escaping @isolated(any) @Sendable (sending _UncheckedSendableValueBox<Value>) async -> Void
) -> ObservationHandle {
    _ = options

    let ownerToken = WeakOwnerRegistry.createToken(owner: owner)
    let observeTaskState = Mutex(ObserveTaskExecutionState())
    let operationChannel = AsyncChannel<_UncheckedSendableValueBox<Value>>()

    let shutdownObserveTaskExecution: @Sendable () -> Void = {
        let activeOperation = observeTaskState.withLock { state -> (task: Task<Void, Never>?, completion: AsyncStream<Void>.Continuation?) in
            guard !state.isCancelled else {
                return (nil, nil)
            }

            state.isCancelled = true
            state.activeOperationID = nil
            let activeTask = state.activeOperationTask
            state.activeOperationTask = nil
            let activeCompletion = state.activeOperationCompletion
            state.activeOperationCompletion = nil
            return (activeTask, activeCompletion)
        }

        activeOperation.task?.cancel()
        activeOperation.completion?.finish()
        operationChannel.finish()
    }

    let runObservedTask: @Sendable (sending _UncheckedSendableValueBox<Value>) async -> Bool = { observedValue in
        let (completionStream, completionContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let startedOperation = observeTaskState.withLock { state -> (id: UInt64, task: Task<Void, Never>)? in
            guard !state.isCancelled else {
                return nil
            }

            let operationID = state.nextOperationID
            state.nextOperationID &+= 1
            let operationTask = Task {
                await task(observedValue)
                completionContinuation.finish()
            }
            state.activeOperationID = operationID
            state.activeOperationTask = operationTask
            state.activeOperationCompletion = completionContinuation
            return (operationID, operationTask)
        }

        guard let startedOperation else {
            completionContinuation.finish()
            return false
        }

        await withTaskCancellationHandler {
            var iterator = completionStream.makeAsyncIterator()
            _ = await iterator.next()
        } onCancel: {
            completionContinuation.finish()
            startedOperation.task.cancel()
        }

        return observeTaskState.withLock { state in
            if state.activeOperationID == startedOperation.id {
                state.activeOperationTask = nil
                state.activeOperationID = nil
                state.activeOperationCompletion = nil
            }
            return !state.isCancelled
        }
    }

    let drainTask = Task {
        for await observedValue in operationChannel {
            guard !Task.isCancelled else {
                break
            }
            guard await runObservedTask(observedValue) else {
                break
            }
        }

        let remainingTask: Task<Void, Never>? = observeTaskState.withLock { state -> Task<Void, Never>? in
            let remainingTask = state.activeOperationTask
            state.activeOperationTask = nil
            state.activeOperationID = nil
            state.activeOperationCompletion = nil
            return remainingTask
        }
        remainingTask?.cancel()
    }

    let monitorTask = Task {
        defer {
            WeakOwnerRegistry.removeToken(ownerToken)
        }

        let observedValues = makeObservedValueStreamNonSendable(
            ownerToken: ownerToken,
            isolation: isolation,
            of: value
        )

        var duplicateState = DuplicateEmissionStateNonSendable(isDuplicate: duplicateFilter)

        if let debounce {
            let debouncedValues = makeDebouncedValueStreamNonSendable(
                observedValues,
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
                await operationChannel.send(_UncheckedSendableValueBox(observedValue))
            }
        } else {
            for await observedValue in observedValues {
                guard !Task.isCancelled else {
                    break
                }
                guard duplicateState.shouldEmit(observedValue) else {
                    continue
                }
                await operationChannel.send(_UncheckedSendableValueBox(observedValue))
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

    OwnerCancellationRegistry.register(handle.box, owner: owner)
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

private func makeObservedValueStreamNonSendable<Owner: AnyObject, Value>(
    ownerToken: UInt64,
    isolation: (any Actor)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value
) -> AsyncStream<Value> {
    let resolveOwner = WeakOwnerRegistry.ownerAccessor(token: ownerToken)
    let resolvedIsolation = value.isolation ?? isolation
    let observeOwnerValue: @isolated(any) @Sendable () -> OwnerValueEmission<_UncheckedSendableValueBox<Value>> = {
        switch _ObservationBridgeLegacy.legacyEvaluateObservedOwnerValue(
            owner: resolveOwner() as? Owner,
            value: value,
            map: _UncheckedSendableValueBox.init
        ) {
        case .ownerGone:
            return .ownerGone
        case .value(let observedValue):
            return .value(observedValue)
        }
    }

    let stream = makeLegacyObservationStream(
        observeOwnerValue,
        isDuplicate: nil,
        isolation: resolvedIsolation
    )
    return AsyncStream { continuation in
        let task = Task {
            for await emission in stream {
                guard !Task.isCancelled else {
                    break
                }

                switch emission {
                case .ownerGone:
                    continuation.finish()
                    return
                case .value(let observedValue):
                    continuation.yield(observedValue.value)
                }
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
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

func makeDebouncedValueStreamNonSendable<Element>(
    _ source: AsyncStream<Element>,
    debounce: ObservationDebounce,
    debounceClock: any Clock<Duration>
) -> AsyncStream<Element> {
    makeDebouncedValueStreamNonSendable(
        source,
        debounce: debounce,
        clock: debounceClock
    )
}

func makeDebouncedValueStreamNonSendable<Element, C: Clock<Duration>>(
    _ source: AsyncStream<Element>,
    debounce: ObservationDebounce,
    clock: C
) -> AsyncStream<Element> {
    let boxedSource = makeUncheckedSendableBoxedStream(source)
    let debouncedBoxes = makeDebouncedValueStream(
        boxedSource,
        debounce: debounce,
        clock: clock
    )
    return makeUncheckedSendableUnboxedStream(debouncedBoxes)
}

private func makeUncheckedSendableBoxedStream<Element>(
    _ source: AsyncStream<Element>
) -> AsyncStream<_UncheckedSendableValueBox<Element>> {
    let sourceBox = _UncheckedSendableValueBox(source)
    return AsyncStream { continuation in
        let task = Task {
            for await nextValue in sourceBox.value {
                guard !Task.isCancelled else {
                    break
                }
                continuation.yield(_UncheckedSendableValueBox(nextValue))
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}

private func makeUncheckedSendableUnboxedStream<Element>(
    _ source: AsyncStream<_UncheckedSendableValueBox<Element>>
) -> AsyncStream<Element> {
    AsyncStream { continuation in
        let task = Task {
            for await boxedValue in source {
                guard !Task.isCancelled else {
                    break
                }
                continuation.yield(boxedValue.value)
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            task.cancel()
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
    let resolveOwner = WeakOwnerRegistry.ownerAccessor(token: ownerToken)
    let resolvedIsolation = value.isolation ?? isolation
    // NOTE:
    // `Observations.Iterator.next(isolation:)` does not rebind `emit` closure isolation.
    // If the projected closure lost actor metadata (e.g. key path getter composition),
    // native Observations can evaluate it off-actor and trip dynamic isolation checks.
    // Legacy path can still execute under `resolvedIsolation`, so bridge there.
    let requiresLegacyIsolationBridge = resolvedIsolation != nil && value.isolation == nil

    let observeOwnerValue: @isolated(any) @Sendable () -> OwnerValueEmission<Value> = {
        guard let owner = resolveOwner() as? Owner else {
            return .ownerGone
        }
        switch _ObservationBridgeLegacy.legacyEvaluateObservedOwnerValue(owner: owner, value: value) {
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
        await forEachLegacyObservationEmission(
            observeOwnerValue,
            isDuplicate: nil,
            isolation: resolvedIsolation
        ) { emission in
            guard !Task.isCancelled else {
                return false
            }
            return await consume(emission)
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
