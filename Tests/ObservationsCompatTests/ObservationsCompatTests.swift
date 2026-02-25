import Observation
import Foundation
import Testing
@testable import ObservationsCompat

@Observable
private final class CounterModel {
    var value: Int = 0
    var secondaryValue: Int = 0
    var isEnabled: Bool = false
    var name: String = ""
    var parity: Int { value % 2 }
}

@Observable
private final class PlainCounterModel {
    var value: Int = 0
}

@Observable
private final class OptionalCounterModel {
    var value: Int? = nil
}

@Observable
private final class DeinitProbeCounterModel {
    var value: Int = 0
    private let onDeinit: @Sendable () -> Void

    init(onDeinit: @escaping @Sendable () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit()
    }
}

private actor DeinitFlag {
    private(set) var didDeinit = false

    func mark() {
        didDeinit = true
    }
}

private actor ValueQueue<Value: Sendable> {
    private var buffered: [Value] = []
    private var waiters: [UUID: CheckedContinuation<Value?, Never>] = [:]

    func push(_ value: Value) {
        if let key = waiters.keys.first, let waiter = waiters.removeValue(forKey: key) {
            waiter.resume(returning: value)
            return
        }
        buffered.append(value)
    }

    func next() async -> Value? {
        if !buffered.isEmpty {
            return buffered.removeFirst()
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: id)
            }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else {
            return
        }
        waiter.resume(returning: nil)
    }
}

private func waitWithTimeout<T: Sendable>(
    nanoseconds: UInt64 = 5_000_000_000,
    _ operation: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            await operation()
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: nanoseconds)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

private func nextWithTimeout<Value: Sendable>(
    from queue: ValueQueue<Value>,
    nanoseconds: UInt64 = 5_000_000_000
) async -> Value? {
    await waitWithTimeout(nanoseconds: nanoseconds) {
        await queue.next()
    } ?? nil
}

@MainActor
@Suite(.serialized)
struct ObservationsCompatTests {
    @available(*, deprecated, message: "Uses deprecated stream API for compatibility verification.")
    @Test
    func legacyBackendEmitsInitialAndDistinctChanges() async {
        let model = CounterModel()
        let stream = ObservationsCompat(backend: .legacy) {
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

        await Task.yield()
        model.value = 1
        await Task.yield()
        model.value = 2
        #expect(await nextWithTimeout(from: queue) == 2)
    }

    @available(*, deprecated, message: "Uses deprecated stream API for compatibility verification.")
    @Test
    func nativeBackendFallsBackToLegacyOnUnsupportedOS() async {
        let model = CounterModel()
        let stream = ObservationsCompat(backend: .native) {
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

        model.value = 7
        #expect(await nextWithTimeout(from: queue) == 7)
    }

    @available(*, deprecated, message: "Uses deprecated stream API for compatibility verification.")
    @Test
    func legacyBackendEmitsInitialOptionalNilValue() async {
        let model = OptionalCounterModel()
        let stream = ObservationsCompat(backend: .legacy) {
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

    @available(*, deprecated, message: "Uses deprecated stream API for compatibility verification.")
    @Test
    func legacyBackendPreservesObserveIsolationAcrossDetachedCreation() async {
        let model = CounterModel()
        let observeOnMainActor: @MainActor @Sendable () -> Int = {
            MainActor.assertIsolated()
            return model.value
        }
        let observe: @isolated(any) @Sendable () -> Int = observeOnMainActor
        let stream = await Task.detached {
            ObservationsCompat(backend: .legacy, observe)
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

    @available(*, deprecated, message: "Uses deprecated stream API for compatibility verification.")
    @Test
    func streamCanBeCancelledSafely() async {
        let model = CounterModel()
        let stream = ObservationsCompat(backend: .legacy) {
            model.value
        }

        let task = Task<Void, Never> {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            while await iterator.next() != nil {}
        }

        await Task.yield()
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

    @available(*, deprecated, message: "Uses deprecated stream API for compatibility verification.")
    @Test
    func legacyBackendReleasesObservedModelAfterTermination() async {
        let deinitFlag = DeinitFlag()
        weak var weakModel: DeinitProbeCounterModel?

        do {
            let model = DeinitProbeCounterModel {
                Task {
                    await deinitFlag.mark()
                }
            }
            weakModel = model

            var stream: ObservationsCompat<Int>? = ObservationsCompat(backend: .legacy) {
                model.value
            }

            let consumer = Task<Void, Never> {
                guard let stream else {
                    return
                }
                var iterator = stream.makeAsyncIterator()
                while await iterator.next() != nil {}
            }

            await Task.yield()
            consumer.cancel()
            await consumer.value
            stream = nil
        }

        await Task.yield()
        await Task.yield()
        #expect(weakModel == nil)
        #expect(await deinitFlag.didDeinit)
    }

    @Test
    func observeEmitsInitialAndDuplicateValuesByDefault() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()

        let handle = model.observeTask(\.parity, retention: .manual) { value in
            await queue.push(value)
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1
        #expect(await nextWithTimeout(from: queue) == 1)

        await Task.yield()
        model.value = 3
        #expect(await nextWithTimeout(from: queue) == 1)
    }

    @Test
    func observeRemoveDuplicatesSuppressesConsecutiveEqualValues() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()

        let handle = model.observe(
            \.parity,
            retention: .manual,
            removeDuplicates: true
        ) { value in
            Task {
                await queue.push(value)
            }
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1
        #expect(await nextWithTimeout(from: queue) == 1)

        await Task.yield()
        model.value = 3
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)

        model.value = 2
        #expect(await nextWithTimeout(from: queue) == 0)
    }

    @Test
    func observeTaskSupportsMultipleKeyPaths() async {
        let model = CounterModel()
        let queue = ValueQueue<[Int]>()

        let handle = model.observeTask([\.value, \.secondaryValue], retention: .manual) { values in
            await queue.push(values)
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue) == [0, 0])

        model.value = 4
        #expect(await nextWithTimeout(from: queue) == [4, 0])

        model.secondaryValue = 9
        #expect(await nextWithTimeout(from: queue) == [4, 9])
    }

    @Test
    func observeTaskAutomaticRetentionKeepsObservationWithoutHandle() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()

        model.observeTask(\.value) { value in
            await queue.push(value)
        }

        #expect(await nextWithTimeout(from: queue) == 0)
        model.value = 9
        #expect(await nextWithTimeout(from: queue) == 9)
    }

    @Test
    func observeTaskManualRetentionStopsAfterCancel() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()

        let handle = model.observeTask(\.value, retention: .manual) { value in
            await queue.push(value)
        }

        #expect(await nextWithTimeout(from: queue) == 0)

        handle.cancel()
        await Task.yield()

        model.value = 10
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observeTaskLatestWinsCancelsPreviousInFlightTask() async {
        let model = CounterModel()
        let started = ValueQueue<Int>()
        let completed = ValueQueue<Int>()
        let cancelled = ValueQueue<Int>()

        let handle = model.observeTask(\.value, retention: .manual) { value in
            await started.push(value)
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                await completed.push(value)
            } catch {
                await cancelled.push(value)
            }
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: started) == 0)

        model.value = 1
        await Task.yield()

        model.value = 2
        let cancelledValue = await nextWithTimeout(from: cancelled)
        #expect(cancelledValue == 0 || cancelledValue == 1)
        #expect(await nextWithTimeout(from: completed) == 2)
        #expect(await nextWithTimeout(from: completed, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observeTaskNativeBackendFallsBackToLegacyOnUnsupportedOS() async {
        let model = PlainCounterModel()
        let queue = ValueQueue<Int>()

        let handle = model.observeTask(\.value, backend: .native, retention: .manual) { value in
            await queue.push(value)
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 42
        #expect(await nextWithTimeout(from: queue) == 42)
    }

    @Test
    func observeTaskAutomaticRetentionDoesNotPreventOwnerDeinit() async {
        let deinitFlag = DeinitFlag()
        weak var weakModel: DeinitProbeCounterModel?

        do {
            let model = DeinitProbeCounterModel {
                Task {
                    await deinitFlag.mark()
                }
            }
            weakModel = model

            model.observeTask(\.value) { _ in
            }
        }

        await Task.yield()
        await Task.yield()
        #expect(weakModel == nil)
        #expect(await deinitFlag.didDeinit)
    }
}
