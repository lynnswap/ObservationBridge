import Observation
import Foundation
import Synchronization
import Testing
@testable import ObservationBridge

@Suite(.serialized)
final class ObservationBridgeSequenceTests {
    @MainActor
    @Test
    func legacyBackendEmitsInitialAndDistinctChanges() async {
        let model = MainActorCounterModel()
        let stream = ObservationBridge(options: legacyOptionsForCurrentRuntime()) {
            model.value
        }
        let queue = ValueQueue<Int>()
        let consumer = Task<Void, Never> {
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let value = await iterator.next() {
                await queue.push(value)
            }
        }
        defer { consumer.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1
        #expect(await nextWithTimeout(from: queue) == 1)

        model.value = 1
        model.value = 2
        #expect(await nextWithTimeout(from: queue) == 2)
    }

    @Test
    func legacyBackendTracksCustomActorIsolatedStream() async {
        let probe = CustomActorStreamProbe()
        let stream = await probe.makeStream()
        let queue = ValueQueue<Int>()
        let consumer = Task<Void, Never> {
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let value = await iterator.next() {
                await queue.push(value)
            }
        }
        defer { consumer.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        await probe.setValue(1)
        #expect(await nextWithTimeout(from: queue) == 1)

        await probe.setValue(2)
        #expect(await nextWithTimeout(from: queue) == 2)
    }

    @MainActor
    @Test
    func legacyBackendCoalescesActorIsolatedBurstAndEventuallyEmitsLatestValue() async {
        let model = MainActorCounterModel()
        let stream = ObservationBridge(options: legacyOptionsForCurrentRuntime()) {
            model.value
        }
        let queue = ValueQueue<Int>()
        let consumer = Task<Void, Never> {
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let value = await iterator.next() {
                await queue.push(value)
            }
        }
        defer { consumer.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        let latestValue = stressIterationCount(local: 500, ci: 100)
        for value in 1...latestValue {
            model.value = value
        }

        let sawLatest = await waitWithTimeout(nanoseconds: 2_000_000_000) {
            while let value = await queue.next() {
                if value == latestValue {
                    return true
                }
            }
            return false
        }
        #expect(sawLatest == true)
    }

    @MainActor
    @Test
    func legacyBackendSuppressesHighFrequencyDuplicateValues() async {
        let model = MainActorCounterModel()
        let stream = ObservationBridge(options: legacyOptionsForCurrentRuntime()) {
            model.value
        }
        let queue = ValueQueue<Int>()
        let consumer = Task<Void, Never> {
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let value = await iterator.next() {
                await queue.push(value)
            }
        }
        defer { consumer.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        for _ in 0..<stressIterationCount(local: 1_000, ci: 100) {
            model.value = 1
        }

        #expect(await nextWithTimeout(from: queue) == 1)
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

    @MainActor
    @Test
    func legacyBackendEmitsInitialOptionalNilValue() async {
        let model = MainActorOptionalCounterModel()
        let stream = ObservationBridge(options: legacyOptionsForCurrentRuntime()) {
            model.value
        }
        let queue = ValueQueue<Int?>()
        let consumer = Task<Void, Never> {
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let value = await iterator.next() {
                await queue.push(value)
            }
        }
        defer { consumer.cancel() }

        #expect(await nextWithTimeout(from: queue) == .some(nil))

        model.value = 3
        #expect(await nextWithTimeout(from: queue) == 3)
    }

    @MainActor
    @Test
    func automaticBackendObservationBridgeIteratorReturnsInitialAndUpdatedValues() async {
        let model = MainActorCounterModel()
        let stream = ObservationBridge {
            model.value
        }
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next() == 0)

        model.value = 42
        #expect(await iterator.next() == 42)
    }

    @MainActor
    @Test
    func automaticBackendMakeObservationBridgeStreamIteratorReturnsInitialAndUpdatedValues() async {
        let model = MainActorCounterModel()
        let stream = makeObservationBridgeStream {
            model.value
        }
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next() == 0)

        model.value = 9
        #expect(await iterator.next() == 9)
    }

    @MainActor
    @Test
    func automaticBackendObservationBridgeBuffersUpdatesWhileConsumerIsBetweenPulls() async {
        let model = MainActorCounterModel()
        let stream = ObservationBridge {
            model.value
        }
        let queue = ValueQueue<Int>()
        let releaseConsumer = ValueQueue<Void>()
        let consumer = Task<Void, Never> {
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let value = await iterator.next() {
                await queue.push(value)
                if value == 0 {
                    _ = await releaseConsumer.next()
                }
            }
        }
        defer { consumer.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1
        await releaseConsumer.push(())

        #expect(await nextWithTimeout(from: queue) == 1)
    }

    @MainActor
    @Test
    func automaticBackendObservationBridgeIteratorPreservesInitialOptionalNil() async {
        let model = MainActorOptionalCounterModel()
        let stream = ObservationBridge {
            model.value
        }
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next() == .some(nil))

        model.value = 3
        #expect(await iterator.next() == 3)
    }

    @MainActor
    @Test
    func automaticBackendNonSendableStreamWithoutRateLimitReturnsInitialAndUpdatedPayload() async {
        let model = MainActorNonSendablePayloadModel()
        let stream = makeObservationBridgeStream {
            model.payload
        }
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next()?.value == 0)

        model.payload = NonSendablePayload(value: 5)
        #expect(await iterator.next()?.value == 5)
    }

    @MainActor
    @Test
    func automaticBackendNonSendableRateLimitedStreamReturnsInitialPayload() async {
        let model = MainActorNonSendablePayloadModel()
        let clock = TestDebounceClock()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .immediateFirst)
        let stream = makeObservationBridgeStream(
            options: legacyOptionsForCurrentRuntime(.rateLimit(.debounce(debounce))),
            clock: clock
        ) {
            model.payload
        }
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next()?.value == 0)
    }

    @MainActor
    @Test
    func legacyBackendPreservesObserveIsolationAcrossDetachedCreation() async {
        let model = MainActorCounterModel()
        let observeOnMainActor: @MainActor @Sendable () -> Int = {
            MainActor.assertIsolated()
            return model.value
        }
        let observe: @isolated(any) @Sendable () -> Int = observeOnMainActor
        let stream = await Task.detached {
            ObservationBridge(options: legacyOptionsForCurrentRuntime(), observe)
        }.value
        let queue = ValueQueue<Int>()
        let consumer = Task.detached(priority: nil) {
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let value = await iterator.next() {
                await queue.push(value)
            }
        }
        defer { consumer.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 11
        #expect(await nextWithTimeout(from: queue) == 11)
    }

    @MainActor
    @Test
    func streamCanBeCancelledSafely() async {
        let model = MainActorCounterModel()
        let stream = ObservationBridge(options: legacyOptionsForCurrentRuntime()) {
            model.value
        }
        let started = ValueQueue<Bool>()

        let task = Task<Void, Never> {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            await started.push(true)
            while await iterator.next() != nil {}
        }

        #expect(await nextWithTimeout(from: started) == true)
        model.value = 1
        let completed = await waitWithTimeout {
            task.cancel()
            await task.value
            return true
        }
        #expect(completed == true)

        model.value = 2
        #expect(model.value == 2)
    }

    @MainActor
    @Test
    func observationBridgeOptionsEmptyEmitsConsecutiveEqualValues() async {
        let model = MainActorCounterModel()
        let stream = ObservationBridge(options: legacyOptionsForCurrentRuntime()) {
            model.parity
        }
        let queue = ValueQueue<Int>()
        let consumer = Task<Void, Never> {
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let value = await iterator.next() {
                await queue.push(value)
            }
        }
        defer { consumer.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1
        #expect(await nextWithTimeout(from: queue) == 1)

        model.value = 3
        #expect(await nextWithTimeout(from: queue) == 1)
    }

    @MainActor
    @Test
    func makeObservationBridgeStreamSupportsOptionsAndClock() async {
        let model = MainActorCounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .immediateFirst)
        let stream = makeObservationBridgeStream(
            options: legacyOptionsForCurrentRuntime(.rateLimit(.debounce(debounce))),
            clock: clock
        ) {
            model.value
        }
        let consumer = Task<Void, Never> {
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let value = await iterator.next() {
                await queue.push(value)
            }
        }
        defer { consumer.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1

        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(200))
        #expect(await nextWithTimeout(from: queue) == 1)
    }

    @MainActor
    @Test
    func observationBridgeIteratorsReceiveIndependentInitialAndUpdatedValues() async {
        let model = MainActorCounterModel()
        let stream = ObservationBridge {
            model.value
        }
        let firstQueue = ValueQueue<Int>()
        let secondQueue = ValueQueue<Int>()

        let firstConsumer = Task<Void, Never> {
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let value = await iterator.next() {
                await firstQueue.push(value)
            }
        }
        let secondConsumer = Task<Void, Never> {
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let value = await iterator.next() {
                await secondQueue.push(value)
            }
        }
        defer {
            firstConsumer.cancel()
            secondConsumer.cancel()
        }

        #expect(await nextWithTimeout(from: firstQueue) == 0)
        #expect(await nextWithTimeout(from: secondQueue) == 0)

        model.value = 7
        #expect(await nextWithTimeout(from: firstQueue) == 7)
        #expect(await nextWithTimeout(from: secondQueue) == 7)
    }
}

private actor CustomActorStreamProbe {
    private let model = CounterModel()

    func makeStream() -> ObservationBridge<Int> {
        ObservationBridge(options: legacyOptionsForCurrentRuntime()) {
            self.preconditionIsolated()
            return self.model.value
        }
    }

    func setValue(_ value: Int) {
        preconditionIsolated()
        model.value = value
    }
}
