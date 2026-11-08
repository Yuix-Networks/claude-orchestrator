// swift-tools-version:6.0
import PackageDescription

// Swift 6 dil modu (strict concurrency) bu projede kapalı: kod tabanı
// senkron API'ler (Process, FileManager, NSStatusItem) kullanıyor ve
// gereksiz concurrency hataları araç akışını yavaşlatır.
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
