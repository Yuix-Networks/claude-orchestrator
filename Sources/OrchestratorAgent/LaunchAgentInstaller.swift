import OrchestratorCore
import Foundation

/// Installs and removes the login item (LaunchAgent).
public struct LaunchAgentInstaller {
    /// Keeps the old name on purpose: a login item installed by v0.1.0 is
    /// replaced under the same label on reinstall, so two agents never run at once.
    public static let defaultLabel = "com.claude-ctl.agent"

    public let label: String

    public init(label: String = LaunchAgentInstaller.defaultLabel) {
        self.label = label
    }

    public var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Writes and loads the LaunchAgent plist.
    @discardableResult
    public func install(executablePath: String) throws -> URL {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath, "agent"],
            "RunAtLoad": true,
            // Restart only on an unexpected exit: a second copy reports "already
            // running" and exits with 0; `KeepAlive: true` would turn that into an
            // endless restart loop.
            "KeepAlive": ["SuccessfulExit": false],
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

        // Unload a previous install first; otherwise bootstrap fails with
        // "already loaded" (5: Input/output error).
        let domain = "gui/\(getuid())"
        _ = launchctl(["bootout", "\(domain)/\(label)"])

        let result = launchctl(["bootstrap", domain, plistURL.path])
        guard result.status == 0 else {
            let detail = result.output.isEmpty ? "exit code \(result.status)" : result.output
            throw OrchestratorError.runtime(
                "Couldn't load the LaunchAgent (plist written to \(plistURL.path)) — launchctl bootstrap: \(detail)"
            )
        }
        return plistURL
    }

    /// Runs launchctl and returns its exit code and combined output.
    private func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }

    /// Removes the LaunchAgent.
    public func uninstall() throws {
        // bootout fails if it isn't loaded; that's fine when uninstalling.
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])

        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }
}
