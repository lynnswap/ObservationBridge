import Observation
import Foundation
import Synchronization
import Testing
@testable import ObservationBridge

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

@MainActor
@Observable
private final class MainActorCounterModel {
    var value: Int = 0
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

private func legacyOptionsForCurrentRuntime(
    _ additional: ObservationOptions = []
) -> ObservationOptions {
    var options = additional
    if #available(iOS 26.0, macOS 26.0, *) {
        options.formUnion([.legacyBackend])
    }
    return options
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

private actor CallbackIsolationActor {
    func handle(_ value: sending Int, queue: ValueQueue<Int>) async {
        await queue.push(value)
    }
}

@globalActor
private actor AlternateGlobalActor {
    static let shared = AlternateGlobalActor()
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

private final class TestDebounceClock: Clock, @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant
    typealias Duration = Swift.Duration

    private struct SleepWaiter {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct SuspensionWaiter {
        let minimumSleepers: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now: Instant
        var sleepers: [UInt64: SleepWaiter] = [:]
        var nextSleepToken: UInt64 = 0
        var suspensionWaiters: [UInt64: SuspensionWaiter] = [:]
        var nextSuspensionToken: UInt64 = 0
    }

    private let state: Mutex<State>

    var now: Instant {
        state.withLock { $0.now }
    }

    var minimumResolution: Duration {
        .nanoseconds(1)
    }

    init(now: Instant = ContinuousClock().now) {
        state = Mutex(State(now: now))
    }

    func sleep(until deadline: Instant, tolerance _: Duration? = nil) async throws {
        if deadline <= now {
            return
        }
        try Task.checkCancellation()

        let sleepToken = state.withLock { state in
            let token = state.nextSleepToken
            state.nextSleepToken &+= 1
            return token
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let suspensionContinuations: [CheckedContinuation<Void, Never>] = state.withLock { state in
                    if deadline <= state.now {
                        continuation.resume(returning: ())
                        return []
                    }

                    state.sleepers[sleepToken] = SleepWaiter(
                        deadline: deadline,
                        continuation: continuation
                    )
                    return Self.popReadySuspensionWaiters(state: &state)
                }
                for suspensionContinuation in suspensionContinuations {
                    suspensionContinuation.resume()
                }
            }
        } onCancel: {
            let cancellationContinuation: CheckedContinuation<Void, Error>? = state.withLock { state in
                state.sleepers.removeValue(forKey: sleepToken)?.continuation
            }
            cancellationContinuation?.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        precondition(duration >= .zero, "duration must be non-negative")

        let readyContinuations: [CheckedContinuation<Void, Error>] = state.withLock { state in
            state.now = state.now.advanced(by: duration)

            let readySleepTokens = state.sleepers.compactMap { token, waiter in
                waiter.deadline <= state.now ? token : nil
            }

            return readySleepTokens.compactMap { token in
                state.sleepers.removeValue(forKey: token)?.continuation
            }
        }

        for continuation in readyContinuations {
            continuation.resume(returning: ())
        }
    }

    func sleep(untilSuspendedBy minimumSleepers: Int = 1) async {
        precondition(minimumSleepers > 0, "minimumSleepers must be positive")
        let suspensionToken = state.withLock { state in
            let token = state.nextSuspensionToken
            state.nextSuspensionToken &+= 1
            return token
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResumeImmediately = state.withLock { state in
                    if state.sleepers.count >= minimumSleepers {
                        return true
                    }

                    state.suspensionWaiters[suspensionToken] = SuspensionWaiter(
                        minimumSleepers: minimumSleepers,
                        continuation: continuation
                    )
                    return false
                }

                if shouldResumeImmediately {
                    continuation.resume()
                }
            }
        } onCancel: {
            let cancellationContinuation = state.withLock { state in
                state.suspensionWaiters.removeValue(forKey: suspensionToken)?.continuation
            }
            cancellationContinuation?.resume()
        }
    }

    private static func popReadySuspensionWaiters(state: inout State) -> [CheckedContinuation<Void, Never>] {
        let readyTokens = state.suspensionWaiters.compactMap { token, waiter in
            state.sleepers.count >= waiter.minimumSleepers ? token : nil
        }

        return readyTokens.compactMap { token in
            state.suspensionWaiters.removeValue(forKey: token)?.continuation
        }
    }
}

private actor OperationGate {
    private var permits: Set<Int> = []
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func wait(for value: Int) async {
        if permits.remove(value) != nil {
            return
        }

        await withCheckedContinuation { continuation in
            waiters[value, default: []].append(continuation)
        }
    }

    func release(_ value: Int) {
        guard var valueWaiters = waiters[value], !valueWaiters.isEmpty else {
            permits.insert(value)
            return
        }

        let continuation = valueWaiters.removeFirst()
        if valueWaiters.isEmpty {
            waiters[value] = nil
        } else {
            waiters[value] = valueWaiters
        }
        continuation.resume()
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

private func waitUntilValueReceived<Value: Sendable & Equatable>(
    _ expected: Value,
    from queue: ValueQueue<Value>,
    nanoseconds: UInt64 = 5_000_000_000
) async -> Bool {
    let reached = await waitWithTimeout(nanoseconds: nanoseconds) {
        while true {
            guard let next = await queue.next() else {
                return false
            }
            if next == expected {
                return true
            }
        }
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
struct ObservationBridgeTests {
    @Test
    func legacyBackendEmitsInitialAndDistinctChanges() async {
        let model = CounterModel()
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

        await Task.yield()
        model.value = 1
        await Task.yield()
        model.value = 2
        #expect(await nextWithTimeout(from: queue) == 2)
    }

    @Test
    func legacyBackendCoalescesBurstAndEventuallyEmitsLatestValue() async {
        let model = CounterModel()
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

        for _ in 0..<1_000 {
            model.value = 1
        }

        #expect(await nextWithTimeout(from: queue) == 1)
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func defaultBackendFallsBackToLegacyOnUnsupportedOS() async {
        if #available(iOS 26.0, macOS 26.0, *) {
            return
        }

        let model = CounterModel()
        let stream = ObservationBridge(options: []) {
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

    @Test
    func legacyBackendPreservesObserveIsolationAcrossDetachedCreation() async {
        let model = CounterModel()
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

    @Test
    func streamCanBeCancelledSafely() async {
        let model = CounterModel()
        let stream = ObservationBridge(options: legacyOptionsForCurrentRuntime()) {
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

            var stream: ObservationBridge<Int>? = ObservationBridge(options: legacyOptionsForCurrentRuntime()) {
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
    func observationBridgeOptionsEmptyEmitsConsecutiveEqualValues() async {
        let model = CounterModel()
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

    @Test
    func observationBridgeRemoveDuplicatesSuppressesConsecutiveEqualValues() async {
        let model = CounterModel()
        let stream = ObservationBridge(options: legacyOptionsForCurrentRuntime([.removeDuplicates])) {
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
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)

        model.value = 2
        #expect(await nextWithTimeout(from: queue) == 0)
    }

    @Test
    func observationBridgeRemoveDuplicatesSuppressesConsecutiveOptionalNilValues() async {
        let model = OptionalCounterModel()
        let stream = ObservationBridge(options: legacyOptionsForCurrentRuntime([.removeDuplicates])) {
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

        model.value = nil
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)

        model.value = 1
        #expect(await nextWithTimeout(from: queue) == 1)

        model.value = nil
        #expect(await nextWithTimeout(from: queue) == .some(nil))

        model.value = nil
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observationBridgeDebounceImmediateFirstSupportsDeterministicClockControl() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .immediateFirst)
        let stream = ObservationBridge(
            options: legacyOptionsForCurrentRuntime([.debounce(debounce)]),
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
        model.value = 2
        model.value = 3

        await clock.sleep(untilSuspendedBy: 1)
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)

        clock.advance(by: .milliseconds(199))
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)

        clock.advance(by: .milliseconds(1))
        #expect(await nextWithTimeout(from: queue) == 3)
    }

    @Test
    func observationBridgeRemoveDuplicatesAppliesToDebouncedOutputs() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .immediateFirst)
        let stream = ObservationBridge(
            options: legacyOptionsForCurrentRuntime([.removeDuplicates, .debounce(debounce)]),
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
        model.value = 2
        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(200))
        #expect(await nextWithTimeout(from: queue) == 2)

        model.value = 2
        await Task.yield()
        clock.advance(by: .milliseconds(200))
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)

        model.value = 3
        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(200))
        #expect(await nextWithTimeout(from: queue) == 3)
    }

    @Test
    func makeObservationBridgeStreamSupportsOptionsAndClock() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .immediateFirst)
        let stream = makeObservationBridgeStream(
            options: legacyOptionsForCurrentRuntime([.debounce(debounce)]),
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
        model.value = 2

        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(200))
        #expect(await nextWithTimeout(from: queue) == 2)
    }


    @Test
    func observeEmitsInitialAndDuplicateValuesByDefault() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()

        let handle = model.observeTask(\.parity, options: []) { value in
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
    func observeSingleKeyPathNoArgEmitsInitialAndSubsequentChanges() async {
        let model = CounterModel()
        let recorder = ValueRecorder<Int>()

        let handle = model.observe(\.value, options: []) {
            recorder.append(1)
        }
        defer { handle.cancel() }

        #expect(await waitUntilCount(1, in: recorder))

        model.value = 4
        #expect(await waitUntilCount(2, in: recorder))

        model.value = 9
        #expect(await waitUntilCount(3, in: recorder))
    }

    @Test
    func observeSingleKeyPathNoArgSupportsRemoveDuplicates() async {
        let model = CounterModel()
        let recorder = ValueRecorder<Int>()

        let handle = model.observe(
            \.parity,
            options: [.removeDuplicates]
        ) {
            recorder.append(1)
        }
        defer { handle.cancel() }

        #expect(await waitUntilCount(1, in: recorder))

        model.value = 1
        #expect(await waitUntilCount(2, in: recorder))

        model.value = 3
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count() == 2)

        model.value = 2
        #expect(await waitUntilCount(3, in: recorder))
    }

    @Test
    func observeTaskSingleKeyPathNoArgEmitsInitialAndSubsequentChanges() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()

        let handle = model.observeTask(\.value, options: []) {
            await queue.push(1)
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue) == 1)

        model.value = 10
        #expect(await nextWithTimeout(from: queue) == 1)

        model.value = 11
        #expect(await nextWithTimeout(from: queue) == 1)
    }

    @Test
    func observeOptionalKeyPathEmitsInitialNilAndTransitions() async {
        let model = OptionalCounterModel()
        let recorder = ValueRecorder<Int?>()

        let handle = model.observe(\.value, options: [.removeDuplicates]) { value in
            recorder.append(value)
        }
        defer { handle.cancel() }

        #expect(await waitUntilCount(1, in: recorder))
        #expect(recorder.snapshot() == [nil])

        model.value = nil
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count() == 1)

        model.value = 1
        #expect(await waitUntilCount(2, in: recorder))

        model.value = nil
        #expect(await waitUntilCount(3, in: recorder))
        #expect(recorder.snapshot().prefix(3).elementsEqual([nil, 1, nil]))

        model.value = nil
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count() == 3)
    }

    @Test
    func observeTaskOptionalKeyPathNoArgSupportsRemoveDuplicates() async {
        let model = OptionalCounterModel()
        let recorder = ValueRecorder<Int>()

        let handle = model.observeTask(\.value, options: [.removeDuplicates]) {
            recorder.append(1)
        }
        defer { handle.cancel() }

        #expect(await waitUntilCount(1, in: recorder))

        model.value = nil
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count() == 1)

        model.value = 1
        #expect(await waitUntilCount(2, in: recorder))

        model.value = nil
        #expect(await waitUntilCount(3, in: recorder))

        model.value = nil
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count() == 3)
    }

    @Test
    func observeTaskRemoveDuplicatesSuppressesConsecutiveOptionalNilValues() async {
        let model = OptionalCounterModel()
        let queue = ValueQueue<Int?>()

        let handle = model.observeTask(
            \.value,
            options: [.removeDuplicates]
        ) { value in
            await queue.push(value)
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue) == .some(nil))

        model.value = nil
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)

        model.value = 1
        #expect(await nextWithTimeout(from: queue) == 1)

        model.value = nil
        #expect(await nextWithTimeout(from: queue) == .some(nil))

        model.value = nil
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observeTaskDebounceImmediateFirstSupportsDeterministicClockControl() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .immediateFirst)

        let handle = model.observeTask(
            \.value,
            options: [.debounce(debounce)],
            clock: clock
        ) { value in
            await queue.push(value)
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1
        model.value = 2
        model.value = 3

        await clock.sleep(untilSuspendedBy: 1)
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)

        clock.advance(by: .milliseconds(199))
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)

        clock.advance(by: .milliseconds(1))
        #expect(await nextWithTimeout(from: queue) == 3)
    }

    @Test
    func observeTaskDebounceDelayedFirstSupportsDeterministicClockControl() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .delayedFirst)

        let handle = model.observeTask(
            \.value,
            options: [.debounce(debounce)],
            clock: clock
        ) { value in
            await queue.push(value)
        }
        defer { handle.cancel() }

        await clock.sleep(untilSuspendedBy: 1)
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)

        clock.advance(by: .milliseconds(200))
        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 10
        model.value = 11
        await clock.sleep(untilSuspendedBy: 1)

        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)

        clock.advance(by: .milliseconds(199))
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)

        clock.advance(by: .milliseconds(1))
        #expect(await nextWithTimeout(from: queue) == 11)
    }

    @Test
    func observeTaskDebounceWithToleranceSupportsDeterministicClockBoundaryChecks() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let debounce = ObservationDebounce(
            interval: .milliseconds(300),
            tolerance: .milliseconds(50),
            mode: .delayedFirst
        )

        let handle = model.observeTask(
            \.value,
            options: [.debounce(debounce)],
            clock: clock
        ) { value in
            await queue.push(value)
        }
        defer { handle.cancel() }

        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(299))
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)
        clock.advance(by: .milliseconds(1))
        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 42
        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(299))
        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)
        clock.advance(by: .milliseconds(1))
        #expect(await nextWithTimeout(from: queue) == 42)
    }

    @Test
    func observeMaintainsMainActorIsolationForMainActorModel() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = MainActorCounterModel()
        let recorder = ValueRecorder<Int>()
        let handle = model.observe(\.value, options: [.removeDuplicates]) { value in
            MainActor.assertIsolated()
            recorder.append(value)
        }
        defer { handle.cancel() }

        #expect(await waitUntilCount(1, in: recorder))
        #expect(recorder.snapshot() == [0])

        model.value = 1
        #expect(await waitUntilCount(2, in: recorder))
        #expect(recorder.snapshot().prefix(2).elementsEqual([0, 1]))
    }

    @Test
    func observeNoArgMaintainsMainActorIsolationForMainActorModel() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = MainActorCounterModel()
        let recorder = ValueRecorder<Int>()
        let handle = model.observe(\.value, options: [.removeDuplicates]) {
            MainActor.assertIsolated()
            recorder.append(1)
        }
        defer { handle.cancel() }

        #expect(await waitUntilCount(1, in: recorder))

        model.value = 1
        #expect(await waitUntilCount(2, in: recorder))

        model.value = 1
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count() == 2)
    }

    @Test
    func observeTaskMaintainsMainActorIsolationForMainActorModel() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = MainActorCounterModel()
        let queue = ValueQueue<Int>()
        let handle = model.observeTask(\.value, options: [.removeDuplicates]) { value in
            MainActor.assertIsolated()
            await queue.push(value)
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1
        #expect(await nextWithTimeout(from: queue) == 1)

        model.value = 1
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observeTaskNoArgMaintainsMainActorIsolationForMainActorModel() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = MainActorCounterModel()
        let queue = ValueQueue<Int>()
        let handle = model.observeTask(\.value, options: [.removeDuplicates]) {
            MainActor.assertIsolated()
            await queue.push(1)
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue) == 1)

        model.value = 1
        #expect(await nextWithTimeout(from: queue) == 1)

        model.value = 1
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observeTaskKeyPathGetterDoesNotUseCallbackActorIsolation() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = MainActorCounterModel()
        let queue = ValueQueue<Int>()
        let handle = await MainActor.run {
            model.observeTask(\.value, options: [.removeDuplicates]) { @AlternateGlobalActor value in
                await queue.push(value)
            }
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        await MainActor.run {
            model.value = 1
        }
        #expect(await nextWithTimeout(from: queue) == 1)
    }

    @Test
    func observeImplPrefersValueIsolationOverCallbackIsolation() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let model = MainActorCounterModel()
        let queue = ValueQueue<Int>()
        let callbackIsolation = CallbackIsolationActor()
        let readMainActorValue: @isolated(any) @Sendable (MainActorCounterModel) -> Int = { @MainActor owner in
            owner.value
        }
        #expect(readMainActorValue.isolation != nil)

        let handle = observeImpl(
            owner: model,
            options: [.removeDuplicates],
            duplicateFilter: { @Sendable lhs, rhs in lhs == rhs },
            debounce: nil,
            debounceClock: ContinuousClock(),
            isolation: callbackIsolation,
            of: readMainActorValue,
            onChange: { value in
                await callbackIsolation.handle(value, queue: queue)
            }
        )
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1
        #expect(await nextWithTimeout(from: queue) == 1)
    }

    @Test
    func observeTaskDebounceAndRemoveDuplicatesSuppressesPostDebounceDuplicateOutputs() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        let clock = TestDebounceClock()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .immediateFirst)

        let handle = model.observeTask(
            \.parity,
            options: [.removeDuplicates, .debounce(debounce)],
            clock: clock
        ) { value in
            await queue.push(value)
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 1
        model.value = 2
        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(200))

        #expect(await nextWithTimeout(from: queue, nanoseconds: 120_000_000) == nil)
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

        if #available(iOS 26.0, macOS 26.0, *) {
            let legacyOnly: ObservationOptions = [.legacyBackend]
            #expect(legacyOnly.contains(.legacyBackend))

            let withLegacy = withFlag.union(legacyOnly)
            #expect(withLegacy.contains(.legacyBackend))
            #expect(withLegacy.contains(.removeDuplicates))

            let legacyRoundTrip = ObservationOptions(rawValue: withLegacy.rawValue)
            #expect(legacyRoundTrip.contains(.legacyBackend))

            let withoutLegacy = withLegacy.subtracting([.legacyBackend])
            #expect(!withoutLegacy.contains(.legacyBackend))
        }

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
        #expect(conflictingUnionAB.hasDebounceConflict)
        #expect(!a.hasDebounceConflict)
        #expect(!b.hasDebounceConflict)
        #expect(conflictingUnionAB.debounce == nil)
        #expect(!conflictingUnionAB.contains(a))
        #expect(!conflictingUnionAB.contains(b))

        let literalMerged: ObservationOptions = [.debounce(debounce), .debounce(otherDebounce)]
        #expect(literalMerged.hasDebounceConflict)
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
        model.isEnabled = true
        #expect(await waitUntilValueReceived(.some("hello"), from: queue))
    }

    @Test
    func observeTaskTriggerOnlyMultipleKeyPathSupportsDebounce() async {
        let model = CounterModel()
        let recorder = ValueRecorder<Int>()
        let debounce = ObservationDebounce(interval: .milliseconds(200), mode: .immediateFirst)

        let handle = model.observeTask(
            [\.value, \.isEnabled],
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

        let handle = model.observeTask([\.value, \.isEnabled], options: []) {
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

        let handle = model.observe([\.value, \.isEnabled], options: []) {
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
    func observeTaskStopsAfterHandleRelease() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        var handle: ObservationHandle? = model.observeTask(\.value, options: []) { value in
            await queue.push(value)
        }

        #expect(await nextWithTimeout(from: queue) == 0)
        #expect(handle != nil)

        handle = nil
        await Task.yield()

        model.value = 9
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observeTaskStoreInSetKeepsObservationAlive() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        var cancellables = Set<ObservationHandle>()

        model.observeTask(\.value, options: []) { value in
            await queue.push(value)
        }
        .store(in: &cancellables)

        #expect(cancellables.count == 1)
        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 9
        #expect(await nextWithTimeout(from: queue) == 9)
    }

    @Test
    func observeTaskStoreInSetStopsAfterRemoval() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        var cancellables = Set<ObservationHandle>()

        model.observeTask(\.value, options: []) { value in
            await queue.push(value)
        }
        .store(in: &cancellables)

        #expect(await nextWithTimeout(from: queue) == 0)

        cancellables.removeAll(keepingCapacity: false)
        await Task.yield()

        model.value = 10
        #expect(await nextWithTimeout(from: queue, nanoseconds: 300_000_000) == nil)
    }

    @Test
    func observeTaskStoreInSetDeduplicatesSameHandle() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()
        var cancellables = Set<ObservationHandle>()
        let handle = model.observeTask(\.value, options: []) { value in
            await queue.push(value)
        }

        handle.store(in: &cancellables)
        handle.store(in: &cancellables)

        #expect(cancellables.count == 1)
        #expect(await nextWithTimeout(from: queue) == 0)
    }

    @Test
    func observeTaskStoreInSetCancelsWhenOwnerDeinitializes() async {
#if canImport(ObjectiveC)
        let started = ValueQueue<Int>()
        let cancelled = ValueQueue<Int>()
        let deinitFlag = DeinitFlag()
        let gate = OperationGate()
        var cancellables = Set<ObservationHandle>()
        weak var weakModel: DeinitProbeCounterModel?

        do {
            let model = DeinitProbeCounterModel {
                Task {
                    await deinitFlag.mark()
                }
            }
            weakModel = model

            model.observeTask(\.value, options: []) { value in
                await started.push(value)
                await withTaskCancellationHandler {
                    await gate.wait(for: value)
                } onCancel: {
                    Task {
                        await cancelled.push(value)
                        await gate.release(value)
                    }
                }
            }
            .store(in: &cancellables)

            #expect(await nextWithTimeout(from: started) == 0)
        }

        let deinitDeadline = ContinuousClock().now + .seconds(2)
        while !(await deinitFlag.didDeinit), ContinuousClock().now < deinitDeadline {
            await Task.yield()
        }
        #expect(await deinitFlag.didDeinit)

        let ownerReleaseDeadline = ContinuousClock().now + .seconds(2)
        while weakModel != nil, ContinuousClock().now < ownerReleaseDeadline {
            await Task.yield()
        }
        #expect(weakModel == nil)
        #expect(await nextWithTimeout(from: cancelled, nanoseconds: 2_000_000_000) == 0)

        cancellables.removeAll(keepingCapacity: false)
#else
        return
#endif
    }

    @Test
    func observeTaskStopsAfterHandleCancel() async {
        let model = CounterModel()
        let queue = ValueQueue<Int>()

        let handle = model.observeTask(\.value, options: []) { value in
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
        let gate = OperationGate()

        let handle = model.observeTask(\.value, options: []) { value in
            await started.push(value)
            await withTaskCancellationHandler {
                await gate.wait(for: value)
                guard !Task.isCancelled else {
                    return
                }
                await completed.push(value)
            } onCancel: {
                Task {
                    await cancelled.push(value)
                    await gate.release(value)
                }
            }
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: started) == 0)

        model.value = 1
        #expect(await waitUntilValueReceived(0, from: cancelled, nanoseconds: 15_000_000_000))
        #expect(await waitUntilValueReceived(1, from: started, nanoseconds: 15_000_000_000))

        model.value = 2
        #expect(await waitUntilValueReceived(1, from: cancelled, nanoseconds: 15_000_000_000))
        #expect(await waitUntilValueReceived(2, from: started, nanoseconds: 15_000_000_000))

        await gate.release(2)
        #expect(await nextWithTimeout(from: completed, nanoseconds: 15_000_000_000) == 2)
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
    func observeTaskDefaultBackendFallsBackToLegacyOnUnsupportedOS() async {
        if #available(iOS 26.0, macOS 26.0, *) {
            return
        }

        let model = PlainCounterModel()
        let queue = ValueQueue<Int>()

        let handle = model.observeTask(\.value, options: []) { value in
            await queue.push(value)
        }
        defer { handle.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 42
        #expect(await nextWithTimeout(from: queue) == 42)
    }

    @Test
    func observeTaskDoesNotPreventOwnerDeinit() async {
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

            model.observeTask(\.value, options: []) {
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
            model.observeTask(\.value, options: legacyOptionsForCurrentRuntime()) { value in
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
    func defaultBackendObserveTaskStressNoRaceAcrossOneMillionIterationsOnModernOS() async {
        if #unavailable(iOS 26.0, macOS 26.0) {
            return
        }

        let iterations = 1_000_000
        let seed = stressSeed(default: 0x26_00_00_00_00_00_00_02)
        let result = await runRandomizedObservationStress(iterations: iterations, seed: seed) { model, onObserved in
            model.observeTask(\.value, options: []) { value in
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
