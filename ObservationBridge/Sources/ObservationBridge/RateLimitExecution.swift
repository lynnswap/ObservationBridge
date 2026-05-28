import AsyncAlgorithms
import Synchronization

struct ThrottleExecutionState<Value: Sendable>: Sendable {
    var readyValue: Value? = nil
    var pendingValue: Value? = nil
    var nextTimerToken: UInt64 = 0
    var activeTimerToken: UInt64? = nil
    var isSourceFinished = false

    mutating func recordIncomingValue(
        _ value: Value,
        keepLatestPending: Bool
    ) {
        if activeTimerToken == nil {
            if readyValue == nil {
                readyValue = value
            } else if pendingValue == nil || keepLatestPending {
                pendingValue = value
            }
        } else if pendingValue == nil || keepLatestPending {
            pendingValue = value
        }
    }

    mutating func finishSource() {
        isSourceFinished = true
    }

    mutating func expireTimer(token: UInt64) -> Bool {
        guard activeTimerToken == token else {
            return false
        }

        activeTimerToken = nil
        if let pendingValue {
            readyValue = pendingValue
            self.pendingValue = nil
        }
        return true
    }

    mutating func nextAction() -> ThrottleAction<Value> {
        if let readyValue {
            self.readyValue = nil
            if isSourceFinished, pendingValue == nil {
                return .emit(value: readyValue, timerToken: nil, finishAfterEmit: true)
            }

            let timerToken = nextTimerToken
            nextTimerToken &+= 1
            activeTimerToken = timerToken
            return .emit(value: readyValue, timerToken: timerToken, finishAfterEmit: false)
        }

        if activeTimerToken == nil {
            if isSourceFinished {
                return .finish
            }
        } else if isSourceFinished, pendingValue == nil {
            activeTimerToken = nil
            return .finish
        }

        return .idle
    }
}

private final class ThrottleStateBox<Value: Sendable>: @unchecked Sendable {
    let state: Mutex<ThrottleExecutionState<Value>>

    init() {
        state = Mutex(ThrottleExecutionState())
    }
}

enum ThrottleAction<Value>: Sendable where Value: Sendable {
    case emit(value: Value, timerToken: UInt64?, finishAfterEmit: Bool)
    case finish
    case idle
}

func makeRateLimitedValueStream<S: AsyncSequence & Sendable>(
    _ source: S,
    rateLimit: ObservationRateLimit,
    rateLimitClock: any Clock<Duration>
) -> AsyncStream<S.Element> where S.Element: Sendable, S.Failure == Never {
    switch rateLimit {
    case let .debounce(debounce):
        return makeDebouncedValueStream(
            source,
            debounce: debounce,
            debounceClock: rateLimitClock
        )
    case let .throttle(throttle):
        return makeThrottledValueStream(
            source,
            throttle: throttle,
            throttleClock: rateLimitClock
        )
    }
}

func makeDebouncedValueStream<S: AsyncSequence & Sendable>(
    _ source: S,
    debounce: ObservationDebounce,
    debounceClock: any Clock<Duration>
) -> AsyncStream<S.Element> where S.Element: Sendable, S.Failure == Never {
    makeDebouncedValueStream(
        source,
        debounce: debounce,
        clock: debounceClock
    )
}

func makeDebouncedValueStream<S: AsyncSequence & Sendable, C: Clock<Duration>>(
    _ source: S,
    debounce: ObservationDebounce,
    clock: C
) -> AsyncStream<S.Element> where S.Element: Sendable, S.Failure == Never {
    switch debounce.mode {
    case .delayedFirst:
        return AsyncStream { continuation in
            let task = Task {
                for await value in source.debounce(
                    for: debounce.interval,
                    tolerance: debounce.tolerance,
                    clock: clock
                ) {
                    guard !Task.isCancelled else {
                        break
                    }
                    continuation.yield(value)
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    case .immediateFirst:
        return AsyncStream { continuation in
            let task = Task {
                let (remainingStream, remainingContinuation) = AsyncStream<S.Element>.makeStream(
                    bufferingPolicy: .bufferingNewest(1)
                )
                let producerTask = Task {
                    var didEmitFirstValue = false
                    for await nextValue in source {
                        guard !Task.isCancelled else {
                            break
                        }
                        guard didEmitFirstValue else {
                            didEmitFirstValue = true
                            continuation.yield(nextValue)
                            continue
                        }
                        remainingContinuation.yield(nextValue)
                    }

                    remainingContinuation.finish()
                }

                for await value in remainingStream.debounce(
                    for: debounce.interval,
                    tolerance: debounce.tolerance,
                    clock: clock
                ) {
                    guard !Task.isCancelled else {
                        break
                    }
                    continuation.yield(value)
                }

                producerTask.cancel()
                await producerTask.value
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

func makeThrottledValueStream<S: AsyncSequence & Sendable>(
    _ source: S,
    throttle: ObservationThrottle,
    throttleClock: any Clock<Duration>
) -> AsyncStream<S.Element> where S.Element: Sendable, S.Failure == Never {
    makeThrottledValueStream(
        source,
        throttle: throttle,
        clock: throttleClock
    )
}

func makeThrottledValueStream<S: AsyncSequence & Sendable, C: Clock<Duration>>(
    _ source: S,
    throttle: ObservationThrottle,
    clock: C
) -> AsyncStream<S.Element> where S.Element: Sendable, S.Failure == Never {
    AsyncStream { continuation in
        let task = Task {
            let stateBox = ThrottleStateBox<S.Element>()
            let (wakeStream, wakeSignal) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            var timerTask: Task<Void, Never>? = nil
            let keepLatestPending = throttle.mode == .latest
            let throttleInterval = throttle.interval

            let sourceTask = Task { @Sendable [stateBox, wakeSignal, keepLatestPending, source] in
                for await value in source {
                    guard !Task.isCancelled else {
                        break
                    }
                    stateBox.state.withLock { state in
                        state.recordIncomingValue(
                            value,
                            keepLatestPending: keepLatestPending
                        )
                    }
                    wakeSignal.yield(())
                }
                stateBox.state.withLock { state in
                    state.finishSource()
                }
                wakeSignal.yield(())
            }

            defer {
                timerTask?.cancel()
                sourceTask.cancel()
                wakeSignal.finish()
                continuation.finish()
            }

            let scheduleTimer = { (timerToken: UInt64) in
                timerTask?.cancel()
                timerTask = Task { @Sendable [stateBox, wakeSignal, clock, throttleInterval] in
                    do {
                        try await clock.sleep(until: clock.now.advanced(by: throttleInterval), tolerance: nil)
                        guard !Task.isCancelled else {
                            return
                        }
                        let shouldWake = stateBox.state.withLock { state in
                            state.expireTimer(token: timerToken)
                        }
                        if shouldWake {
                            wakeSignal.yield(())
                        }
                    } catch is CancellationError {
                    } catch {
                        // `Clock.sleep` is untyped throws; non-cancellation errors violate
                        // the clock contract expected by this rate-limit pipeline.
                        preconditionFailure("throttle timer unexpectedly threw")
                    }
                }
            }

            let nextAction = {
                stateBox.state.withLock { state -> ThrottleAction<S.Element> in
                    state.nextAction()
                }
            }

            for await _ in wakeStream {
                guard !Task.isCancelled else {
                    break
                }

                while !Task.isCancelled {
                    let action = nextAction()
                    switch action {
                    case let .emit(value, timerToken, finishAfterEmit):
                        continuation.yield(value)
                        if let timerToken {
                            scheduleTimer(timerToken)
                        } else {
                            timerTask?.cancel()
                            timerTask = nil
                        }

                        if finishAfterEmit {
                            return
                        }
                    case .finish:
                        timerTask?.cancel()
                        timerTask = nil
                        return
                    case .idle:
                        break
                    }

                    if case .idle = action {
                        break
                    }
                }
            }
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}

func makeRateLimitedValueStreamNonSendable<Element>(
    _ source: AsyncStream<Element>,
    rateLimit: ObservationRateLimit,
    rateLimitClock: any Clock<Duration>
) -> AsyncStream<Element> {
    switch rateLimit {
    case let .debounce(debounce):
        return makeDebouncedValueStreamNonSendable(
            source,
            debounce: debounce,
            debounceClock: rateLimitClock
        )
    case let .throttle(throttle):
        return makeThrottledValueStreamNonSendable(
            source,
            throttle: throttle,
            throttleClock: rateLimitClock
        )
    }
}

func makeDebouncedValueStreamNonSendable<Element>(
    _ source: AsyncStream<Element>,
    debounce: ObservationDebounce,
    debounceClock: any Clock<Duration>
) -> AsyncStream<Element> {
    makeDebouncedValueStreamNonSendable(
        source,
        debounce: debounce,
        clock: debounceClock
    )
}

func makeDebouncedValueStreamNonSendable<Element, C: Clock<Duration>>(
    _ source: AsyncStream<Element>,
    debounce: ObservationDebounce,
    clock: C
) -> AsyncStream<Element> {
    let boxedSource = makeUncheckedSendableBoxedStream(source)
    let debouncedBoxes = makeDebouncedValueStream(
        boxedSource,
        debounce: debounce,
        clock: clock
    )
    return makeUncheckedSendableUnboxedStream(debouncedBoxes)
}

func makeThrottledValueStreamNonSendable<Element>(
    _ source: AsyncStream<Element>,
    throttle: ObservationThrottle,
    throttleClock: any Clock<Duration>
) -> AsyncStream<Element> {
    makeThrottledValueStreamNonSendable(
        source,
        throttle: throttle,
        clock: throttleClock
    )
}

func makeThrottledValueStreamNonSendable<Element, C: Clock<Duration>>(
    _ source: AsyncStream<Element>,
    throttle: ObservationThrottle,
    clock: C
) -> AsyncStream<Element> {
    let boxedSource = makeUncheckedSendableBoxedStream(source)
    let throttledBoxes = makeThrottledValueStream(
        boxedSource,
        throttle: throttle,
        clock: clock
    )
    return makeUncheckedSendableUnboxedStream(throttledBoxes)
}

private func makeUncheckedSendableBoxedStream<Element>(
    _ source: AsyncStream<Element>
) -> AsyncStream<_UncheckedSendableValueBox<Element>> {
    let sourceBox = _UncheckedSendableValueBox(source)
    return AsyncStream { continuation in
        let task = Task {
            for await nextValue in sourceBox.value {
                guard !Task.isCancelled else {
                    break
                }
                continuation.yield(_UncheckedSendableValueBox(nextValue))
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}

private func makeUncheckedSendableUnboxedStream<Element>(
    _ source: AsyncStream<_UncheckedSendableValueBox<Element>>
) -> AsyncStream<Element> {
    AsyncStream { continuation in
        let task = Task {
            for await boxedValue in source {
                guard !Task.isCancelled else {
                    break
                }
                continuation.yield(boxedValue.value)
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}
