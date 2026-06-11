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
///   - isolation: The actor isolation used to start the observation.
/// - Returns: A token that keeps the observation alive until cancelled or deinitialized.
public func withPortableContinuousObservation(
    options: PortableObservationTracking.Options = .didSet,
    @_inheritActorContext apply: @escaping @isolated(any) @Sendable (borrowing PortableObservationTracking.Event) -> Void,
    isolation: isolated (any Actor)? = #isolation
) -> PortableObservationTracking.Token {
    let delivery = ObservationDelivery()
    let slot = ObservationScopeSlot(
        options: options,
        observationIsolation: apply.isolation ?? isolation,
        delivery: delivery,
        pipeline: ObservationScopeImplicitTrackingPipeline(apply)
    )
    delivery.bind(to: slot)
    let token = PortableObservationTracking.Token(slot: slot, delivery: delivery)
    slot.start(isolation: isolation)
    return token
}

// Will/did-set events go through the continuous SPI backend on every OS so trigger key
// paths can be captured for `PortableObservationTracking.Event.matches(_:)`
// without an untracked window between passes. The native
// `withObservationTracking(options:)` backend is used when `.deinit` events are
// requested (dependency deinit cannot be observed any other way), or as the
// did-set fallback when the SPI symbols are unavailable: the public native API
// still observes did-set changes that the public legacy API cannot deliver.
func runScopedObservationLoop(
    options: PortableObservationTracking.Options,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot
) async {
    #if compiler(>=6.4)
    if #available(anyAppleOS 27.0, *),
       shouldUseNativeScopedObservation(for: options) {
        await runNativeScopedObservationLoop(
            options: options,
            isolation: isolation,
            slot: slot
        )
        return
    }
    #endif

    await runLegacyScopedObservationLoop(
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
    #if compiler(>=6.4)
    if #available(anyAppleOS 27.0, *),
       shouldUseNativeScopedObservation(for: options) {
        return runInitialNativeScopedObservationPass(
            options: options,
            isolation: isolation,
            slot: slot
        )
    }
    #endif

    return runInitialLegacyScopedObservationPass(
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
    #if compiler(>=6.4)
    if #available(anyAppleOS 27.0, *),
       shouldUseNativeScopedObservation(for: options) {
        await runNativeScopedObservationLoopAfterInitialPass(
            options: options,
            isolation: isolation,
            slot: slot
        )
        return
    }
    #endif

    await runLegacyScopedObservationLoopAfterInitialPass(
        options: options,
        isolation: isolation,
        slot: slot
    )
}

#if compiler(>=6.4)
@available(anyAppleOS 27.0, *)
private func runNativeScopedObservationLoop(
    options: PortableObservationTracking.Options,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot
) async {
    var pendingEvent = ObservationScopePendingEvent.initial

    while !Task.isCancelled {
        guard await trackNativeScopedObservation(
            event: pendingEvent,
            options: options,
            isolation: isolation,
            slot: slot
        ) else {
            break
        }

        guard nativeTrackingOptions(for: options) != nil else {
            break
        }

        guard let nextEvent = await slot.waitForChange() else {
            break
        }

        pendingEvent = nextEvent
    }

    slot.cancel()
}

@available(anyAppleOS 27.0, *)
private func runInitialNativeScopedObservationPass(
    options: PortableObservationTracking.Options,
    isolation _: isolated (any Actor)?,
    slot: ObservationScopeSlot
) -> InitialScopedObservationResult {
    let result = trackNativeScopedObservationInCurrentContext(
        event: .initial,
        options: options,
        slot: slot
    )
    result.finishWithoutSampling()

    guard result.shouldContinue else {
        slot.cancel()
        return .finished
    }

    guard nativeTrackingOptions(for: options) != nil else {
        slot.cancel()
        return .finished
    }

    return .waitingForChange
}

@available(anyAppleOS 27.0, *)
private func runNativeScopedObservationLoopAfterInitialPass(
    options: PortableObservationTracking.Options,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot
) async {
    while !Task.isCancelled {
        guard let pendingEvent = await slot.waitForChange() else {
            break
        }

        guard await trackNativeScopedObservation(
            event: pendingEvent,
            options: options,
            isolation: isolation,
            slot: slot
        ) else {
            break
        }

        guard nativeTrackingOptions(for: options) != nil else {
            break
        }

    }

    slot.cancel()
}

@available(anyAppleOS 27.0, *)
private func trackNativeScopedObservation(
    event pendingEvent: ObservationScopePendingEvent,
    options: PortableObservationTracking.Options,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot
) async -> Bool {
    let result = await withObservationIsolation(isolation: isolation) {
        trackNativeScopedObservationInCurrentContext(
            event: pendingEvent,
            options: options,
            slot: slot
        )
    }
    await result.sampleAndFinish()
    return result.shouldContinue
}

@available(anyAppleOS 27.0, *)
private func trackNativeScopedObservationInCurrentContext(
    event pendingEvent: ObservationScopePendingEvent,
    options: PortableObservationTracking.Options,
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

    guard let trackingOptions = nativeTrackingOptions(for: options) else {
        let didApply = pipeline.apply(event: event)
        return complete(shouldContinue: slot.isActive, didApply: didApply)
    }

    var didApply = false
    withObservationTracking(options: trackingOptions) {
        didApply = pipeline.apply(event: event)
    } onChange: { nativeEvent in
        emitNativeScopedObservationChange(nativeEvent, slot: slot)
    }

    return complete(shouldContinue: slot.isActive, didApply: didApply)
}

@available(anyAppleOS 27.0, *)
private func nativeTrackingOptions(for options: PortableObservationTracking.Options) -> ObservationTracking.Options? {
    var trackingOptions = ObservationTracking.Options()
    var hasOptions = false

    if options.contains(.didSet) {
        trackingOptions.insert(.didSet)
        hasOptions = true
    } else if options.contains(.willSet) {
        trackingOptions.insert(.willSet)
        hasOptions = true
    }
    if options.contains(.deinit) {
        trackingOptions.insert(.deinit)
        hasOptions = true
    }

    guard hasOptions else {
        return nil
    }

    return trackingOptions
}

@available(anyAppleOS 27.0, *)
private func emitNativeScopedObservationChange(
    _ nativeEvent: borrowing ObservationTracking.Event,
    slot: ObservationScopeSlot
) {
    let kind = nativeScopedObservationEventKind(for: nativeEvent.kind)
    nativeEvent.cancel()

    guard let kind else {
        return
    }

    // The public native Event only answers per-candidate `matches` probes, so the trigger
    // key path cannot be extracted here. Deinit passes are never key-path-triggered;
    // will/did-set passes degrade to conservative `matches` results.
    let triggers: ObservationEventTriggers = kind == .deinit ? .none : .unknown
    slot.emitChange(kind: kind, triggers: triggers)
}

@available(anyAppleOS 27.0, *)
private func nativeScopedObservationEventKind(
    for nativeKind: ObservationTracking.Event.Kind
) -> PortableObservationTracking.Event.Kind? {
    if nativeKind == .didSet {
        return .didSet
    }
    if nativeKind == .willSet {
        return .willSet
    }
    if nativeKind == .deinit {
        return .deinit
    }

    return nil
}

@available(anyAppleOS 27.0, *)
private func shouldUseNativeScopedObservation(for options: PortableObservationTracking.Options) -> Bool {
    if shouldForceLegacyScopedObservation {
        return false
    }

    if options.contains(.deinit) {
        return true
    }

    return options.contains(.didSet) && !canUseObservationTrackingSPI
}

private var shouldForceLegacyScopedObservation: Bool {
    _ObservationScopeTesting.forcePublicDidSetFallback.withLock { $0 }
}
#endif

private func runLegacyScopedObservationLoop(
    options: PortableObservationTracking.Options,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot
) async {
    var pendingEvent = ObservationScopePendingEvent.initial

    while !Task.isCancelled {
        let mode = legacyTrackingMode(for: options)

        guard await trackLegacyScopedObservation(
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

func runInitialLegacyScopedObservationPass(
    options: PortableObservationTracking.Options,
    isolation _: isolated (any Actor)?,
    slot: ObservationScopeSlot
) -> InitialScopedObservationResult {
    let mode = legacyTrackingMode(for: options)

    let result = trackLegacyScopedObservationInCurrentContext(
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

func runLegacyScopedObservationLoopAfterInitialPass(
    options: PortableObservationTracking.Options,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot
) async {
    while !Task.isCancelled {
        guard let pendingEvent = await slot.waitForChange() else {
            break
        }

        let mode = legacyTrackingMode(for: options)

        guard await trackLegacyScopedObservation(
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

private func trackLegacyScopedObservation(
    event pendingEvent: ObservationScopePendingEvent,
    mode: LegacyScopedTrackingMode?,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot
) async -> Bool {
    let result = await withObservationIsolation(isolation: isolation) {
        trackLegacyScopedObservationInCurrentContext(
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

private func trackLegacyScopedObservationInCurrentContext(
    event pendingEvent: ObservationScopePendingEvent,
    mode: LegacyScopedTrackingMode?,
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
    case .continuous(let kind):
        let generation = slot.beginTrackingPass()
        let handleFire: @Sendable (OpaqueObservationTracking) -> Void = { [weak slot] tracking in
            guard let slot else {
                cancelObservationTrackingIfAvailable(tracking)
                return
            }

            let directive = slot.acceptTrackingEvent(
                generation: generation,
                kind: kind,
                triggers: .keyPath(observationTrackingChangedKeyPath(tracking))
            )
            if directive == .cancelTracking {
                cancelObservationTrackingIfAvailable(tracking)
            }
        }

        if kind == .didSet {
            didApply = _withObservationTrackingDidSet({
                pipeline.apply(event: event)
            }, didSet: handleFire)
        } else {
            didApply = _withObservationTrackingWillSet({
                pipeline.apply(event: event)
            }, willSet: handleFire)
        }
        slot.markTrackingArmed(generation)
    case .publicOneShot(let kind):
        withObservationTracking {
            didApply = pipeline.apply(event: event)
        } onChange: {
            slot.emitChange(kind: kind, triggers: .unknown)
        }
    }

    return complete(shouldContinue: slot.isActive, didApply: didApply)
}

private enum LegacyScopedTrackingMode: Equatable {
    /// SPI-based tracking that stays armed across passes and captures trigger key paths.
    case continuous(PortableObservationTracking.Event.Kind)

    /// Public `withObservationTracking` fallback: one-shot, will-set timing, no key paths.
    case publicOneShot(PortableObservationTracking.Event.Kind)
}

private func legacyTrackingMode(for options: PortableObservationTracking.Options) -> LegacyScopedTrackingMode? {
    // Public `withObservationTracking` only exposes will-set timing. Without the hidden SPI,
    // avoid synthesizing an event that can re-read stale values while claiming `.didSet`.
    if options.contains(.didSet) {
        if canUseObservationTrackingSPI {
            return .continuous(.didSet)
        }

        if options.contains(.willSet) {
            return .publicOneShot(.willSet)
        }

        return nil
    }

    if options.contains(.willSet) {
        if canUseObservationTrackingSPI {
            return .continuous(.willSet)
        }

        return .publicOneShot(.willSet)
    }

    return nil
}

private func makeScopedObservationEvent(
    _ pendingEvent: ObservationScopePendingEvent,
    slot: ObservationScopeSlot
) -> PortableObservationTracking.Event {
    guard pendingEvent.kind == .initial else {
        return PortableObservationTracking.Event(kind: pendingEvent.kind, triggers: pendingEvent.triggers)
    }

    return PortableObservationTracking.Event(kind: pendingEvent.kind) { [weak slot] in
        slot?.cancel()
    }
}

private func withObservationIsolation<T: Sendable>(
    isolation: isolated (any Actor)?,
    _ operation: () -> T
) -> T {
    // The isolated parameter makes the caller hop to `isolation` before this body runs.
    return operation()
}

// `ObservationTracking` is hidden from the Swift 6.2 public interface even though the
// willSet/didSet SPIs pass it to these closures. Use a resilient imported value as the
// opaque ABI carrier so Swift forwards the hidden value with the same indirect convention.
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

// `changed` is not required: when its getter is missing, continuous tracking still works
// and events degrade to unknown triggers (conservative `matches`). `cancel` is required
// because superseded trackings must be able to cancel themselves.
private var canUseObservationTrackingSPI: Bool {
    if _ObservationScopeTesting.forcePublicDidSetFallback.withLock({ $0 }) {
        return false
    }
    if _ObservationScopeTesting.forceContinuousTrackingSPIUnavailable.withLock({ $0 }) {
        return false
    }

    #if arch(arm64) || arch(x86_64)
    return observationTrackingDidSetAddress != nil
        && observationTrackingWillSetAddress != nil
        && observationTrackingCancelAddress != nil
    #else
    return false
    #endif
}

enum _ObservationScopeTesting {
    /// Forces the public-API fallback on every backend, including the native one.
    static let forcePublicDidSetFallback = Mutex(false)

    /// Simulates missing SPI symbols while leaving the native backend available.
    static let forceContinuousTrackingSPIUnavailable = Mutex(false)
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
