import Observation
import Synchronization

struct ObservationScopeID: Hashable, Sendable {
    let fileID: String
    let line: UInt
    let column: UInt
}

struct ObservationScopeDescriptor: Equatable, Sendable {
    let ownerID: ObjectIdentifier
    let options: ObservationOptions
    let observationIsolationID: ObjectIdentifier?
    let callbackIsolationID: ObjectIdentifier?

    init(
        owner: AnyObject,
        options: ObservationOptions,
        observationIsolation: (any Actor)?,
        callbackIsolation: (any Actor)?
    ) {
        self.ownerID = ObjectIdentifier(owner)
        self.options = options
        self.observationIsolationID = observationScopeActorID(observationIsolation)
        self.callbackIsolationID = observationScopeActorID(callbackIsolation)
    }
}

func observationScopeActorID(_ actor: (any Actor)?) -> ObjectIdentifier? {
    actor.map { ObjectIdentifier($0 as AnyObject) }
}

typealias ObservationScopeStartOperation = @Sendable (isolated (any Actor)?) -> Task<Void, Never>?

enum InitialLegacyScopedObservationResult: Sendable {
    case waitingForChange(ObservationEvent.Kind)
    case finished
}

protocol ObservationScopeCallback: Sendable {
    func call(event: ObservationEvent, owner: AnyObject) -> Bool
}

// Keep the `Owner` metatype out of slot/task/onChange captures. Swift does not treat
// unconstrained class metatypes as Sendable, so the typed cast is confined to this invoker.
struct TypedObservationScopeCallback<Owner: AnyObject>: ObservationScopeCallback, @unchecked Sendable {
    private let callback: @isolated(any) @Sendable (ObservationEvent, Owner) -> Void

    init(_ callback: @escaping @isolated(any) @Sendable (ObservationEvent, Owner) -> Void) {
        self.callback = callback
    }

    func call(event: ObservationEvent, owner: AnyObject) -> Bool {
        guard let owner = owner as? Owner else {
            return false
        }

        callObservationCallback(callback, event, owner)
        return true
    }
}

// Shared by registrar callbacks, observation tasks, and explicit scope cancellation.
// Mutable lifecycle state is protected by `state`; the typed owner callback is erased above.
final class ObservationScopeSlot: @unchecked Sendable {
    private struct State {
        var isCancelled = false
        var dirty = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var task: Task<Void, Never>?
        var startOperation: ObservationScopeStartOperation?
        var callback: (any ObservationScopeCallback)?
    }

    private struct Cancellation {
        var shouldCancel: Bool
        var waiters: [CheckedContinuation<Void, Never>]
        var task: Task<Void, Never>?
    }

    private enum WaitSetup {
        case changed
        case terminated
        case wait
    }

    let descriptor: ObservationScopeDescriptor
    let ownerToken: UInt64
    let delivery: ObservationDelivery
    private let state: Mutex<State>

    var isActive: Bool {
        state.withLock { state in
            !state.isCancelled
        }
    }

    init(
        descriptor: ObservationScopeDescriptor,
        ownerToken: UInt64,
        delivery: ObservationDelivery,
        callback: any ObservationScopeCallback
    ) {
        self.descriptor = descriptor
        self.ownerToken = ownerToken
        self.delivery = delivery
        state = Mutex(State(callback: callback))
    }

    deinit {
        cancel()
    }

    func setStartOperation(_ operation: @escaping ObservationScopeStartOperation) {
        state.withLock { state in
            guard !state.isCancelled else {
                return
            }

            state.startOperation = operation
        }
    }

    func call(event: ObservationEvent, owner: AnyObject) -> Bool {
        guard let callback = state.withLock({ state in state.callback }) else {
            return false
        }

        return callback.call(event: event, owner: owner)
    }

    func reserveStart() -> (@Sendable () -> Void)? {
        guard let operation = takeStartOperation() else {
            return nil
        }

        guard isActive else {
            return nil
        }

        return makeReservedStartOperation(slot: self, operation: operation)
    }

    func start(isolation: isolated (any Actor)?) {
        guard let operation = takeStartOperation() else {
            return
        }

        guard isActive else {
            return
        }

        runStartOperation(operation, isolation: isolation)
    }

    func start() {
        start(isolation: nil)
    }

    func runReservedStart(_ operation: @escaping ObservationScopeStartOperation) {
        runStartOperation(operation, isolation: nil)
    }

    func cancel() {
        let cancellation = state.withLock { state -> Cancellation in
            guard !state.isCancelled else {
                return Cancellation(shouldCancel: false, waiters: [], task: nil)
            }

            state.isCancelled = true
            state.dirty = false
            state.startOperation = nil
            state.callback = nil
            let waiters = state.waiters
            state.waiters.removeAll(keepingCapacity: true)
            let task = state.task
            state.task = nil
            return Cancellation(shouldCancel: true, waiters: waiters, task: task)
        }

        guard cancellation.shouldCancel else {
            return
        }

        WeakOwnerRegistry.removeToken(ownerToken)
        for waiter in cancellation.waiters {
            waiter.resume()
        }
        delivery.finish()
        cancellation.task?.cancel()
    }

    func emitChange() {
        let continuations = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.isCancelled else {
                return []
            }

            if state.waiters.isEmpty {
                state.dirty = true
                return []
            }

            let continuations = state.waiters
            state.waiters.removeAll(keepingCapacity: true)
            return continuations
        }

        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitForChange() async -> Bool {
        let setup = state.withLock { state -> WaitSetup in
            if state.isCancelled {
                return .terminated
            }
            if state.dirty {
                state.dirty = false
                return .changed
            }
            return .wait
        }

        switch setup {
        case .changed:
            return true
        case .terminated:
            return false
        case .wait:
            break
        }

        await withCheckedContinuation { continuation in
            let immediate = state.withLock { state -> CheckedContinuation<Void, Never>? in
                if state.isCancelled {
                    return continuation
                }
                if state.dirty {
                    state.dirty = false
                    return continuation
                }
                state.waiters.append(continuation)
                return nil
            }
            immediate?.resume()
        }

        return isActive
    }

    private func takeStartOperation() -> ObservationScopeStartOperation? {
        state.withLock { state in
            let operation = state.startOperation
            state.startOperation = nil
            return operation
        }
    }

    private func runStartOperation(
        _ operation: ObservationScopeStartOperation,
        isolation: isolated (any Actor)?
    ) {
        guard isActive else {
            return
        }

        if let task = operation(isolation) {
            replaceTask(with: task)
        }
    }

    private func replaceTask(with newTask: Task<Void, Never>) {
        let taskToCancel = state.withLock { state -> Task<Void, Never>? in
            guard !state.isCancelled else {
                return newTask
            }

            let oldTask = state.task
            state.task = newTask
            return oldTask
        }
        taskToCancel?.cancel()
    }
}

private func makeReservedStartOperation(
    slot: ObservationScopeSlot,
    operation: @escaping ObservationScopeStartOperation
) -> @Sendable () -> Void {
    { [weak slot] in
        slot?.runReservedStart(operation)
    }
}

@inline(__always)
private func callObservationCallback<Owner: AnyObject>(
    _ callback: @escaping @isolated(any) @Sendable (ObservationEvent, Owner) -> Void,
    _ event: ObservationEvent,
    _ owner: Owner
) {
    let unisolated = unsafe unsafeBitCast(
        callback,
        to: (@Sendable (ObservationEvent, Owner) -> Void).self
    )
    unisolated(event, owner)
}
