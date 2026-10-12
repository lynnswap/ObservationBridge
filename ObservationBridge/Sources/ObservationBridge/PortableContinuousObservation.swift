internal import ABIBridge
import Foundation
import Observation
import Synchronization

/// Starts a portable continuous observation.
///
/// Every observable property read inside `apply` becomes a dependency for the
/// next pass. Read the values you want to keep observing on every pass, including
/// ``PortableObservationTracking/Event/Kind/initial``. The callback inherits the
/// caller's actor context.
///
/// The initial pass normally runs synchronously before this function returns.
/// When the native OS 27+ fallback is selected because exact Observation runtime
/// SPI is unavailable, the initial pass follows native scheduling and may run
/// after the token is returned. See <doc:ContinuousObservation> for event timing
/// and key-path matching.
///
/// - Parameters:
///   - options: The subsequent events to deliver. Defaults to
///     ``PortableObservationTracking/Options/didSet``. An empty set delivers only
///     the initial pass.
///   - apply: The tracking callback for the initial pass and selected subsequent
///     events. Its event is borrowed for the duration of the callback; copy
///     ``PortableObservationTracking/Event/kind`` if you need to retain the reason
///     for the pass.
///   - currentIsolation: The caller's actor isolation, inferred by default.
/// - Returns: A token that keeps the observation alive until it is cancelled or
///   its last copy is released. If startup fails, the token is inactive and its
///   `error` contains the failure. Runtime lookup and ABI preparation run on
///   demand and may block the caller. Use `PortableObservationTracking.prepare()`
///   to start this work ahead of time on an independent worker.

public func withPortableContinuousObservation(
    options: PortableObservationTracking.Options = .didSet,
    @_inheritActorContext apply: @escaping @isolated(any) @Sendable (borrowing PortableObservationTracking.Event) -> Void,
    _ currentIsolation: isolated (any Actor)? = #isolation
) -> PortableObservationTracking.Token {
    startPortableContinuousObservation(
        options: options,
        apply: apply,
        currentIsolation: currentIsolation
    )
}

private func startPortableContinuousObservation(
    options: PortableObservationTracking.Options,
    apply: @escaping @isolated(any) @Sendable (borrowing PortableObservationTracking.Event) -> Void,
    currentIsolation: isolated (any Actor)?
) -> PortableObservationTracking.Token {
    let preparation: Result<ObservationRuntime, any Swift.Error>? =
        requestedRuntimeTrackingMode(for: options).map { mode in
            Result { try ObservationRuntimePreparation.resolve(mode) }
        }
    let delivery = ObservationDelivery()
    let observationIsolation = apply.isolation ?? currentIsolation
    let pipeline = ObservationScopeImplicitTrackingPipeline(apply)

    #if compiler(>=6.4)
    if #available(anyAppleOS 27.0, *),
        runtimeTrackingMode(for: options) == nil,
        let nativeOptions = nativeContinuousObservationOptions(for: options)
    {
        return startNativeContinuousObservationFallback(
            options: nativeOptions,
            pipeline: pipeline,
            delivery: delivery,
            observationIsolation: observationIsolation,
            currentIsolation: currentIsolation
        )
    }
    #endif

    let slot = ObservationScopeSlot(
        options: options,
        observationIsolation: observationIsolation,
        delivery: delivery,
        pipeline: pipeline
    )
    delivery.bind(to: slot)
    let token = PortableObservationTracking.Token(slot: slot, delivery: delivery)
    do {
        _ = try preparation?.get()
    } catch {
        slot.fail(error)
        return token
    }
    slot.start(isolation: currentIsolation)
    return token
}

// Mutation events use the Observation runtime SPI on every OS so `matches(_:)`
// can mirror Swift's `withContinuousObservation` key-path comparison. The public
// native Event cannot be retained across the deferred portable callback pass, so
// the native continuous fallback is reserved for liveness when exact SPI is unavailable.
func runScopedObservationLoop(
    options: PortableObservationTracking.Options,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot
) async {
    await runRuntimeScopedObservationLoop(
        options: options,
        isolation: isolation,
        slot: slot
    )
}

func runInitialScopedObservationPass(
    options: PortableObservationTracking.Options,
    isolation: isolated (any Actor)?,
    slot: ObservationScopeSlot
) -> InitialScopedObservationResult {
    return runInitialRuntimeScopedObservationPass(
        options: options,
        isolation: isolation,
        slot: slot
    )
}

func runScopedObservationLoopAfterInitialPass(
    options: PortableObservationTracking.Options,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot
) async {
    await runRuntimeScopedObservationLoopAfterInitialPass(
        options: options,
        isolation: isolation,
        slot: slot
    )
}

private func runRuntimeScopedObservationLoop(
    options: PortableObservationTracking.Options,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot
) async {
    var pendingEvent = ObservationScopePendingEvent.initial

    while !Task.isCancelled {
        let mode = runtimeTrackingMode(for: options)

        guard await trackRuntimeScopedObservation(
            event: pendingEvent,
            mode: mode,
            isolation: isolation,
            slot: slot
        ) else {
            break
        }

        guard mode != nil else {
            break
        }

        guard let nextEvent = await slot.waitForChange() else {
            break
        }

        pendingEvent = nextEvent
    }

    slot.cancel()
}

func runInitialRuntimeScopedObservationPass(
    options: PortableObservationTracking.Options,
    isolation _: isolated (any Actor)?,
    slot: ObservationScopeSlot
) -> InitialScopedObservationResult {
    let mode = runtimeTrackingMode(for: options)

    let result = trackRuntimeScopedObservationInCurrentContext(
        event: .initial,
        mode: mode,
        slot: slot
    )
    result.finishWithoutSampling()

    guard result.shouldContinue else {
        slot.cancel()
        return .finished
    }

    guard mode != nil else {
        slot.cancel()
        return .finished
    }

    return .waitingForChange
}

func runRuntimeScopedObservationLoopAfterInitialPass(
    options: PortableObservationTracking.Options,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot
) async {
    while !Task.isCancelled {
        guard let pendingEvent = await slot.waitForChange() else {
            break
        }

        let mode = runtimeTrackingMode(for: options)

        guard await trackRuntimeScopedObservation(
            event: pendingEvent,
            mode: mode,
            isolation: isolation,
            slot: slot
        ) else {
            break
        }

        guard mode != nil else {
            break
        }
    }

    slot.cancel()
}

#if compiler(>=6.4)
@available(anyAppleOS 27.0, *)
private func startNativeContinuousObservationFallback(
    options: ObservationTracking.Options,
    pipeline: ObservationScopeImplicitTrackingPipeline,
    delivery: ObservationDelivery,
    observationIsolation: (any Actor)?,
    currentIsolation: isolated (any Actor)?
) -> PortableObservationTracking.Token {
    let cancellation = NativeContinuousObservationCancellation()
    let completionQueue = ObservationDeliveryCompletionQueue()
    let token = PortableObservationTracking.Token(
        nativeContinuousCancellation: cancellation,
        delivery: delivery
    )

    let startsInCurrentIsolation =
        observationScopeActorID(observationIsolation) == observationScopeActorID(currentIsolation)

    if startsInCurrentIsolation {
        installNativeContinuousObservationFallback(
            options: options,
            pipeline: pipeline,
            delivery: delivery,
            cancellation: cancellation,
            completionQueue: completionQueue,
            isolation: currentIsolation
        )
    } else if let observationIsolation {
        cancellation.installTask(makeObservationTask {
            await withObservationIsolation(isolation: observationIsolation) { isolatedObservation in
                installNativeContinuousObservationFallback(
                    options: options,
                    pipeline: pipeline,
                    delivery: delivery,
                    cancellation: cancellation,
                    completionQueue: completionQueue,
                    isolation: isolatedObservation
                )
            }
        })
    } else {
        installNativeContinuousObservationFallback(
            options: options,
            pipeline: pipeline,
            delivery: delivery,
            cancellation: cancellation,
            completionQueue: completionQueue,
            isolation: nil
        )
    }
    return token
}

@available(anyAppleOS 27.0, *)
private func installNativeContinuousObservationFallback(
    options: ObservationTracking.Options,
    pipeline: ObservationScopeImplicitTrackingPipeline,
    delivery: ObservationDelivery,
    cancellation: NativeContinuousObservationCancellation,
    completionQueue: ObservationDeliveryCompletionQueue,
    isolation: isolated (any Actor)?
) {
    let nativeToken = withContinuousObservation(options: options) { nativeEvent in
        isolation?.assertIsolated()
        // This closure is the native continuous tracking body. It must read the
        // observed values before returning, so `withContinuousObservation` can
        // install the next dependency set.
        deliverNativeContinuousObservationEvent(
            nativeEvent,
            pipeline: pipeline,
            delivery: delivery,
            cancellation: cancellation,
            completionQueue: completionQueue
        )
    }
    cancellation.install(nativeToken)
}

@available(anyAppleOS 27.0, *)
private func installNativeContinuousObservationFallback(
    options: ObservationTracking.Options,
    pipeline: ObservationScopeImplicitTrackingPipeline,
    delivery: ObservationDelivery,
    cancellation: NativeContinuousObservationCancellation,
    completionQueue: ObservationDeliveryCompletionQueue,
    isolation: isolated (any Actor)
) {
    isolation.assertIsolated()
    let nativeToken = withContinuousObservation(options: options) { nativeEvent in
        isolation.assertIsolated()
        // This closure is the native continuous tracking body. It must read the
        // observed values before returning, so `withContinuousObservation` can
        // install the next dependency set.
        deliverNativeContinuousObservationEvent(
            nativeEvent,
            pipeline: pipeline,
            delivery: delivery,
            cancellation: cancellation,
            completionQueue: completionQueue
        )
    }
    cancellation.install(nativeToken)
}

@available(anyAppleOS 27.0, *)
private func deliverNativeContinuousObservationEvent(
    _ nativeEvent: borrowing ObservationTracking.Event,
    pipeline: ObservationScopeImplicitTrackingPipeline,
    delivery: ObservationDelivery,
    cancellation: NativeContinuousObservationCancellation,
    completionQueue: ObservationDeliveryCompletionQueue
) {
    guard let kind = portableNativeContinuousObservationEventKind(for: nativeEvent.kind) else {
        return
    }

    guard delivery.beginDelivery() else {
        return
    }

    let triggers: ObservationEventTriggers = kind == .initial ? .none : .conservative
    let event = PortableObservationTracking.Event(kind: kind, triggers: triggers) {
        cancellation.cancel()
        delivery.finish()
    }

    if pipeline.apply(event: event) {
        completionQueue.enqueue(delivery.endDelivery())
    } else {
        delivery.discardDelivery()
    }
}

@available(anyAppleOS 27.0, *)
private func nativeContinuousObservationOptions(
    for options: PortableObservationTracking.Options
) -> ObservationTracking.Options? {
    var nativeOptions = ObservationTracking.Options()
    var hasMutationOption = false

    if options.contains(.willSet) {
        nativeOptions.insert(.willSet)
        hasMutationOption = true
    }
    if options.contains(.didSet) {
        nativeOptions.insert(.didSet)
        hasMutationOption = true
    }

    return hasMutationOption ? nativeOptions : nil
}

@available(anyAppleOS 27.0, *)
private func portableNativeContinuousObservationEventKind(
    for nativeKind: ObservationTracking.Event.Kind
) -> PortableObservationTracking.Event.Kind? {
    if nativeKind == .initial {
        return .initial
    }
    if nativeKind == .willSet {
        return .willSet
    }
    if nativeKind == .didSet {
        return .didSet
    }
    return nil
}
#endif

private func trackRuntimeScopedObservation(
    event pendingEvent: ObservationScopePendingEvent,
    mode: RuntimeScopedTrackingMode?,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot
) async -> Bool {
    let result = await withObservationIsolation(isolation: isolation) {
        trackRuntimeScopedObservationInCurrentContext(
            event: pendingEvent,
            mode: mode,
            slot: slot
        )
    }
    await result.sampleAndFinish()
    return result.shouldContinue
}

private struct ScopedObservationTrackResult: Sendable {
    let shouldContinue: Bool
    let completion: ObservationDeliveryCompletion?

    func sampleAndFinish() async {
        await completion?.sampleAndFinish()
    }

    func finishWithoutSampling() {
        completion?.finishWithoutSampling()
    }
}

private func trackRuntimeScopedObservationInCurrentContext(
    event pendingEvent: ObservationScopePendingEvent,
    mode: RuntimeScopedTrackingMode?,
    slot: ObservationScopeSlot
) -> ScopedObservationTrackResult {
    guard let pipeline = slot.pipelineSnapshot() else {
        return ScopedObservationTrackResult(shouldContinue: false, completion: nil)
    }

    let event = makeScopedObservationEvent(pendingEvent, slot: slot)

    let delivery = slot.delivery
    guard delivery.beginDelivery() else {
        return ScopedObservationTrackResult(shouldContinue: false, completion: nil)
    }

    func complete(
        shouldContinue: Bool,
        didApply: Bool
    ) -> ScopedObservationTrackResult {
        if didApply {
            return ScopedObservationTrackResult(
                shouldContinue: shouldContinue,
                completion: delivery.endDelivery()
            )
        }

        delivery.discardDelivery()
        return ScopedObservationTrackResult(shouldContinue: shouldContinue, completion: nil)
    }

    guard let mode else {
        let didApply = pipeline.apply(event: event)
        return complete(shouldContinue: slot.isActive, didApply: didApply)
    }

    do {
        let runtime = try ObservationRuntimePreparation.resolve(mode)
        guard let handler = try slot.runtimeTrackingHandler({
            try runtime.handler(kind: mode == .didSet ? .didSet : .willSet, slot: slot)
        }) else {
            return complete(shouldContinue: false, didApply: false)
        }
        let didApply = try unsafe NativeSwiftClosure<() -> Bool>.withUnsafeNonescaping({
            pipeline.apply(event: event)
        }) { apply in
            try unsafe runtime.function.unsafeInvoke(apply, handler)
        }
        return complete(shouldContinue: slot.isActive, didApply: didApply)
    } catch {
        slot.fail(error)
        return complete(shouldContinue: false, didApply: false)
    }
}

private enum RuntimeScopedTrackingMode: Hashable, Sendable {
    case willSet
    case didSet

    var label: String {
        self == .didSet ? "didSet" : "willSet"
    }
}

private func requestedRuntimeTrackingMode(for options: PortableObservationTracking.Options) -> RuntimeScopedTrackingMode? {
    if options.contains(.didSet) {
        return .didSet
    }

    if options.contains(.willSet) {
        return .willSet
    }

    return nil
}

private func runtimeTrackingMode(for options: PortableObservationTracking.Options) -> RuntimeScopedTrackingMode? {
    switch requestedRuntimeTrackingMode(for: options) {
    case .didSet:
        return canUseDidSetObservationTrackingSPI ? .didSet : nil
    case .willSet:
        return canUseWillSetObservationTrackingSPI ? .willSet : nil
    case nil:
        return nil
    }
}

private func makeScopedObservationEvent(
    _ pendingEvent: ObservationScopePendingEvent,
    slot: ObservationScopeSlot
) -> PortableObservationTracking.Event {
    let cancellation: @Sendable () -> Void = { [weak slot] in
        slot?.cancel()
    }
    return PortableObservationTracking.Event(
        kind: pendingEvent.kind,
        triggers: pendingEvent.triggers,
        cancellation: cancellation
    )
}

private func withObservationIsolation<T: Sendable>(
    isolation: isolated (any Actor)?,
    _ operation: () -> T
) -> T {
    // The isolated parameter makes the caller hop to `isolation` before this body runs.
    return operation()
}

private func withObservationIsolation<T: Sendable>(
    isolation: isolated (any Actor),
    _ operation: @Sendable (isolated (any Actor)) -> T
) -> T {
    operation(isolation)
}

extension PortableObservationTracking {
    /// A failure starting or running a portable observation.
    public enum Error: Swift.Error, Sendable {
        /// Reading the triggering key path and cancelling its tracking both failed.
        case cancellationFailed(operation: any Swift.Error, cancellation: any Swift.Error)
    }

    /// Prepares the Observation runtime ahead of synchronous observation starts.
    ///
    /// Preparation is optional and runs on an independent worker. Synchronous
    /// observations perform missing work or join only the required lookup and ABI
    /// preparation, without waiting for this entire operation. Repeated successful
    /// calls reuse the prepared handles.
    /// On OS 27+, unavailable exact SPI selects the native liveness fallback.
    /// On earlier versions, both mutation event implementations must be available;
    /// preparation throws if either cannot be resolved. Tracking failures after
    /// startup stop the observation and are available through `Token.error`.
    public static func prepare() async throws {
        try await ObservationRuntimePreparation.prepare()
    }
}

typealias ObservationRuntimeTrackingHandler = NativeSwiftClosure<@Sendable (NativeSwiftBorrowedValue) -> Void>

private struct ObservationRuntime: Sendable {
    typealias TrackingFunction = NativeSwiftFunction<(NativeSwiftClosure<() -> Bool>, ObservationRuntimeTrackingHandler) -> Bool>

    let type: NativeSwiftType
    let function: TrackingFunction
    let changed: NativeSwiftMethod<() -> AnyKeyPath?>
    let cancel: NativeSwiftMethod<() -> Void>

    func handler(
        kind: PortableObservationTracking.Event.Kind,
        slot: ObservationScopeSlot
    ) throws -> ObservationRuntimeTrackingHandler {
        try ObservationRuntimeTrackingHandler { [weak slot, changed, cancel] tracking in
            let keyPath: AnyKeyPath?
            do {
                keyPath = try unsafe changed.unsafeInvoke(on: tracking)
            } catch {
                let operationError = error
                do {
                    try unsafe cancel.unsafeInvoke(on: tracking)
                    slot?.fail(operationError)
                } catch {
                    slot?.fail(PortableObservationTracking.Error.cancellationFailed(
                        operation: operationError, cancellation: error
                    ))
                }
                return
            }
            do {
                try unsafe cancel.unsafeInvoke(on: tracking)
                slot?.emitChange(kind: kind, triggers: .keyPath(keyPath))
            } catch {
                slot?.fail(error)
            }
        }
    }
}

private enum ObservationRuntimePreparation {
    static let cached = Mutex<[RuntimeScopedTrackingMode: ObservationRuntime]>([:])

    static func prepare() async throws {
        try await ABIRuntime.shared.prepare { runtime in
            let didSet = Result { try resolve(.didSet, using: runtime) }
            let willSet = Result { try resolve(.willSet, using: runtime) }
            #if compiler(>=6.4)
            if #available(anyAppleOS 27.0, *) {
                return
            }
            #endif
            _ = try didSet.get()
            _ = try willSet.get()
        }
    }

    static func resolve(
        _ mode: RuntimeScopedTrackingMode,
        using runtime: ABIRuntime = .shared
    ) throws -> ObservationRuntime {
        if let prepared = cached.withLock({ $0[mode] }) {
            return prepared
        }

        // ABIBridge joins its captured index and ABI work. Keep loader and Swift
        // metadata initialization outside our cache lock so they can reenter.
        let type = try runtime.swiftType(named: "Observation.ObservationTracking")
        let changed = try type.getter(named: "changed", as: (() -> AnyKeyPath?).self, receiverABI: .opaque(named: type.name))
        let cancel = try type.method(named: "cancel()", as: (() -> Void).self, receiverABI: .opaque(named: type.name))
        let function = try runtime.swiftFunction(
            named: "Observation.withObservationTracking<A>(_: () -> A, \(mode.label): @Sendable (Observation.ObservationTracking) -> ()) -> A",
            as: ((NativeSwiftClosure<() -> Bool>, ObservationRuntimeTrackingHandler) -> Bool).self,
            genericArguments: [.type(Bool.self)],
            valueABIs: [type: .opaque(named: type.name)],
            in: type.image,
            loading: .loadedOnly
        )
        let prepared = ObservationRuntime(type: type, function: function, changed: changed, cancel: cancel)
        return withExtendedLifetime(prepared) {
            cached.withLock { stored in
                if let existing = stored[mode] {
                    return existing
                }
                stored[mode] = prepared
                return prepared
            }
        }
    }
}

private var canUseDidSetObservationTrackingSPI: Bool {
    !_ObservationScopeTesting.forceObservationTrackingSPIUnavailable.withLock({ $0 })
        && !_ObservationScopeTesting.forceDidSetObservationTrackingSPIUnavailable.withLock({ $0 })
        && ObservationRuntimePreparation.cached.withLock { $0[.didSet] != nil }
}

private var canUseWillSetObservationTrackingSPI: Bool {
    !_ObservationScopeTesting.forceObservationTrackingSPIUnavailable.withLock({ $0 })
        && ObservationRuntimePreparation.cached.withLock { $0[.willSet] != nil }
}

enum _ObservationScopeTesting {
    static let forceObservationTrackingSPIUnavailable = Mutex(false)
    static let forceDidSetObservationTrackingSPIUnavailable = Mutex(false)

    static var hasRequiredObservationTrackingSPISymbols: Bool {
        missingRequiredObservationTrackingSPISymbols.isEmpty
    }

    static var missingRequiredObservationTrackingSPISymbols: [String] {
        [RuntimeScopedTrackingMode.didSet, .willSet].compactMap { mode in
            do {
                _ = try ObservationRuntimePreparation.resolve(mode)
                return nil
            } catch {
                return "withObservationTracking(_:\(mode.label):): \(error)"
            }
        }
    }

    static func withoutCachedRuntime<Result>(
        _ operation: () async throws -> Result,
        isolation: isolated (any Actor)? = #isolation
    ) async rethrows -> Result {
        let runtime = ObservationRuntimePreparation.cached.withLock { stored in
            let runtime = stored
            stored = [:]
            return runtime
        }
        defer {
            let displaced = ObservationRuntimePreparation.cached.withLock { stored in
                let displaced = stored
                stored = runtime
                return displaced
            }
            withExtendedLifetime(displaced) {}
        }
        return try await operation()
    }
}
