import Foundation

/// Login item (LaunchAgent) kurulumu ve kaldırılması.
public struct LaunchAgentInstaller {
    public static let defaultLabel = "com.claude-ctl.agent"

    public let label: String

    public init(label: String = LaunchAgentInstaller.defaultLabel) {
        self.label = label
    }

    public var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// LaunchAgent plist'ini yazar ve yükler.
    @discardableResult
    public func install(executablePath: String) throws -> URL {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath, "agent"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null"
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: plistURL, options: .atomic)

        // launchd'ye bildir (başarısız olursa plist yine de yazılmış olur).
        let domain = "gui/\(getuid())"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", domain, plistURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        return plistURL
    }

    /// LaunchAgent'ı kaldırır.
    public func uninstall() throws {
        let domain = "gui/\(getuid())"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "\(domain)/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }
}
