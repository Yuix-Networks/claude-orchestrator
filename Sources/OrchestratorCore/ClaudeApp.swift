import Foundation

/// Kurulu Claude Desktop uygulaması hakkında salt-okunur bilgi.
///
/// Global kural: bu modül uygulama bundle'ine asla yazmaz; yalnızca okur.
public enum ClaudeApp {
    public static let defaultPath = "/Applications/Claude.app"

    /// Kurulu uygulamanın `CFBundleShortVersionString` değeri (okunamazsa `nil`).
    public static func version(appPath: String = defaultPath) -> String? {
        let infoPlist = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String
        else { return nil }
        return version
    }

    /// Uygulama kurulu mu?
    public static func isInstalled(appPath: String = defaultPath) -> Bool {
        FileManager.default.fileExists(atPath: appPath)
    }
}
