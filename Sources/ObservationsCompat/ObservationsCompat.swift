import Observation
import Synchronization

public enum ObservationsCompatBackend: Sendable {
    case automatic
    case native
    case legacy
}

public struct ObservationsCompatStream<Value: Sendable & Equatable>: AsyncSequence, Sendable {
    public typealias Element = Value

    public struct Iterator: AsyncIteratorProtocol {
        private var base: AsyncStream<Value>.Iterator

        fileprivate init(base: AsyncStream<Value>.Iterator) {
            self.base = base
        }

        public mutating func next() async -> Value? {
            await base.next()
        }
    }

    private let stream: AsyncStream<Value>

    fileprivate init(stream: AsyncStream<Value>) {
        self.stream = stream
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(base: stream.makeAsyncIterator())
    }
}

public func makeObservationsCompatStream<Value: Sendable & Equatable>(
    backend: ObservationsCompatBackend = .automatic,
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> ObservationsCompatStream<Value> {
    switch resolveBackend(backend) {
    case .legacy:
        return makeLegacyStream(observe)
    case .native:
        if #available(iOS 26.0, macOS 26.0, *) {
            return makeNativeStream(observe)
        }
        return makeLegacyStream(observe)
    case .automatic:
        return makeLegacyStream(observe)
    }
}

private func resolveBackend(_ backend: ObservationsCompatBackend) -> ObservationsCompatBackend {
    switch backend {
    case .automatic:
        if #available(iOS 26.0, macOS 26.0, *) {
            return .native
        }
        return .legacy
    case .native:
        if #available(iOS 26.0, macOS 26.0, *) {
            return .native
        }
        return .legacy
    case .legacy:
        return .legacy
    }
}

private func makeLegacyStream<Value: Sendable & Equatable>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> ObservationsCompatStream<Value> {
    let stream = AsyncStream<Value> { continuation in
        let pendingChanges = PendingChangeCounter()
        let (changeWakes, changeSignal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            await runLegacyProducer(
                observe: observe,
                changeWakes: changeWakes,
                pendingChanges: pendingChanges,
                changeSignal: changeSignal,
                continuation: continuation
            )
        }

        continuation.onTermination = { _ in
            task.cancel()
            changeSignal.finish()
        }
    }
    return ObservationsCompatStream(stream: stream)
}

@inline(__always)
private func invokeIsolatedObserve<Value: Sendable>(
    _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> Value {
    typealias IsolatedObserve = @isolated(any) @Sendable () -> Value
    typealias NonisolatedObserve = @Sendable () -> Value
    let raw = unsafeBitCast(observe as IsolatedObserve, to: NonisolatedObserve.self)
    return raw()
}

private func runLegacyProducer<Value: Sendable & Equatable>(
    observe: @escaping @isolated(any) @Sendable () -> Value,
    changeWakes: AsyncStream<Void>,
    pendingChanges: PendingChangeCounter,
    changeSignal: AsyncStream<Void>.Continuation,
    continuation: AsyncStream<Value>.Continuation
) async {
    var latestValue: Value?
    var hasLatestValue = false

    func emitIfNeeded(_ value: Value) {
        if hasLatestValue, latestValue == value {
            return
        }
        hasLatestValue = true
        latestValue = value
        continuation.yield(value)
    }

    func registerTracking() {
        let result = withObservationTracking({
            Result(catching: {
                invokeIsolatedObserve(observe)
            })
        }, onChange: {
            pendingChanges.increment()
            changeSignal.yield(())
        })
        switch result {
        case .success(let value):
            emitIfNeeded(value)
        case .failure:
            preconditionFailure("observe closure unexpectedly threw")
        }
    }

    registerTracking()
    for await _ in changeWakes {
        if Task.isCancelled {
            break
        }
        var remaining = pendingChanges.takeAll()
        while remaining > 0 {
            registerTracking()
            remaining -= 1
        }
    }
    changeSignal.finish()
    continuation.finish()
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

@available(iOS 26.0, macOS 26.0, *)
private func makeNativeStream<Value: Sendable & Equatable>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> ObservationsCompatStream<Value> {
    let stream = AsyncStream<Value> { continuation in
        let task = Task {
            var previousValue: Value?
            var hasPreviousValue = false
            let observations = Observations(observe)
            for await value in observations {
                if Task.isCancelled {
                    break
                }
                if hasPreviousValue, previousValue == value {
                    continue
                }
                hasPreviousValue = true
                previousValue = value
                continuation.yield(value)
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
    return ObservationsCompatStream(stream: stream)
}
