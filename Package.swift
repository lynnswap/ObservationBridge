// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "ObservationBridge",
    platforms: [
        .iOS(.v18),
        .macCatalyst(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2)
    ],
    products: [
        .library(
            name: "ObservationBridge",
            targets: ["ObservationBridge"]
        ),
        .executable(
            name: "ObservationBridgeBenchmarks",
            targets: ["ObservationBridgeBenchmarks"]
        )
    ],
    traits: [
        .trait(
            name: "BenchmarkSupport",
            description: "Compile benchmark-only instrumentation hooks into ObservationBridge."
        )
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "_ObservationBridgeRuntimeABI",
            path: "ObservationBridge/Sources/_ObservationBridgeRuntimeABI"
        ),
        .target(
            name: "ObservationBridge",
            dependencies: [
                .target(
                    name: "_ObservationBridgeBenchmarkSupport",
                    condition: .when(traits: ["BenchmarkSupport"])
                ),
                "_ObservationBridgeRuntimeABI",
            ],
            path: "ObservationBridge/Sources/ObservationBridge",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        ),
        .target(
            name: "_ObservationBridgeBenchmarkSupport",
            path: "ObservationBridge/Sources/_ObservationBridgeBenchmarkSupport",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "ObservationBridgeBenchmarks",
            dependencies: [
                "ObservationBridge",
                .target(
                    name: "_ObservationBridgeBenchmarkSupport",
                    condition: .when(traits: ["BenchmarkSupport"])
                ),
            ],
            path: "Benchmarks/ObservationBridgeBenchmarks",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        ),
        .testTarget(
            name: "ObservationBridgeTests",
            dependencies: ["ObservationBridge"],
            path: "ObservationBridge/Tests/ObservationBridgeTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        )
    ]
)
