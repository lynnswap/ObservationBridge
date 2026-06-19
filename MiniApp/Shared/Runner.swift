import Foundation
import Observation
import ObservationBridge
import Synchronization

enum RunnerConfiguration {
    static let iterations = 1_000_000
    static let seed: UInt64 = 0x26_00_00_00_00_00_00_01
}

struct RunnerResult: Sendable {
    let iterations: Int
    let workers: Int
    let seed: UInt64
    let completed: Bool
    let observedCallbacks: Int
    let matchedMutations: Int
    let firstFailure: String?
    let elapsedSeconds: Double
}

@Observable
private final class LockedCounterModel: Sendable {
    @ObservationIgnored
    private let valueStorage = Mutex<Int>(0)

    nonisolated var value: Int {
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

    nonisolated func writeAndRead(_ newValue: Int) -> Int {
        withMutation(keyPath: \.value) {
            valueStorage.withLock {
                $0 = newValue
                return $0
            }
        }
    }
}

private struct RunnerRNG: Sendable {
    private var state: UInt64

    nonisolated init(seed: UInt64) {
        if seed == 0 {
            state = 0xA5A5_A5A5_A5A5_A5A5
        } else {
            state = seed
        }
    }

    nonisolated mutating func nextUInt64() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    nonisolated mutating func nextBool() -> Bool {
        (nextUInt64() & 1) == 0
    }

    nonisolated mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(nextUInt64() % UInt64(upperBound))
    }
}

private actor FailureRecorder {
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

private struct RunnerOutcome: Sendable {
    let firstFailure: String?
}

enum Runner {
    nonisolated static func run(
        iterations: Int = RunnerConfiguration.iterations,
        seed: UInt64 = RunnerConfiguration.seed
    ) async -> RunnerResult {
        let startNanos = DispatchTime.now().uptimeNanoseconds
        let result = await runRandomizedObservation(
            iterations: iterations,
            seed: seed
        )
        let endNanos = DispatchTime.now().uptimeNanoseconds
        let elapsedSeconds = Double(endNanos - startNanos) / 1_000_000_000

        return RunnerResult(
            iterations: iterations,
            workers: result.workers,
            seed: seed,
            completed: result.completed,
            observedCallbacks: result.observedCallbacks,
            matchedMutations: result.matchedMutations,
            firstFailure: result.firstFailure,
            elapsedSeconds: elapsedSeconds
        )
    }

    private nonisolated static func runTwoThreadWriteAndReadRound(
        model: LockedCounterModel,
        first: Int,
        second: Int,
        firstYields: Int,
        secondYields: Int,
        swapOrder: Bool
    ) async -> [Int] {
        await withTaskGroup(of: Int.self) { group in
            let firstOperation: (Int, Int)
            let secondOperation: (Int, Int)

            if swapOrder {
                firstOperation = (second, secondYields)
                secondOperation = (first, firstYields)
            } else {
                firstOperation = (first, firstYields)
                secondOperation = (second, secondYields)
            }

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

    private nonisolated static func waitWithTimeout<T: Sendable>(
        nanoseconds: UInt64 = 180_000_000_000,
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

    private nonisolated static func runRandomizedObservation(
        iterations: Int,
        seed: UInt64
    ) async -> (
        completed: Bool,
        workers: Int,
        observedCallbacks: Int,
        matchedMutations: Int,
        firstFailure: String?
    ) {
        let workers = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        let totalObservedCallbacks = Mutex<Int>(0)
        let totalMatchedMutations = Mutex<Int>(0)

        let outcome = await waitWithTimeout {
            let failureRecorder = FailureRecorder()
            let baseIterationsPerWorker = iterations / workers
            let extraIterations = iterations % workers

            await withTaskGroup(of: Void.self) { group in
                for workerIndex in 0..<workers {
                    let workerIterations = baseIterationsPerWorker + (workerIndex < extraIterations ? 1 : 0)
                    let workerSeed = seed &+ (UInt64(workerIndex) &* 0x9E37_79B1_85EB_CA87)

                    group.addTask {
                        var rng = RunnerRNG(seed: workerSeed)
                        let model = LockedCounterModel()
                        let observedFlag = Mutex(false)
                        let matchedFlag = Mutex(false)
                        let observation = withPortableContinuousObservation { event in
                            if event.matches(\LockedCounterModel.value) {
                                matchedFlag.withLock { $0 = true }
                                totalMatchedMutations.withLock { $0 += 1 }
                            }

                            totalObservedCallbacks.withLock { $0 += 1 }
                            observedFlag.withLock { $0 = true }
                            _ = model.value
                        }
                        defer { observation.cancel() }

                        for iteration in 0..<workerIterations {
                            if Task.isCancelled {
                                await failureRecorder.record("cancelled")
                                return
                            }

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
                                return
                            }
                        }

                        for _ in 0..<4 {
                            await Task.yield()
                        }

                        if !observedFlag.withLock({ $0 }) {
                            await failureRecorder.record("worker=\(workerIndex), observation callback did not run")
                        }
                        if !matchedFlag.withLock({ $0 }) {
                            await failureRecorder.record("worker=\(workerIndex), observation event did not match value")
                        }
                    }
                }
            }

            return RunnerOutcome(firstFailure: await failureRecorder.firstFailure())
        }

        let observedCallbacks = totalObservedCallbacks.withLock { $0 }
        let matchedMutations = totalMatchedMutations.withLock { $0 }

        guard let outcome else {
            return (false, workers, observedCallbacks, matchedMutations, "timed out")
        }
        return (true, workers, observedCallbacks, matchedMutations, outcome.firstFailure)
    }
}
