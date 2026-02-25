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
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        ),
        .target(
            name: "ObservationsCompat",
            dependencies: ["ObservationsCompatLegacy"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
                .treatAllWarnings(as: .error),
            ]
        ),
        .testTarget(
            name: "ObservationsCompatTests",
            dependencies: ["ObservationsCompat"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
                .treatAllWarnings(as: .error),
            ]
        )
    ]
)
