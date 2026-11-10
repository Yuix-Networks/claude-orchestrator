import Foundation

/// State of the shared CLAUDE.md link in an instance.
public enum MemoryLinkState: String, Equatable {
    /// The link was created by this operation.
    case linked
    /// The link already points to the shared file.
    case alreadyLinked
    /// The instance has its own CLAUDE.md; left alone (`force` backs it up and links).
    case ownFile
    /// No link (status query).
    case missing
    /// The link was removed.
    case unlinked
}

/// Per-instance result of a shared CLAUDE.md operation.
public struct MemoryLinkResult: Equatable {
    public var instance: String
    public var state: MemoryLinkState
    /// The old file set aside by `force`.
    public var backup: URL?
}

/// Shared CLAUDE.md.
///
/// Each instance has its own `CLAUDE_CONFIG_DIR`, so Claude Code doesn't read the
/// default install's `~/.claude/CLAUDE.md` in instances. This extension puts a symlink
/// to that file in each instance's config directory: the rules are edited in one place
/// and are the same in every instance.
extension Orchestrator {
    /// The shared file: the default install's CLAUDE.md.
    public var sharedMemoryFile: URL { defaultCodeDir.appendingPathComponent("CLAUDE.md") }

    func memoryFile(_ instance: String) -> URL {
        paths.codeDir(instance).appendingPathComponent("CLAUDE.md")
    }

    /// Links the shared CLAUDE.md into instances.
    ///
    /// - Parameters:
    ///   - instance: Only this instance (`nil` → all of them).
    ///   - force: If the instance has its own CLAUDE.md, move it aside as
    ///     `CLAUDE.md.bak-<time>` and link.
    @discardableResult
    public func linkSharedMemory(instance: String? = nil, force: Bool = false) throws -> [MemoryLinkResult] {
        guard FileManager.default.fileExists(atPath: sharedMemoryFile.path) else {
            throw OrchestratorError.runtime("shared file missing: \(sharedMemoryFile.path) — create it first")
        }
        return try memoryTargets(instance).map { name in
            let fm = FileManager.default
            let target = memoryFile(name)
            switch memoryState(name) {
            case .alreadyLinked:
                return MemoryLinkResult(instance: name, state: .alreadyLinked, backup: nil)
            case .ownFile where !force:
                return MemoryLinkResult(instance: name, state: .ownFile, backup: nil)
            case .ownFile:
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
                let backup = target.deletingLastPathComponent().appendingPathComponent("CLAUDE.md.bak-\(stamp)")
                try fm.moveItem(at: target, to: backup)
                try fm.createSymbolicLink(at: target, withDestinationURL: sharedMemoryFile)
                return MemoryLinkResult(instance: name, state: .linked, backup: backup)
            default:
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Replace a link that points elsewhere or is broken.
                if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
                    try fm.removeItem(at: target)
                }
                try fm.createSymbolicLink(at: target, withDestinationURL: sharedMemoryFile)
                return MemoryLinkResult(instance: name, state: .linked, backup: nil)
            }
        }
    }

    /// Removes the shared CLAUDE.md links (leaves the instance's own files alone).
    @discardableResult
    public func unlinkSharedMemory(instance: String? = nil) throws -> [MemoryLinkResult] {
        try memoryTargets(instance).map { name in
            guard memoryState(name) == .alreadyLinked else {
                return MemoryLinkResult(instance: name, state: memoryState(name), backup: nil)
            }
            try FileManager.default.removeItem(at: memoryFile(name))
            return MemoryLinkResult(instance: name, state: .unlinked, backup: nil)
        }
    }

    /// Link state of each instance.
    public func sharedMemoryStatus() throws -> [MemoryLinkResult] {
        try memoryTargets(nil).map { MemoryLinkResult(instance: $0, state: memoryState($0), backup: nil) }
    }

    func memoryState(_ instance: String) -> MemoryLinkState {
        let target = memoryFile(instance)
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) {
            let resolved = URL(fileURLWithPath: destination, relativeTo: target.deletingLastPathComponent())
                .standardizedFileURL.path
            return resolved == sharedMemoryFile.standardizedFileURL.path ? .alreadyLinked : .missing
        }
        return FileManager.default.fileExists(atPath: target.path) ? .ownFile : .missing
    }

    private func memoryTargets(_ instance: String?) throws -> [String] {
        if let instance {
            _ = try store.instance(named: instance)
            return [instance]
        }
        return try store.load().instances.keys.sorted()
    }

    /// For `new`/`start`: link if there's no link and the shared file exists; never overwrite.
    func ensureSharedMemory(_ instance: String) {
        guard FileManager.default.fileExists(atPath: sharedMemoryFile.path),
              memoryState(instance) == .missing
        else { return }
        _ = try? linkSharedMemory(instance: instance)
    }
}
