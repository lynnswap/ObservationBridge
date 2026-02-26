//
//  ContentView.swift
//  MiniApp
//
//  Created by Kazuki Nakashima on 2026/02/25.
//

import Foundation
import Observation
import ObservationsCompat
import Synchronization
import SwiftUI

private enum StressRunMode: Sendable {
    case `default`
    case forceLegacy

    var title: String {
        switch self {
        case .default:
            return "default"
        case .forceLegacy:
            return "forceLegacy"
        }
    }

    var seed: UInt64 {
        switch self {
        case .default:
            return 0x26_00_00_00_00_00_00_01
        case .forceLegacy:
            return 0x26_00_00_00_00_00_00_02
        }
    }

    var options: ObservationOptions {
        switch self {
        case .default:
            return []
        case .forceLegacy:
            if #available(iOS 26.0, macOS 26.0, *) {
                return [.legacyBackend]
            }
            return []
        }
    }
}

struct ContentView: View {
    @State private var isRunning = false
    @State private var runningMode: StressRunMode?
    @State private var defaultElapsedSeconds: Double?
    @State private var forceLegacyElapsedSeconds: Double?
    @State private var runningTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("Run") {
                    LabeledContent("Status") {
                        if isRunning, let runningMode {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Running (\(runningMode.title))")
                            }
                        } else {
                            Text("Idle")
                        }
                    }

                    Button("Run Default") {
                        startRun(mode: .default)
                    }
                    .disabled(isRunning)

                    if #available(iOS 26.0, macOS 26.0, *) {
                        Button("Run Force Legacy") {
                            startRun(mode: .forceLegacy)
                        }
                        .disabled(isRunning)
                    }

                    if isRunning {
                        Button("Cancel", role: .destructive) {
                            cancelRun()
                        }
                    }
                }

                Section("Elapsed Time") {
                    LabeledContent("Default") {
                        Text(formattedElapsed(defaultElapsedSeconds))
                            .monospacedDigit()
                    }
                    LabeledContent("Force Legacy") {
                        Text(formattedElapsed(forceLegacyElapsedSeconds))
                            .monospacedDigit()
                    }
                }
            }
            .navigationTitle("Stress Runner")
        }
    }

    private func formattedElapsed(_ seconds: Double?) -> String {
        guard let seconds else {
            return "-"
        }
        return Measurement(value: seconds, unit: UnitDuration.seconds)
            .formatted(
                .measurement(
                    width: .abbreviated,
                    usage: .asProvided,
                    numberFormatStyle: .number.precision(.fractionLength(3))
                )
            )
    }

    private func startRun(mode: StressRunMode) {
        guard !isRunning else {
            return
        }

        let iterations = 1_000_000

        isRunning = true
        runningMode = mode

        runningTask = Task {
            let result = await StressBenchmarkRunner.run(
                mode: mode,
                iterations: iterations,
                seed: mode.seed
            )

            if Task.isCancelled {
                return
            }

            await MainActor.run {
                switch mode {
                case .default:
                    defaultElapsedSeconds = result.elapsedSeconds
                case .forceLegacy:
                    forceLegacyElapsedSeconds = result.elapsedSeconds
                }

                isRunning = false
                runningMode = nil
                runningTask = nil
            }
        }
    }

    private func cancelRun() {
        runningTask?.cancel()
        runningTask = nil
        isRunning = false
        runningMode = nil
    }
}

@Observable
private final class StressLockedCounterModel: Sendable {
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

private struct StressRNG: Sendable {
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

private struct StressRunResult: Sendable {
    let mode: StressRunMode
    let effectiveBackend: String
    let iterations: Int
    let workers: Int
    let seed: UInt64
    let completed: Bool
    let firstFailure: String?
    let elapsedSeconds: Double
}

private enum StressBenchmarkRunner {
    private typealias RegisterObservation = @Sendable (
        StressLockedCounterModel,
        @escaping @Sendable (Int) -> Void
    ) -> ObservationHandle

    static func run(
        mode: StressRunMode,
        iterations: Int,
        seed: UInt64
    ) async -> StressRunResult {
        let startNanos = DispatchTime.now().uptimeNanoseconds
        let result = await runRandomizedObservationStress(
            iterations: iterations,
            seed: seed
        ) { model, onObserved in
            model.observeTask(\.value, options: mode.options) { value in
                onObserved(value)
            }
        }
        let endNanos = DispatchTime.now().uptimeNanoseconds
        let elapsedSeconds = Double(endNanos - startNanos) / 1_000_000_000

        return StressRunResult(
            mode: mode,
            effectiveBackend: resolvedBackend(for: mode),
            iterations: iterations,
            workers: result.workers,
            seed: seed,
            completed: result.completed,
            firstFailure: result.firstFailure,
            elapsedSeconds: elapsedSeconds
        )
    }

    private static func resolvedBackend(for mode: StressRunMode) -> String {
        switch mode {
        case .forceLegacy:
            return "legacy"
        case .default:
            if #available(iOS 26.0, macOS 26.0, *) {
                return "native"
            }
            return "legacy"
        }
    }

    private static func runTwoThreadWriteAndReadRound(
        model: StressLockedCounterModel,
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

    private static func waitWithTimeout<T: Sendable>(
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

    private static func runRandomizedObservationStress(
        iterations: Int,
        seed: UInt64,
        register: @escaping RegisterObservation
    ) async -> (completed: Bool, workers: Int, firstFailure: String?) {
        let workers = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        let outcome = await waitWithTimeout {
            let failureRecorder = StressFailureRecorder()
            let baseIterationsPerWorker = iterations / workers
            let extraIterations = iterations % workers

            await withTaskGroup(of: Void.self) { group in
                for workerIndex in 0..<workers {
                    let workerIterations = baseIterationsPerWorker + (workerIndex < extraIterations ? 1 : 0)
                    let workerSeed = seed &+ (UInt64(workerIndex) &* 0x9E37_79B1_85EB_CA87)

                    group.addTask {
                        var rng = StressRNG(seed: workerSeed)
                        let model = StressLockedCounterModel()
                        let observedFlag = Mutex(false)
                        let handle = register(model) { _ in
                            observedFlag.withLock { $0 = true }
                        }
                        defer { handle.cancel() }

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
}

#Preview {
    ContentView()
}
