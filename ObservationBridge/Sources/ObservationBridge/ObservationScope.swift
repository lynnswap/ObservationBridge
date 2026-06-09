import Darwin
import Foundation
import Observation
import Synchronization
import _ObservationBridgePrivateABI

/// Owns owner-bound observations for an explicit lifecycle.
///
/// Call `observe(...)` at lifecycle boundaries such as
/// view setup or cell configuration. The scope cancels all stored observations when it is
/// deallocated.
public final class ObservationScope: @unchecked Sendable {
    private let storage = Mutex(ObservationScopeStorage())

    /// Creates an empty observation scope.
    public init() {}

    /// Starts or replaces an owner-bound observation.
    ///
    /// The callback body is the tracking body: every observable property read from `owner` inside
    /// `apply` becomes part of the observation. Calling the same observation again from the same
    /// call site replaces the existing pipeline so the new callback body is tracked immediately.
    ///
    /// - Parameters:
    ///   - owner: The observable object whose properties are read by `apply`.
    ///   - options: Event delivery options. Defaults to ``ObservationOptions/didSet``.
    ///   - apply: The callback to run for the initial pass and selected subsequent events.
    ///   - isolation: The actor isolation used to start the observation.
    @discardableResult
    public func observe<Owner: AnyObject & Observable>(
        _ owner: Owner,
        options: ObservationOptions = .didSet,
        @_inheritActorContext _ apply: @escaping @isolated(any) @Sendable (ObservationEvent, Owner) -> Void,
        isolation: isolated (any Actor)? = #isolation,
        _fileID: StaticString = #fileID,
        _line: UInt = #line,
        _column: UInt = #column
    ) -> ObservationDelivery {
        let delivery = ObservationDelivery()
        let slot = installObservation(
            owner: owner,
            options: options,
            startIsolation: isolation,
            observationIsolation: apply.isolation ?? isolation,
            delivery: delivery,
            pipeline: TypedObservationScopeImplicitTrackingPipeline(apply),
            _fileID: _fileID,
            _line: _line,
            _column: _column
        )
        delivery.bind(to: slot)
        return delivery
    }

    /// Starts or replaces an owner-bound observation with explicit tracking dependencies.
    ///
    /// Only observable properties read from `owner` inside `tracking` become part of the
    /// observation. Observable properties read by `apply` are not tracked by this observation.
    /// Calling the same observation again from the same call site replaces the existing pipeline
    /// so the new tracking body is tracked immediately.
    ///
    /// - Parameters:
    ///   - owner: The observable object whose properties are read by `tracking` and `apply`.
    ///   - options: Event delivery options. Defaults to ``ObservationOptions/didSet``.
    ///   - tracking: The closure that reads the observable properties to track.
    ///   - apply: The callback to run for the initial pass and selected subsequent events.
    ///   - isolation: The actor isolation used to start the observation.
    @discardableResult
    public func observe<Owner: AnyObject & Observable>(
        _ owner: Owner,
        options: ObservationOptions = .didSet,
        @_inheritActorContext tracking: @escaping @isolated(any) @Sendable (Owner) -> Void,
        @_inheritActorContext _ apply: @escaping @isolated(any) @Sendable (ObservationEvent, Owner) -> Void,
        isolation: isolated (any Actor)? = #isolation,
        _fileID: StaticString = #fileID,
        _line: UInt = #line,
        _column: UInt = #column
    ) -> ObservationDelivery {
        let trackingIsolation = tracking.isolation ?? isolation
        let applyIsolation = apply.isolation ?? isolation
        let observationIsolation = resolveObservationIsolation(
            trackingIsolation: trackingIsolation,
            applyIsolation: applyIsolation
        )

        let delivery = ObservationDelivery()
        let slot = installObservation(
            owner: owner,
            options: options,
            startIsolation: isolation,
            observationIsolation: observationIsolation,
            delivery: delivery,
            pipeline: TypedObservationScopeExplicitTrackingPipeline(
                tracking: tracking,
                apply: apply
            ),
            _fileID: _fileID,
            _line: _line,
            _column: _column
        )
        delivery.bind(to: slot)
        return delivery
    }

    /// Cancels every observation currently owned by the scope.
    public func cancelAll() {
        let currentSlots = storage.withLock { storage in
            storage.takeAllSlots()
        }

        currentSlots.cancel()
    }

    deinit {
        cancelAll()
    }

    @discardableResult
    private func installObservation<Owner: AnyObject & Observable>(
        owner: Owner,
        options: ObservationOptions,
        startIsolation: isolated (any Actor)?,
        observationIsolation: (any Actor)?,
        delivery: ObservationDelivery,
        pipeline: any ObservationScopePipeline,
        _fileID: StaticString,
        _line: UInt,
        _column: UInt
    ) -> ObservationScopeSlot {
        let cancellationGeneration = storage.withLock { storage in
            storage.cancellationGeneration
        }
        let id = ObservationScopeID(
            fileID: _fileID,
            line: _line,
            column: _column
        )
        let slot = makeObservationSlot(
            owner: owner,
            options: options,
            isolation: observationIsolation,
            delivery: delivery,
            pipeline: pipeline
        )
        let insertion = storage.withLock { storage in
            storage.install(
                slot,
                for: id,
                expectedCancellationGeneration: cancellationGeneration
            )
        }
        insertion.replacedSlot?.cancel()
        if insertion.shouldCancelNewSlot {
            slot.cancel()
        }
        insertion.slotToStart?.start(isolation: startIsolation)
        return slot
    }

    private func makeObservationSlot<Owner: AnyObject & Observable>(
        owner: Owner,
        options: ObservationOptions,
        isolation: (any Actor)?,
        delivery: ObservationDelivery,
        pipeline: any ObservationScopePipeline
    ) -> ObservationScopeSlot {
        ObservationScopeSlot(
            owner: owner,
            options: options,
            observationIsolation: isolation,
            delivery: delivery,
            pipeline: pipeline
        )
    }

    private func resolveObservationIsolation(
        trackingIsolation: (any Actor)?,
        applyIsolation: (any Actor)?
    ) -> (any Actor)? {
        let trackingActorID = observationScopeActorID(trackingIsolation)
        let applyActorID = observationScopeActorID(applyIsolation)

        if let trackingActorID, let applyActorID, trackingActorID != applyActorID {
            preconditionFailure("Observation tracking and apply closures must use the same actor isolation.")
        }

        return applyIsolation ?? trackingIsolation
    }
}

private struct ObservationScopeStorage {
    var cancellationGeneration: UInt64 = 0
    var singleID: ObservationScopeID?
    var singleSlot: ObservationScopeSlot?
    var slots: [ObservationScopeDictionaryID: ObservationScopeSlot]?

    mutating func install(
        _ slot: ObservationScopeSlot,
        for id: ObservationScopeID,
        expectedCancellationGeneration: UInt64
    ) -> ObservationScopeInsertion {
        guard cancellationGeneration == expectedCancellationGeneration else {
            return ObservationScopeInsertion(
                slotToStart: nil,
                replacedSlot: nil,
                shouldCancelNewSlot: true
            )
        }

        if slots != nil {
            let replacedSlot = slots!.updateValue(slot, forKey: ObservationScopeDictionaryID(id))
            return ObservationScopeInsertion(
                slotToStart: slot,
                replacedSlot: replacedSlot,
                shouldCancelNewSlot: false
            )
        }

        if let currentID = singleID, let currentSlot = singleSlot {
            if currentID == id {
                singleSlot = slot
                return ObservationScopeInsertion(
                    slotToStart: slot,
                    replacedSlot: currentSlot,
                    shouldCancelNewSlot: false
                )
            }

            slots = [
                ObservationScopeDictionaryID(currentID): currentSlot,
                ObservationScopeDictionaryID(id): slot,
            ]
            singleID = nil
            singleSlot = nil
            return ObservationScopeInsertion(
                slotToStart: slot,
                replacedSlot: nil,
                shouldCancelNewSlot: false
            )
        }

        singleID = id
        singleSlot = slot
        return ObservationScopeInsertion(
            slotToStart: slot,
            replacedSlot: nil,
            shouldCancelNewSlot: false
        )
    }

    mutating func takeAllSlots() -> ObservationScopeSlotBatch {
        cancellationGeneration &+= 1

        if let slot = singleSlot {
            singleID = nil
            singleSlot = nil
            return .single(slot)
        }

        guard let currentSlots = slots else {
            return .empty
        }

        slots = nil
        return .many(Array(currentSlots.values))
    }
}

private struct ObservationScopeInsertion {
    let slotToStart: ObservationScopeSlot?
    let replacedSlot: ObservationScopeSlot?
    let shouldCancelNewSlot: Bool
}

private enum ObservationScopeSlotBatch {
    case empty
    case single(ObservationScopeSlot)
    case many([ObservationScopeSlot])

    func cancel() {
        switch self {
        case .empty:
            return
        case .single(let slot):
            slot.cancel()
        case .many(let slots):
            for slot in slots {
                slot.cancel()
            }
        }
    }
}

func runScopedObservationLoop(
    options: ObservationOptions,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot
) async {
    #if compiler(>=6.4)
    if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *),
       !shouldForceLegacyScopedObservation {
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
    options: ObservationOptions,
    isolation: isolated (any Actor)?,
    slot: ObservationScopeSlot
) -> InitialScopedObservationResult {
    #if compiler(>=6.4)
    if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *),
       !shouldForceLegacyScopedObservation {
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
    options: ObservationOptions,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot,
    nextKind: ObservationEvent.Kind
) async {
    #if compiler(>=6.4)
    if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *),
       !shouldForceLegacyScopedObservation {
        await runNativeScopedObservationLoopAfterInitialPass(
            options: options,
            isolation: isolation,
            slot: slot,
            nextKind: nextKind
        )
        return
    }
    #endif

    await runLegacyScopedObservationLoopAfterInitialPass(
        options: options,
        isolation: isolation,
        slot: slot,
        nextKind: nextKind
    )
}

#if compiler(>=6.4)
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
private func runNativeScopedObservationLoop(
    options: ObservationOptions,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot
) async {
    var kind = ObservationEvent.Kind.initial

    while !Task.isCancelled {
        guard await trackNativeScopedObservation(
            kind: kind,
            options: options,
            isolation: isolation,
            slot: slot
        ) else {
            break
        }

        guard nativeTrackingOptions(for: options) != nil else {
            break
        }

        guard await slot.waitForChange() else {
            break
        }

        kind = .didSet
    }

    slot.cancel()
}

@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
private func runInitialNativeScopedObservationPass(
    options: ObservationOptions,
    isolation _: isolated (any Actor)?,
    slot: ObservationScopeSlot
) -> InitialScopedObservationResult {
    let result = trackNativeScopedObservationInCurrentContext(
        kind: .initial,
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

    return .waitingForChange(.didSet)
}

@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
private func runNativeScopedObservationLoopAfterInitialPass(
    options: ObservationOptions,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot,
    nextKind: ObservationEvent.Kind
) async {
    var kind = nextKind

    while !Task.isCancelled {
        guard await slot.waitForChange() else {
            break
        }

        guard await trackNativeScopedObservation(
            kind: kind,
            options: options,
            isolation: isolation,
            slot: slot
        ) else {
            break
        }

        guard nativeTrackingOptions(for: options) != nil else {
            break
        }

        kind = .didSet
    }

    slot.cancel()
}

@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
private func trackNativeScopedObservation(
    kind: ObservationEvent.Kind,
    options: ObservationOptions,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot
) async -> Bool {
    let result = await withObservationIsolation(isolation: isolation) {
        trackNativeScopedObservationInCurrentContext(
            kind: kind,
            options: options,
            slot: slot
        )
    }
    await result.sampleAndFinish()
    return result.shouldContinue
}

@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
private func trackNativeScopedObservationInCurrentContext(
    kind: ObservationEvent.Kind,
    options: ObservationOptions,
    slot: ObservationScopeSlot
) -> ScopedObservationTrackResult {
    guard let pipeline = slot.pipelineSnapshot() else {
        return ScopedObservationTrackResult(shouldContinue: false, completion: nil)
    }

    let event = ObservationEvent(kind: kind, slot: slot)

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
    if pipeline.appliesInsideTracking {
        withObservationTracking(options: trackingOptions) {
            didApply = pipeline.apply(event: event)
        } onChange: { nativeEvent in
            nativeEvent.cancel()
            slot.emitChange()
        }

        return complete(shouldContinue: slot.isActive, didApply: didApply)
    }

    var didTrack = false
    withObservationTracking(options: trackingOptions) {
        didTrack = pipeline.track()
    } onChange: { nativeEvent in
        nativeEvent.cancel()
        slot.emitChange()
    }

    guard didTrack else {
        return complete(shouldContinue: false, didApply: false)
    }

    didApply = pipeline.apply(event: event)

    return complete(shouldContinue: slot.isActive && didTrack, didApply: didApply)
}

@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
private func nativeTrackingOptions(for options: ObservationOptions) -> ObservationTracking.Options? {
    guard options.contains(.didSet) else {
        return nil
    }

    return .didSet
}

private var shouldForceLegacyScopedObservation: Bool {
    _ObservationScopeTesting.forcePublicDidSetFallback.withLock { $0 }
}
#endif

private func runLegacyScopedObservationLoop(
    options: ObservationOptions,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot
) async {
    var kind = ObservationEvent.Kind.initial

    while !Task.isCancelled {
        let changeKind = legacyChangeKind(for: options)

        guard await trackLegacyScopedObservation(
            kind: kind,
            changeKind: changeKind,
            isolation: isolation,
            slot: slot
        ) else {
            break
        }

        guard let changeKind else {
            break
        }

        guard await slot.waitForChange() else {
            break
        }

        kind = changeKind
    }

    slot.cancel()
}

func runInitialLegacyScopedObservationPass(
    options: ObservationOptions,
    isolation _: isolated (any Actor)?,
    slot: ObservationScopeSlot
) -> InitialScopedObservationResult {
    let changeKind = legacyChangeKind(for: options)

    let result = trackLegacyScopedObservationInCurrentContext(
        kind: .initial,
        changeKind: changeKind,
        slot: slot
    )
    result.finishWithoutSampling()

    guard result.shouldContinue else {
        slot.cancel()
        return .finished
    }

    guard let changeKind else {
        slot.cancel()
        return .finished
    }

    return .waitingForChange(changeKind)
}

func runLegacyScopedObservationLoopAfterInitialPass(
    options: ObservationOptions,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot,
    nextKind: ObservationEvent.Kind
) async {
    var kind = nextKind

    while !Task.isCancelled {
        guard await slot.waitForChange() else {
            break
        }

        let changeKind = legacyChangeKind(for: options)

        guard await trackLegacyScopedObservation(
            kind: kind,
            changeKind: changeKind,
            isolation: isolation,
            slot: slot
        ) else {
            break
        }

        guard let changeKind else {
            break
        }

        kind = changeKind
    }

    slot.cancel()
}

private func trackLegacyScopedObservation(
    kind: ObservationEvent.Kind,
    changeKind: ObservationEvent.Kind?,
    isolation: (any Actor)?,
    slot: ObservationScopeSlot
) async -> Bool {
    let result = await withObservationIsolation(isolation: isolation) {
        trackLegacyScopedObservationInCurrentContext(
            kind: kind,
            changeKind: changeKind,
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
    kind: ObservationEvent.Kind,
    changeKind: ObservationEvent.Kind?,
    slot: ObservationScopeSlot
) -> ScopedObservationTrackResult {
    guard let pipeline = slot.pipelineSnapshot() else {
        return ScopedObservationTrackResult(shouldContinue: false, completion: nil)
    }

    let event = ObservationEvent(kind: kind, slot: slot)

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

    guard let changeKind else {
        let didApply = pipeline.apply(event: event)
        return complete(shouldContinue: slot.isActive, didApply: didApply)
    }

    var didApply = false
    if pipeline.appliesInsideTracking {
        if changeKind == .didSet {
            guard withObservationTrackingDidSetIfAvailable({
                didApply = pipeline.apply(event: event)
            }, didSet: { tracking in
                cancelObservationTrackingIfAvailable(tracking)
                slot.emitChange()
            }) else {
                return complete(shouldContinue: false, didApply: didApply)
            }
        } else {
            withObservationTracking {
                didApply = pipeline.apply(event: event)
            } onChange: {
                slot.emitChange()
            }
        }

        return complete(shouldContinue: slot.isActive, didApply: didApply)
    }

    var didTrack = false
    if changeKind == .didSet {
        guard withObservationTrackingDidSetIfAvailable({
            didTrack = pipeline.track()
        }, didSet: { tracking in
            cancelObservationTrackingIfAvailable(tracking)
            slot.emitChange()
        }) else {
            return complete(shouldContinue: false, didApply: didApply)
        }
    } else {
        withObservationTracking {
            didTrack = pipeline.track()
        } onChange: {
            slot.emitChange()
        }
    }

    guard didTrack else {
        return complete(shouldContinue: false, didApply: false)
    }

    didApply = pipeline.apply(event: event)

    return complete(shouldContinue: slot.isActive && didTrack, didApply: didApply)
}

private func legacyChangeKind(for options: ObservationOptions) -> ObservationEvent.Kind? {
    // Public `withObservationTracking` only exposes will-set timing. Without the hidden did-set
    // SPI, avoid synthesizing an event that can re-read stale values while claiming `.didSet`.
    guard options.contains(.didSet), canUseObservationTrackingDidSetSPI else {
        return nil
    }

    return .didSet
}

private func withObservationIsolation<T: Sendable>(
    isolation: isolated (any Actor)?,
    _ operation: () -> T
) -> T {
    // The isolated parameter makes the caller hop to `isolation` before this body runs.
    return operation()
}

// `ObservationTracking` is hidden from the Swift 6.2 public interface even though the
// didSet SPI passes it to this closure. Use a resilient imported value as the opaque
// ABI carrier so Swift forwards the hidden value with the same indirect convention.
private typealias OpaqueObservationTracking = URL

@_weakLinked
@_silgen_name("$s11Observation04withA8Tracking_6didSetxxyXE_yAA0aC0VYbctlF")
private func _withObservationTrackingDidSet<T>(
    _ apply: () -> T,
    didSet: @escaping @Sendable (OpaqueObservationTracking) -> Void
) -> T

private let observationTrackingDidSetAddress: UInt? =
    unsafe lookupObservationSymbol("$s11Observation04withA8Tracking_6didSetxxyXE_yAA0aC0VYbctlF")
        .map { UInt(bitPattern: $0) }

private let observationTrackingCancelAddress: UInt? =
    unsafe lookupObservationSymbol("$s11Observation0A8TrackingV6cancelyyF")
        .map { UInt(bitPattern: $0) }

private var canUseObservationTrackingDidSetSPI: Bool {
    if _ObservationScopeTesting.forcePublicDidSetFallback.withLock({ $0 }) {
        return false
    }

    #if arch(arm64) || arch(x86_64)
    return observationTrackingDidSetAddress != nil && observationTrackingCancelAddress != nil
    #else
    return false
    #endif
}

enum _ObservationScopeTesting {
    static let forcePublicDidSetFallback = Mutex(false)
}

private func withObservationTrackingDidSetIfAvailable(
    _ apply: () -> Void,
    didSet: @escaping @Sendable (OpaqueObservationTracking) -> Void
) -> Bool {
    guard canUseObservationTrackingDidSetSPI else {
        return false
    }

    _withObservationTrackingDidSet(apply, didSet: didSet)
    return true
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

    unsafe withUnsafePointer(to: tracking) { trackingPointer in
        unsafe OBObservationTrackingCancel(observationTrackingCancelFunction, trackingPointer)
    }
}

private func lookupObservationSymbol(_ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    unsafe dlsym(unsafe UnsafeMutableRawPointer(bitPattern: -2), name)
}
