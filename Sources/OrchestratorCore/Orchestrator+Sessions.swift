import Foundation

/// Where sessions live: an instance or the default Claude install.
public struct SessionEndpoint: Equatable {
    /// Name for the default Claude Desktop install (the one not managed by claude-orchestrator).
    ///
    /// If an instance with this name exists, the instance wins; new instances
    /// can't use this name.
    public static let defaultName = "default"

    public var name: String
    /// `CLAUDE_CONFIG_DIR`.
    public var codeDir: URL
    /// Electron profile.
    public var profileDir: URL
    public var isRunning: Bool
    public var isDefault: Bool
    /// Transcript summary cache.
    public var cacheFile: URL?

    public var store: SessionStore { SessionStore(codeDir: codeDir, profileDir: profileDir, cacheFile: cacheFile) }

    /// Newest Claude Code CLI version downloaded into the profile (`<profile>/claude-code/<version>`).
    public var cliVersion: String? {
        let dir = profileDir.appendingPathComponent("claude-code")
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.first?.isNumber == true }
        return versions.max { SessionTransfer.compareVersions($0, $1) == .orderedAscending }
    }
}

/// A session and where it lives.
public struct LocatedSession: Equatable {
    public var endpoint: SessionEndpoint
    public var session: SessionSummary
}

/// Result of the `clone` command.
public struct CloneResult: Equatable {
    public var instance: Instance
    public var sessionCount: Int
}

extension Orchestrator {
    // MARK: - Endpoints

    /// Directories of the default Claude install.
    public static var defaultCodeDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    public static var defaultProfileDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Claude")
    }

    /// Endpoint by name (`default` → the default Claude install).
    public func endpoint(_ name: String) throws -> SessionEndpoint {
        let config = try store.load()
        if config.instances[name] == nil, name == SessionEndpoint.defaultName {
            return SessionEndpoint(
                name: name,
                codeDir: defaultCodeDir,
                profileDir: defaultProfileDir,
                isRunning: launcher.runningDefaultPid() != nil,
                isDefault: true,
                cacheFile: paths.sessionCacheFile
            )
        }
        guard config.instances[name] != nil else {
            throw OrchestratorError.notFound("instance '\(name)' not found")
        }
        return SessionEndpoint(
            name: name,
            codeDir: paths.codeDir(name),
            profileDir: paths.profileDir(name),
            isRunning: launcher.runningPid(profileDir: paths.profileDir(name)) != nil,
            isDefault: false,
            cacheFile: paths.sessionCacheFile
        )
    }

    /// Endpoints of every instance (sorted by name).
    public func instanceEndpoints() throws -> [SessionEndpoint] {
        try store.load().instances.keys.sorted().map { try endpoint($0) }
    }

    // MARK: - Listing

    /// Sessions (most recent activity first).
    ///
    /// - Parameters:
    ///   - instance: Only this instance (`default` included). `nil` → every instance.
    ///   - project: Only sessions in this working directory.
    ///   - runningOnly: Only running instances.
    public func sessions(instance: String? = nil, project: String? = nil, runningOnly: Bool = false) throws -> [LocatedSession] {
        let endpoints = try instance.map { [try endpoint($0)] } ?? instanceEndpoints()
        let projectPath = project.map { URL(fileURLWithPath: $0).standardizedFileURL.path }

        return endpoints
            .filter { !runningOnly || $0.isRunning }
            .flatMap { endpoint in
                endpoint.store.sessions().map { LocatedSession(endpoint: endpoint, session: $0) }
            }
            .filter { located in
                guard let projectPath else { return true }
                if let cwd = located.session.cwd { return cwd == projectPath }
                return located.session.projectSlug == SessionStore.slug(for: projectPath)
            }
            .sorted { $0.session.lastActivity > $1.session.lastActivity }
    }

    /// Session by id (or unique prefix).
    ///
    /// Without `instance`, every instance is searched; if it matches in more than
    /// one instance, an ambiguity error is thrown.
    public func findSession(_ id: String, instance: String? = nil) throws -> LocatedSession {
        let endpoints = try instance.map { [try endpoint($0)] } ?? instanceEndpoints()
        var matches: [LocatedSession] = []
        for endpoint in endpoints {
            if let session = try endpoint.store.find(id) {
                matches.append(LocatedSession(endpoint: endpoint, session: session))
            }
        }
        guard let first = matches.first else {
            throw OrchestratorError.notFound("session not found: \(id)")
        }
        guard matches.count == 1 else {
            let names = matches.map(\.endpoint.name).joined(separator: ", ")
            throw OrchestratorError.usage("session exists in more than one instance (\(names)) — pick one with --instance")
        }
        return first
    }

    /// The instance's most recently active session.
    public func lastSession(instance: String) throws -> LocatedSession {
        guard let last = try sessions(instance: instance).first else {
            throw OrchestratorError.notFound("no sessions in instance '\(instance)'")
        }
        return last
    }

    // MARK: - Transfer

    /// Copies or moves the session to another instance.
    ///
    /// Writing to a running instance's config directory (or, with `move`, deleting
    /// from a running source) can race with Claude Code's open files, so it needs `force`.
    public func transferSession(
        _ id: String,
        from: String? = nil,
        to: String,
        move: Bool,
        force: Bool = false
    ) throws -> TransferResult {
        let located = try findSession(id, instance: from)
        return try transfer(located, to: to, move: move, force: force)
    }

    /// Transfers a session that has already been found.
    public func transfer(_ located: LocatedSession, to: String, move: Bool, force: Bool = false) throws -> TransferResult {
        let target = try endpoint(to)
        if !force, target.isRunning {
            throw OrchestratorError.runtime(
                "target instance is running: \(target.name) — stop it first, or use --force to continue"
            )
        }
        if move, !force, located.endpoint.isRunning {
            throw OrchestratorError.runtime(
                "source instance is running: \(located.endpoint.name) — stop it before moving "
                + "(or use 'copy' / --force to continue)"
            )
        }
        let transfer = SessionTransfer(
            source: located.endpoint.store,
            target: target.store,
            backupsDir: paths.backupsDir,
            targetCLIVersion: target.cliVersion
        )
        return try transfer.transfer(located.session, move: move, force: force)
    }

    // MARK: - Cloning

    /// Clones the instance along with its profile, Claude Code config and sessions.
    ///
    /// A running source can't be cloned: a copy of a live Chromium profile (LevelDB,
    /// SQLite) would be inconsistent. On APFS the copy uses `clonefile`
    /// (almost no extra disk space).
    public func clone(_ sourceName: String, as newName: String, workdir: String? = nil) throws -> CloneResult {
        try validateNewName(newName)
        let source = try store.instance(named: sourceName)
        let config = try store.load()
        guard config.instances[newName] == nil else {
            throw OrchestratorError.runtime("instance '\(newName)' already exists")
        }
        if launcher.runningPid(profileDir: paths.profileDir(sourceName)) != nil {
            throw OrchestratorError.runtime(
                "source instance is running: \(sourceName) — stop it before cloning"
            )
        }

        let fm = FileManager.default
        let destination = paths.instanceDir(newName)
        if fm.fileExists(atPath: destination.path) {
            throw OrchestratorError.runtime(
                "target directory already exists: \(destination.path) — remove the old data (remove --purge) or pick another name"
            )
        }
        try fm.createDirectory(at: paths.instancesRoot, withIntermediateDirectories: true)

        let temporary = paths.instancesRoot.appendingPathComponent(".\(newName).clone-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: paths.instanceDir(sourceName), to: temporary)
            // The run state and Chromium singleton locks belong to the source.
            for leftover in ["state.json", "profile/SingletonLock", "profile/SingletonCookie", "profile/SingletonSocket"] {
                let url = temporary.appendingPathComponent(leftover)
                if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil || fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                }
            }
            try fm.moveItem(at: temporary, to: destination)
        } catch {
            try? fm.removeItem(at: temporary)
            throw OrchestratorError.runtime("couldn't clone: \(error.localizedDescription)")
        }

        let instance = Instance(name: newName, workdir: workdir ?? source.workdir, iconBadge: source.iconBadge)
        try store.upsert(instance)
        if let workdir = instance.workdir, fm.fileExists(atPath: workdir), workdir != source.workdir {
            _ = try? seeder.seed(profileDir: paths.profileDir(newName), workdir: workdir)
        }

        let count = SessionStore(codeDir: paths.codeDir(newName)).sessions().count
        return CloneResult(instance: instance, sessionCount: count)
    }

    /// Copies all sessions of one instance to another (`new --sessions-from`).
    ///
    /// - Returns: The copied sessions and the skipped ones (with the reason).
    public func copyAllSessions(from source: String, to target: String) throws -> (copied: [TransferResult], skipped: [(String, String)]) {
        var copied: [TransferResult] = []
        var skipped: [(String, String)] = []
        for located in try sessions(instance: source) {
            do {
                copied.append(try transfer(located, to: target, move: false))
            } catch {
                skipped.append((located.session.id, "\(error)"))
            }
        }
        return (copied, skipped)
    }

    /// New instance name: format rules + reserved names.
    func validateNewName(_ name: String) throws {
        try NameValidator.validate(name)
        if name == SessionEndpoint.defaultName {
            throw OrchestratorError.invalidName(
                "'\(name)' is a reserved name (it means the default Claude install) — pick another name"
            )
        }
    }
}
