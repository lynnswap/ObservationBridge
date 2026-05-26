import Darwin
import Foundation
import Observation
import Synchronization
import _ObservationBridgePrivateABI

/// Owns owner-bound observations for an explicit lifecycle.
///
/// Call ``observe(_:options:_:isolation:_fileID:_line:_column:)`` at lifecycle boundaries such as
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
    public func observe<Owner: AnyObject & Observable>(
        _ owner: Owner,
        options: ObservationOptions = .didSet,
        @_inheritActorContext _ apply: @escaping @isolated(any) @Sendable (ObservationEvent, Owner) -> Void,
        isolation: isolated (any Actor)? = #isolation,
        _fileID: StaticString = #fileID,
        _line: UInt = #line,
        _column: UInt = #column
    ) {
        installObservation(
            owner: owner,
            options: options,
            startIsolation: isolation,
            observationIsolation: apply.isolation ?? isolation,
            callbackIsolation: apply.isolation,
            apply: apply,
            _fileID: _fileID,
            _line: _line,
            _column: _column
        )
    }

    /// Starts or replaces an owner-bound observation that records callback-produced values.
    ///
    /// This overload is intended for tests that need to wait for a specific observed value without
    /// maintaining a separate recorder. The callback body is still the tracking body.
    ///
    /// - Returns: A value recorder tied to the lifetime of the installed observation.
    public func observe<Owner: AnyObject & Observable, Value: Sendable>(
        _ owner: Owner,
        options: ObservationOptions = .didSet,
        @_inheritActorContext _ apply: @escaping @isolated(any) @Sendable (ObservationEvent, Owner) -> Value,
        isolation: isolated (any Actor)? = #isolation,
        _fileID: StaticString = #fileID,
        _line: UInt = #line,
        _column: UInt = #column
    ) -> ObservedValues<Value> {
        let values = ObservedValues<Value>()
        let valueCallbackBox: any ObservationScopeAnyValueCallbackBox =
            ObservationScopeValueCallbackBox(callback: apply, values: values)
        let recordingCallback: @isolated(any) @Sendable (ObservationEvent, Owner) -> Void =
            makeObservationValueRecordingCallback(valueCallbackBox)
        let handle = installObservation(
            owner: owner,
            options: options,
            startIsolation: isolation,
            observationIsolation: apply.isolation ?? isolation,
            callbackIsolation: apply.isolation,
            onFinish: { [values] in
                values.finish()
            },
            apply: recordingCallback,
            _fileID: _fileID,
            _line: _line,
            _column: _column
        )
        values.setCancelOperation {
            handle.cancel()
        }
        return values
    }

    /// Cancels every observation currently owned by the scope.
    public func cancelAll() {
        let currentSlots = storage.withLock { storage in
            storage.cancellationGeneration &+= 1
            let currentSlots = Array(storage.slots.values)
            storage.slots.removeAll(keepingCapacity: true)
            return currentSlots
        }

        for slot in currentSlots {
            slot.cancel()
        }
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
        callbackIsolation: (any Actor)?,
        onFinish: @escaping @Sendable () -> Void = {},
        apply: @escaping @isolated(any) @Sendable (ObservationEvent, Owner) -> Void,
        _fileID: StaticString,
        _line: UInt,
        _column: UInt
    ) -> ObservationHandle {
        let cancellationGeneration = storage.withLock { storage in
            storage.cancellationGeneration
        }
        let id = ObservationScopeID(
            fileID: String(describing: _fileID),
            line: _line,
            column: _column
        )
        let descriptor = ObservationScopeDescriptor(
            owner: owner,
            options: options,
            observationIsolation: observationIsolation,
            callbackIsolation: callbackIsolation
        )
        let slot = makeObservationSlot(
            owner: owner,
            descriptor: descriptor,
            options: options,
            isolation: observationIsolation,
            onFinish: onFinish,
            apply: apply
        )
        let insertion = storage.withLock { storage -> (slotToStart: (any ObservationScopeSlotProtocol)?, shouldCancelNewSlot: Bool) in
            guard storage.cancellationGeneration == cancellationGeneration else {
                return (nil, true)
            }

            let replacedSlot = storage.slots.updateValue(slot, forKey: id)
            replacedSlot?.cancel()
            return (slot, false)
        }
        if insertion.shouldCancelNewSlot {
            slot.cancel()
        }
        insertion.slotToStart?.start(isolation: startIsolation)
        return slot.handle
    }

    private func makeObservationSlot<Owner: AnyObject & Observable>(
        owner: Owner,
        descriptor: ObservationScopeDescriptor,
        options: ObservationOptions,
        isolation: (any Actor)?,
        onFinish: @escaping @Sendable () -> Void,
        apply: @escaping @isolated(any) @Sendable (ObservationEvent, Owner) -> Void
    ) -> ObservationScopeSlot<Owner> {
        let ownerToken = WeakOwnerRegistry.createToken(owner: owner)
        let state = ScopedObservationState()
        let lifetime = ObservationExecutionLifetime()
        let callbackBox = ObservationScopeCallbackBox(apply)
        let callbackCleaner: any ObservationScopeCallbackClearing = callbackBox
        let runner: any ScopedObservationRunner = TypedScopedObservationRunner(callbackBox: callbackBox)
        let taskBox = ObservationTaskBox()
        lifetime.addCancellationHandler {
            WeakOwnerRegistry.removeToken(ownerToken)
        }
        lifetime.addCancellationHandler {
            state.terminate()
        }
        lifetime.addCancellationHandler(onFinish)
        lifetime.addCancellationHandler {
            callbackCleaner.clear()
        }

        let handle = ObservationHandle {
            lifetime.cancel()
            taskBox.finish()
        }
        OwnerCancellationRegistry.register(handle, owner: owner)

        return ObservationScopeSlot(
            descriptor: descriptor,
            state: state,
            handle: handle,
            taskBox: taskBox,
            callbackBox: callbackBox
        ) { currentIsolation in
            let startsInCurrentIsolation =
                observationScopeActorID(isolation) == observationScopeActorID(currentIsolation)

            if startsInCurrentIsolation {
                switch runner.runInitialPass(
                    ownerToken: ownerToken,
                    options: options,
                    isolation: currentIsolation,
                    state: state
                ) {
                case .waitingForChange(let kind):
                    return makeObservationTask {
                        defer {
                            lifetime.cancel()
                        }

                        await runner.runAfterInitialPass(
                            ownerToken: ownerToken,
                            options: options,
                            isolation: isolation,
                            state: state,
                            nextKind: kind
                        )
                    }
                case .finished:
                    lifetime.cancel()
                    return nil
                }
            }

            return makeObservationTask {
                defer {
                    lifetime.cancel()
                }

                await runner.run(
                    ownerToken: ownerToken,
                    options: options,
                    isolation: isolation,
                    state: state
                )
            }
        }
    }
}

private struct ObservationScopeStorage {
    var cancellationGeneration: UInt64 = 0
    var slots: [ObservationScopeID: any ObservationScopeSlotProtocol] = [:]
}

func runScopedObservationLoop<Owner: AnyObject & Observable>(
    ownerToken: UInt64,
    options: ObservationOptions,
    isolation: (any Actor)?,
    state: ScopedObservationState,
    callbackBox: ObservationScopeCallbackBox<Owner>
) async {
    #if compiler(>=6.4)
    // TODO: Replace this fallback with native withContinuousObservation(options:apply:)
    // and ObservationTracking.Event forwarding once the Swift 6.4 API is available.
    #endif
    await runLegacyScopedObservationLoop(
        ownerToken: ownerToken,
        options: options,
        isolation: isolation,
        state: state,
        callbackBox: callbackBox
    )
}

private func runLegacyScopedObservationLoop<Owner: AnyObject & Observable>(
    ownerToken: UInt64,
    options: ObservationOptions,
    isolation: (any Actor)?,
    state: ScopedObservationState,
    callbackBox: ObservationScopeCallbackBox<Owner>
) async {
    var kind = ObservationEvent.Kind.initial

    while !Task.isCancelled {
        let changeKind = legacyChangeKind(for: options)

        guard await trackLegacyScopedObservation(
            ownerToken: ownerToken,
            kind: kind,
            changeKind: changeKind,
            isolation: isolation,
            state: state,
            callbackBox: callbackBox
        ) else {
            break
        }

        guard let changeKind else {
            break
        }

        guard await state.waitForChange() else {
            break
        }

        kind = changeKind
    }

    state.terminate()
}

func runInitialLegacyScopedObservationPass<Owner: AnyObject & Observable>(
    ownerToken: UInt64,
    options: ObservationOptions,
    isolation _: isolated (any Actor)?,
    state: ScopedObservationState,
    callbackBox: ObservationScopeCallbackBox<Owner>
) -> InitialLegacyScopedObservationResult {
    let changeKind = legacyChangeKind(for: options)

    guard trackLegacyScopedObservationInCurrentContext(
        ownerToken: ownerToken,
        kind: .initial,
        changeKind: changeKind,
        state: state,
        callbackBox: callbackBox
    ) else {
        state.terminate()
        return .finished
    }

    guard let changeKind else {
        state.terminate()
        return .finished
    }

    return .waitingForChange(changeKind)
}

func runLegacyScopedObservationLoopAfterInitialPass<Owner: AnyObject & Observable>(
    ownerToken: UInt64,
    options: ObservationOptions,
    isolation: (any Actor)?,
    state: ScopedObservationState,
    callbackBox: ObservationScopeCallbackBox<Owner>,
    nextKind: ObservationEvent.Kind
) async {
    var kind = nextKind

    while !Task.isCancelled {
        guard await state.waitForChange() else {
            break
        }

        let changeKind = legacyChangeKind(for: options)

        guard await trackLegacyScopedObservation(
            ownerToken: ownerToken,
            kind: kind,
            changeKind: changeKind,
            isolation: isolation,
            state: state,
            callbackBox: callbackBox
        ) else {
            break
        }

        guard let changeKind else {
            break
        }

        kind = changeKind
    }

    state.terminate()
}

private func trackLegacyScopedObservation<Owner: AnyObject & Observable>(
    ownerToken: UInt64,
    kind: ObservationEvent.Kind,
    changeKind: ObservationEvent.Kind?,
    isolation: (any Actor)?,
    state: ScopedObservationState,
    callbackBox: ObservationScopeCallbackBox<Owner>
) async -> Bool {
    await withObservationIsolation(isolation: isolation) {
        trackLegacyScopedObservationInCurrentContext(
            ownerToken: ownerToken,
            kind: kind,
            changeKind: changeKind,
            state: state,
            callbackBox: callbackBox
        )
    }
}

private func trackLegacyScopedObservationInCurrentContext<Owner: AnyObject & Observable>(
    ownerToken: UInt64,
    kind: ObservationEvent.Kind,
    changeKind: ObservationEvent.Kind?,
    state: ScopedObservationState,
    callbackBox: ObservationScopeCallbackBox<Owner>
) -> Bool {
    guard !state.isTerminated else {
        return false
    }

    guard let owner = WeakOwnerRegistry.owner(token: ownerToken) as? Owner else {
        return false
    }

    let event = ObservationEvent(kind: kind) {
        state.terminate()
    }

    guard let changeKind else {
        callbackBox.call(event: event, owner: owner)
        return !state.isTerminated
    }

    if changeKind == .didSet {
        guard withObservationTrackingDidSetIfAvailable({
            callbackBox.call(event: event, owner: owner)
        }, didSet: { tracking in
            state.emitChange()
            cancelObservationTrackingIfAvailable(tracking)
        }) else {
            return false
        }
    } else {
        withObservationTracking {
            callbackBox.call(event: event, owner: owner)
        } onChange: {
            state.emitChange()
        }
    }

    return !state.isTerminated
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

private typealias ObservationTrackingDidSetFunction = @convention(thin) (
    () -> Void,
    @Sendable (OpaqueObservationTracking) -> Void
) -> Void

private let observationTrackingDidSetFunction: ObservationTrackingDidSetFunction? =
    unsafe lookupObservationSymbol(
        "$s11Observation04withA8Tracking_6didSetxxyXE_yAA0aC0VYbctlF",
        as: ObservationTrackingDidSetFunction.self
    )

private let observationTrackingCancelAddress: UInt? =
    unsafe lookupObservationSymbol("$s11Observation0A8TrackingV6cancelyyF")
        .map { UInt(bitPattern: $0) }

private var canUseObservationTrackingDidSetSPI: Bool {
    if _ObservationScopeTesting.forcePublicDidSetFallback.withLock({ $0 }) {
        return false
    }

    #if arch(arm64) || arch(x86_64)
    return observationTrackingDidSetFunction != nil && observationTrackingCancelAddress != nil
    #else
    return false
    #endif
}

enum _ObservationScopeTesting {
    static let forcePublicDidSetFallback = Mutex(false)
}

private func withObservationTrackingDidSetIfAvailable(
    _ apply: () -> Void,
    didSet: @Sendable (OpaqueObservationTracking) -> Void
) -> Bool {
    guard canUseObservationTrackingDidSetSPI, let observationTrackingDidSetFunction else {
        return false
    }

    observationTrackingDidSetFunction(apply, didSet)
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

private func lookupObservationSymbol<T>(
    _ name: UnsafePointer<CChar>,
    as type: T.Type
) -> T? {
    guard let symbol = unsafe lookupObservationSymbol(name) else {
        return nil
    }
    return unsafe unsafeBitCast(symbol, to: type)
}

private func lookupObservationSymbol(_ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    unsafe dlsym(unsafe UnsafeMutableRawPointer(bitPattern: -2), name)
}
