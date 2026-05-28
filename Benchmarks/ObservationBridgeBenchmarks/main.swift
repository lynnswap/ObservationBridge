import Darwin
import Foundation
import Observation
import ObservationBridge

@Observable
final class BenchmarkCounterModel: @unchecked Sendable {
    var value = 0
}

@Observable
final class BenchmarkPayloadModel: @unchecked Sendable {
    var payload = BenchmarkPayload(value: 0)
}

final class BenchmarkPayload {
    let value: Int

    init(value: Int) {
        self.value = value
    }
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

enum BenchmarkCase: String, CaseIterable {
    case scopeSetupTeardown
    case scopeReplaceSameCallsite
    case streamConstructAndFirstValue
    case nonSendableStreamConstructAndFirstValue
}

struct BenchmarkConfiguration {
    var selectedCases: [BenchmarkCase] = [.scopeSetupTeardown]
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
    let date: String
}

enum BenchmarkError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case streamEnded(String)

    var description: String {
        switch self {
        case .invalidArgument(let message):
            message
        case .streamEnded(let message):
            message
        }
    }
}

@main
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
            let checksum = try await execute(
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
                checksum: checksum,
                heapBefore: heapBefore,
                heapAfter: heapAfter,
                heapSizeInUseDelta: heapAfter.sizeInUse - heapBefore.sizeInUse,
                date: ISO8601DateFormatter().string(from: Date())
            )
            try emit(result, outputHandle: outputHandle)
        }
    }

    private static func execute(
        _ benchmarkCase: BenchmarkCase,
        iterations: Int
    ) async throws -> Int {
        switch benchmarkCase {
        case .scopeSetupTeardown:
            return runScopeSetupTeardown(iterations: iterations)
        case .scopeReplaceSameCallsite:
            return runScopeReplaceSameCallsite(iterations: iterations)
        case .streamConstructAndFirstValue:
            return try await runStreamConstructAndFirstValue(iterations: iterations)
        case .nonSendableStreamConstructAndFirstValue:
            return try await runNonSendableStreamConstructAndFirstValue(iterations: iterations)
        }
    }

    @inline(never)
    private static func runScopeSetupTeardown(iterations: Int) -> Int {
        let sink = BenchmarkSink()

        for index in 0..<iterations {
            let model = BenchmarkCounterModel()
            model.value = index
            let observations = ObservationScope()
            observations.observe(model, options: []) { _, model in
                sink.record(model.value)
            }
            observations.cancelAll()
        }

        return sink.value
    }

    @inline(never)
    private static func runScopeReplaceSameCallsite(iterations: Int) -> Int {
        let model = BenchmarkCounterModel()
        let observations = ObservationScope()
        let sink = BenchmarkSink()
        defer {
            observations.cancelAll()
        }

        for index in 0..<iterations {
            model.value = index
            installReplacingObservation(
                model: model,
                observations: observations,
                sink: sink
            )
        }

        return sink.value
    }

    @inline(never)
    private static func installReplacingObservation(
        model: BenchmarkCounterModel,
        observations: ObservationScope,
        sink: BenchmarkSink
    ) {
        observations.observe(model) { _, model in
            sink.record(model.value)
        }
    }

    @inline(never)
    private static func runStreamConstructAndFirstValue(iterations: Int) async throws -> Int {
        let sink = BenchmarkSink()

        for index in 0..<iterations {
            let model = BenchmarkCounterModel()
            model.value = index
            let stream = makeObservationBridgeStream {
                model.value
            }
            var iterator = stream.makeAsyncIterator()
            guard let value = await iterator.next() else {
                throw BenchmarkError.streamEnded("stream ended before initial value")
            }
            sink.record(value)
        }

        return sink.value
    }

    @inline(never)
    private static func runNonSendableStreamConstructAndFirstValue(iterations: Int) async throws -> Int {
        let sink = BenchmarkSink()

        for index in 0..<iterations {
            let model = BenchmarkPayloadModel()
            model.payload = BenchmarkPayload(value: index)
            let stream = makeObservationBridgeStream {
                model.payload
            }
            var iterator = stream.makeAsyncIterator()
            guard let payload = await iterator.next() else {
                throw BenchmarkError.streamEnded("non-Sendable stream ended before initial value")
            }
            sink.record(payload.value)
        }

        return sink.value
    }

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

        let summary = [
            result.caseName,
            "run=\(result.runIndex)",
            "iterations=\(result.iterations)",
            "elapsed=\(result.elapsedSeconds)s",
            "nsPerIteration=\(result.nanosecondsPerIteration)",
            "heapDelta=\(result.heapSizeInUseDelta)",
            "checksum=\(result.checksum)"
        ].joined(separator: " ")
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
