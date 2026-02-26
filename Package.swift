// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ObservationsCompat",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
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
            name: "ObservationsCompatLegacy",
            path: "ObservationsCompat/Sources/ObservationsCompatLegacy",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        ),
        .target(
            name: "ObservationsCompat",
            dependencies: [
                "ObservationsCompatLegacy",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms")
            ],
            path: "ObservationsCompat/Sources/ObservationsCompat",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        ),
        .testTarget(
            name: "ObservationsCompatTests",
            dependencies: ["ObservationsCompat"],
            path: "ObservationsCompat/Tests/ObservationsCompatTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        )
    ]
)
