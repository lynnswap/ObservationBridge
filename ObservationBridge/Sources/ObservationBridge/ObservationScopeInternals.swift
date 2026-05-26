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

protocol ObservationScopeSlotProtocol: AnyObject, Sendable {
    var descriptor: ObservationScopeDescriptor { get }
    var isActive: Bool { get }

    func reserveStart() -> (@Sendable () -> Void)?
    func start(isolation: isolated (any Actor)?)
    func cancel()
}

protocol ObservationScopeCallbackClearing: Sendable {
    func clear()
}

final class ObservationScopeSlot<Owner: AnyObject>: ObservationScopeSlotProtocol, @unchecked Sendable {
    let descriptor: ObservationScopeDescriptor
    let callbackBox: ObservationScopeCallbackBox<Owner>
    let handle: ObservationHandle
    private let state: ScopedObservationState
    private let taskBox: ObservationTaskBox
    private let startOperation: Mutex<ObservationScopeStartOperation?>

    var isActive: Bool {
        !state.isTerminated
    }

    init(
        descriptor: ObservationScopeDescriptor,
        state: ScopedObservationState,
        handle: ObservationHandle,
        taskBox: ObservationTaskBox,
        callbackBox: ObservationScopeCallbackBox<Owner>,
        startOperation: @escaping ObservationScopeStartOperation
    ) {
        self.descriptor = descriptor
        self.state = state
        self.handle = handle
        self.taskBox = taskBox
        self.callbackBox = callbackBox
        self.startOperation = Mutex(startOperation)

        handle.addCancellationHandler { [callbackBox] in
            callbackBox.clear()
        }
    }

    func reserveStart() -> (@Sendable () -> Void)? {
        guard let operation = takeStartOperation() else {
            return nil
        }

        guard isActive else {
            return nil
        }

        return { [state, taskBox] in
            guard !state.isTerminated else {
                return
            }

            if let task = operation(nil) {
                taskBox.replace(with: task)
            }
        }
    }

    func start(isolation: isolated (any Actor)?) {
        guard let operation = takeStartOperation() else {
            return
        }

        guard isActive else {
            return
        }

        if let task = operation(isolation) {
            taskBox.replace(with: task)
        }
    }

    func start() {
        start(isolation: nil)
    }

    func cancel() {
        handle.cancel()
    }

    private func takeStartOperation() -> ObservationScopeStartOperation? {
        startOperation.withLock { state in
            let operation = state
            state = nil
            return operation
        }
    }
}

final class ObservationScopeCallbackBox<Owner: AnyObject>: @unchecked Sendable {
    private struct State {
        var callback: @isolated(any) @Sendable (ObservationEvent, Owner) -> Void
    }

    private let state: Mutex<State>

    init(
        _ callback: @escaping @isolated(any) @Sendable (ObservationEvent, Owner) -> Void
    ) {
        state = Mutex(State(callback: callback))
    }

    func snapshot() -> @isolated(any) @Sendable (ObservationEvent, Owner) -> Void {
        state.withLock { state in
            state.callback
        }
    }

    func update(
        _ callback: @escaping @isolated(any) @Sendable (ObservationEvent, Owner) -> Void
    ) {
        state.withLock { state in
            state.callback = callback
        }
    }

    func clear() {
        update { _, _ in }
    }

    func call(event: ObservationEvent, owner: Owner) {
        let callback = snapshot()
        callObservationCallback(callback, event, owner)
    }
}

extension ObservationScopeCallbackBox: ObservationScopeCallbackClearing {}

protocol ObservationScopeAnyValueCallbackBox: Sendable {
    func call(event: ObservationEvent, owner: AnyObject)
}

final class ObservationScopeValueCallbackBox<Owner: AnyObject, Value: Sendable>: ObservationScopeAnyValueCallbackBox, @unchecked Sendable {
    private let callback: @isolated(any) @Sendable (ObservationEvent, Owner) -> Value
    private let values: ObservedValues<Value>

    init(
        callback: @escaping @isolated(any) @Sendable (ObservationEvent, Owner) -> Value,
        values: ObservedValues<Value>
    ) {
        self.callback = callback
        self.values = values
    }

    func call(event: ObservationEvent, owner anyOwner: AnyObject) {
        guard let owner = anyOwner as? Owner else {
            return
        }

        guard values.beginDelivery() else {
            return
        }
        defer {
            values.endDelivery()
        }

        values.record(callObservationValueCallback(callback, event, owner))
    }
}

func makeObservationValueRecordingCallback<Owner: AnyObject>(
    _ callbackBox: any ObservationScopeAnyValueCallbackBox
) -> @isolated(any) @Sendable (ObservationEvent, Owner) -> Void {
    let erasedCallback: @isolated(any) @Sendable (ObservationEvent, AnyObject) -> Void = { event, owner in
        callbackBox.call(event: event, owner: owner)
    }
    return unsafe unsafeBitCast(
        erasedCallback,
        to: (@isolated(any) @Sendable (ObservationEvent, Owner) -> Void).self
    )
}

protocol ScopedObservationRunner: Sendable {
    func run(
        ownerToken: UInt64,
        options: ObservationOptions,
        isolation: (any Actor)?,
        state: ScopedObservationState
    ) async

    func runInitialPass(
        ownerToken: UInt64,
        options: ObservationOptions,
        isolation: isolated (any Actor)?,
        state: ScopedObservationState
    ) -> InitialLegacyScopedObservationResult

    func runAfterInitialPass(
        ownerToken: UInt64,
        options: ObservationOptions,
        isolation: (any Actor)?,
        state: ScopedObservationState,
        nextKind: ObservationEvent.Kind
    ) async
}

final class TypedScopedObservationRunner<Owner: AnyObject & Observable>: ScopedObservationRunner, @unchecked Sendable {
    private let callbackBox: ObservationScopeCallbackBox<Owner>

    init(callbackBox: ObservationScopeCallbackBox<Owner>) {
        self.callbackBox = callbackBox
    }

    func run(
        ownerToken: UInt64,
        options: ObservationOptions,
        isolation: (any Actor)?,
        state: ScopedObservationState
    ) async {
        await runScopedObservationLoop(
            ownerToken: ownerToken,
            options: options,
            isolation: isolation,
            state: state,
            callbackBox: callbackBox
        )
    }

    func runInitialPass(
        ownerToken: UInt64,
        options: ObservationOptions,
        isolation: isolated (any Actor)?,
        state: ScopedObservationState
    ) -> InitialLegacyScopedObservationResult {
        runInitialLegacyScopedObservationPass(
            ownerToken: ownerToken,
            options: options,
            isolation: isolation,
            state: state,
            callbackBox: callbackBox
        )
    }

    func runAfterInitialPass(
        ownerToken: UInt64,
        options: ObservationOptions,
        isolation: (any Actor)?,
        state: ScopedObservationState,
        nextKind: ObservationEvent.Kind
    ) async {
        await runLegacyScopedObservationLoopAfterInitialPass(
            ownerToken: ownerToken,
            options: options,
            isolation: isolation,
            state: state,
            callbackBox: callbackBox,
            nextKind: nextKind
        )
    }
}

final class ScopedObservationState: @unchecked Sendable {
    private struct State {
        var dirty = false
        var terminated = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private enum WaitSetup {
        case changed
        case terminated
        case wait
    }

    private let state = Mutex(State())

    var isTerminated: Bool {
        state.withLock { state in
            state.terminated
        }
    }

    func emitChange() {
        let continuations = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.terminated else {
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

    func terminate() {
        let continuations = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.terminated else {
                return []
            }

            state.terminated = true
            state.dirty = false
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
            if state.terminated {
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
                if state.terminated {
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

        return state.withLock { state in
            !state.terminated
        }
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

@inline(__always)
func callObservationValueCallback<Owner: AnyObject, Value: Sendable>(
    _ callback: @escaping @isolated(any) @Sendable (ObservationEvent, Owner) -> Value,
    _ event: ObservationEvent,
    _ owner: Owner
) -> Value {
    let unisolated = unsafe unsafeBitCast(
        callback,
        to: (@Sendable (ObservationEvent, Owner) -> Value).self
    )
    return unisolated(event, owner)
}
