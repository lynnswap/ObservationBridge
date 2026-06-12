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
    func apply(event: borrowing PortableObservationTracking.Event) -> Bool
}

/// A change wake-up carried from registrar callbacks to the observation loop.
struct ObservationScopePendingEvent: Sendable {
    let kind: PortableObservationTracking.Event.Kind
    var triggers: ObservationEventTriggers

    static let initial = ObservationScopePendingEvent(kind: .initial, triggers: .none)
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
    private let applyCallback: @isolated(any) @Sendable (borrowing PortableObservationTracking.Event) -> Void

    init(_ applyCallback: @escaping @isolated(any) @Sendable (borrowing PortableObservationTracking.Event) -> Void) {
        self.applyCallback = applyCallback
    }

    func apply(event: borrowing PortableObservationTracking.Event) -> Bool {
        callObservationApply(applyCallback, event)
        return true
    }
}

// Shared by registrar callbacks, observation tasks, and explicit scope cancellation.
// Mutable lifecycle state is protected by `state`; the typed apply closure is erased above.
final class ObservationScopeSlot: @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var isCancelled = false
        var pendingEvent: ObservationScopePendingEvent?
        var trackingCancellationsAfterNextPass: [@Sendable () -> Void] = []
        var waiters = ObservationScopeWaiters()
        var task: Task<Void, Never>?
        var pipeline: (any ObservationScopePipeline)?

        mutating func popPendingEvent() -> ObservationScopePendingEvent? {
            defer { pendingEvent = nil }
            return pendingEvent
        }
    }

    struct PipelineSnapshot: @unchecked Sendable {
        let pipeline: any ObservationScopePipeline

        func apply(event: borrowing PortableObservationTracking.Event) -> Bool {
            pipeline.apply(event: event)
        }
    }

    private struct Cancellation {
        var shouldCancel: Bool
        var waiters: ObservationScopeWaiterBatch
        var task: Task<Void, Never>?
        var trackingCancellations: [@Sendable () -> Void]
    }

    private enum WaitSetup {
        case changed(ObservationScopePendingEvent)
        case terminated
        case wait
    }

    let options: PortableObservationTracking.Options
    let observationIsolation: (any Actor)?
    let delivery: ObservationDelivery
    private let state: Mutex<State>

    var isActive: Bool {
        state.withLock { state in
            !state.isCancelled
        }
    }

    init(
        options: PortableObservationTracking.Options,
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
                return Cancellation(shouldCancel: false, waiters: .empty, task: nil, trackingCancellations: [])
            }

            state.isCancelled = true
            state.pendingEvent = nil
            state.pipeline = nil
            let trackingCancellations = state.trackingCancellationsAfterNextPass
            state.trackingCancellationsAfterNextPass.removeAll(keepingCapacity: true)
            let waiters = state.waiters.takeAll()
            let task = state.task
            state.task = nil
            return Cancellation(
                shouldCancel: true,
                waiters: waiters,
                task: task,
                trackingCancellations: trackingCancellations
            )
        }

        guard cancellation.shouldCancel else {
            return
        }

        cancellation.waiters.resumeAll(returning: nil)
        for cancelTracking in cancellation.trackingCancellations {
            cancelTracking()
        }
        delivery.finish()
        cancellation.task?.cancel()
    }

    @discardableResult
    func emitChange(
        kind: PortableObservationTracking.Event.Kind,
        triggers: ObservationEventTriggers,
        cancelTrackingAfterNextPass: (@Sendable () -> Void)? = nil
    ) -> Bool {
        let event = ObservationScopePendingEvent(kind: kind, triggers: triggers)
        let (accepted, waiters) = state.withLock { state -> (Bool, ObservationScopeWaiterBatch) in
            guard !state.isCancelled else {
                return (false, .empty)
            }

            if let cancelTrackingAfterNextPass {
                state.trackingCancellationsAfterNextPass.append(cancelTrackingAfterNextPass)
            }

            if state.waiters.isEmpty {
                state.pendingEvent = event
                return (true, .empty)
            }

            return (true, state.waiters.takeAll())
        }

        waiters.resumeAll(returning: event)
        return accepted
    }

    func cancelTrackingsDeferredUntilNextPass() {
        let trackingCancellations = state.withLock { state in
            let trackingCancellations = state.trackingCancellationsAfterNextPass
            state.trackingCancellationsAfterNextPass.removeAll(keepingCapacity: true)
            return trackingCancellations
        }

        for cancelTracking in trackingCancellations {
            cancelTracking()
        }
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
    _ apply: @escaping @isolated(any) @Sendable (borrowing PortableObservationTracking.Event) -> Void,
    _ event: borrowing PortableObservationTracking.Event
) {
    let unisolated = unsafe unsafeBitCast(
        apply,
        to: (@Sendable (borrowing PortableObservationTracking.Event) -> Void).self
    )
    unisolated(event)
}
