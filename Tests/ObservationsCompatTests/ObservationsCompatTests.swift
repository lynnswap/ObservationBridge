import Observation
import Testing
@testable import ObservationsCompat

@Observable
@MainActor
private final class CounterModel {
    var value: Int = 0
}

@Observable
@MainActor
private final class OptionalCounterModel {
    var value: Int? = nil
}

@Observable
@MainActor
private final class DeinitProbeCounterModel {
    var value: Int = 0
    private let onDeinit: @Sendable () -> Void

    init(onDeinit: @escaping @Sendable () -> Void) {
        self.onDeinit = onDeinit
    }

    isolated deinit {
        onDeinit()
    }
}

private actor DeinitFlag {
    private(set) var didDeinit = false

    func mark() {
        didDeinit = true
    }
}

private func waitWithTimeout<T: Sendable>(
    nanoseconds: UInt64 = 1_000_000_000,
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

@MainActor
@Suite(.serialized)
struct ObservationsCompatTests {
    @Test
    func legacyBackendEmitsInitialAndDistinctChanges() async {
        let model = CounterModel()
        let stream = makeObservationsCompatStream(backend: .legacy) {
            model.value
        }
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == 0)

        model.value = 1
        #expect(await iterator.next() == 1)

        await Task.yield()
        model.value = 1
        await Task.yield()
        model.value = 2
        #expect(await iterator.next() == 2)
    }

    @Test
    func nativeBackendFallsBackToLegacyOnUnsupportedOS() async {
        let model = CounterModel()
        let stream = makeObservationsCompatStream(backend: .native) {
            model.value
        }

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == 0)

        model.value = 7
        let second = await iterator.next()
        #expect(second == 7)
    }

    @Test
    func legacyBackendEmitsInitialOptionalNilValue() async {
        let model = OptionalCounterModel()
        let stream = makeObservationsCompatStream(backend: .legacy) {
            model.value
        }

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == .some(nil))

        model.value = 3
        let second = await iterator.next()
        #expect(second == .some(3))
    }

    @Test
    func streamCanBeCancelledSafely() async {
        let model = CounterModel()
        let stream = makeObservationsCompatStream(backend: .legacy) {
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

            var stream: ObservationsCompatStream<Int>? = makeObservationsCompatStream(backend: .legacy) {
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
}
