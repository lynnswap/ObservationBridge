import Synchronization

final class ObservationOwnerCancellationStore: Sendable {
    private struct State {
        var ownerDeinitCancellationHandlers: [ObjectIdentifier: @Sendable () -> Void] = [:]
    }

    private let state = Mutex(State())

    func insertCancellationHandler(
        id: ObjectIdentifier,
        _ handler: @escaping @Sendable () -> Void
    ) {
        state.withLock { state in
            state.ownerDeinitCancellationHandlers[id] = handler
        }
    }

    func remove(id: ObjectIdentifier) {
        state.withLock { state in
            state.ownerDeinitCancellationHandlers[id] = nil
        }
    }

    deinit {
        let handlersToRun = state.withLock { state in
            let handlers = Array(state.ownerDeinitCancellationHandlers.values)
            state.ownerDeinitCancellationHandlers.removeAll(keepingCapacity: false)
            return handlers
        }

        for handler in handlersToRun {
            handler()
        }
    }
}
