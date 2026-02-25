import Observation
import ObservationsCompatLegacy
import Synchronization

private enum OwnerValueEmission<Value: Sendable>: Sendable {
    case value(Value)
    case ownerGone
}

private struct ObserveTaskExecutionState<Value: Sendable>: Sendable {
    var activeOperationTask: Task<Void, Never>? = nil
    var activeOperationID: UInt64? = nil
    var nextOperationID: UInt64 = 0
    var pendingLatestValue: Value? = nil
    var isCancelled = false
}

func observeImpl<Owner: AnyObject, Value: Sendable>(
    owner: Owner,
    backend: ObservationsCompatBackend,
    retention: ObservationRetention,
    duplicateFilter: (@Sendable (Value, Value) -> Bool)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    onChange: @escaping @Sendable (Value) -> Void
) -> ObservationHandle {
    let ownerToken = WeakOwnerRegistry.createToken(owner: owner)
    let monitorTask = Task {
        await forEachOwnerValueEmission(
            ownerToken: ownerToken,
            backend: backend,
            duplicateFilter: duplicateFilter,
            of: value
        ) { emission in
            switch emission {
            case .ownerGone:
                return false
            case .value(let observedValue):
                onChange(observedValue)
                return true
            }
        }
    }

    let handle = ObservationHandle {
        monitorTask.cancel()
    }
    handle.box.addCancellationHandler {
        WeakOwnerRegistry.removeToken(ownerToken)
    }

    return applyRetention(handle, owner: owner, retention: retention)
}

func observeTaskImpl<Owner: AnyObject, Value: Sendable>(
    owner: Owner,
    backend: ObservationsCompatBackend,
    retention: ObservationRetention,
    duplicateFilter: (@Sendable (Value, Value) -> Bool)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    task: @escaping @Sendable (Value) async -> Void
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
        await forEachOwnerValueEmission(
            ownerToken: ownerToken,
            backend: backend,
            duplicateFilter: duplicateFilter,
            of: value
        ) { emission in
            let observedValue: Value
            switch emission {
            case .ownerGone:
                return false
            case .value(let value):
                observedValue = value
            }

            return enqueueLatestValue(observedValue)
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

    return applyRetention(handle, owner: owner, retention: retention)
}

private func forEachOwnerValueEmission<Owner: AnyObject, Value: Sendable>(
    ownerToken: UInt64,
    backend: ObservationsCompatBackend,
    duplicateFilter: (@Sendable (Value, Value) -> Bool)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value,
    consume: @escaping @Sendable (OwnerValueEmission<Value>) async -> Bool
) async {
    let optionalDuplicateFilter: (@Sendable (OwnerValueEmission<Value>, OwnerValueEmission<Value>) -> Bool)? = duplicateFilter.map { duplicateFilter in
        { @Sendable (lhs: OwnerValueEmission<Value>, rhs: OwnerValueEmission<Value>) -> Bool in
            switch (lhs, rhs) {
            case let (.value(lhs), .value(rhs)):
                return duplicateFilter(lhs, rhs)
            case (.ownerGone, .ownerGone):
                return true
            default:
                return false
            }
        }
    }

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

    switch resolveBackend(backend) {
    case .native:
        if #available(iOS 26.0, macOS 26.0, *) {
            await forEachNativeEmission(
                observeOwnerValue,
                isDuplicate: optionalDuplicateFilter,
                consume: consume
            )
            return
        }
        fallthrough
    case .legacy, .automatic:
        let stream = makeLegacyObservationStream(
            observeOwnerValue,
            isDuplicate: optionalDuplicateFilter
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
    isDuplicate: (@Sendable (OwnerValueEmission<Value>, OwnerValueEmission<Value>) -> Bool)?,
    consume: @escaping @Sendable (OwnerValueEmission<Value>) async -> Bool
) async {
    var previousValue: OwnerValueEmission<Value>?
    var hasPreviousValue = false
    let observations = Observations(observe)

    for await value in observations {
        guard !Task.isCancelled else {
            break
        }

        if hasPreviousValue, let previousValue, let isDuplicate, isDuplicate(previousValue, value) {
            continue
        }

        hasPreviousValue = true
        previousValue = value
        guard await consume(value) else {
            break
        }
    }
}

private func applyRetention(
    _ handle: ObservationHandle,
    owner: AnyObject,
    retention: ObservationRetention
) -> ObservationHandle {
    guard retention == .automatic else {
        return handle
    }

    AutomaticRetentionRegistry.retain(handle.box, owner: owner)

    return handle
}
