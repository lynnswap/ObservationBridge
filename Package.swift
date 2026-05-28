// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ObservationBridge",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
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
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "_ObservationBridgeLegacy",
            dependencies: ["_ObservationBridgePrivateABI"],
            path: "ObservationBridge/Sources/_ObservationBridgeLegacy",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        ),
        .target(
            name: "_ObservationBridgePrivateABI",
            path: "ObservationBridge/Sources/_ObservationBridgePrivateABI"
        ),
        .target(
            name: "ObservationBridge",
            dependencies: [
                .target(
                    name: "_ObservationBridgeBenchmarkSupport",
                    condition: .when(traits: ["BenchmarkSupport"])
                ),
                "_ObservationBridgePrivateABI",
                "_ObservationBridgeLegacy",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms")
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
                "_ObservationBridgeBenchmarkSupport",
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
