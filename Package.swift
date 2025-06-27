// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "KratonSecureKit",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13)
    ],
    products: [
        .library(name: "KratonSecureKit", targets: ["KratonSecureKit"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "KratonSecureKit",
            dependencies: ["KratonSecureKitGo", "KratonSecureKitC"]
        ),
        .target(
            name: "KratonSecureKitC",
            dependencies: [],
            publicHeadersPath: "."
        ),
        .target(
            name: "KratonSecureKitGo",
            dependencies: [],
            exclude: [
                "goruntime-boottime-over-monotonic.diff",
                "go.mod",
                "go.sum",
                "api-apple.go",
                "Makefile"
            ],
            publicHeadersPath: ".",
            linkerSettings: [.linkedLibrary("wg-go")]
        )
    ]
)
