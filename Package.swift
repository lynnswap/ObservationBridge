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
        .library(
            name: "ObservationsCompat",
            targets: ["ObservationsCompat"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "ObservationBridgeLegacy",
            path: "ObservationBridge/Sources/ObservationBridgeLegacy",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        ),
        .target(
            name: "ObservationBridge",
            dependencies: [
                "ObservationBridgeLegacy",
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
            name: "ObservationsCompat",
            dependencies: ["ObservationBridge"],
            path: "ObservationBridge/Sources/ObservationsCompat",
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
