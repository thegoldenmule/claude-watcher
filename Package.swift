// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClaudeWatcher",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ClaudeWatcher", targets: ["ClaudeWatcher"]),
        .library(name: "ClaudeWatcherCore", targets: ["ClaudeWatcherCore"]),
    ],
    targets: [
        .target(
            name: "ClaudeWatcherCore",
            path: "Sources/ClaudeWatcherCore"
        ),
        .executableTarget(
            name: "ClaudeWatcher",
            dependencies: ["ClaudeWatcherCore"],
            path: "Sources/ClaudeWatcher"
        ),
        .testTarget(
            name: "ClaudeWatcherCoreTests",
            dependencies: ["ClaudeWatcherCore"],
            path: "Tests/ClaudeWatcherCoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
