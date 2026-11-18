import Darwin
import Foundation

/// Desktop notifications and the confirmation dialog for Claude updates.
///
/// A command-line tool can't receive notification clicks by itself (that needs an
/// app bundle), so clicks go through `terminal-notifier` when it is installed: a
/// click runs `claude-orchestrator update apply --dialog`. Without it, the
/// confirmation dialog is shown straight away; it is the notification.
public struct UpdateNotifier {
    /// Path of `claude-orchestrator` itself (what a click runs).
    public var executable: String
    public var terminalNotifier: String?
    public var appPath: String

    public init(
        executable: String = SelfExecutable.path,
        terminalNotifier: String? = UpdateNotifier.findTerminalNotifier(),
        appPath: String = ClaudeApp.defaultPath
    ) {
        self.executable = executable
        self.terminalNotifier = terminalNotifier
        self.appPath = appPath
    }

    public static func findTerminalNotifier() -> String? {
        ["/opt/homebrew/bin/terminal-notifier", "/usr/local/bin/terminal-notifier"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static let group = "claude-orchestrator-update"

    /// Text shared by the notification and the dialog.
    public static func summary(_ pending: PendingUpdate, instances: [String], closedByUpdate: [String]) -> String {
        var lines = ["Claude \(pending.stagedVersion) is ready (installed: \(pending.installedVersion))."]
        if !closedByUpdate.isEmpty {
            lines.append("Already closed itself to update: \(closedByUpdate.joined(separator: ", ")).")
        }
        if instances.isEmpty {
            lines.append("It installs once every Claude is closed.")
        } else {
            lines.append("All instances need a restart to install it: \(instances.joined(separator: ", ")).")
        }
        return lines.joined(separator: " ")
    }

    /// Tells the user an update is waiting. A click (or "Update Now") runs the controlled update.
    public func announce(_ pending: PendingUpdate, instances: [String], closedByUpdate: [String]) {
        let message = Self.summary(pending, instances: instances, closedByUpdate: closedByUpdate)
        if let terminalNotifier {
            run(terminalNotifier, [
                "-title", "Claude update: all instances must restart",
                "-subtitle", "\(pending.installedVersion) → \(pending.stagedVersion) · click to update",
                "-message", message,
                "-group", Self.group,
                "-sound", "default",
                "-execute", "\(shellQuote(executable)) update apply --dialog"
            ], wait: true)
        } else {
            Detached.spawn(executable, ["update", "apply", "--dialog"])
        }
    }

    /// An informational banner (no action on click).
    public func banner(title: String, message: String) {
        if let terminalNotifier {
            run(terminalNotifier, ["-title", title, "-message", message, "-group", Self.group], wait: true)
        } else {
            run("/usr/bin/osascript", [
                "-e", "on run argv",
                "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
                "-e", "end run",
                title, message
            ], wait: true)
        }
    }

    public enum Answer: Equatable {
        case update
        case later
    }

    /// Blocking "Update Now / Later" dialog. Closing it or letting it time out means later.
    public func confirm(_ pending: PendingUpdate, instances: [String], closedByUpdate: [String]) -> Answer {
        let message = Self.summary(pending, instances: instances, closedByUpdate: closedByUpdate)
            + "\n\nclaude-orchestrator will close them, install the update and open each instance again with its own profile. "
            + "Work in progress in Claude Code sessions is interrupted."
        let icon = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Resources/electron.icns").path
        let output = run("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "set iconFile to POSIX file (item 3 of argv)",
            "-e", "try",
            "-e", "set r to display dialog (item 2 of argv) with title (item 1 of argv) buttons {\"Later\", \"Update Now\"} "
                + "default button \"Update Now\" cancel button \"Later\" with icon iconFile giving up after 1800",
            "-e", "on error",
            "-e", "return \"Later\"",
            "-e", "end try",
            "-e", "if gave up of r then return \"Later\"",
            "-e", "return button returned of r",
            "-e", "end run",
            "Claude update", message, icon
        ], wait: true)
        return output?.trimmingCharacters(in: .whitespacesAndNewlines) == "Update Now" ? .update : .later
    }

    @discardableResult
    private func run(_ path: String, _ arguments: [String], wait: Bool) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        guard wait else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Starts a process in its own session, so it outlives whoever started it — in
/// particular a Claude instance that the update is about to close.
public enum Detached {
    @discardableResult
    public static func spawn(_ executable: String, _ arguments: [String], log: URL? = nil) -> Int32? {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        let output = log?.path ?? "/dev/null"
        if let log {
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        posix_spawn_file_actions_addopen(&actions, 1, output, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        return status == 0 ? pid : nil
    }
}

/// Path of the running `claude-orchestrator`, as it was invoked (a Homebrew
/// symlink stays a symlink, so it survives `brew upgrade`).
public enum SelfExecutable {
    public static var path: String {
        let invoked = CommandLine.arguments.first ?? ""
        if invoked.contains("/") {
            return URL(fileURLWithPath: invoked).standardizedFileURL.path
        }
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for directory in directories {
            let candidate = "\(directory)/\(invoked)"
            if !invoked.isEmpty, FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return Bundle.main.executablePath ?? "/opt/homebrew/bin/claude-orchestrator"
    }

    /// Is this process running inside a Claude instance (for example a Claude Code terminal)?
    /// Closing that instance would take this process with it.
    public static func runsInsideClaude(table: ProcessTable = PsProcessTable(), appPath: String = ClaudeApp.defaultPath) -> Bool {
        let entries = table.entries()
        let byPid = Dictionary(entries.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let scanner = ClaudeProcessScanner(appPath: appPath)
        var pid = getppid()
        var steps = 0
        while pid > 1, steps < 64, let entry = byPid[pid] {
            if scanner.isMain(entry) || scanner.isHelper(entry) { return true }
            pid = entry.ppid
            steps += 1
        }
        return false
    }
}
