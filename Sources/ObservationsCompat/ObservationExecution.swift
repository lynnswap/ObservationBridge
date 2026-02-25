import ObservationsCompatLegacy
import Synchronization

private enum OwnerValueEmission<Value: Sendable>: Sendable {
    case value(Value)
    case ownerGone
}

private struct ObserveTaskExecutionState: Sendable {
    var activeTask: Task<Void, Never>? = nil
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
    let stream = makeOwnerValueStream(
        ownerToken: ownerToken,
        backend: backend,
        duplicateFilter: duplicateFilter,
        of: value
    )

    let monitorTask = Task {
        observationLoop: for await emission in stream {
            if Task.isCancelled {
                break
            }

            switch emission {
            case .ownerGone:
                break observationLoop
            case .value(let observedValue):
                onChange(observedValue)
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
    let stream = makeOwnerValueStream(
        ownerToken: ownerToken,
        backend: backend,
        duplicateFilter: duplicateFilter,
        of: value
    )
    let observeTaskState = Mutex(ObserveTaskExecutionState())

    let monitorTask = Task {
        observationLoop: for await emission in stream {
            if Task.isCancelled {
                break
            }

            let observedValue: Value
            switch emission {
            case .ownerGone:
                break observationLoop
            case .value(let value):
                observedValue = value
            }

            let transition = observeTaskState.withLock { state in
                if state.isCancelled {
                    return (previous: Task<Void, Never>?(nil), installed: false)
                }

                let previousTask = state.activeTask
                let nextTask = Task {
                    await task(observedValue)
                }
                state.activeTask = nextTask
                return (previous: previousTask, installed: true)
            }

            guard transition.installed else {
                break observationLoop
            }
            transition.previous?.cancel()
        }

        let remainingTask = observeTaskState.withLock { state in
            state.isCancelled = true
            let remainingTask = state.activeTask
            state.activeTask = nil
            return remainingTask
        }
        remainingTask?.cancel()
    }

    let handle = ObservationHandle {
        monitorTask.cancel()

        let remainingTask = observeTaskState.withLock { state in
            state.isCancelled = true
            let remainingTask = state.activeTask
            state.activeTask = nil
            return remainingTask
        }
        remainingTask?.cancel()
    }
    handle.box.addCancellationHandler {
        WeakOwnerRegistry.removeToken(ownerToken)
    }

    return applyRetention(handle, owner: owner, retention: retention)
}

private func makeOwnerValueStream<Owner: AnyObject, Value: Sendable>(
    ownerToken: UInt64,
    backend: ObservationsCompatBackend,
    duplicateFilter: (@Sendable (Value, Value) -> Bool)?,
    @_inheritActorContext of value: @escaping @isolated(any) @Sendable (Owner) -> Value
) -> AsyncStream<OwnerValueEmission<Value>> {
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

    return makeObservationStream(backend: backend, observeOwnerValue, isDuplicate: optionalDuplicateFilter)
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
