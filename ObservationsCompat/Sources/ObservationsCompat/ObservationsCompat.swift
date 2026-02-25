import Observation
import ObservationsCompatLegacy

public enum ObservationsCompatBackend: Sendable {
    case automatic
    case native
    case legacy
}

public extension Observable where Self: AnyObject {
    @discardableResult
    func observe<Value: Sendable>(
        _ keyPath: sending KeyPath<Self, Value>,
        retention: ObservationRetention = .automatic,
        removeDuplicates: Bool = false,
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending Value) -> Void
    ) -> ObservationHandle {
        observe(
            keyPath,
            backend: .automatic,
            retention: retention,
            removeDuplicates: removeDuplicates,
            onChange: onChange
        )
    }

    @discardableResult
    func observe<Value: Sendable & Equatable>(
        _ keyPath: sending KeyPath<Self, Value>,
        retention: ObservationRetention = .automatic,
        removeDuplicates: Bool = false,
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending Value) -> Void
    ) -> ObservationHandle {
        observe(
            keyPath,
            backend: .automatic,
            retention: retention,
            removeDuplicates: removeDuplicates,
            onChange: onChange
        )
    }

    @discardableResult
    func observeTask<Value: Sendable>(
        _ keyPath: sending KeyPath<Self, Value>,
        retention: ObservationRetention = .automatic,
        removeDuplicates: Bool = false,
        @_inheritActorContext task: @escaping @isolated(any) @Sendable (sending Value) async -> Void
    ) -> ObservationHandle {
        observeTask(
            keyPath,
            backend: .automatic,
            retention: retention,
            removeDuplicates: removeDuplicates,
            task: task
        )
    }

    @discardableResult
    func observeTask<Value: Sendable & Equatable>(
        _ keyPath: sending KeyPath<Self, Value>,
        retention: ObservationRetention = .automatic,
        removeDuplicates: Bool = false,
        @_inheritActorContext task: @escaping @isolated(any) @Sendable (sending Value) async -> Void
    ) -> ObservationHandle {
        observeTask(
            keyPath,
            backend: .automatic,
            retention: retention,
            removeDuplicates: removeDuplicates,
            task: task
        )
    }

    @discardableResult
    func observe(
        _ keyPaths: sending [PartialKeyPath<Self>],
        retention: ObservationRetention = .automatic,
        removeDuplicates: Bool = false,
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable () -> Void
    ) -> ObservationHandle {
        observe(
            keyPaths,
            backend: .automatic,
            retention: retention,
            removeDuplicates: removeDuplicates,
            onChange: onChange
        )
    }

    @discardableResult
    func observeTask(
        _ keyPaths: sending [PartialKeyPath<Self>],
        retention: ObservationRetention = .automatic,
        removeDuplicates: Bool = false,
        @_inheritActorContext task: @escaping @isolated(any) @Sendable () async -> Void
    ) -> ObservationHandle {
        observeTask(
            keyPaths,
            backend: .automatic,
            retention: retention,
            removeDuplicates: removeDuplicates,
            task: task
        )
    }

    @discardableResult
    func observe<Value: Sendable>(
        _ keyPath: sending KeyPath<Self, Value>,
        backend: ObservationsCompatBackend,
        retention: ObservationRetention = .automatic,
        removeDuplicates: Bool = false,
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending Value) -> Void
    ) -> ObservationHandle {
        if removeDuplicates {
            preconditionFailure("removeDuplicates requires Value to conform to Equatable")
        }

        return observeImpl(
            owner: self,
            backend: backend,
            retention: retention,
            duplicateFilter: nil,
            of: makeKeyPathGetter(keyPath),
            onChange: makeOnChangeAdapter(onChange)
        )
    }

    @discardableResult
    func observe<Value: Sendable & Equatable>(
        _ keyPath: sending KeyPath<Self, Value>,
        backend: ObservationsCompatBackend,
        retention: ObservationRetention = .automatic,
        removeDuplicates: Bool = false,
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending Value) -> Void
    ) -> ObservationHandle {
        observeImpl(
            owner: self,
            backend: backend,
            retention: retention,
            duplicateFilter: removeDuplicates ? { @Sendable lhs, rhs in lhs == rhs } : nil,
            of: makeKeyPathGetter(keyPath),
            onChange: makeOnChangeAdapter(onChange)
        )
    }

    @discardableResult
    func observeTask<Value: Sendable>(
        _ keyPath: sending KeyPath<Self, Value>,
        backend: ObservationsCompatBackend,
        retention: ObservationRetention = .automatic,
        removeDuplicates: Bool = false,
        @_inheritActorContext task: @escaping @isolated(any) @Sendable (sending Value) async -> Void
    ) -> ObservationHandle {
        if removeDuplicates {
            preconditionFailure("removeDuplicates requires Value to conform to Equatable")
        }

        return observeTaskImpl(
            owner: self,
            backend: backend,
            retention: retention,
            duplicateFilter: nil,
            of: makeKeyPathGetter(keyPath),
            task: task
        )
    }

    @discardableResult
    func observeTask<Value: Sendable & Equatable>(
        _ keyPath: sending KeyPath<Self, Value>,
        backend: ObservationsCompatBackend,
        retention: ObservationRetention = .automatic,
        removeDuplicates: Bool = false,
        @_inheritActorContext task: @escaping @isolated(any) @Sendable (sending Value) async -> Void
    ) -> ObservationHandle {
        observeTaskImpl(
            owner: self,
            backend: backend,
            retention: retention,
            duplicateFilter: removeDuplicates ? { @Sendable lhs, rhs in lhs == rhs } : nil,
            of: makeKeyPathGetter(keyPath),
            task: task
        )
    }

    @discardableResult
    func observe(
        _ keyPaths: sending [PartialKeyPath<Self>],
        backend: ObservationsCompatBackend,
        retention: ObservationRetention = .automatic,
        removeDuplicates: Bool = false,
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable () -> Void
    ) -> ObservationHandle {
        if removeDuplicates {
            preconditionFailure("removeDuplicates is not supported for multiple key path trigger observation")
        }

        return observeImpl(
            owner: self,
            backend: backend,
            retention: retention,
            duplicateFilter: nil,
            of: makeAnyKeyPathsTriggerGetter(keyPaths),
            onChange: { _ in
                await onChange()
            }
        )
    }

    @discardableResult
    func observeTask(
        _ keyPaths: sending [PartialKeyPath<Self>],
        backend: ObservationsCompatBackend,
        retention: ObservationRetention = .automatic,
        removeDuplicates: Bool = false,
        @_inheritActorContext task: @escaping @isolated(any) @Sendable () async -> Void
    ) -> ObservationHandle {
        if removeDuplicates {
            preconditionFailure("removeDuplicates is not supported for multiple key path trigger observation")
        }

        return observeTaskImpl(
            owner: self,
            backend: backend,
            retention: retention,
            duplicateFilter: nil,
            of: makeAnyKeyPathsTriggerGetter(keyPaths),
            task: { _ in
                await task()
            }
        )
    }
}

// KeyPath / PartialKeyPath are immutable metadata; wrapping allows safe capture in @Sendable closures.
private struct _UncheckedSendableKeyPath<Owner: AnyObject, Value>: @unchecked Sendable {
    let keyPath: KeyPath<Owner, Value>
}

private struct _UncheckedSendablePartialKeyPaths<Owner: AnyObject>: @unchecked Sendable {
    let keyPaths: [PartialKeyPath<Owner>]
}

private func makeKeyPathGetter<Owner: AnyObject, Value: Sendable>(
    _ keyPath: sending KeyPath<Owner, Value>
) -> @isolated(any) @Sendable (Owner) -> Value {
    let keyPath = _UncheckedSendableKeyPath(keyPath: keyPath)
    return { owner in
        owner[keyPath: keyPath.keyPath]
    }
}

private func makeAnyKeyPathsTriggerGetter<Owner: AnyObject>(
    _ keyPaths: sending [PartialKeyPath<Owner>]
) -> @isolated(any) @Sendable (Owner) -> Void {
    let keyPaths = _UncheckedSendablePartialKeyPaths(keyPaths: keyPaths)
    return { owner in
        for keyPath in keyPaths.keyPaths {
            _ = owner[keyPath: keyPath]
        }
    }
}

private func makeOnChangeAdapter<Value>(
    _ onChange: @escaping @isolated(any) @Sendable (sending Value) -> Void
) -> @isolated(any) @Sendable (sending Value) async -> Void {
    { value in
        await onChange(value)
    }
}

func makeObservationStream<Value: Sendable>(
    backend: ObservationsCompatBackend = .automatic,
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isDuplicate: (@Sendable (Value, Value) -> Bool)? = nil
) -> AsyncStream<Value> {
    switch resolveBackend(backend) {
    case .legacy:
        return makeLegacyObservationStream(observe, isDuplicate: isDuplicate)
    case .native:
        if #available(iOS 26.0, macOS 26.0, *) {
            return makeNativeStream(observe, isDuplicate: isDuplicate)
        }
        return makeLegacyObservationStream(observe, isDuplicate: isDuplicate)
    case .automatic:
        return makeLegacyObservationStream(observe, isDuplicate: isDuplicate)
    }
}

func resolveBackend(_ backend: ObservationsCompatBackend) -> ObservationsCompatBackend {
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

@available(iOS 26.0, macOS 26.0, *)
private func makeNativeStream<Value: Sendable>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isDuplicate: (@Sendable (Value, Value) -> Bool)?
) -> AsyncStream<Value> {
    AsyncStream<Value> { continuation in
        let task = Task {
            var previousValue: Value?
            var hasPreviousValue = false
            let observations = Observations(observe)

            for await value in observations {
                if Task.isCancelled {
                    break
                }

                if hasPreviousValue, let previousValue, let isDuplicate, isDuplicate(previousValue, value) {
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
}

public struct ObservationsCompat<Value: Sendable & Equatable>: AsyncSequence, Sendable {
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

    public init(
        backend: ObservationsCompatBackend = .automatic,
        @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
    ) {
        stream = makeObservationStream(backend: backend, observe, isDuplicate: ==)
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(base: stream.makeAsyncIterator())
    }
}

@available(*, deprecated, renamed: "ObservationsCompat")
public typealias ObservationsCompatStream<Value> = ObservationsCompat<Value> where Value: Sendable, Value: Equatable

public func makeObservationsCompatStream<Value: Sendable & Equatable>(
    backend: ObservationsCompatBackend = .automatic,
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> ObservationsCompat<Value> {
    ObservationsCompat(backend: backend, observe)
}
