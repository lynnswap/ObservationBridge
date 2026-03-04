import Synchronization

final class ObservationLifetimeStore: Sendable {
    private struct State {
        var strongBoxes: [ObjectIdentifier: ObservationHandleBox] = [:]
        var ownerDeinitCancellationHandlers: [ObjectIdentifier: @Sendable () -> Void] = [:]
    }

    private let state = Mutex(State())

    func insert(_ box: ObservationHandleBox, id: ObjectIdentifier) {
        state.withLock { state in
            state.strongBoxes[id] = box
            state.ownerDeinitCancellationHandlers[id] = { [weak box] in
                box?.cancel()
            }
        }
    }

    func disableStrongRetention(id: ObjectIdentifier) {
        state.withLock { state in
            state.strongBoxes[id] = nil
        }
    }

    func remove(id: ObjectIdentifier) {
        state.withLock { state in
            state.strongBoxes[id] = nil
            state.ownerDeinitCancellationHandlers[id] = nil
        }
    }

    deinit {
        let handlersToRun = state.withLock { state in
            let handlers = Array(state.ownerDeinitCancellationHandlers.values)
            state.ownerDeinitCancellationHandlers.removeAll(keepingCapacity: false)
            state.strongBoxes.removeAll(keepingCapacity: false)
            return handlers
        }

        for handler in handlersToRun {
            handler()
        }
    }
}
