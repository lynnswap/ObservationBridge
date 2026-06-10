import Synchronization

#if canImport(_ObservationBridgeBenchmarkSupport)
internal import _ObservationBridgeBenchmarkSupport
#endif

func observationScopeActorID(_ actor: (any Actor)?) -> ObjectIdentifier? {
    actor.map { ObjectIdentifier($0 as AnyObject) }
}

enum InitialScopedObservationResult: Sendable {
    case waitingForChange
    case finished
}

protocol ObservationScopePipeline: Sendable {
    func apply(event: borrowing ObservationEvent) -> Bool
}

/// A change wake-up carried from registrar callbacks to the observation loop.
struct ObservationScopePendingEvent: Sendable {
    let kind: ObservationEvent.Kind
    var triggers: ObservationEventTriggers

    static let initial = ObservationScopePendingEvent(kind: .initial, triggers: .none)
}

/// What a registrar callback should do with its backing tracking after reporting a change.
enum ObservationScopeTrackingDirective: Sendable {
    /// The tracking is still current (or still covering an in-flight pass); keep it armed.
    case keepTracking

    /// The tracking was superseded or the slot is cancelled; the callback must cancel it.
    case cancelTracking
}

private struct ObservationScopeWaiters: @unchecked Sendable {
    private var first: CheckedContinuation<ObservationScopePendingEvent?, Never>?
    private var additional: [CheckedContinuation<ObservationScopePendingEvent?, Never>]?

    var isEmpty: Bool {
        first == nil
    }

    mutating func append(_ continuation: CheckedContinuation<ObservationScopePendingEvent?, Never>) {
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
    case single(CheckedContinuation<ObservationScopePendingEvent?, Never>)
    case many(
        CheckedContinuation<ObservationScopePendingEvent?, Never>,
        [CheckedContinuation<ObservationScopePendingEvent?, Never>]
    )

    func resumeAll(returning event: ObservationScopePendingEvent?) {
        switch self {
        case .empty:
            return
        case .single(let continuation):
            continuation.resume(returning: event)
        case .many(let first, let additional):
            first.resume(returning: event)
            for continuation in additional {
                continuation.resume(returning: event)
            }
        }
    }
}

struct ObservationScopeImplicitTrackingPipeline: ObservationScopePipeline, @unchecked Sendable {
    private let applyCallback: @isolated(any) @Sendable (borrowing ObservationEvent) -> Void

    init(_ applyCallback: @escaping @isolated(any) @Sendable (borrowing ObservationEvent) -> Void) {
        self.applyCallback = applyCallback
    }

    func apply(event: borrowing ObservationEvent) -> Bool {
        callObservationApply(applyCallback, event)
        return true
    }
}

// Shared by registrar callbacks, observation tasks, and explicit scope cancellation.
// Mutable lifecycle state is protected by `state`; the typed apply closure is erased above.
final class ObservationScopeSlot: @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var isCancelled = false
        var pendingEvents: [ObservationScopePendingEvent] = []
        var waiters = ObservationScopeWaiters()
        var task: Task<Void, Never>?
        var pipeline: (any ObservationScopePipeline)?

        // Continuous-tracking bookkeeping. `trackingGeneration` is bumped when a tracking
        // pass begins; `armedTrackingGeneration` catches up once that pass has installed
        // its tracking. A superseded tracking keeps delivering while the replacement pass
        // is still in flight (closing the re-arm window) and cancels itself on its first
        // change after the replacement is armed.
        var trackingGeneration: UInt64 = 0
        var armedTrackingGeneration: UInt64 = 0

        mutating func appendPendingEvent(_ event: ObservationScopePendingEvent) {
            guard pendingEvents.last?.kind != event.kind else {
                pendingEvents[pendingEvents.count - 1].triggers.formUnion(event.triggers)
                return
            }

            pendingEvents.append(event)
        }

        mutating func popPendingEvent() -> ObservationScopePendingEvent? {
            guard !pendingEvents.isEmpty else {
                return nil
            }

            return pendingEvents.removeFirst()
        }
    }

    struct PipelineSnapshot: @unchecked Sendable {
        let pipeline: any ObservationScopePipeline

        func apply(event: borrowing ObservationEvent) -> Bool {
            pipeline.apply(event: event)
        }
    }

    private struct Cancellation {
        var shouldCancel: Bool
        var waiters: ObservationScopeWaiterBatch
        var task: Task<Void, Never>?
    }

    private enum WaitSetup {
        case changed(ObservationScopePendingEvent)
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
        options: ObservationOptions,
        observationIsolation: (any Actor)?,
        delivery: ObservationDelivery,
        pipeline: any ObservationScopePipeline
    ) {
        self.options = options
        self.observationIsolation = observationIsolation
        self.delivery = delivery
        state = Mutex(State(pipeline: pipeline))
    }

    deinit {
        cancel()
    }

    func pipelineSnapshot() -> PipelineSnapshot? {
        state.withLock { state in
            guard !state.isCancelled, let pipeline = state.pipeline else {
                return nil
            }

            return PipelineSnapshot(pipeline: pipeline)
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
            case .waitingForChange:
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
                        slot: self
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
            state.pendingEvents.removeAll(keepingCapacity: false)
            state.pipeline = nil
            let waiters = state.waiters.takeAll()
            let task = state.task
            state.task = nil
            return Cancellation(shouldCancel: true, waiters: waiters, task: task)
        }

        guard cancellation.shouldCancel else {
            return
        }

        cancellation.waiters.resumeAll(returning: nil)
        delivery.finish()
        cancellation.task?.cancel()
    }

    func emitChange(kind: ObservationEvent.Kind, triggers: ObservationEventTriggers) {
        let event = ObservationScopePendingEvent(kind: kind, triggers: triggers)
        let waiters = state.withLock { state -> ObservationScopeWaiterBatch in
            guard !state.isCancelled else {
                return .empty
            }

            if state.waiters.isEmpty {
                state.appendPendingEvent(event)
                return .empty
            }

            return state.waiters.takeAll()
        }

        waiters.resumeAll(returning: event)
    }

    /// Marks the start of a tracking pass and returns its generation token.
    func beginTrackingPass() -> UInt64 {
        state.withLock { state in
            state.trackingGeneration &+= 1
            return state.trackingGeneration
        }
    }

    /// Records that the pass for `generation` finished installing its tracking.
    func markTrackingArmed(_ generation: UInt64) {
        state.withLock { state in
            guard generation == state.trackingGeneration else {
                return
            }

            state.armedTrackingGeneration = generation
        }
    }

    /// Reports a change observed by the tracking armed for `generation`.
    ///
    /// Superseded trackings keep delivering while the replacement pass has not finished
    /// arming (their events are the only coverage for mutations made during that pass);
    /// once the replacement is armed they are told to cancel and their event is dropped
    /// because the armed tracking observes the same mutation.
    func acceptTrackingEvent(
        generation: UInt64,
        kind: ObservationEvent.Kind,
        triggers: ObservationEventTriggers
    ) -> ObservationScopeTrackingDirective {
        let event = ObservationScopePendingEvent(kind: kind, triggers: triggers)
        let (directive, waiters) = state.withLock {
            state -> (ObservationScopeTrackingDirective, ObservationScopeWaiterBatch) in
            guard !state.isCancelled else {
                return (.cancelTracking, .empty)
            }

            if generation != state.trackingGeneration,
               state.armedTrackingGeneration == state.trackingGeneration {
                return (.cancelTracking, .empty)
            }

            if state.waiters.isEmpty {
                state.appendPendingEvent(event)
                return (.keepTracking, .empty)
            }

            return (.keepTracking, state.waiters.takeAll())
        }

        waiters.resumeAll(returning: event)
        return directive
    }

    func waitForChange() async -> ObservationScopePendingEvent? {
        let setup = state.withLock { state -> WaitSetup in
            if state.isCancelled {
                return .terminated
            }
            if let event = state.popPendingEvent() {
                return .changed(event)
            }
            return .wait
        }

        switch setup {
        case .changed(let event):
            return event
        case .terminated:
            return nil
        case .wait:
            break
        }

        return await withCheckedContinuation { continuation in
            let immediate = state.withLock { state -> WaitSetup? in
                if state.isCancelled {
                    return .terminated
                }
                if let event = state.popPendingEvent() {
                    return .changed(event)
                }
                state.waiters.append(continuation)

                #if canImport(_ObservationBridgeBenchmarkSupport)
                ObservationBridgeBenchmarkObservationScopeWaiterRegistered()
                #endif

                return nil
            }

            switch immediate {
            case .changed(let event):
                continuation.resume(returning: event)
            case .terminated:
                continuation.resume(returning: nil)
            case .wait:
                preconditionFailure("Observation wait registration cannot resume with a suspended state.")
            case nil:
                break
            }
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

@inline(__always)
private func callObservationApply(
    _ apply: @escaping @isolated(any) @Sendable (borrowing ObservationEvent) -> Void,
    _ event: borrowing ObservationEvent
) {
    let unisolated = unsafe unsafeBitCast(
        apply,
        to: (@Sendable (borrowing ObservationEvent) -> Void).self
    )
    unisolated(event)
}
