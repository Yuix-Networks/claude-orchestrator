import AppKit
import ClaudeCtlCore

/// AppKit'e bağlı yardımcılar (yalnızca agent modunda kullanılır).
public enum AppKitSupport {
    /// Bir süreci öne getirir (pencereleri de öne alır).
    public static func activateProcess(pid: Int32) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }

    /// Kullanıcıya bilgi penceresi gösterir.
    public static func presentMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Tamam")
        alert.runModal()
    }

    /// Claude ikonunu menü çubuğu için yükler.
    public static func claudeIcon() -> NSImage? {
        let path = URL(fileURLWithPath: ClaudeApp.defaultPath)
            .appendingPathComponent("Contents/Resources/electron.icns")
        guard let image = NSImage(contentsOf: path) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}
