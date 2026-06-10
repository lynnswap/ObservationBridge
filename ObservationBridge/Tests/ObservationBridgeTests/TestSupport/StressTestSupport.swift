import Foundation
import Synchronization
@testable import ObservationBridge

struct StressRNG: Sendable {
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

func stressSeed(default defaultSeed: UInt64) -> UInt64 {
    if let raw = ProcessInfo.processInfo.environment["OBS_COMPAT_STRESS_SEED"],
       let parsed = UInt64(raw)
    {
        return parsed
    }
    return defaultSeed
}

func stressIterationCount(local: Int, ci: Int) -> Int {
    ProcessInfo.processInfo.environment["CI"] == "true" ? ci : local
}

actor StressFailureRecorder {
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

struct StressRunOutcome: Sendable {
    let firstFailure: String?
}

typealias NativeStressRegistrar = @Sendable (
    LockedCounterModel,
    @escaping @Sendable (Int) -> Void
) -> PortableObservationToken

func runTwoThreadWriteAndReadRound(
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

func runRandomizedObservationStress(
    iterations: Int,
    seed: UInt64,
    register: @escaping NativeStressRegistrar
) async -> (completed: Bool, workers: Int, firstFailure: String?) {
    let isCI = ProcessInfo.processInfo.environment["CI"] == "true"
    let resolvedIterations = isCI ? min(iterations, 200) : iterations
    let maxWorkers = isCI ? 2 : 8
    let workers = max(2, min(ProcessInfo.processInfo.activeProcessorCount, maxWorkers))
    let timeout: UInt64 = isCI ? 30_000_000_000 : 180_000_000_000
    let outcome = await waitWithTimeout(nanoseconds: timeout) {
        let failureRecorder = StressFailureRecorder()
        let baseIterationsPerWorker = resolvedIterations / workers
        let extraIterations = resolvedIterations % workers

        await withTaskGroup(of: Void.self) { group in
            for workerIndex in 0..<workers {
                let workerIterations = baseIterationsPerWorker + (workerIndex < extraIterations ? 1 : 0)
                let workerSeed = seed &+ (UInt64(workerIndex) &* 0x9E37_79B1_85EB_CA87)

                group.addTask {
                    var rng = StressRNG(seed: workerSeed)
                    let model = LockedCounterModel()
                    let observedFlag = Mutex(false)
                    let token = register(model) { _ in
                        observedFlag.withLock { $0 = true }
                    }
                    defer { token.cancel() }

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
