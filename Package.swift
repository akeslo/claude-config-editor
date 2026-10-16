// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeConfig",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "ConfigCore"),
        .executableTarget(name: "ClaudeConfig", dependencies: ["ConfigCore"]),
        .testTarget(name: "ConfigCoreTests", dependencies: ["ConfigCore"]),
    ]
)
