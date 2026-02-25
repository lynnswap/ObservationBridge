import Observation
import Synchronization

package func makeLegacyObservationStream<Value: Sendable>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isDuplicate: (@Sendable (Value, Value) -> Bool)? = nil
) -> AsyncStream<Value> {
    AsyncStream<Value> { continuation in
        let pendingChanges = PendingChangeCounter()
        let (changeWakes, changeSignal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observeIsolation = observe.isolation
        let task = Task {
            await runLegacyProducer(
                observe: observe,
                observeIsolation: observeIsolation,
                changeWakes: changeWakes,
                pendingChanges: pendingChanges,
                changeSignal: changeSignal,
                isDuplicate: isDuplicate,
                continuation: continuation
            )
        }

        continuation.onTermination = { _ in
            task.cancel()
            changeSignal.finish()
        }
    }
}

private func runLegacyProducer<Value: Sendable>(
    observe: @escaping @isolated(any) @Sendable () -> Value,
    observeIsolation: (any Actor)?,
    changeWakes: AsyncStream<Void>,
    pendingChanges: PendingChangeCounter,
    changeSignal: AsyncStream<Void>.Continuation,
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
            pendingChanges: pendingChanges,
            changeSignal: changeSignal
        )
        emitIfNeeded(value)
    }

    await registerTracking()
    for await _ in changeWakes {
        if Task.isCancelled {
            break
        }

        var remaining = pendingChanges.takeAll()
        while remaining > 0 {
            await registerTracking()
            remaining -= 1
        }
    }

    changeSignal.finish()
    continuation.finish()
}

private enum LatestObservedValue<Value> {
    case unset
    case set(Value)
}

private func trackLegacyValue<Value: Sendable>(
    isolation _: isolated (any Actor)?,
    observe: @escaping @isolated(any) @Sendable () -> Value,
    pendingChanges: PendingChangeCounter,
    changeSignal: AsyncStream<Void>.Continuation
) -> Value {
    // Keep this aligned with Swift stdlib Observation (`Observations.swift`):
    // `Result(catching:)` inside `withObservationTracking` currently emits an
    // `@isolated(any)` conversion warning, but avoids isolation bypasses such as `unsafeBitCast`.
    let result = withObservationTracking({
        Result(catching: observe)
    }, onChange: {
        pendingChanges.increment()
        changeSignal.yield(())
    })

    switch result {
    case .success(let value):
        return value
    case .failure:
        preconditionFailure("observe closure unexpectedly threw")
    }
}

private final class PendingChangeCounter: Sendable {
    private let count = Mutex(0)

    func increment() {
        count.withLock { value in
            value += 1
        }
    }

    func takeAll() -> Int {
        count.withLock { value in
            let current = value
            value = 0
            return current
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
