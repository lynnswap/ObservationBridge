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
    guard canUseObservationTrackingDidSetSPI, let observationTrackingDidSetFunction else {
        return nil
    }

    var observedValue: Value?
    observationTrackingDidSetFunction({
        observedValue = callIsolatedWithFastPath(observe)
    }, { tracking in
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
    let result = Result(catching: closure)
    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        preconditionFailure("legacy observation produced unexpected error: \(error)")
    }
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
    let result = Optional(input).map(closure)
    switch result {
    case .some(let value):
        return value
    case .none:
        preconditionFailure("legacy observation produced unexpected nil mapping")
    }
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
    #if arch(arm64) || arch(x86_64)
    return observationTrackingDidSetFunction != nil && observationTrackingCancelAddress != nil
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

private final class LegacyObservationState: @unchecked Sendable {
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

    func emitChange() {
        emitWillChange()
    }

    func emitWillChange() {
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
            continuation.resume(returning: ())
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
            continuation.resume(returning: ())
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
