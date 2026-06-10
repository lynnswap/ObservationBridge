import Darwin
import Dispatch
import Foundation
import Observation
import ObservationBridge
import Synchronization

#if canImport(_ObservationBridgeBenchmarkSupport)
import _ObservationBridgeBenchmarkSupport
#endif

@Observable
final class BenchmarkCounterModel: @unchecked Sendable {
    var value = 0
}

final class BenchmarkSink: @unchecked Sendable {
    private var storage = 0

    var value: Int {
        storage
    }

    @inline(never)
    func record(_ value: Int) {
        storage &+= value
    }
}

final class ChangeDeliveryRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var callbackDeliveryCount = 0
    private var checksum = 0

    var snapshot: (callbackDeliveryCount: Int, checksum: Int) {
        condition.lock()
        defer {
            condition.unlock()
        }

        return (callbackDeliveryCount, checksum)
    }

    @inline(never)
    func recordCallback(_ value: Int) {
        condition.lock()
        callbackDeliveryCount &+= 1
        checksum &+= value
        condition.broadcast()
        condition.unlock()
    }

    func waitForCallbackDeliveryCount(_ expectedCount: Int) throws {
        condition.lock()
        defer {
            condition.unlock()
        }

        let deadline = Date(timeIntervalSinceNow: 10)
        while callbackDeliveryCount < expectedCount {
            guard condition.wait(until: deadline) else {
                throw BenchmarkError.timeout(
                    "timed out waiting for \(expectedCount) callback deliveries"
                )
            }
        }
    }
}

#if canImport(_ObservationBridgeBenchmarkSupport)
private enum RuntimeEnqueueHooks {
    static func activate() {
        ObservationBridgeRuntimeEnqueueHooksInstall()
        ObservationBridgeRuntimeEnqueueHooksReset()
        ObservationBridgeRuntimeEnqueueHooksSetActive(1)
    }

    static func deactivate() {
        ObservationBridgeRuntimeEnqueueHooksSetActive(0)
    }

    static var snapshot: (globalEnqueues: Int, mainExecutorEnqueues: Int) {
        (
            Int(ObservationBridgeRuntimeEnqueueHooksGlobalCount()),
            Int(ObservationBridgeRuntimeEnqueueHooksMainExecutorCount())
        )
    }
}

private enum WaiterRegistrationHooks {
    private static let timeoutNanoseconds: UInt64 = 10_000_000_000

    static func activate() {
        ObservationBridgeBenchmarkWaiterRegistrationHooksReset()
        ObservationBridgeBenchmarkWaiterRegistrationHooksSetActive(1)
    }

    static func deactivate() {
        ObservationBridgeBenchmarkWaiterRegistrationHooksSetActive(0)
    }

    static var count: Int {
        Int(ObservationBridgeBenchmarkWaiterRegistrationHooksCount())
    }

    static func waitForCount(_ expectedCount: Int) throws {
        let didReachCount = ObservationBridgeBenchmarkWaiterRegistrationHooksWaitForCount(
            UInt64(expectedCount),
            timeoutNanoseconds
        )
        guard didReachCount != 0 else {
            throw BenchmarkError.timeout(
                """
                timed out waiting for \(expectedCount) waiter registrations; \
                rebuild with --traits BenchmarkSupport
                """
            )
        }
    }
}
#endif

enum BenchmarkCase: String, CaseIterable {
    case portableSetupTeardown
    #if canImport(_ObservationBridgeBenchmarkSupport)
    case portableChangeRuntimeActivity
    #endif
}

struct BenchmarkConfiguration {
    var selectedCases: [BenchmarkCase] = [.portableSetupTeardown]
    var iterations = 100_000
    var warmupIterations = 1_000
    var runs = 5
    var outputPath: String?
}

struct HeapSnapshot: Encodable {
    let sizeInUse: Int
    let sizeAllocated: Int
    let maxSizeInUse: Int

    static func capture() -> HeapSnapshot {
        var stats = malloc_statistics_t()
        unsafe malloc_zone_statistics(unsafe malloc_default_zone(), &stats)
        return HeapSnapshot(
            sizeInUse: Int(stats.size_in_use),
            sizeAllocated: Int(stats.size_allocated),
            maxSizeInUse: Int(stats.max_size_in_use)
        )
    }
}

struct BenchmarkResult: Encodable {
    let caseName: String
    let runIndex: Int
    let iterations: Int
    let warmupIterations: Int
    let elapsedSeconds: Double
    let nanosecondsPerIteration: Double
    let checksum: Int
    let heapBefore: HeapSnapshot
    let heapAfter: HeapSnapshot
    let heapSizeInUseDelta: Int
    let runtimeActivity: RuntimeActivitySnapshot?
    let date: String
}

struct BenchmarkExecutionResult {
    let checksum: Int
    var runtimeActivity: RuntimeActivitySnapshot? = nil
}

struct RuntimeActivitySnapshot: Encodable {
    let changes: Int
    let callbackDeliveries: Int
    let waiterRegistrations: Int
    let runtimeGlobalEnqueues: Int
    let runtimeMainExecutorEnqueues: Int
    let runtimeTotalEnqueues: Int
    let callbackDeliveriesPerChange: Double
    let runtimeEnqueuesPerChange: Double
    let runtimeGlobalEnqueuesPerChange: Double
    let runtimeMainExecutorEnqueuesPerChange: Double
}

enum BenchmarkError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case timeout(String)

    var description: String {
        switch self {
        case .invalidArgument(let message):
            message
        case .timeout(let message):
            message
        }
    }
}

enum ObservationBridgeBenchmarks {
    static func main() async throws {
        let configuration = try parseArguments(CommandLine.arguments.dropFirst())
        var outputHandle: FileHandle?
        if let outputPath = configuration.outputPath {
            let url = URL(fileURLWithPath: outputPath)
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: outputPath) {
                FileManager.default.createFile(atPath: outputPath, contents: nil)
            }
            outputHandle = try FileHandle(forWritingTo: url)
            try outputHandle?.seekToEnd()
        }

        defer {
            try? outputHandle?.close()
        }

        for benchmarkCase in configuration.selectedCases {
            try await runCase(
                benchmarkCase,
                configuration: configuration,
                outputHandle: outputHandle
            )
        }
    }

    private static func runCase(
        _ benchmarkCase: BenchmarkCase,
        configuration: BenchmarkConfiguration,
        outputHandle: FileHandle?
    ) async throws {
        if configuration.warmupIterations > 0 {
            _ = try await execute(
                benchmarkCase,
                iterations: configuration.warmupIterations
            )
        }

        for runIndex in 0..<configuration.runs {
            let heapBefore = HeapSnapshot.capture()
            let start = DispatchTime.now().uptimeNanoseconds
            let execution = try await execute(
                benchmarkCase,
                iterations: configuration.iterations
            )
            let end = DispatchTime.now().uptimeNanoseconds
            let heapAfter = HeapSnapshot.capture()
            let elapsedSeconds = Double(end - start) / 1_000_000_000
            let result = BenchmarkResult(
                caseName: benchmarkCase.rawValue,
                runIndex: runIndex,
                iterations: configuration.iterations,
                warmupIterations: configuration.warmupIterations,
                elapsedSeconds: elapsedSeconds,
                nanosecondsPerIteration: Double(end - start) / Double(configuration.iterations),
                checksum: execution.checksum,
                heapBefore: heapBefore,
                heapAfter: heapAfter,
                heapSizeInUseDelta: heapAfter.sizeInUse - heapBefore.sizeInUse,
                runtimeActivity: execution.runtimeActivity,
                date: ISO8601DateFormatter().string(from: Date())
            )
            try emit(result, outputHandle: outputHandle)
        }
    }

    private static func execute(
        _ benchmarkCase: BenchmarkCase,
        iterations: Int
    ) async throws -> BenchmarkExecutionResult {
        switch benchmarkCase {
        case .portableSetupTeardown:
            return BenchmarkExecutionResult(checksum: runPortableSetupTeardown(iterations: iterations))
        #if canImport(_ObservationBridgeBenchmarkSupport)
        case .portableChangeRuntimeActivity:
            return try await runPortableChangeRuntimeActivity(iterations: iterations)
        #endif
        }
    }

    @inline(never)
    private static func runPortableSetupTeardown(iterations: Int) -> Int {
        let sink = BenchmarkSink()

        for index in 0..<iterations {
            let model = BenchmarkCounterModel()
            model.value = index
            let token = withPortableContinuousObservation(options: []) { _ in
                sink.record(model.value)
            }
            token.cancel()
        }

        return sink.value
    }

    #if canImport(_ObservationBridgeBenchmarkSupport)
    @inline(never)
    private static func runPortableChangeRuntimeActivity(
        iterations: Int
    ) async throws -> BenchmarkExecutionResult {
        let model = BenchmarkCounterModel()
        model.value = -1
        let recorder = ChangeDeliveryRecorder()

        WaiterRegistrationHooks.activate()
        defer {
            WaiterRegistrationHooks.deactivate()
        }

        let token = withPortableContinuousObservation { _ in
            recorder.recordCallback(model.value)
        }
        defer {
            token.cancel()
        }
        try recorder.waitForCallbackDeliveryCount(1)
        try WaiterRegistrationHooks.waitForCount(1)

        let baseline = recorder.snapshot
        let baselineWaiterRegistrationCount = WaiterRegistrationHooks.count
        RuntimeEnqueueHooks.activate()
        defer {
            RuntimeEnqueueHooks.deactivate()
        }

        for index in 0..<iterations {
            model.value = index
            try recorder.waitForCallbackDeliveryCount(
                baseline.callbackDeliveryCount + index + 1
            )
            try WaiterRegistrationHooks.waitForCount(
                baselineWaiterRegistrationCount + index + 1
            )
        }

        let final = recorder.snapshot
        let finalWaiterRegistrationCount = WaiterRegistrationHooks.count
        let runtime = RuntimeEnqueueHooks.snapshot
        let callbackDeliveries = final.callbackDeliveryCount - baseline.callbackDeliveryCount
        let waiterRegistrations = finalWaiterRegistrationCount - baselineWaiterRegistrationCount
        let totalEnqueues = runtime.globalEnqueues + runtime.mainExecutorEnqueues
        let changeCount = max(iterations, 1)
        let activity = RuntimeActivitySnapshot(
            changes: iterations,
            callbackDeliveries: callbackDeliveries,
            waiterRegistrations: waiterRegistrations,
            runtimeGlobalEnqueues: runtime.globalEnqueues,
            runtimeMainExecutorEnqueues: runtime.mainExecutorEnqueues,
            runtimeTotalEnqueues: totalEnqueues,
            callbackDeliveriesPerChange: Double(callbackDeliveries) / Double(changeCount),
            runtimeEnqueuesPerChange: Double(totalEnqueues) / Double(changeCount),
            runtimeGlobalEnqueuesPerChange: Double(runtime.globalEnqueues) / Double(changeCount),
            runtimeMainExecutorEnqueuesPerChange: Double(runtime.mainExecutorEnqueues) / Double(changeCount)
        )
        return BenchmarkExecutionResult(
            checksum: final.checksum - baseline.checksum,
            runtimeActivity: activity
        )
    }
    #endif

    private static func emit(
        _ result: BenchmarkResult,
        outputHandle: FileHandle?
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        if let outputHandle {
            try outputHandle.write(contentsOf: data)
            try outputHandle.write(contentsOf: Data([0x0A]))
        }

        var summaryParts = [
            result.caseName,
            "run=\(result.runIndex)",
            "iterations=\(result.iterations)",
            "elapsed=\(result.elapsedSeconds)s",
            "nsPerIteration=\(result.nanosecondsPerIteration)",
            "heapDelta=\(result.heapSizeInUseDelta)",
            "checksum=\(result.checksum)"
        ]
        if let runtimeActivity = result.runtimeActivity {
            summaryParts.append("changes=\(runtimeActivity.changes)")
            summaryParts.append("callbacks=\(runtimeActivity.callbackDeliveries)")
            summaryParts.append("waiterRegistrations=\(runtimeActivity.waiterRegistrations)")
            summaryParts.append("callbackPerChange=\(runtimeActivity.callbackDeliveriesPerChange)")
            summaryParts.append("runtimeEnqueues=\(runtimeActivity.runtimeTotalEnqueues)")
            summaryParts.append("runtimeEnqueuesPerChange=\(runtimeActivity.runtimeEnqueuesPerChange)")
            summaryParts.append("globalEnqueues=\(runtimeActivity.runtimeGlobalEnqueues)")
            summaryParts.append("mainExecutorEnqueues=\(runtimeActivity.runtimeMainExecutorEnqueues)")
        }
        let summary = summaryParts.joined(separator: " ")
        print(summary)
    }

    private static func parseArguments<S: Sequence>(
        _ arguments: S
    ) throws -> BenchmarkConfiguration where S.Element == String {
        var configuration = BenchmarkConfiguration()
        var iterator = arguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--case":
                guard let value = iterator.next() else {
                    throw BenchmarkError.invalidArgument("--case requires a value")
                }
                configuration.selectedCases = try parseCases(value)
            case "--iterations":
                configuration.iterations = try parsePositiveInt(
                    iterator.next(),
                    name: "--iterations"
                )
            case "--warmup":
                configuration.warmupIterations = try parseNonNegativeInt(
                    iterator.next(),
                    name: "--warmup"
                )
            case "--runs":
                configuration.runs = try parsePositiveInt(
                    iterator.next(),
                    name: "--runs"
                )
            case "--output":
                guard let value = iterator.next() else {
                    throw BenchmarkError.invalidArgument("--output requires a value")
                }
                configuration.outputPath = value
            case "--help", "-h":
                printUsageAndExit()
            default:
                throw BenchmarkError.invalidArgument("unknown argument: \(argument)")
            }
        }

        return configuration
    }

    private static func parseCases(_ rawValue: String) throws -> [BenchmarkCase] {
        if rawValue == "all" {
            return BenchmarkCase.allCases
        }

        let cases = try rawValue.split(separator: ",").map { rawCase in
            guard let benchmarkCase = BenchmarkCase(rawValue: String(rawCase)) else {
                throw BenchmarkError.invalidArgument("unknown benchmark case: \(rawCase)")
            }
            return benchmarkCase
        }

        guard !cases.isEmpty else {
            throw BenchmarkError.invalidArgument("--case requires at least one case")
        }
        return cases
    }

    private static func parsePositiveInt(
        _ rawValue: String?,
        name: String
    ) throws -> Int {
        let value = try parseNonNegativeInt(rawValue, name: name)
        guard value > 0 else {
            throw BenchmarkError.invalidArgument("\(name) must be greater than 0")
        }
        return value
    }

    private static func parseNonNegativeInt(
        _ rawValue: String?,
        name: String
    ) throws -> Int {
        guard let rawValue else {
            throw BenchmarkError.invalidArgument("\(name) requires a value")
        }
        guard let value = Int(rawValue), value >= 0 else {
            throw BenchmarkError.invalidArgument("\(name) must be a non-negative integer")
        }
        return value
    }

    private static func printUsageAndExit() -> Never {
        let cases = BenchmarkCase.allCases.map(\.rawValue).joined(separator: ", ")
        print(
            """
            Usage:
              ObservationBridgeBenchmarks [--case name|all|a,b] [--iterations n] [--warmup n] [--runs n] [--output path]

            Cases:
              \(cases)
            """
        )
        Foundation.exit(0)
    }
}

try await ObservationBridgeBenchmarks.main()
