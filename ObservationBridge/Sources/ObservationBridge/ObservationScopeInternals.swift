import Observation
import Synchronization

#if canImport(_ObservationBridgeBenchmarkSupport)
internal import _ObservationBridgeBenchmarkSupport
#endif

struct ObservationScopeID: Equatable, Sendable {
    let fileID: ObservationScopeFileID
    let line: UInt
    let column: UInt

    init(fileID: StaticString, line: UInt, column: UInt) {
        self.fileID = ObservationScopeFileID(fileID)
        self.line = line
        self.column = column
    }
}

struct ObservationScopeDictionaryID: Hashable, Sendable {
    private let fileID: ObservationScopeFileID
    private let line: UInt
    private let column: UInt
    private let fileFingerprint: UInt64

    init(_ id: ObservationScopeID) {
        fileID = id.fileID
        line = id.line
        column = id.column
        fileFingerprint = id.fileID.fingerprint
    }

    static func == (lhs: ObservationScopeDictionaryID, rhs: ObservationScopeDictionaryID) -> Bool {
        lhs.line == rhs.line
            && lhs.column == rhs.column
            && lhs.fileID == rhs.fileID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(fileID.count)
        hasher.combine(fileFingerprint)
        hasher.combine(line)
        hasher.combine(column)
    }
}

// The pointer comes from a `StaticString` literal and refers to process-lifetime
// read-only storage. Equality still falls back to byte comparison for correctness.
@safe struct ObservationScopeFileID: Equatable, @unchecked Sendable {
    fileprivate let bytes: UnsafePointer<UInt8>
    fileprivate let count: Int

    init(_ value: StaticString) {
        unsafe bytes = value.utf8Start
        count = value.utf8CodeUnitCount
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        if unsafe lhs.bytes == rhs.bytes {
            return true
        }

        for index in 0..<lhs.count {
            if unsafe lhs.bytes[index] != rhs.bytes[index] {
                return false
            }
        }
        return true
    }

    fileprivate var fingerprint: UInt64 {
        var fingerprint: UInt64 = 14_695_981_039_346_656_037
        for index in 0..<count {
            fingerprint ^= UInt64(unsafe bytes[index])
            fingerprint &*= 1_099_511_628_211
        }
        return fingerprint
    }
}

func observationScopeActorID(_ actor: (any Actor)?) -> ObjectIdentifier? {
    actor.map { ObjectIdentifier($0 as AnyObject) }
}

enum InitialScopedObservationResult: Sendable {
    case waitingForChange(ObservationEvent.Kind)
    case finished
}

protocol ObservationScopePipeline: Sendable {
    var appliesInsideTracking: Bool { get }

    func apply(event: borrowing ObservationEvent, owner: AnyObject) -> Bool
    func track(owner: AnyObject) -> Bool
}

private struct ObservationScopeWaiters: @unchecked Sendable {
    private var first: CheckedContinuation<Void, Never>?
    private var additional: [CheckedContinuation<Void, Never>]?

    var isEmpty: Bool {
        first == nil
    }

    mutating func append(_ continuation: CheckedContinuation<Void, Never>) {
        guard first != nil else {
            first = continuation
            return
        }

        if additional == nil {
            additional = []
        }
        additional!.append(continuation)
    }

    mutating func takeAll() -> ObservationScopeWaiterBatch {
        guard let first else {
            return .empty
        }

        self.first = nil
        guard let additional else {
            return .single(first)
        }
        self.additional = nil

        if additional.isEmpty {
            return .single(first)
        }
        return .many(first, additional)
    }
}

private enum ObservationScopeWaiterBatch: @unchecked Sendable {
    case empty
    case single(CheckedContinuation<Void, Never>)
    case many(CheckedContinuation<Void, Never>, [CheckedContinuation<Void, Never>])

    func resumeAll() {
        switch self {
        case .empty:
            return
        case .single(let continuation):
            continuation.resume()
        case .many(let first, let additional):
            first.resume()
            for continuation in additional {
                continuation.resume()
            }
        }
    }
}

// Keep the `Owner` metatype out of slot/task/onChange captures. Swift does not treat
// unconstrained class metatypes as Sendable, so the typed cast is confined to this invoker.
struct TypedObservationScopeImplicitTrackingPipeline<Owner: AnyObject>: ObservationScopePipeline, @unchecked Sendable {
    let appliesInsideTracking = true

    private let applyCallback: @isolated(any) @Sendable (borrowing ObservationEvent, Owner) -> Void

    init(_ applyCallback: @escaping @isolated(any) @Sendable (borrowing ObservationEvent, Owner) -> Void) {
        self.applyCallback = applyCallback
    }

    func apply(event: borrowing ObservationEvent, owner: AnyObject) -> Bool {
        guard let owner = owner as? Owner else {
            return false
        }

        callObservationApply(applyCallback, event, owner)
        return true
    }

    func track(owner _: AnyObject) -> Bool {
        false
    }
}

struct TypedObservationScopeExplicitTrackingPipeline<Owner: AnyObject>: ObservationScopePipeline, @unchecked Sendable {
    let appliesInsideTracking = false

    private let trackingCallback: @isolated(any) @Sendable (Owner) -> Void
    private let applyCallback: @isolated(any) @Sendable (borrowing ObservationEvent, Owner) -> Void

    init(
        tracking: @escaping @isolated(any) @Sendable (Owner) -> Void,
        apply: @escaping @isolated(any) @Sendable (borrowing ObservationEvent, Owner) -> Void
    ) {
        self.trackingCallback = tracking
        self.applyCallback = apply
    }

    func apply(event: borrowing ObservationEvent, owner: AnyObject) -> Bool {
        guard let owner = owner as? Owner else {
            return false
        }

        callObservationApply(applyCallback, event, owner)
        return true
    }

    func track(owner: AnyObject) -> Bool {
        guard let owner = owner as? Owner else {
            return false
        }

        callObservationTrack(trackingCallback, owner)
        return true
    }
}

// Shared by registrar callbacks, observation tasks, and explicit scope cancellation.
// Mutable lifecycle state is protected by `state`; the typed owner pipeline is erased above.
final class ObservationScopeSlot: @unchecked Sendable {
    private struct State: @unchecked Sendable {
        weak var owner: AnyObject?
        var isCancelled = false
        var dirty = false
        var waiters = ObservationScopeWaiters()
        var task: Task<Void, Never>?
        var pipeline: (any ObservationScopePipeline)?
    }

    struct PipelineSnapshot: @unchecked Sendable {
        let owner: AnyObject
        let pipeline: any ObservationScopePipeline

        var appliesInsideTracking: Bool {
            pipeline.appliesInsideTracking
        }

        func apply(event: borrowing ObservationEvent) -> Bool {
            pipeline.apply(event: event, owner: owner)
        }

        func track() -> Bool {
            pipeline.track(owner: owner)
        }
    }

    private struct Cancellation {
        var shouldCancel: Bool
        var waiters: ObservationScopeWaiterBatch
        var task: Task<Void, Never>?
    }

    private enum WaitSetup {
        case changed
        case terminated
        case wait
    }

    let options: ObservationOptions
    let observationIsolation: (any Actor)?
    let delivery: ObservationDelivery
    private let state: Mutex<State>

    var isActive: Bool {
        state.withLock { state in
            !state.isCancelled
        }
    }

    init(
        owner: AnyObject,
        options: ObservationOptions,
        observationIsolation: (any Actor)?,
        delivery: ObservationDelivery,
        pipeline: any ObservationScopePipeline
    ) {
        self.options = options
        self.observationIsolation = observationIsolation
        self.delivery = delivery
        state = Mutex(State(owner: owner, pipeline: pipeline))
    }

    deinit {
        cancel()
    }

    func pipelineSnapshot() -> PipelineSnapshot? {
        state.withLock { state in
            guard !state.isCancelled, let owner = state.owner, let pipeline = state.pipeline else {
                return nil
            }

            return PipelineSnapshot(owner: owner, pipeline: pipeline)
        }
    }

    func start(isolation: isolated (any Actor)?) {
        guard isActive else {
            return
        }

        let startsInCurrentIsolation =
            observationScopeActorID(observationIsolation) == observationScopeActorID(isolation)

        if startsInCurrentIsolation {
            switch runInitialScopedObservationPass(
                options: options,
                isolation: isolation,
                slot: self
            ) {
            case .waitingForChange(let kind):
                replaceTask(with: makeObservationTask { [weak self, options, observationIsolation] in
                    guard let self else {
                        return
                    }
                    defer {
                        self.cancel()
                    }

                    await runScopedObservationLoopAfterInitialPass(
                        options: options,
                        isolation: observationIsolation,
                        slot: self,
                        nextKind: kind
                    )
                })
            case .finished:
                cancel()
            }
            return
        }

        replaceTask(with: makeObservationTask { [weak self, options, observationIsolation] in
            guard let self else {
                return
            }
            defer {
                self.cancel()
            }

            await runScopedObservationLoop(
                options: options,
                isolation: observationIsolation,
                slot: self
            )
        })
    }

    func start() {
        start(isolation: nil)
    }

    func cancel() {
        let cancellation = state.withLock { state -> Cancellation in
            guard !state.isCancelled else {
                return Cancellation(shouldCancel: false, waiters: .empty, task: nil)
            }

            state.isCancelled = true
            state.dirty = false
            state.owner = nil
            state.pipeline = nil
            let waiters = state.waiters.takeAll()
            let task = state.task
            state.task = nil
            return Cancellation(shouldCancel: true, waiters: waiters, task: task)
        }

        guard cancellation.shouldCancel else {
            return
        }

        cancellation.waiters.resumeAll()
        delivery.finish()
        cancellation.task?.cancel()
    }

    func emitChange() {
        let waiters = state.withLock { state -> ObservationScopeWaiterBatch in
            guard !state.isCancelled else {
                return .empty
            }

            if state.waiters.isEmpty {
                state.dirty = true
                return .empty
            }

            return state.waiters.takeAll()
        }

        waiters.resumeAll()
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

                #if canImport(_ObservationBridgeBenchmarkSupport)
                ObservationBridgeBenchmarkObservationScopeWaiterRegistered()
                #endif

                return nil
            }
            immediate?.resume()
        }

        return isActive
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

@inline(__always)
private func callObservationApply<Owner: AnyObject>(
    _ apply: @escaping @isolated(any) @Sendable (borrowing ObservationEvent, Owner) -> Void,
    _ event: borrowing ObservationEvent,
    _ owner: Owner
) {
    let unisolated = unsafe unsafeBitCast(
        apply,
        to: (@Sendable (borrowing ObservationEvent, Owner) -> Void).self
    )
    unisolated(event, owner)
}

@inline(__always)
private func callObservationTrack<Owner: AnyObject>(
    _ track: @escaping @isolated(any) @Sendable (Owner) -> Void,
    _ owner: Owner
) {
    let unisolated = unsafe unsafeBitCast(
        track,
        to: (@Sendable (Owner) -> Void).self
    )
    unisolated(owner)
}
