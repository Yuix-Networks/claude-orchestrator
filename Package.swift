// swift-tools-version:6.0
import PackageDescription

// Swift 6 language mode (strict concurrency) is off for this project: the
// codebase uses synchronous APIs (Process, FileManager, NSStatusItem), and
// needless concurrency errors would only slow down the tooling.
let swiftV5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "claude-orchestrator",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OrchestratorCore", targets: ["OrchestratorCore"]),
        .executable(name: "claude-orchestrator", targets: ["claude-orchestrator"])
    ],
    targets: [
        .target(name: "OrchestratorCore", swiftSettings: swiftV5),
        .target(name: "OrchestratorAgent", dependencies: ["OrchestratorCore"], swiftSettings: swiftV5),
        .executableTarget(name: "claude-orchestrator", dependencies: ["OrchestratorCore", "OrchestratorAgent"], swiftSettings: swiftV5),
        .testTarget(name: "OrchestratorCoreTests", dependencies: ["OrchestratorCore"], swiftSettings: swiftV5),
        .testTarget(name: "OrchestratorAgentTests", dependencies: ["OrchestratorAgent", "OrchestratorCore"], swiftSettings: swiftV5)
    ]
)
