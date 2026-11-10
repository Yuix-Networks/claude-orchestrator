import Foundation

/// `claude-orchestrator` file system layout.
///
/// Every path is derived from a single `root`. Tests pass a temporary root;
/// in production the root is `~/Library/Application Support/claude-ctl`.
public struct Paths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Production root: `~/Library/Application Support/claude-ctl`.
    ///
    /// The tool was renamed to `claude-orchestrator`, but the data directory
    /// deliberately keeps the old name so instances created with v0.1.0 keep
    /// working without a migration.
    ///
    /// If `CLAUDE_ORCHESTRATOR_HOME` is set, it becomes the root (useful for
    /// trying things out without touching real instances).
    public static var `default`: Paths {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_ORCHESTRATOR_HOME"], !override.isEmpty {
            return Paths(root: URL(fileURLWithPath: override))
        }
        return Paths(root: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/claude-ctl"))
    }

    /// `config.json`, which holds the instance definitions.
    public var configFile: URL { root.appendingPathComponent("config.json") }

    /// Root of the instance directories.
    public var instancesRoot: URL { root.appendingPathComponent("instances") }

    /// Directory holding the agent's singleton pid file.
    public var stateDirectory: URL { root.appendingPathComponent("state") }

    /// Backups made by `session move`.
    public var backupsDir: URL { root.appendingPathComponent("backups") }

    /// Cache of session summaries (safe to delete).
    public var sessionCacheFile: URL { root.appendingPathComponent("cache/sessions.json") }

    public func instanceDir(_ name: String) -> URL {
        instancesRoot.appendingPathComponent(name)
    }

    /// Electron profile (`--user-data-dir`).
    public func profileDir(_ name: String) -> URL {
        instanceDir(name).appendingPathComponent("profile")
    }

    /// Claude Code config directory (`CLAUDE_CONFIG_DIR`).
    public func codeDir(_ name: String) -> URL {
        instanceDir(name).appendingPathComponent("claude-code")
    }

    /// Runtime state (pid, start time, version).
    public func stateFile(_ name: String) -> URL {
        instanceDir(name).appendingPathComponent("state.json")
    }
}
