// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-logger-splunk",
    platforms: [
        // Aligned with `swift-logger-remote` minimums so the
        // `RemoteTransport` adapter can link against the engine.
        .iOS("13.4"),
        .tvOS("13.4"),
        .macOS("10.15.4"),
        .watchOS("6.2"),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "LoggerSplunk",
            targets: ["LoggerSplunk"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/swift-loggers/swift-logger-remote.git",
            .upToNextMinor(from: "0.1.0")
        ),
        .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "LoggerSplunk",
            dependencies: [
                .product(name: "LoggerRemote", package: "swift-logger-remote")
            ]
        ),
        .testTarget(
            name: "LoggerSplunkTests",
            dependencies: [
                "LoggerSplunk",
                .product(name: "LoggerRemote", package: "swift-logger-remote")
            ],
            exclude: ["CoverageMap.md"]
        )
    ]
)
