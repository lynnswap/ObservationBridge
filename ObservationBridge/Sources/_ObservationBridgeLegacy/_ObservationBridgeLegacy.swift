import Darwin
import Foundation
import Observation
import Synchronization
import _ObservationBridgePrivateABI

package func makeLegacyObservationStream<Value: Sendable>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isolation: (any Actor)? = #isolation
) -> AsyncStream<Value> {
    AsyncStream<Value> { continuation in
        let observationState = LegacyObservationState()
        let observeIsolation = isolation ?? observe.isolation
        let task = Task {
            await withTaskCancellationHandler(operation: {
                await runLegacyObservationLoop(
                    observe: observe,
                    observeIsolation: observeIsolation,
                    observationState: observationState,
                    emit: { value in
                        continuation.yield(value)
                        return true
                    }
                )
                continuation.finish()
            }, onCancel: {
                observationState.terminate()
            })
        }

        continuation.onTermination = { _ in
            observationState.terminate()
            task.cancel()
        }
    }
}

package func forEachLegacyObservationEmission<Value: Sendable>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isolation: (any Actor)? = #isolation,
    consume: @escaping @Sendable (Value) async -> Bool
) async {
    let observationState = LegacyObservationState()
    let observeIsolation = isolation ?? observe.isolation

    await withTaskCancellationHandler(operation: {
        await runLegacyObservationLoop(
            observe: observe,
            observeIsolation: observeIsolation,
            observationState: observationState,
            emit: consume
        )
    }, onCancel: {
        observationState.terminate()
    })
}

private func runLegacyObservationLoop<Value: Sendable>(
    observe: @escaping @isolated(any) @Sendable () -> Value,
    observeIsolation: (any Actor)?,
    observationState: LegacyObservationState,
    emit: @escaping @Sendable (Value) async -> Bool
) async {
    func registerTracking() async -> Bool {
        let value = await trackLegacyValue(
            isolation: observeIsolation,
            observe: observe,
            observationState: observationState
        )
        return await emit(value)
    }

    guard !Task.isCancelled else {
        observationState.terminate()
        return
    }

    guard await registerTracking() else {
        observationState.terminate()
        return
    }

    while await observationState.waitForChange() {
        guard !Task.isCancelled else {
            break
        }
        guard await registerTracking() else {
            break
        }
    }

    observationState.terminate()
}

private func trackLegacyValue<Value: Sendable>(
    isolation: (any Actor)?,
    observe: @escaping @isolated(any) @Sendable () -> Value,
    observationState: LegacyObservationState
) async -> Value {
    await withObservationIsolation(isolation: isolation) {
        if let value = trackLegacyValueWithDidSetIfAvailable(
            observe: observe,
            observationState: observationState
        ) {
            return value
        }

        return withObservationTracking({
            callIsolatedWithFastPath(observe)
        }, onChange: {
            observationState.emitWillChange()
        })
    }
}

private func trackLegacyValueWithDidSetIfAvailable<Value: Sendable>(
    observe: @escaping @isolated(any) @Sendable () -> Value,
    observationState: LegacyObservationState
) -> Value? {
    guard canUseObservationTrackingDidSetSPI else {
        return nil
    }

    var observedValue: Value?
    _withObservationTrackingDidSet({
        observedValue = callIsolatedWithFastPath(observe)
    }, didSet: { tracking in
        observationState.emitChange()
        cancelObservationTrackingIfAvailable(tracking)
    })

    guard let observedValue else {
        preconditionFailure("legacy observation didSet tracking did not produce a value")
    }
    return observedValue
}

@inline(__always)
private func callIsolatedWithFastPath<Value>(
    _ closure: @escaping @isolated(any) @Sendable () -> Value
) -> Value {
    if closure.isolation == nil {
        let unisolated = unsafe unsafeBitCast(closure, to: (@Sendable () -> Value).self)
        return unisolated()
    }

    // Swift cannot synchronously call an arbitrary @isolated(any) closure here;
    // this conversion is expected to preserve the legacy same-isolation path.
    let sameIsolation = unsafe unsafeBitCast(closure, to: (@Sendable () -> Value).self)
    return sameIsolation()
}

@inline(__always)
private func callIsolatedWithFastPath<Input, Value>(
    _ closure: @escaping @isolated(any) (Input) -> Value,
    _ input: Input
) -> Value {
    if closure.isolation == nil {
        let unisolated = unsafe unsafeBitCast(closure, to: ((Input) -> Value).self)
        return unisolated(input)
    }

    // Swift cannot synchronously call an arbitrary @isolated(any) closure here;
    // this conversion is expected to preserve the legacy same-isolation path.
    let sameIsolation = unsafe unsafeBitCast(closure, to: ((Input) -> Value).self)
    return sameIsolation(input)
}

private func withObservationIsolation<T>(
    isolation: isolated (any Actor)?,
    _ operation: () -> T
) -> T {
    operation()
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
    #if arch(arm64) || arch(x86_64)
    return observationTrackingDidSetAddress != nil && observationTrackingCancelAddress != nil
    #else
    return false
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

private struct LegacyObservationWaiters: @unchecked Sendable {
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

    mutating func takeAll() -> LegacyObservationWaiterBatch {
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

private enum LegacyObservationWaiterBatch: @unchecked Sendable {
    case empty
    case single(CheckedContinuation<Void, Never>)
    case many(CheckedContinuation<Void, Never>, [CheckedContinuation<Void, Never>])

    func resumeAll() {
        switch self {
        case .empty:
            return
        case .single(let continuation):
            continuation.resume(returning: ())
        case .many(let first, let additional):
            first.resume(returning: ())
            for continuation in additional {
                continuation.resume(returning: ())
            }
        }
    }
}

private final class LegacyObservationState: @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var dirty = false
        var terminated = false
        var waiters = LegacyObservationWaiters()
    }

    private enum WaitSetup {
        case changed
        case terminated
        case wait
    }

    private let state = Mutex(State())

    func emitChange() {
        emitWillChange()
    }

    func emitWillChange() {
        let waiters = state.withLock { state -> LegacyObservationWaiterBatch in
            guard !state.terminated else {
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

    func terminate() {
        let waiters = state.withLock { state -> LegacyObservationWaiterBatch in
            guard !state.terminated else {
                return .empty
            }

            state.terminated = true
            state.dirty = false
            return state.waiters.takeAll()
        }

        waiters.resumeAll()
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
            immediate?.resume(returning: ())
        }

        return state.withLock { state in
            !state.terminated
        }
    }
}

package func legacyEvaluateObservedValue<Value>(
    isolation: isolated (any Actor)? = #isolation,
    observe: @escaping @isolated(any) @Sendable () -> Value
) -> Value {
    withObservationIsolation(isolation: isolation) {
        callIsolatedWithFastPath(observe)
    }
}
