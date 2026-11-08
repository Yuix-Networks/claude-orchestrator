// swift-tools-version:6.0
import PackageDescription

// Swift 6 dil modu (strict concurrency) bu projede kapalı: kod tabanı
// senkron API'ler (Process, FileManager, NSStatusItem) kullanıyor ve
// gereksiz concurrency hataları araç akışını yavaşlatır.
let swiftV5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "claude-ctl",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClaudeCtlCore", targets: ["ClaudeCtlCore"]),
        .executable(name: "claude-ctl", targets: ["claude-ctl"])
    ],
    targets: [
        .target(name: "ClaudeCtlCore", swiftSettings: swiftV5),
        .executableTarget(name: "claude-ctl", dependencies: ["ClaudeCtlCore"], swiftSettings: swiftV5),
        .testTarget(name: "ClaudeCtlCoreTests", dependencies: ["ClaudeCtlCore"], swiftSettings: swiftV5)
    ]
)
