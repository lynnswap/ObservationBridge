import Observation
import Synchronization

package func makeLegacyObservationStream<Value: Sendable>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isDuplicate: (@Sendable (Value, Value) -> Bool)? = nil,
    isolation: (any Actor)? = #isolation
) -> AsyncStream<Value> {
    AsyncStream<Value> { continuation in
        let observationState = LegacyObservationState()
        let observeIsolation = isolation ?? observe.isolation
        let task = Task {
            await runLegacyProducer(
                observe: observe,
                observeIsolation: observeIsolation,
                observationState: observationState,
                isDuplicate: isDuplicate,
                continuation: continuation
            )
        }

        continuation.onTermination = { _ in
            observationState.terminate()
            task.cancel()
        }
    }
}

private func runLegacyProducer<Value: Sendable>(
    observe: @escaping @isolated(any) @Sendable () -> Value,
    observeIsolation: (any Actor)?,
    observationState: LegacyObservationState,
    isDuplicate: (@Sendable (Value, Value) -> Bool)?,
    continuation: AsyncStream<Value>.Continuation
) async {
    var latestValue: LatestObservedValue<Value> = .unset
    var started = false

    func emitIfNeeded(_ value: Value) {
        if case .set(let previousValue) = latestValue,
           let isDuplicate,
           isDuplicate(previousValue, value)
        {
            return
        }

        latestValue = .set(value)
        continuation.yield(value)
    }

    while true {
        guard !Task.isCancelled else {
            break
        }

        let generationID = observationState.nextGenerationID()

        if started {
            let shouldContinue = await observationState.waitForChange(
                id: generationID,
                isolation: observeIsolation
            )
            guard shouldContinue else {
                break
            }
            guard !Task.isCancelled else {
                break
            }
        } else {
            started = true
        }

        let value = await trackLegacyValue(
            isolation: observeIsolation,
            observe: observe,
            observationState: observationState
        )
        emitIfNeeded(value)
    }

    observationState.terminate()
    continuation.finish()
}

private enum LatestObservedValue<Value> {
    case unset
    case set(Value)
}

private func trackLegacyValue<Value: Sendable>(
    isolation: (any Actor)?,
    observe: @escaping @isolated(any) @Sendable () -> Value,
    observationState: LegacyObservationState
) async -> Value {
    // Keep this aligned with Swift stdlib Observation (`Observations.swift`):
    // `Result(catching:)` inside `withObservationTracking` currently emits an
    // `@isolated(any)` conversion warning, but avoids isolation bypasses such as `unsafeBitCast`.
    await withObservationIsolation(isolation: isolation) {
        let result = withObservationTracking({
            Result(catching: observe)
        }, onChange: {
            observationState.emitWillChange()
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

private final class LegacyObservationState: @unchecked Sendable {
    private enum StoredContinuation {
        case cancelled
        case active(UnsafeContinuation<Void, Never>)

        func resume() {
            switch self {
            case .cancelled:
                break
            case .active(let continuation):
                continuation.resume()
            }
        }
    }

    private struct State {
        var nextGenerationID = 0
        var continuations: [Int: StoredContinuation] = [:]
        var dirty = false
        var terminated = false
    }

    private enum WaitSetup {
        case changed
        case terminated
        case wait
    }

    private let state = Mutex(State())

    func nextGenerationID() -> Int {
        state.withLock { state in
            defer {
                state.nextGenerationID &+= 1
            }
            return state.nextGenerationID
        }
    }

    func cancel(id: Int) {
        let continuation = state.withLock { state -> StoredContinuation? in
            guard let continuation = state.continuations.removeValue(forKey: id) else {
                state.continuations[id] = .cancelled
                return nil
            }
            return continuation
        }

        continuation?.resume()
    }

    func emitWillChange() {
        let continuations = state.withLock { state -> [StoredContinuation] in
            guard !state.terminated else {
                return []
            }

            if state.continuations.isEmpty {
                state.dirty = true
            }

            let continuations = Array(state.continuations.values)
            state.continuations.removeAll(keepingCapacity: false)
            return continuations
        }

        for continuation in continuations {
            continuation.resume()
        }
    }

    func terminate() {
        let continuations = state.withLock { state -> [StoredContinuation] in
            guard !state.terminated else {
                return []
            }

            state.terminated = true
            state.dirty = false
            let continuations = Array(state.continuations.values)
            state.continuations.removeAll(keepingCapacity: false)
            return continuations
        }

        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitForChange(
        id: Int,
        isolation: isolated (any Actor)?
    ) async -> Bool {
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

        await withTaskCancellationHandler(operation: {
            await withUnsafeContinuation(isolation: isolation) { continuation in
                let immediate = state.withLock { state -> UnsafeContinuation<Void, Never>? in
                    defer {
                        state.dirty = false
                    }

                    if state.terminated {
                        return continuation
                    }

                    switch state.continuations[id] {
                    case .cancelled:
                        return continuation
                    case .active:
                        preconditionFailure("legacy observation waiter incorrectly shared across task isolations")
                    case .none:
                        if state.dirty {
                            return continuation
                        }

                        state.continuations[id] = .active(continuation)
                        return nil
                    }
                }

                immediate?.resume()
            }
        }, onCancel: {
            cancel(id: id)
        }, isolation: isolation)

        return state.withLock { state in
            !state.terminated
        }
    }
}

package func legacyEvaluateObservedOwnerValue<Owner: AnyObject, Value>(
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

package func legacyEvaluateObservedOwnerValue<Owner: AnyObject, Value, Mapped>(
    owner: Owner?,
    value: @escaping @isolated(any) (Owner) -> Value,
    map: (Value) -> Mapped
) -> LegacyOwnerObservationResult<Mapped> {
    switch legacyEvaluateObservedOwnerValue(owner: owner, value: value) {
    case .ownerGone:
        return .ownerGone
    case .value(let observedValue):
        return .value(map(observedValue))
    }
}

package func legacyEvaluateObservedValue<Value>(
    observe: @escaping @isolated(any) @Sendable () -> Value
) -> Value {
    let result = Result(catching: observe)
    switch result {
    case .success(let value):
        return value
    case .failure:
        preconditionFailure("observe closure unexpectedly threw")
    }
}

package enum LegacyOwnerObservationResult<Value> {
    case ownerGone
    case value(Value)
}

extension LegacyOwnerObservationResult: Sendable where Value: Sendable {}
