import Foundation

/// Read-only information about the installed Claude Desktop app.
///
/// Global rule: this module never writes to the app bundle; it only reads it.
public enum ClaudeApp {
    public static let defaultPath = "/Applications/Claude.app"

    /// The installed app's `CFBundleShortVersionString` (`nil` if it can't be read).
    public static func version(appPath: String = defaultPath) -> String? {
        let infoPlist = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String
        else { return nil }
        return version
    }

    /// Is the app installed?
    public static func isInstalled(appPath: String = defaultPath) -> Bool {
        FileManager.default.fileExists(atPath: appPath)
    }
}
