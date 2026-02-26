import Observation
import Foundation
import Synchronization
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
private final class LockedCounterModel: Sendable {
    @ObservationIgnored
    private let valueStorage = Mutex<Int>(0)

    var value: Int {
        get {
            access(keyPath: \.value)
            return valueStorage.withLock { $0 }
        }
        set {
            withMutation(keyPath: \.value) {
                valueStorage.withLock { $0 = newValue }
            }
        }
    }

    func writeAndRead(_ newValue: Int) -> Int {
        withMutation(keyPath: \.value) {
            valueStorage.withLock {
                $0 = newValue
                return $0
            }
        }
    }
}

@Observable
private final class OptionalCounterModel {
    var value: Int? = nil
}

private struct CounterSnapshot: Sendable, Equatable {
    let value: Int
    let isEnabled: Bool
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

private struct StressRNG: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xA5A5_A5A5_A5A5_A5A5 : seed
    }

    mutating func nextUInt64() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func nextBool() -> Bool {
        (nextUInt64() & 1) == 0
    }

    mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(nextUInt64() % UInt64(upperBound))
    }
}

private func stressSeed(default defaultSeed: UInt64) -> UInt64 {
    if let raw = ProcessInfo.processInfo.environment["OBS_COMPAT_STRESS_SEED"],
       let parsed = UInt64(raw)
    {
        return parsed
    }
    return defaultSeed
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

private final class ValueRecorder<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])

    func append(_ value: Value) {
        storage.withLock { values in
            values.append(value)
        }
    }

    func snapshot() -> [Value] {
        storage.withLock { values in
            values
        }
    }

    func count() -> Int {
        storage.withLock { values in
            values.count
        }
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

private func waitUntilCount<Value: Sendable>(
    _ expectedCount: Int,
    in recorder: ValueRecorder<Value>,
    nanoseconds: UInt64 = 5_000_000_000
) async -> Bool {
    let reached = await waitWithTimeout(nanoseconds: nanoseconds) {
        while recorder.count() < expectedCount {
            if Task.isCancelled {
                return false
            }
            await Task.yield()
        }
        return true
    }
    return reached == true
}

private actor StressFailureRecorder {
    private var firstFailureMessage: String?

    func record(_ message: String) {
        if firstFailureMessage == nil {
            firstFailureMessage = message
        }
    }

    func firstFailure() -> String? {
        firstFailureMessage
    }
}

private struct StressRunOutcome: Sendable {
    let firstFailure: String?
}

private typealias NativeStressRegistrar = @Sendable (LockedCounterModel, @escaping @Sendable (Int) -> Void) -> ObservationHandle

private func runTwoThreadWriteAndReadRound(
    model: LockedCounterModel,
    first: Int,
    second: Int,
    firstYields: Int,
    secondYields: Int,
    swapOrder: Bool
) async -> [Int] {
    await withTaskGroup(of: Int.self) { group in
        let firstOperation: (Int, Int) = swapOrder ? (second, secondYields) : (first, firstYields)
        let secondOperation: (Int, Int) = swapOrder ? (first, firstYields) : (second, secondYields)

        group.addTask {
            for _ in 0..<firstOperation.1 {
                await Task.yield()
            }
            return model.writeAndRead(firstOperation.0)
        }
        group.addTask {
            for _ in 0..<secondOperation.1 {
                await Task.yield()
            }
            return model.writeAndRead(secondOperation.0)
        }

        var values: [Int] = []
        values.reserveCapacity(2)
        for await value in group {
            values.append(value)
        }
        return values
    }
}

private func runRandomizedObservationStress(
    iterations: Int,
    seed: UInt64,
    register: @escaping NativeStressRegistrar
) async -> (completed: Bool, workers: Int, firstFailure: String?) {
    let workers = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))
    let outcome = await waitWithTimeout(nanoseconds: 180_000_000_000) {
        let failureRecorder = StressFailureRecorder()
        let baseIterationsPerWorker = iterations / workers
        let extraIterations = iterations % workers

        await withTaskGroup(of: Void.self) { group in
            for workerIndex in 0..<workers {
                let workerIterations = baseIterationsPerWorker + (workerIndex < extraIterations ? 1 : 0)
                let workerSeed = seed &+ (UInt64(workerIndex) &* 0x9E37_79B1_85EB_CA87)

                group.addTask {
                    var rng = StressRNG(seed: workerSeed)
                    let model = LockedCounterModel()
                    let observedFlag = Mutex(false)
                    let handle = register(model) { _ in
                        observedFlag.withLock { $0 = true }
                    }
                    defer { handle.cancel() }

                    for iteration in 0..<workerIterations {
                        let first = rng.nextInt(upperBound: 1_000_000_000)
                        let second = rng.nextInt(upperBound: 1_000_000_000) ^ 0x55AA_55AA
                        let firstYields = rng.nextInt(upperBound: 4)
                        let secondYields = rng.nextInt(upperBound: 4)
                        let swapOrder = rng.nextBool()

                        let values = await runTwoThreadWriteAndReadRound(
                            model: model,
                            first: first,
                            second: second,
                            firstYields: firstYields,
                            secondYields: secondYields,
                            swapOrder: swapOrder
                        )
                        let expected = Set([first, second])
                        if Set(values) != expected {
                            await failureRecorder.record(
                                "worker=\(workerIndex), iteration=\(iteration), expected=\(expected), actual=\(values)"
                            )
                            break
                        }
                    }

                    if !observedFlag.withLock({ $0 }) {
                        await failureRecorder.record("worker=\(workerIndex), observation callback did not run")
                    }
                }
            }
        }
        return StressRunOutcome(firstFailure: await failureRecorder.firstFailure())
    }

    guard let outcome else {
        return (false, workers, "timed out")
    }
    return (true, workers, outcome.firstFailure)
}

@MainActor
@Suite
struct ObservationsCompatTests {
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

    @Test
    func legacyBackendCoalescesBurstAndEventuallyEmitsLatestValue() async {
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

        let latestValue = 500
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

    @Test
    func legacyBackendSuppressesHighFrequencyDuplicateValues() async {
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

        for _ in 0..<1_000 {
            model.value = 1
        }

        #expect(await nextWithTimeout(from: queue) == 1)
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

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

        let handle = model.observeTask(\.parity, retention: .manual, options: []) { value in
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
        let recorder = ValueRecorder<Int>()

        let handle = model.observe(
            \.parity,
            retention: .manual,
            options: [.removeDuplicates]
        ) { value in
            recorder.append(value)
        }
        defer { handle.cancel() }

        #expect(await waitUntilCount(1, in: recorder))
        #expect(recorder.snapshot() == [0])

        model.value = 1
        #expect(await waitUntilCount(2, in: recorder))
        #expect(recorder.snapshot().prefix(2).elementsEqual([0, 1]))

        await Task.yield()
        model.value = 3
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.snapshot().prefix(2).elementsEqual([0, 1]))
        #expect(recorder.count() == 2)

        model.value = 2
        #expect(await waitUntilCount(3, in: recorder))
        #expect(recorder.snapshot().prefix(3).elementsEqual([0, 1, 0]))
    }

    @Test
    func observeTaskDebounceImmediateFirstEmitsInitialImmediatelyAndCoalescesFollowingValues() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .immediateFirst)

        let handle = model.observeTask(
            \.value,
            retention: .manual,
            options: [.debounce(debounce)]
        ) { value in
            await queue.push(value)
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1
        model.value = 2
        model.value = 3

        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)
        #expect(await nextWithTimeout(from: queue, nanoseconds: 2_000_000_000) == 3)
    }

    @Test
    func observeTaskDebounceDelayedFirstDelaysInitialValue() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .delayedFirst)

        let handle = model.observeTask(
            \.value,
            retention: .manual,
            options: [.debounce(debounce)]
        ) { value in
            await queue.push(value)
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)
        #expect(await nextWithTimeout(from: queue, nanoseconds: 2_000_000_000) == 0)

        model.value = 10
        model.value = 11
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)
        #expect(await nextWithTimeout(from: queue, nanoseconds: 2_000_000_000) == 11)
    }

    @Test
    func observationOptionsSetAlgebraPreservesDebounceMetadata() {
        let debounce = ObservationDebounce(
            interval: .milliseconds(100),
            tolerance: .milliseconds(20),
            mode: .immediateFirst
        )

        let debounceOnly: ObservationOptions = [.debounce(debounce)]
        #expect(debounceOnly.debounce?.interval == .milliseconds(100))
        #expect(debounceOnly.debounce?.tolerance == .milliseconds(20))
        #expect(debounceOnly.debounce?.mode == .immediateFirst)

        let sameDebounce = ObservationOptions.debounce(debounce)
        #expect(sameDebounce.rawValue == debounceOnly.rawValue)
        #expect(sameDebounce == debounceOnly)

        let roundTrippedDebounce = ObservationOptions(rawValue: debounceOnly.rawValue)
        #expect(roundTrippedDebounce.debounce?.interval == .milliseconds(100))
        #expect(roundTrippedDebounce.debounce?.tolerance == .milliseconds(20))
        #expect(roundTrippedDebounce.debounce?.mode == .immediateFirst)

        let withFlag = debounceOnly.union([.removeDuplicates])
        #expect(withFlag.contains(.removeDuplicates))
        #expect(withFlag.debounce?.interval == .milliseconds(100))

        let roundTrippedWithFlag = ObservationOptions(rawValue: withFlag.rawValue)
        #expect(roundTrippedWithFlag.contains(.removeDuplicates))
        #expect(roundTrippedWithFlag.debounce?.interval == .milliseconds(100))

        let otherDebounce = ObservationDebounce(interval: .milliseconds(150), mode: .delayedFirst)
        #expect(!withFlag.contains(.debounce(otherDebounce)))

        var unchanged = withFlag
        let removedDifferentDebounce = unchanged.remove(.debounce(otherDebounce))
        #expect(removedDifferentDebounce == nil)
        #expect(unchanged.debounce?.interval == .milliseconds(100))

        let a = ObservationOptions.debounce(debounce)
        let b = ObservationOptions.debounce(otherDebounce)
        let conflictingUnionAB = a.union(b)
        let conflictingUnionBA = b.union(a)
        #expect(conflictingUnionAB == conflictingUnionBA)
        #expect(conflictingUnionAB.debounce == nil)
        #expect(!conflictingUnionAB.contains(a))
        #expect(!conflictingUnionAB.contains(b))

        let literalMerged: ObservationOptions = [.debounce(debounce), .debounce(otherDebounce)]
        #expect(literalMerged.debounce == nil)
        #expect(literalMerged == ObservationOptions(rawValue: literalMerged.rawValue))

        let subtractSpecificFromConflict = literalMerged.subtracting([.debounce(debounce)])
        #expect(subtractSpecificFromConflict == literalMerged)

        let clearedConflict = literalMerged.subtracting(literalMerged)
        #expect(clearedConflict == ObservationOptions())

        let thirdDebounce = ObservationDebounce(interval: .milliseconds(200), mode: .immediateFirst)
        let c = ObservationOptions.debounce(thirdDebounce)
        let mergedLeftAssociative = a.union(b).union(c)
        let mergedRightAssociative = a.union(b.union(c))
        #expect(mergedLeftAssociative == mergedRightAssociative)
        #expect(mergedLeftAssociative.debounce == nil)
        #expect(!mergedLeftAssociative.contains(c))

        let symmetricAB = a.symmetricDifference(b)
        let symmetricBA = b.symmetricDifference(a)
        #expect(symmetricAB == symmetricBA)
        #expect(symmetricAB.debounce == nil)

        let intersected = withFlag.intersection([.debounce(debounce)])
        #expect(!intersected.contains(.removeDuplicates))
        #expect(intersected.debounce?.interval == .milliseconds(100))

        let withoutFlag = withFlag.subtracting([.removeDuplicates])
        #expect(!withoutFlag.contains(.removeDuplicates))
        #expect(withoutFlag.debounce?.interval == .milliseconds(100))

        var removedFlag = withFlag
        let removed = removedFlag.remove(.removeDuplicates)
        #expect(removed != nil)
        #expect(!removedFlag.contains(.removeDuplicates))
        #expect(removedFlag.debounce?.interval == .milliseconds(100))

        let clearedDebounce = withFlag.subtracting([.debounce(debounce)])
        #expect(clearedDebounce.debounce == nil)
    }

    @Test
    func observationOptionsDebounceNormalizesSubmillisecondDurations() {
        let submillisecondDebounce = ObservationDebounce(
            interval: .microseconds(1_400),
            tolerance: .microseconds(1_600),
            mode: .delayedFirst
        )
        let canonicalDebounce = ObservationDebounce(
            interval: .milliseconds(1),
            tolerance: .milliseconds(2),
            mode: .delayedFirst
        )

        let submillisecondOptions = ObservationOptions.debounce(submillisecondDebounce)
        let canonicalOptions: ObservationOptions = [.debounce(canonicalDebounce)]

        #expect(submillisecondOptions.debounce?.interval == .milliseconds(1))
        #expect(submillisecondOptions.debounce?.tolerance == .milliseconds(2))
        #expect(submillisecondOptions.contains(canonicalOptions))
        #expect(canonicalOptions.contains(submillisecondOptions))
        #expect(submillisecondOptions.intersection(canonicalOptions) == canonicalOptions)
    }

    @Test
    func observeMultipleKeyPathValueProjectionSupportsRemoveDuplicates() async {
        let model = CounterModel()
        let recorder = ValueRecorder<CounterSnapshot>()

        let handle = model.observe(
            [\.value, \.isEnabled],
            retention: .manual,
            options: [.removeDuplicates],
            of: { owner in
                CounterSnapshot(value: owner.value, isEnabled: owner.isEnabled)
            }
        ) { snapshot in
            recorder.append(snapshot)
        }
        defer { handle.cancel() }

        #expect(await waitUntilCount(1, in: recorder))
        #expect(recorder.snapshot() == [CounterSnapshot(value: 0, isEnabled: false)])

        model.value = 1
        #expect(await waitUntilCount(2, in: recorder))
        #expect(
            recorder.snapshot().prefix(2).elementsEqual([
                CounterSnapshot(value: 0, isEnabled: false),
                CounterSnapshot(value: 1, isEnabled: false)
            ])
        )

        model.value = 1
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count() == 2)

        model.isEnabled = true
        #expect(await waitUntilCount(3, in: recorder))
        #expect(
            recorder.snapshot().prefix(3).elementsEqual([
                CounterSnapshot(value: 0, isEnabled: false),
                CounterSnapshot(value: 1, isEnabled: false),
                CounterSnapshot(value: 1, isEnabled: true)
            ])
        )
    }

    @Test
    func observeTaskMultipleKeyPathValueProjectionSupportsDebounce() async {
        let model = CounterModel()
        let queue = ValueQueue<CounterSnapshot>()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .immediateFirst)

        let handle = model.observeTask(
            [\.value, \.isEnabled],
            retention: .manual,
            options: [.debounce(debounce)],
            of: { owner in
                CounterSnapshot(value: owner.value, isEnabled: owner.isEnabled)
            }
        ) { value in
            await queue.push(value)
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue) == CounterSnapshot(value: 0, isEnabled: false))

        model.value = 1
        model.isEnabled = true
        model.value = 2

        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)
        #expect(await nextWithTimeout(from: queue, nanoseconds: 2_000_000_000) == CounterSnapshot(value: 2, isEnabled: true))
    }

    @Test
    func observeTaskMultipleKeyPathValueProjectionSupportsOptionalNilValues() async {
        let model = CounterModel()
        let queue = ValueQueue<String?>()

        let handle = model.observeTask(
            [\.name, \.isEnabled],
            retention: .manual,
            options: [],
            of: { owner in
                owner.isEnabled ? owner.name : nil
            }
        ) { value in
            await queue.push(value)
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue) == .some(nil))

        model.name = "hello"
        #expect(await nextWithTimeout(from: queue) == .some(nil))

        model.isEnabled = true
        #expect(await nextWithTimeout(from: queue) == "hello")
    }

    @Test
    func observeTaskTriggerOnlyMultipleKeyPathSupportsDebounce() async {
        let model = CounterModel()
        let recorder = ValueRecorder<Int>()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .immediateFirst)

        let handle = model.observeTask(
            [\.value, \.isEnabled],
            retention: .manual,
            options: [.debounce(debounce)]
        ) {
            recorder.append(1)
        }
        defer { handle.cancel() }

        #expect(await waitUntilCount(1, in: recorder))

        model.value = 1
        model.value = 2
        model.isEnabled = true
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(recorder.count() == 1)

        #expect(await waitUntilCount(2, in: recorder))
    }

    @Test
    func observeTaskSupportsMultipleKeyPaths() async {
        let model = CounterModel()
        let recorder = ValueRecorder<Int>()

        let handle = model.observeTask([\.value, \.isEnabled], retention: .manual, options: []) {
            recorder.append(1)
        }
        defer { handle.cancel() }

        #expect(await waitUntilCount(1, in: recorder))
        #expect(recorder.count() == 1)

        model.value = 4
        #expect(await waitUntilCount(2, in: recorder))

        model.isEnabled = true
        #expect(await waitUntilCount(3, in: recorder))
    }

    @Test
    func observeSupportsMultipleKeyPathsAsTriggerOnly() async {
        let model = CounterModel()
        let recorder = ValueRecorder<Int>()

        let handle = model.observe([\.value, \.isEnabled], retention: .manual, options: []) {
            recorder.append(1)
        }
        defer { handle.cancel() }

        #expect(await waitUntilCount(1, in: recorder))

        model.value = 4
        #expect(await waitUntilCount(2, in: recorder))

        model.isEnabled = true
        #expect(await waitUntilCount(3, in: recorder))
    }

    @Test
    func observeTaskAutomaticRetentionKeepsObservationWithoutHandle() async {
#if canImport(ObjectiveC)
        let model = CounterModel()
        let queue = ValueQueue<Int>()

        model.observeTask(\.value, options: []) { value in
            await queue.push(value)
        }

        #expect(await nextWithTimeout(from: queue) == 0)
        model.value = 9
        #expect(await nextWithTimeout(from: queue) == 9)
#else
        return
#endif
    }

    @Test
    func observeTaskManualRetentionStopsAfterCancel() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()

        let handle = model.observeTask(\.value, retention: .manual, options: []) { value in
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

        let handle = model.observeTask(\.value, retention: .manual, options: []) { value in
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
    func observeTaskDebounceStillPreservesLatestWinsCancellation() async {
        let model = CounterModel()
        let started = ValueQueue<Int>()
        let completed = ValueQueue<Int>()
        let cancelled = ValueQueue<Int>()
        let debounce = ObservationDebounce(interval: .milliseconds(150), mode: .immediateFirst)

        let handle = model.observeTask(
            \.value,
            retention: .manual,
            options: [.debounce(debounce)]
        ) { value in
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
        model.value = 2

        let cancelledValue = await nextWithTimeout(from: cancelled)
        #expect(cancelledValue == 0)
        #expect(await nextWithTimeout(from: completed) == 2)
        #expect(await nextWithTimeout(from: completed, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observeTaskNativeBackendFallsBackToLegacyOnUnsupportedOS() async {
        let model = PlainCounterModel()
        let queue = ValueQueue<Int>()

        let handle = model.observeTask(\.value, backend: .native, retention: .manual, options: []) { value in
            await queue.push(value)
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 42
        #expect(await nextWithTimeout(from: queue) == 42)
    }

    @Test
    func observeTaskAutomaticRetentionDoesNotPreventOwnerDeinit() async {
#if canImport(ObjectiveC)
        let deinitFlag = DeinitFlag()
        weak var weakModel: DeinitProbeCounterModel?

        do {
            let model = DeinitProbeCounterModel {
                Task {
                    await deinitFlag.mark()
                }
            }
            weakModel = model

            model.observeTask(\.value, options: []) { _ in
            }
        }

        await Task.yield()
        await Task.yield()
        #expect(weakModel == nil)
        #expect(await deinitFlag.didDeinit)
#else
        return
#endif
    }

    @Test
    func legacyBackendObserveTaskStressNoRaceAcrossOneMillionIterations() async {
        let iterations = 1_000_000
        let seed = stressSeed(default: 0x26_00_00_00_00_00_00_01)
        let result = await runRandomizedObservationStress(iterations: iterations, seed: seed) { model, onObserved in
            model.observeTask(\.value, backend: .legacy, retention: .manual, options: []) { value in
                onObserved(value)
            }
        }

        if !result.completed || result.firstFailure != nil {
            Issue.record(
                "stress seed: \(seed), workers: \(result.workers), failure: \(result.firstFailure ?? "none")"
            )
        }
        #expect(result.completed)
        #expect(result.firstFailure == nil)
    }

    @Test
    func nativeBackendObserveTaskStressNoRaceAcrossOneMillionIterations() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let iterations = 1_000_000
        let seed = stressSeed(default: 0x26_00_00_00_00_00_00_02)
        let result = await runRandomizedObservationStress(iterations: iterations, seed: seed) { model, onObserved in
            model.observeTask(\.value, backend: .native, retention: .manual, options: []) { value in
                onObserved(value)
            }
        }

        if !result.completed || result.firstFailure != nil {
            Issue.record(
                "native stress seed: \(seed), workers: \(result.workers), failure: \(result.firstFailure ?? "none")"
            )
        }
        #expect(result.completed)
        #expect(result.firstFailure == nil)
    }

}
