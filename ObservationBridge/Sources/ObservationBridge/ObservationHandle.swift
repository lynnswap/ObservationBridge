import Synchronization

public struct ObservationHandle: Sendable, Hashable {
    let box: ObservationHandleBox

    init(onCancel: @escaping @Sendable () -> Void) {
        box = ObservationHandleBox(handlers: [onCancel])
    }

    public static func == (lhs: ObservationHandle, rhs: ObservationHandle) -> Bool {
        ObjectIdentifier(lhs.box) == ObjectIdentifier(rhs.box)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(box))
    }

    public func cancel() {
        box.cancel()
    }

    public func store(in set: inout Set<ObservationHandle>) {
        set.insert(self)
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
