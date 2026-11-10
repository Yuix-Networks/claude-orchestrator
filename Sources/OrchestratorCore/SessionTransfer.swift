import Foundation

/// Result of a session transfer.
public struct TransferResult: Equatable {
    public var session: SessionSummary
    /// Files written to the target.
    public var copiedFiles: [URL]
    /// Desktop metadata file written to the target profile (`nil` if it couldn't be written).
    public var desktopMetadata: URL?
    /// Backup directory the source files were moved to during `move`.
    public var backup: URL?
    public var warnings: [String]
}

/// Copies or moves sessions between two config directories (instances).
///
/// Rules:
/// - Refused if the target already has a session with the same id (`force` overwrites it).
/// - Refused if the target project directory belongs to a different real path (slug clash).
/// - Each file is first copied under a temporary name in the target directory,
///   then put in place with `rename`, so no half-written transcript is left behind.
/// - `move` never deletes the source files; it moves them under `backupsDir` (reversible).
public struct SessionTransfer {
    public let source: SessionStore
    public let target: SessionStore
    /// Root of the `move` backups.
    public let backupsDir: URL
    /// Installed Claude Code CLI version of the target instance (`nil` if unknown).
    public let targetCLIVersion: String?

    /// Desktop metadata fields tied to the account or environment: they become
    /// invalid under another account, so they are not copied.
    static let accountBoundMetadataKeys: Set<String> = [
        "remoteMcpServersConfig", "envScopeId", "startedFromEnvironmentId",
        "toolSurfaceSnapshot", "promptAppendSnapshot", "spawnSeed",
        "cliMcpAppServerNames", "remoteControlAutoEligible", "steeredByRemoteClient",
        "sessionPermissionUpdates", "alwaysAllowedReasons"
    ]

    public init(source: SessionStore, target: SessionStore, backupsDir: URL, targetCLIVersion: String? = nil) {
        self.source = source
        self.target = target
        self.backupsDir = backupsDir
        self.targetCLIVersion = targetCLIVersion
    }

    // MARK: - Pre-checks

    /// Problems that block the transfer (empty means it can go ahead).
    public func blockers(for session: SessionSummary, force: Bool) -> [String] {
        var problems: [String] = []
        if source.codeDir.standardizedFileURL == target.codeDir.standardizedFileURL {
            problems.append("source and target are the same instance")
            return problems
        }
        let targetTranscript = targetProjectDir(session).appendingPathComponent("\(session.id).jsonl")
        if !force, FileManager.default.fileExists(atPath: targetTranscript.path) {
            problems.append("the target already has a session with id \(session.id) (use --force to overwrite)")
        }
        if !force, let cwd = session.cwd, let original = originalPath(of: targetProjectDir(session)), original != cwd {
            problems.append(
                "project directory clash: in the target, '\(session.projectSlug)' belongs to '\(original)', "
                + "but the session is in '\(cwd)' (use --force to override)"
            )
        }
        return problems
    }

    /// Warnings that don't block the transfer but should be shown to the user.
    public func warnings(for session: SessionSummary) -> [String] {
        var notes: [String] = []
        if let sessionVersion = session.cliVersion, let targetCLIVersion,
           Self.compareVersions(sessionVersion, targetCLIVersion) == .orderedDescending {
            notes.append(
                "the session was written by Claude Code \(sessionVersion), but the target CLI is \(targetCLIVersion) — "
                + "the transcript format may differ"
            )
        }
        return notes
    }

    // MARK: - Transfer

    /// Copies the session; with `move`, the source is moved to a backup.
    @discardableResult
    public func transfer(_ session: SessionSummary, move: Bool, force: Bool) throws -> TransferResult {
        let problems = blockers(for: session, force: force)
        guard problems.isEmpty else {
            throw OrchestratorError.runtime(problems.joined(separator: "; "))
        }

        let fm = FileManager.default
        let targetDir = targetProjectDir(session)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        var copied: [URL] = []
        // The transcript is written last, so an interrupted transfer doesn't
        // leave a visible (half-copied) session in the target.
        let sidecar = session.transcript.deletingPathExtension()
        if fm.fileExists(atPath: sidecar.path) {
            copied.append(try atomicCopy(sidecar, to: targetDir.appendingPathComponent(sidecar.lastPathComponent)))
        }
        for todo in source.todoFiles(for: session.id) {
            try fm.createDirectory(at: target.todosDir, withIntermediateDirectories: true)
            copied.append(try atomicCopy(todo, to: target.todosDir.appendingPathComponent(todo.lastPathComponent)))
        }
        copied.append(try atomicCopy(session.transcript, to: targetDir.appendingPathComponent("\(session.id).jsonl")))

        try mergeIndexEntry(for: session, into: targetDir)

        var notes = warnings(for: session)
        let metadata = try copyDesktopMetadata(for: session, force: force, warnings: &notes)

        // Verify: can the target config directory see the session?
        guard (try? target.find(session.id)) != nil else {
            throw OrchestratorError.runtime("couldn't verify the transfer: the session doesn't show up in the target (\(session.id))")
        }

        var backup: URL?
        if move {
            backup = try moveSourceToBackup(session)
        }

        return TransferResult(
            session: session,
            copiedFiles: copied,
            desktopMetadata: metadata,
            backup: backup,
            warnings: notes
        )
    }

    // MARK: - Helpers

    func targetProjectDir(_ session: SessionSummary) -> URL {
        target.projectsDir.appendingPathComponent(session.projectSlug)
    }

    /// `sessions-index.json` → `originalPath` (`nil` if missing).
    func originalPath(of projectDir: URL) -> String? {
        let url = projectDir.appendingPathComponent("sessions-index.json")
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object["originalPath"] as? String
    }

    /// Copies a file or directory under a temporary name, then puts it in place with `rename`.
    @discardableResult
    func atomicCopy(_ from: URL, to destination: URL) throws -> URL {
        let fm = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: from, to: temporary)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fm.removeItem(at: temporary)
            throw OrchestratorError.runtime(
                "couldn't copy \(from.path) → \(destination.path) — \(error.localizedDescription)"
            )
        }
        return destination
    }

    /// Adds the entry from the source index to the target index (replacing one with the same id).
    ///
    /// The source config path inside the entry is rewritten to the target config
    /// path (fields like `fullPath` hold absolute paths).
    func mergeIndexEntry(for session: SessionSummary, into targetDir: URL) throws {
        let sourceIndex = session.transcript.deletingLastPathComponent().appendingPathComponent("sessions-index.json")
        let targetIndex = targetDir.appendingPathComponent("sessions-index.json")

        let sourceObject = readObject(sourceIndex)
        let sourceEntries = sourceObject?["entries"] as? [[String: Any]] ?? []
        guard let entry = sourceEntries.first(where: { $0["sessionId"] as? String == session.id }) else {
            return // No entry in the source: Claude Code also finds transcripts from the directory.
        }

        var targetObject = readObject(targetIndex) ?? [
            "version": sourceObject?["version"] ?? 1,
            "originalPath": session.cwd ?? sourceObject?["originalPath"] ?? NSNull()
        ]
        var entries = (targetObject["entries"] as? [[String: Any]] ?? [])
            .filter { $0["sessionId"] as? String != session.id }
        entries.append(rewritePaths(entry) as? [String: Any] ?? entry)
        targetObject["entries"] = entries

        let data = try JSONSerialization.data(withJSONObject: targetObject, options: [.prettyPrinted, .sortedKeys])
        try writeAtomically(data, to: targetIndex)
    }

    private func rewritePaths(_ value: Any) -> Any {
        let from = source.codeDir.standardizedFileURL.path
        let to = target.codeDir.standardizedFileURL.path
        switch value {
        case let string as String:
            return string.hasPrefix(from + "/") ? to + string.dropFirst(from.count) : string
        case let dictionary as [String: Any]:
            return dictionary.mapValues { rewritePaths($0) }
        case let array as [Any]:
            return array.map { rewritePaths($0) }
        default:
            return value
        }
    }

    /// Copies the metadata so the session shows up in the Desktop Code tab sidebar.
    ///
    /// Account-bound fields are dropped and a new `local_<uuid>` id is assigned.
    /// Nothing is written if the active account/org of the target profile can't be determined (a warning is added instead).
    func copyDesktopMetadata(for session: SessionSummary, force: Bool, warnings: inout [String]) throws -> URL? {
        guard let sourceFile = source.desktopMetadataFiles()[session.id],
              var object = readObject(sourceFile)
        else { return nil }

        let resumeHint = "It may not show up in the Claude Desktop sidebar; to open it from the terminal: "
            + "CLAUDE_CONFIG_DIR=\"\(target.codeDir.path)\" claude --resume \(session.id)"
        guard let directory = target.desktopMetadataDirectory() else {
            warnings.append("couldn't determine the active account/org in the target profile (it may not be signed in) — " + resumeHint)
            return nil
        }

        if let existing = target.desktopMetadataFiles()[session.id] {
            guard force else { return existing }
            try? FileManager.default.removeItem(at: existing)
        }

        let localID = "local_\(UUID().uuidString.lowercased())"
        for key in Self.accountBoundMetadataKeys { object.removeValue(forKey: key) }
        object["sessionId"] = localID
        object["cliSessionId"] = session.id

        let destination = directory.appendingPathComponent("\(localID).json")
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try writeAtomically(data, to: destination)
        return destination
    }

    /// `move`: moves the source files to the backup directory and removes the index entry.
    func moveSourceToBackup(_ session: SessionSummary) throws -> URL {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let backup = backupsDir.appendingPathComponent("\(stamp)-\(session.id)")
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)

        var items = source.files(for: session)
        if let metadata = source.desktopMetadataFiles()[session.id] { items.append(metadata) }
        for item in items {
            try fm.moveItem(at: item, to: backup.appendingPathComponent(item.lastPathComponent))
        }

        // The source index is copied to the backup, then the entry is removed from it.
        let index = session.transcript.deletingLastPathComponent().appendingPathComponent("sessions-index.json")
        if var object = readObject(index), let entries = object["entries"] as? [[String: Any]] {
            let kept = entries.filter { $0["sessionId"] as? String != session.id }
            if kept.count != entries.count {
                try fm.copyItem(at: index, to: backup.appendingPathComponent("sessions-index.json"))
                object["entries"] = kept
                let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                try writeAtomically(data, to: index)
            }
        }

        // Record where it came from, for restoring.
        let manifest: [String: Any] = [
            "sessionId": session.id,
            "sourceConfigDir": source.codeDir.path,
            "targetConfigDir": target.codeDir.path,
            "projectSlug": session.projectSlug,
            "movedAt": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: backup.appendingPathComponent("manifest.json"))
        return backup
    }

    private func readObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw OrchestratorError.runtime("couldn't write \(url.path) — \(error.localizedDescription)")
        }
    }

    /// Dotted version comparison (`2.1.29` < `2.1.308`).
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }
}
