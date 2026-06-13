import Darwin
import Foundation
import Observation
import Synchronization
import _ObservationBridgeRuntimeABI

/// Starts a portable continuous observation.
///
/// The callback body is the tracking body: every observable property read inside
/// `apply` becomes part of the observation. The `.initial` pass runs synchronously
/// when observation starts in the caller's current actor context.
///
/// - Parameters:
///   - options: Event delivery options. Defaults to ``PortableObservationTracking/Options/didSet``.
///   - apply: The callback to run for the initial pass and selected subsequent events.
/// - Returns: A token that keeps the observation alive until cancelled or deinitialized.
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

    var didApply = false
    switch mode {
    case .didSet:
        didApply = _withObservationTrackingDidSet({
            pipeline.apply(event: event)
        }, didSet: makeRuntimeTrackingHandler(kind: .didSet, slot: slot))
    case .willSet:
        didApply = _withObservationTrackingWillSet({
            pipeline.apply(event: event)
        }, willSet: makeRuntimeTrackingHandler(kind: .willSet, slot: slot))
    }

    return complete(shouldContinue: slot.isActive, didApply: didApply)
}

private enum RuntimeScopedTrackingMode: Equatable {
    case willSet
    case didSet
}

private func runtimeTrackingMode(for options: PortableObservationTracking.Options) -> RuntimeScopedTrackingMode? {
    if options.contains(.didSet) {
        return canUseDidSetObservationTrackingSPI ? .didSet : nil
    }

    if options.contains(.willSet) {
        return canUseWillSetObservationTrackingSPI ? .willSet : nil
    }

    return nil
}

private func makeRuntimeTrackingHandler(
    kind: PortableObservationTracking.Event.Kind,
    slot: ObservationScopeSlot
) -> @Sendable (OpaqueObservationTracking) -> Void {
    { [weak slot] tracking in
        let triggers = ObservationEventTriggers.keyPath(observationTrackingChangedKeyPath(tracking))
        cancelObservationTrackingIfAvailable(tracking)

        guard let slot else {
            return
        }

        slot.emitChange(
            kind: kind,
            triggers: triggers
        )
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

// The SPI overloads pass a runtime `ObservationTracking` value whose public shape differs
// across Swift releases. Use a resilient imported value as the opaque ABI carrier so Swift
// forwards the hidden value with the same indirect convention.
private typealias OpaqueObservationTracking = URL

@_weakLinked
@_silgen_name("$s11Observation04withA8Tracking_6didSetxxyXE_yAA0aC0VYbctlF")
private func _withObservationTrackingDidSet<T>(
    _ apply: () -> T,
    didSet: @escaping @Sendable (OpaqueObservationTracking) -> Void
) -> T

@_weakLinked
@_silgen_name("$s11Observation04withA8Tracking_7willSetxxyXE_yAA0aC0VYbctlF")
private func _withObservationTrackingWillSet<T>(
    _ apply: () -> T,
    willSet: @escaping @Sendable (OpaqueObservationTracking) -> Void
) -> T

private let observationTrackingDidSetAddress: UInt? =
    unsafe lookupObservationSymbol("$s11Observation04withA8Tracking_6didSetxxyXE_yAA0aC0VYbctlF")
        .map { UInt(bitPattern: $0) }

private let observationTrackingWillSetAddress: UInt? =
    unsafe lookupObservationSymbol("$s11Observation04withA8Tracking_7willSetxxyXE_yAA0aC0VYbctlF")
        .map { UInt(bitPattern: $0) }

private let observationTrackingCancelAddress: UInt? =
    unsafe lookupObservationSymbol("$s11Observation0A8TrackingV6cancelyyF")
        .map { UInt(bitPattern: $0) }

private let observationTrackingChangedAddress: UInt? =
    unsafe lookupObservationSymbol("$s11Observation0A8TrackingV7changeds10AnyKeyPathCSgvg")
        .map { UInt(bitPattern: $0) }

private var canUseObservationTrackingSupportSPI: Bool {
    if _ObservationScopeTesting.forceObservationTrackingSPIUnavailable.withLock({ $0 }) {
        return false
    }

    return canUseObservationTrackingSupportSPIIgnoringTestOverride
}

private var canUseObservationTrackingSupportSPIIgnoringTestOverride: Bool {
    #if arch(arm64) || arch(x86_64)
    return observationTrackingChangedAddress != nil
        && observationTrackingCancelAddress != nil
    #else
    return false
    #endif
}

private var canUseDidSetObservationTrackingSPI: Bool {
    if _ObservationScopeTesting.forceDidSetObservationTrackingSPIUnavailable.withLock({ $0 }) {
        return false
    }

    return canUseObservationTrackingSupportSPI && observationTrackingDidSetAddress != nil
}

private var canUseWillSetObservationTrackingSPI: Bool {
    canUseObservationTrackingSupportSPI && observationTrackingWillSetAddress != nil
}

enum _ObservationScopeTesting {
    /// Simulates missing Observation runtime SPI symbols.
    static let forceObservationTrackingSPIUnavailable = Mutex(false)
    static let forceDidSetObservationTrackingSPIUnavailable = Mutex(false)

    static var missingRequiredObservationTrackingSPISymbols: [String] {
        missingRequiredRuntimeSPISymbols()
    }

    static var hasRequiredObservationTrackingSPISymbols: Bool {
        missingRequiredRuntimeSPISymbols().isEmpty
    }
}

private func missingRequiredRuntimeSPISymbols() -> [String] {
    #if arch(arm64) || arch(x86_64)
    var missing: [String] = []
    if observationTrackingDidSetAddress == nil {
        missing.append("withObservationTracking(_:didSet:)")
    }
    if observationTrackingWillSetAddress == nil {
        missing.append("withObservationTracking(_:willSet:)")
    }
    if observationTrackingCancelAddress == nil {
        missing.append("ObservationTracking.cancel")
    }
    if observationTrackingChangedAddress == nil {
        missing.append("ObservationTracking.changed")
    }
    return missing
    #else
    return ["unsupported architecture"]
    #endif
}

private func observationTrackingChangedKeyPath(
    _ tracking: OpaqueObservationTracking
) -> AnyKeyPath? {
    guard
        let observationTrackingChangedAddress,
        let observationTrackingChangedFunction = unsafe UnsafeMutableRawPointer(
            bitPattern: observationTrackingChangedAddress
        )
    else {
        return nil
    }

    // The getter returns the Optional<AnyKeyPath> payload as a single owned (+1) pointer.
    #if compiler(>=6.4)
    return withUnsafePointer(to: tracking) { trackingPointer in
        guard let rawKeyPath = unsafe OBObservationTrackingChanged(
            observationTrackingChangedFunction,
            trackingPointer
        ) else {
            return nil
        }
        return unsafe Unmanaged<AnyKeyPath>.fromOpaque(rawKeyPath).takeRetainedValue()
    }
    #else
    return unsafe withUnsafePointer(to: tracking) { trackingPointer in
        guard let rawKeyPath = unsafe OBObservationTrackingChanged(
            observationTrackingChangedFunction,
            trackingPointer
        ) else {
            return nil
        }
        return unsafe Unmanaged<AnyKeyPath>.fromOpaque(rawKeyPath).takeRetainedValue()
    }
    #endif
}

private func cancelObservationTrackingIfAvailable(_ tracking: OpaqueObservationTracking) {
    guard
        let observationTrackingCancelAddress,
        let observationTrackingCancelFunction = unsafe UnsafeMutableRawPointer(
            bitPattern: observationTrackingCancelAddress
        )
    else {
        return
    }

    #if compiler(>=6.4)
    withUnsafePointer(to: tracking) { trackingPointer in
        unsafe OBObservationTrackingCancel(observationTrackingCancelFunction, trackingPointer)
    }
    #else
    unsafe withUnsafePointer(to: tracking) { trackingPointer in
        unsafe OBObservationTrackingCancel(observationTrackingCancelFunction, trackingPointer)
    }
    #endif
}

private func lookupObservationSymbol(_ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    unsafe dlsym(unsafe UnsafeMutableRawPointer(bitPattern: -2), name)
}
