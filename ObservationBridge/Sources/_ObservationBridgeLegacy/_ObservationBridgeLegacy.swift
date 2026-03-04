import Observation
import Synchronization

package func makeLegacyObservationStream<Value: Sendable>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isDuplicate: (@Sendable (Value, Value) -> Bool)? = nil,
    isolation: (any Actor)? = #isolation
) -> AsyncStream<Value> {
    AsyncStream<Value> { continuation in
        let changeGate = LegacyChangeGate()
        let observeIsolation = isolation ?? observe.isolation
        let task = Task {
            await runLegacyProducer(
                observe: observe,
                observeIsolation: observeIsolation,
                changeGate: changeGate,
                isDuplicate: isDuplicate,
                continuation: continuation
            )
        }

        continuation.onTermination = { _ in
            changeGate.terminate()
            task.cancel()
        }
    }
}

private func runLegacyProducer<Value: Sendable>(
    observe: @escaping @isolated(any) @Sendable () -> Value,
    observeIsolation: (any Actor)?,
    changeGate: LegacyChangeGate,
    isDuplicate: (@Sendable (Value, Value) -> Bool)?,
    continuation: AsyncStream<Value>.Continuation
) async {
    var latestValue: LatestObservedValue<Value> = .unset

    func emitIfNeeded(_ value: Value) {
        if case .set(let previousValue) = latestValue, let isDuplicate, isDuplicate(previousValue, value) {
            return
        }

        latestValue = .set(value)
        continuation.yield(value)
    }

    func registerTracking() async {
        let value = await trackLegacyValue(
            isolation: observeIsolation,
            observe: observe,
            changeGate: changeGate
        )
        emitIfNeeded(value)
    }

    await registerTracking()
    while await changeGate.waitForChange() {
        guard !Task.isCancelled else {
            break
        }
        await registerTracking()
    }

    changeGate.terminate()
    continuation.finish()
}

private enum LatestObservedValue<Value> {
    case unset
    case set(Value)
}

private func trackLegacyValue<Value: Sendable>(
    isolation: (any Actor)?,
    observe: @escaping @isolated(any) @Sendable () -> Value,
    changeGate: LegacyChangeGate
) async -> Value {
    // Keep this aligned with Swift stdlib Observation (`Observations.swift`):
    // `Result(catching:)` inside `withObservationTracking` currently emits an
    // `@isolated(any)` conversion warning, but avoids isolation bypasses such as `unsafeBitCast`.
    await withObservationIsolation(isolation: isolation) {
        let result = withObservationTracking({
            Result(catching: observe)
        }, onChange: {
            changeGate.signalChange()
        })

        switch result {
        case .success(let value):
            return value
        case .failure:
            preconditionFailure("observe closure unexpectedly threw")
        }
    }
}

private func withObservationIsolation<T>(
    isolation: isolated (any Actor)?,
    _ operation: () -> T
) -> T {
    operation()
}

private final class LegacyChangeGate: Sendable {
    private struct State {
        var dirty = false
        var terminated = false
        var waiter: CheckedContinuation<Void, Never>? = nil
    }

    private enum WaitSetup {
        case changed
        case terminated
        case wait
    }

    private let state = Mutex(State())

    func signalChange() {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { state in
            guard !state.terminated else {
                return nil
            }

            state.dirty = true
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }

    func terminate() {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { state in
            guard !state.terminated else {
                return nil
            }

            state.terminated = true
            state.dirty = false
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }

    func waitForChange() async -> Bool {
        let setup = state.withLock { state in
            if state.terminated {
                return WaitSetup.terminated
            }
            if state.dirty {
                state.dirty = false
                return WaitSetup.changed
            }
            return WaitSetup.wait
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
            let waiter: CheckedContinuation<Void, Never>? = state.withLock { state in
                if state.terminated {
                    return continuation
                }
                if state.dirty {
                    state.dirty = false
                    return continuation
                }

                precondition(state.waiter == nil, "LegacyChangeGate supports a single waiter")
                state.waiter = continuation
                return nil
            }
            waiter?.resume()
        }

        return state.withLock { state in
            if state.terminated {
                return false
            }
            if state.dirty {
                state.dirty = false
            }
            return true
        }
    }
}

package func legacyEvaluateObservedOwnerValue<Owner: AnyObject, Value: Sendable>(
    owner: Owner?,
    value: @escaping @isolated(any) (Owner) -> Value
) -> LegacyOwnerObservationResult<Value> {
    guard let owner else {
        return .ownerGone
    }

    switch Optional(owner).map(value) {
    case .some(let observedValue):
        return .value(observedValue)
    case .none:
        return .ownerGone
    }
}

package enum LegacyOwnerObservationResult<Value: Sendable>: Sendable {
    case ownerGone
    case value(Value)
}
