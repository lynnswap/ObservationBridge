private struct SendableObservationBridgeStreamBuilder<Value: Sendable>: Sendable {
    let options: ObservationStreamOptions
    let observe: @isolated(any) @Sendable () -> Value
    let capturedIsolation: (any Actor)?
    let rateLimit: ObservationRateLimit?
    let rateLimitClock: any Clock<Duration>

    func makeStream() -> AsyncStream<Value> {
        makeObservationStreamFromCapturedIsolation(
            options: options,
            observe,
            capturedIsolation: capturedIsolation,
            rateLimit: rateLimit,
            rateLimitClock: rateLimitClock
        )
    }
}

private struct ObservationBridgeStreamBuilder<Value>: Sendable {
    let options: ObservationStreamOptions
    let observe: @isolated(any) @Sendable () -> Value
    let capturedIsolation: (any Actor)?
    let rateLimit: ObservationRateLimit?
    let rateLimitClock: any Clock<Duration>

    func makeStream() -> AsyncStream<Value> {
        makeObservationStreamFromCapturedIsolation(
            options: options,
            observe,
            capturedIsolation: capturedIsolation,
            rateLimit: rateLimit,
            rateLimitClock: rateLimitClock
        )
    }
}

/// An `AsyncSequence` that emits values read from an `@Observable` dependency.
///
/// Each iterator creates its own observation pipeline. Keep the sequence or iterator alive while
/// values should continue to be produced.
public struct ObservationBridge<Value>: AsyncSequence {
    /// The value emitted by the sequence.
    public typealias Element = Value

    /// The sequence does not throw.
    public typealias Failure = Never

    /// An iterator over values emitted by an ``ObservationBridge``.
    public struct Iterator: AsyncIteratorProtocol {
        /// The value emitted by the iterator.
        public typealias Element = Value

        /// The iterator does not throw.
        public typealias Failure = Never

        private var base: AsyncStream<Value>.Iterator

        fileprivate init(base: AsyncStream<Value>.Iterator) {
            self.base = base
        }

        /// Returns the next observed value, or `nil` when the observation finishes.
        public mutating func next() async -> Value? {
            await base.next()
        }
    }

    private let makeStream: @Sendable () -> AsyncStream<Value>

    fileprivate init(streamFactory: @escaping @Sendable () -> AsyncStream<Value>) {
        makeStream = streamFactory
    }

    /// Creates a sequence with explicit observation options.
    ///
    /// - Parameters:
    ///   - options: Configuration for backend selection and rate limiting.
    ///   - clock: The clock used for debounce or throttle timing. Defaults to `ContinuousClock`.
    ///   - observe: A closure that reads the value to observe.
    public init(
        options: ObservationStreamOptions,
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
    ) {
        let constructionIsolation: (any Actor)? = #isolation

        let builder = ObservationBridgeStreamBuilder(
            options: options,
            observe: observe,
            capturedIsolation: constructionIsolation,
            rateLimit: options.rateLimit,
            rateLimitClock: clock
        )
        self.init(streamFactory: builder.makeStream)
    }

    /// Creates an iterator and starts a fresh observation pipeline for it.
    public func makeAsyncIterator() -> Iterator {
        Iterator(base: makeStream().makeAsyncIterator())
    }

    /// Creates a sequence with default observation options.
    ///
    /// - Parameter observe: A closure that reads the value to observe.
    public init(
        @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
    ) {
        self.init(
            options: ObservationStreamOptions(),
            observe
        )
    }
}

extension ObservationBridge: Sendable where Value: Sendable {}

public extension ObservationBridge where Value: Sendable {
    /// Creates a sequence for a `Sendable` value with explicit observation options.
    ///
    /// - Parameters:
    ///   - options: Configuration for backend selection and rate limiting.
    ///   - clock: The clock used for debounce or throttle timing. Defaults to `ContinuousClock`.
    ///   - observe: A closure that reads the value to observe.
    init(
        options: ObservationStreamOptions,
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
    ) {
        let constructionIsolation: (any Actor)? = #isolation

        let builder = SendableObservationBridgeStreamBuilder(
            options: options,
            observe: observe,
            capturedIsolation: constructionIsolation,
            rateLimit: options.rateLimit,
            rateLimitClock: clock
        )
        self.init(streamFactory: builder.makeStream)
    }

    /// Creates a sequence for a `Sendable` value with default observation options.
    ///
    /// - Parameter observe: A closure that reads the value to observe.
    init(
        @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
    ) {
        self.init(
            options: ObservationStreamOptions(),
            observe
        )
    }
}

/// Creates an `AsyncSequence` that emits values read from an `@Observable` dependency.
///
/// - Parameter observe: A closure that reads the value to observe.
/// - Returns: A sequence that creates an observation pipeline for each iterator.
public func makeObservationBridgeStream<Value>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> ObservationBridge<Value> {
    ObservationBridge(observe)
}

/// Creates an `AsyncSequence` for a `Sendable` value read from an `@Observable` dependency.
///
/// - Parameter observe: A closure that reads the value to observe.
/// - Returns: A sequence that creates an observation pipeline for each iterator.
public func makeObservationBridgeStream<Value: Sendable>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> ObservationBridge<Value> {
    ObservationBridge(observe)
}

/// Creates an `AsyncSequence` with explicit observation options.
///
/// - Parameters:
///   - options: Configuration for backend selection and rate limiting.
///   - clock: The clock used for debounce or throttle timing. Defaults to `ContinuousClock`.
///   - observe: A closure that reads the value to observe.
/// - Returns: A sequence that creates an observation pipeline for each iterator.
public func makeObservationBridgeStream<Value>(
    options: ObservationStreamOptions,
    clock: any Clock<Duration> = ContinuousClock(),
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> ObservationBridge<Value> {
    ObservationBridge(
        options: options,
        clock: clock,
        observe
    )
}

/// Creates an `AsyncSequence` for a `Sendable` value with explicit observation options.
///
/// - Parameters:
///   - options: Configuration for backend selection and rate limiting.
///   - clock: The clock used for debounce or throttle timing. Defaults to `ContinuousClock`.
///   - observe: A closure that reads the value to observe.
/// - Returns: A sequence that creates an observation pipeline for each iterator.
public func makeObservationBridgeStream<Value: Sendable>(
    options: ObservationStreamOptions,
    clock: any Clock<Duration> = ContinuousClock(),
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> ObservationBridge<Value> {
    ObservationBridge(
        options: options,
        clock: clock,
        observe
    )
}
