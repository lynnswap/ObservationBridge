import Synchronization

public struct ObservationHandle: Sendable {
    let box: ObservationHandleBox

    init(onCancel: @escaping @Sendable () -> Void) {
        box = ObservationHandleBox(handlers: [onCancel])
    }

    public func cancel() {
        box.cancel()
    }
}

final class ObservationHandleBox: Sendable {
    private struct State {
        var isCancelled = false
        var handlers: [@Sendable () -> Void]
    }

    private let state: Mutex<State>

    init(handlers: [@Sendable () -> Void]) {
        state = Mutex(State(handlers: handlers))
    }

    func addCancellationHandler(_ handler: @escaping @Sendable () -> Void) {
        let shouldRunImmediately = state.withLock { state in
            if state.isCancelled {
                return true
            }
            state.handlers.append(handler)
            return false
        }

        if shouldRunImmediately {
            handler()
        }
    }

    func cancel() {
        let handlersToRun = state.withLock { state in
            if state.isCancelled {
                return [@Sendable () -> Void]()
            }

            state.isCancelled = true
            let handlers = state.handlers
            state.handlers = []
            return handlers
        }

        for handler in handlersToRun {
            handler()
        }
    }

    deinit {
        cancel()
    }
}
