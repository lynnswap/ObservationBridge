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
            dependencies: ["ObservationsCompatLegacy"],
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
