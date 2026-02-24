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
            name: "ObservationsCompat",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        ),
        .testTarget(
            name: "ObservationsCompatTests",
            dependencies: ["ObservationsCompat"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        )
    ]
)
