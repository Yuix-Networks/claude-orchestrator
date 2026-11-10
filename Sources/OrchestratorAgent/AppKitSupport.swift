import AppKit
import OrchestratorCore

/// AppKit-dependent helpers (used only in agent mode).
public enum AppKitSupport {
    /// Brings a process to the front, along with its windows.
    public static func activateProcess(pid: Int32) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }

    /// Shows the user an informational alert.
    public static func presentMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Loads the Claude icon for the menu bar.
    public static func claudeIcon() -> NSImage? {
        let path = URL(fileURLWithPath: ClaudeApp.defaultPath)
            .appendingPathComponent("Contents/Resources/electron.icns")
        guard let image = NSImage(contentsOf: path) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}
