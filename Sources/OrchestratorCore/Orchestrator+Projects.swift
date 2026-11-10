import Foundation

/// Status of a project in an instance.
public enum ProjectPresence: String, Equatable {
    /// The environment exists in every known account in the profile.
    case synced
    /// The environment is missing from at least one account.
    case missing
    /// No account in the profile yet (not signed in): the environment is written by the
    /// first `start` after sign-in; the trusted folder is already added.
    case pendingSignIn
}

/// Result of syncing projects to an instance.
public struct ProjectSyncResult: Equatable {
    public var instance: String
    public var isRunning: Bool
    public var applied: PresetApplyResult?
    public var error: String?
    /// Does the profile have a Desktop UI store? If so, Claude reads the list from its own
    /// store, and entries added to the file won't show up without `reimportProjects` (`--reset-desktop`).
    public var desktopStateExists: Bool = false

    /// Environments were added to the file, but Claude won't pick them up on its own.
    public var needsDesktopReimport: Bool {
        desktopStateExists && (applied?.addedCount ?? 0) > 0
    }
}

/// Per-instance result of removing a project.
public struct ProjectRemoveResult: Equatable {
    public var instance: String
    public var isRunning: Bool
    public var removed: PresetRemoveResult?
    public var error: String?
}

/// Result of an import.
public struct ProjectImportResult: Equatable {
    public var imported: [Project]
    /// Skipped folders, and why.
    public var skipped: [(path: String, reason: String)]

    public static func == (lhs: ProjectImportResult, rhs: ProjectImportResult) -> Bool {
        lhs.imported == rhs.imported && lhs.skipped.map(\.path) == rhs.skipped.map(\.path)
    }
}

extension Orchestrator {
    // MARK: - Registry

    /// Registered projects (sorted by name).
    public func projects() throws -> [Project] {
        try store.load().projects.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Registers the project and syncs it to every instance.
    ///
    /// - Parameters:
    ///   - name: Environment name shown in Claude Desktop. `nil` uses the folder name.
    ///   - path: Main folder (`~` and relative paths are accepted; it must exist).
    ///   - additionalFolders: Extra folders.
    ///   - replace: Overwrite a project with the same name.
    public func addProject(
        name: String?,
        path: String,
        additionalFolders: [String] = [],
        replace: Bool = false
    ) throws -> (project: Project, sync: [ProjectSyncResult]) {
        let resolvedPath = try Self.resolveDirectory(path)
        var folders: [String] = []
        for folder in try additionalFolders.map({ try Self.resolveDirectory($0) })
        where folder != resolvedPath && !folders.contains(folder) {
            folders.append(folder)
        }
        let projectName = try Self.validateProjectName(name ?? URL(fileURLWithPath: resolvedPath).lastPathComponent)

        var config = try store.load()
        if let existing = config.projects[projectName], !replace {
            throw OrchestratorError.runtime(
                "project '\(projectName)' already exists (\(existing.path)) — use --replace to change it"
            )
        }
        if let other = config.projects.values.first(where: { $0.path == resolvedPath && $0.name != projectName }) {
            throw OrchestratorError.runtime("this folder is already registered as '\(other.name)': \(resolvedPath)")
        }

        let project = Project(
            name: projectName,
            path: resolvedPath,
            additionalFolders: folders,
            createdAt: config.projects[projectName]?.createdAt ?? Date()
        )
        config.projects[projectName] = project
        try store.save(config)

        return (project, try syncProjects(only: [project]))
    }

    /// Removes the project from the registry; unless `keepInInstances` is set, also
    /// removes its environment and trusted folder from the instances.
    ///
    /// Folders used by another registered project or an instance workdir stay
    /// in the trusted folders.
    public func removeProject(name: String, keepInInstances: Bool = false) throws -> [ProjectRemoveResult] {
        var config = try store.load()
        guard let project = config.projects.removeValue(forKey: name) else {
            throw OrchestratorError.notFound("project '\(name)' not found")
        }
        try store.save(config)
        guard !keepInInstances else { return [] }
        return withdraw([project], remaining: config)
    }

    /// Removes the projects' environments from every instance.
    ///
    /// - Parameter remaining: The config after removal; folders still used by a
    ///   registered project or an instance workdir in it stay in the trusted folders.
    func withdraw(_ projects: [Project], remaining config: Config) -> [ProjectRemoveResult] {
        guard !projects.isEmpty else { return [] }
        let stillUsed = Set(config.projects.values.flatMap { [$0.path] + $0.additionalFolders })
        let cwds = projects.map(\.path)
        let candidates = projects.flatMap { [$0.path] + $0.additionalFolders }

        var results: [ProjectRemoveResult] = []
        for instance in config.instances.values.sorted(by: { $0.name < $1.name }) {
            let protected = stillUsed.union(instance.workdir.map { [$0] } ?? [])
            let folders = candidates.filter { !protected.contains($0) }
            let running = launcher.runningPid(profileDir: paths.profileDir(instance.name)) != nil
            do {
                let removed = try seeder.remove(cwds: cwds, trustedFolders: folders, from: paths.profileDir(instance.name))
                results.append(ProjectRemoveResult(instance: instance.name, isRunning: running, removed: removed, error: nil))
            } catch {
                results.append(ProjectRemoveResult(instance: instance.name, isRunning: running, removed: nil, error: "\(error)"))
            }
        }
        return results
    }

    // MARK: - Desktop UI store

    /// Makes Claude Desktop re-import its environment list from the file.
    ///
    /// Desktop keeps the list in its own UI store (`Local Storage`, key
    /// `ccd-session-presets.<account>`) and imports `ccd-session-presets.json` only
    /// once, on the first launch with that account; after that it overwrites the file
    /// with its own list. Moving `Local Storage` to a backup while the profile is closed
    /// makes the next launch import the file again. Sign-in isn't affected (cookies are
    /// separate); only UI preferences are lost (sidebar layout, drafts…).
    ///
    /// - Returns: Location of the backup (`nil` if there is no `Local Storage`).
    /// - Throws: If the instance is running (a running UI writes the list back).
    @discardableResult
    public func resetDesktopState(instance: String) throws -> URL? {
        let endpoint = try endpoint(instance)
        guard !endpoint.isDefault else {
            throw OrchestratorError.usage("the default Claude install's UI store can't be reset")
        }
        if endpoint.isRunning {
            throw OrchestratorError.runtime("instance is running: \(instance) — run 'claude-orchestrator stop \(instance)' first")
        }
        let storage = endpoint.profileDir.appendingPathComponent("Local Storage")
        guard FileManager.default.fileExists(atPath: storage.path) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let backup = endpoint.profileDir.appendingPathComponent("Local Storage.bak-\(stamp)")
        try FileManager.default.moveItem(at: storage, to: backup)
        return backup
    }

    /// Resets the UI store in every instance and rewrites the registered projects.
    ///
    /// First checks that all of them are stopped; if even one is running, nothing
    /// is changed.
    public func reimportProjects(instance: String? = nil) throws -> (backups: [String: URL], synced: [ProjectSyncResult]) {
        let endpoints = try instance.map { [try endpoint($0)] } ?? instanceEndpoints()
        let running = endpoints.filter(\.isRunning).map(\.name)
        guard running.isEmpty else {
            throw OrchestratorError.runtime(
                "instances are running: \(running.joined(separator: ", ")) — stop them first (a running Claude writes the list back)"
            )
        }
        var backups: [String: URL] = [:]
        for endpoint in endpoints {
            if let backup = try resetDesktopState(instance: endpoint.name) { backups[endpoint.name] = backup }
        }
        return (backups, try syncProjects(instance: instance))
    }

    // MARK: - Sync

    /// Writes the registered projects to instance profiles (idempotent).
    ///
    /// - Parameters:
    ///   - instance: Only this instance (`default` = the non-instance Claude).
    ///     `nil` → every instance (the default install isn't included).
    ///   - only: Only these projects (`nil` → all of them).
    public func syncProjects(instance: String? = nil, only: [Project]? = nil) throws -> [ProjectSyncResult] {
        let projects = try only ?? self.projects()
        let endpoints = try instance.map { [try endpoint($0)] } ?? instanceEndpoints()
        return endpoints.map { endpoint in
            let state = FileManager.default.fileExists(
                atPath: endpoint.profileDir.appendingPathComponent("Local Storage").path)
            do {
                let applied = try seeder.apply(projects.map(\.presetSpec), to: endpoint.profileDir, allAccounts: true)
                return ProjectSyncResult(instance: endpoint.name, isRunning: endpoint.isRunning, applied: applied,
                                         error: nil, desktopStateExists: state)
            } catch {
                return ProjectSyncResult(instance: endpoint.name, isRunning: endpoint.isRunning, applied: nil,
                                         error: "\(error)", desktopStateExists: state)
            }
        }
    }

    /// Status of the project in each instance.
    public func projectPresence(_ project: Project) throws -> [(instance: String, presence: ProjectPresence)] {
        try instanceEndpoints().map { endpoint in
            let presets = seeder.existingPresets(profileDir: endpoint.profileDir)
            let accounts = Set(presets.map(\.account))
                .union(ProfileSeeder.activeAccountUUID(profileDir: endpoint.profileDir).map { [$0] } ?? [])
            guard !accounts.isEmpty else { return (endpoint.name, .pendingSignIn) }
            let withProject = Set(presets.filter { $0.cwd == project.path }.map(\.account))
            return (endpoint.name, withProject.isSuperset(of: accounts) ? .synced : .missing)
        }
    }

    // MARK: - Import

    /// Registers the existing environments of an instance (or the `default` install).
    ///
    /// If the same folder exists in several accounts, the most recently used name wins.
    /// Folders that are already registered or not on disk are skipped. On a name clash,
    /// a suffix like ` (2)` is added.
    public func importProjects(from source: String) throws -> ProjectImportResult {
        let endpoint = try endpoint(source)
        var config = try store.load()
        let registeredPaths = Set(config.projects.values.map(\.path))

        var newest: [String: ExistingPreset] = [:]
        for preset in seeder.existingPresets(profileDir: endpoint.profileDir) {
            if let current = newest[preset.cwd], current.lastUsedAt >= preset.lastUsedAt { continue }
            newest[preset.cwd] = preset
        }

        var imported: [Project] = []
        var skipped: [(path: String, reason: String)] = []
        for preset in newest.values.sorted(by: { $0.cwd < $1.cwd }) {
            if registeredPaths.contains(preset.cwd) {
                skipped.append((preset.cwd, "already registered"))
                continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: preset.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                skipped.append((preset.cwd, "folder not found"))
                continue
            }
            let baseName = (try? Self.validateProjectName(preset.name)) ?? URL(fileURLWithPath: preset.cwd).lastPathComponent
            var name = baseName
            var counter = 2
            while config.projects[name] != nil {
                name = "\(baseName) (\(counter))"
                counter += 1
            }
            let folders = preset.additionalFolders.filter { FileManager.default.fileExists(atPath: $0) }
            let project = Project(name: name, path: preset.cwd, additionalFolders: folders)
            config.projects[name] = project
            imported.append(project)
        }
        try store.save(config)
        return ProjectImportResult(imported: imported, skipped: skipped)
    }

    // MARK: - Validation

    /// Project name: not empty, at most 80 characters, no control characters.
    static func validateProjectName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw OrchestratorError.usage("invalid project name: '\(raw)' (1-80 characters, no line breaks)")
        }
        return name
    }

    /// Turns a `~` or relative path into an absolute, standardized one; it must be a folder.
    ///
    /// - Parameter base: Base for relative paths (default: the current directory).
    static func resolveDirectory(_ path: String, relativeTo base: URL? = nil) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let root = base ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : root.appendingPathComponent(expanded)
        let resolved = url.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OrchestratorError.runtime("folder not found: \(resolved)")
        }
        return resolved
    }
}
