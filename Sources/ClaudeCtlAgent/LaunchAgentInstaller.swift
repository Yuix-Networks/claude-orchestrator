import ClaudeCtlCore
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
            // Yalnızca beklenmedik çıkışta yeniden başlat: ikinci örnek "zaten
            // çalışıyor" deyip 0 ile çıkar; `KeepAlive: true` bunu sonsuz
            // yeniden başlatma döngüsüne çevirirdi.
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

        // Önceki kurulum yüklüyse önce boşalt; aksi halde bootstrap
        // "already loaded" (5: Input/output error) ile başarısız olur.
        let domain = "gui/\(getuid())"
        _ = launchctl(["bootout", "\(domain)/\(label)"])

        let result = launchctl(["bootstrap", domain, plistURL.path])
        guard result.status == 0 else {
            let detail = result.output.isEmpty ? "çıkış kodu \(result.status)" : result.output
            throw ClaudeCtlError.runtime(
                "LaunchAgent yüklenemedi (plist yazıldı: \(plistURL.path)) — launchctl bootstrap: \(detail)"
            )
        }
        return plistURL
    }

    /// launchctl'ı çalıştırır; çıkış kodu ve birleşik çıktıyı döner.
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

    /// LaunchAgent'ı kaldırır.
    public func uninstall() throws {
        // Yüklü değilse bootout başarısız olur; kaldırma için sorun değil.
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])

        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }
}
