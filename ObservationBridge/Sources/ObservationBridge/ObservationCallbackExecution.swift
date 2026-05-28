import Synchronization

@discardableResult
func makeObservationTask<Success: Sendable>(
    @_inheritActorContext operation: @escaping @isolated(any) @Sendable () async -> Success
) -> Task<Success, Never> {
    if #available(iOS 26.0, macOS 26.0, *) {
        return Task.immediate(operation: operation)
    }
    return Task(operation: operation)
}

final class ObservationExecutionLifetime: Sendable {
    private struct State {
        var isCancelled = false
        var handlers: [@Sendable () -> Void] = []
    }

    private let state = Mutex(State())

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
}

final class ObservationTaskBox: Sendable {
    private struct State {
        var isFinished = false
        var task: Task<Void, Never>?
    }

    private struct Replacement {
        var tasksToCancel: [Task<Void, Never>]
        var installed: Bool
    }

    private let state = Mutex(State())

    @discardableResult
    func replace(with newTask: Task<Void, Never>?) -> Bool {
        let replacement = state.withLock { state in
            if state.isFinished {
                let oldTask = state.task
                state.task = nil
                return Replacement(
                    tasksToCancel: [oldTask, newTask].compactMap { $0 },
                    installed: false
                )
            }

            let oldTask = state.task
            state.task = newTask
            return Replacement(
                tasksToCancel: [oldTask].compactMap { $0 },
                installed: true
            )
        }
        for task in replacement.tasksToCancel {
            task.cancel()
        }
        return replacement.installed
    }

    func cancel() {
        let taskToCancel = state.withLock { state in
            let task = state.task
            state.task = nil
            return task
        }
        taskToCancel?.cancel()
    }

    func finish() {
        let taskToCancel = state.withLock { state in
            if state.isFinished {
                return nil as Task<Void, Never>?
            }

            state.isFinished = true
            let task = state.task
            state.task = nil
            return task
        }
        taskToCancel?.cancel()
    }
}

struct _UncheckedSendableValueBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
