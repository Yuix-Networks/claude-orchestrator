import Foundation

/// Difference between the hand-edited projects file (`projects.json`) and the registry.
///
/// File format:
///
/// ```json
/// {
///   "projects": [
///     { "name": "vpn", "path": "~/workspace/vpn/vpn-api-backend",
///       "folders": ["~/workspace/vpn/unblock-master-vpn"] },
///     { "path": "~/workspace/tto" }
///   ]
/// }
/// ```
///
/// - `name` is optional (defaults to the folder name); `folders` is optional.
/// - `permissionMode` is optional: `bypassPermissions`, `acceptEdits`, `auto`,
///   `plan`, `default` — the default permission mode for sessions opened in this project.
/// - `defaults` (optional) applies to every project: `folders` is added to each
///   project's extra folders (except the project's own folder), and `permissionMode`
///   is used when the project doesn't set one.
/// - Paths can use `~` or be relative to the folder the file is in.
/// - Keys starting with `//` are ignored as notes; `//` comments and trailing
///   commas are also accepted when reading (JSON5).
public struct ProjectPlan: Equatable {
    /// Projects not in the registry, to be added.
    public var toAdd: [Project]
    /// Projects whose folder or extra folders changed (old, new).
    public var toUpdate: [ProjectChange]
    /// Renamed projects (same main folder, new name).
    public var toRename: [ProjectChange]
    /// Projects not in the file that `prune` will remove.
    public var toRemove: [Project]
    /// Projects not in the file that stay because `prune` wasn't given.
    public var untracked: [Project]
    public var unchanged: [Project]

    public var hasChanges: Bool {
        !(toAdd.isEmpty && toUpdate.isEmpty && toRename.isEmpty && toRemove.isEmpty)
    }
}

/// Old and new version of a project.
public struct ProjectChange: Equatable {
    public var old: Project
    public var new: Project
}

/// Result of `project apply`.
public struct ProjectApplyResult: Equatable {
    public var plan: ProjectPlan
    /// Writing added/changed projects to instances.
    public var synced: [ProjectSyncResult]
    /// Removing the old environments of changed/removed projects.
    public var withdrawn: [ProjectRemoveResult]
}

extension Orchestrator {
    /// Default file for `project apply` / `project export`.
    public static var defaultManifestURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/claude-orchestrator/projects.json")
    }

    // MARK: - Reading

    /// Reads and validates the projects file.
    ///
    /// All problems are collected and reported in one error (it doesn't stop at the
    /// first one), so every typo in a hand-edited file shows up at once.
    public static func loadManifest(_ url: URL) throws -> [Project] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw OrchestratorError.runtime("couldn't read projects file: \(url.path) — \(error.localizedDescription)")
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            throw OrchestratorError.runtime("projects file isn't valid JSON: \(url.path) — \(detail)")
        }

        guard let object = root as? [String: Any] else {
            throw OrchestratorError.runtime("projects file must be a JSON object: { \"projects\": [ … ] }")
        }
        var problems: [String] = []
        for key in object.keys where !["projects", "version", "defaults"].contains(key) && !key.hasPrefix("//") {
            problems.append("unknown field: \"\(key)\" (expected: \"projects\", \"defaults\")")
        }
        if let version = object["version"], (version as? Int) != 1 {
            problems.append("unsupported version: \(version) (only 1)")
        }
        guard let entries = object["projects"] as? [Any] else {
            problems.append("\"projects\" must be an array")
            throw OrchestratorError.runtime(Self.manifestError(url, problems))
        }

        let base = url.deletingLastPathComponent()

        // Shared settings.
        var defaultFolders: [String] = []
        var defaultMode: String?
        if let rawDefaults = object["defaults"] {
            if let defaults = rawDefaults as? [String: Any] {
                for key in defaults.keys where !["folders", "permissionMode"].contains(key) && !key.hasPrefix("//") {
                    problems.append("defaults: unknown field \"\(key)\" (expected: folders, permissionMode)")
                }
                if let rawFolders = defaults["folders"] {
                    if let list = rawFolders as? [String] {
                        for raw in list {
                            do {
                                let folder = try resolveDirectory(raw, relativeTo: base)
                                if !defaultFolders.contains(folder) { defaultFolders.append(folder) }
                            } catch {
                                problems.append("defaults: extra folder — \(error)")
                            }
                        }
                    } else {
                        problems.append("defaults: \"folders\" must be an array of strings")
                    }
                }
                if let rawMode = defaults["permissionMode"] {
                    if let mode = validatePermissionMode(rawMode) { defaultMode = mode } else {
                        problems.append("defaults: \(permissionModeProblem(rawMode))")
                    }
                }
            } else {
                problems.append("\"defaults\" must be an object")
            }
        }

        var projects: [Project] = []
        var names: [String: Int] = [:]
        var paths: [String: Int] = [:]

        for (index, entry) in entries.enumerated() {
            let label = "projects[\(index)]"
            guard let item = entry as? [String: Any] else {
                problems.append("\(label): must be an object")
                continue
            }
            for key in item.keys where !["name", "path", "folders", "permissionMode"].contains(key) && !key.hasPrefix("//") {
                problems.append("\(label): unknown field \"\(key)\" (expected: name, path, folders, permissionMode)")
            }
            guard let rawPath = item["path"] as? String else {
                problems.append("\(label): \"path\" is required and must be a string")
                continue
            }
            let path: String
            do {
                path = try resolveDirectory(rawPath, relativeTo: base)
            } catch {
                problems.append("\(label): \(error)")
                continue
            }

            let rawName = item["name"] ?? URL(fileURLWithPath: path).lastPathComponent
            guard let nameText = rawName as? String, let name = try? validateProjectName(nameText) else {
                problems.append("\(label): invalid \"name\" (a string of 1-80 characters)")
                continue
            }
            let tag = "\(label) \"\(name)\""

            var folders: [String] = []
            if let rawFolders = item["folders"] {
                guard let list = rawFolders as? [String] else {
                    problems.append("\(tag): \"folders\" must be an array of strings")
                    continue
                }
                for raw in list {
                    do {
                        let folder = try resolveDirectory(raw, relativeTo: base)
                        if folder != path && !folders.contains(folder) { folders.append(folder) }
                    } catch {
                        problems.append("\(tag): extra folder — \(error)")
                    }
                }
            }

            var mode = defaultMode
            if let rawMode = item["permissionMode"] {
                if let valid = validatePermissionMode(rawMode) { mode = valid } else {
                    problems.append("\(tag): \(permissionModeProblem(rawMode))")
                }
            }
            for folder in defaultFolders where folder != path && !folders.contains(folder) {
                folders.append(folder)
            }

            if let first = names[name] {
                problems.append("\(tag): same name as projects[\(first)]")
                continue
            }
            if let first = paths[path] {
                problems.append("\(tag): same folder as projects[\(first)] (\(path))")
                continue
            }
            names[name] = index
            paths[path] = index
            projects.append(Project(name: name, path: path, additionalFolders: folders, permissionMode: mode))
        }

        guard problems.isEmpty else {
            throw OrchestratorError.runtime(Self.manifestError(url, problems))
        }
        return projects
    }

    private static func validatePermissionMode(_ raw: Any) -> String? {
        guard let mode = raw as? String, ProfileSeeder.permissionModes.contains(mode) else { return nil }
        return mode
    }

    private static func permissionModeProblem(_ raw: Any) -> String {
        let allowed = ProfileSeeder.permissionModes.sorted().joined(separator: ", ")
        return "invalid \"permissionMode\": \(raw) (valid: \(allowed))"
    }

    private static func manifestError(_ url: URL, _ problems: [String]) -> String {
        "projects file has \(problems.count) problem(s) (\(url.path)) — nothing was changed:\n"
            + problems.map { "  - \($0)" }.joined(separator: "\n")
    }

    // MARK: - Plan and apply

    /// Works out the difference between the file and the registry (writes nothing).
    public func planApply(_ desired: [Project], prune: Bool) throws -> ProjectPlan {
        let current = try store.load().projects
        let desiredNames = Set(desired.map(\.name))
        // Registered projects whose name isn't in the file, keyed by main folder.
        var absentByPath: [String: Project] = [:]
        for project in current.values where !desiredNames.contains(project.name) {
            absentByPath[project.path] = project
        }

        var plan = ProjectPlan(toAdd: [], toUpdate: [], toRename: [], toRemove: [], untracked: [], unchanged: [])
        for wanted in desired {
            if let existing = current[wanted.name] {
                var updated = wanted
                updated.createdAt = existing.createdAt
                if existing.sameDefinition(as: wanted) {
                    plan.unchanged.append(existing)
                } else {
                    plan.toUpdate.append(ProjectChange(old: existing, new: updated))
                }
            } else if let renamed = absentByPath.removeValue(forKey: wanted.path) {
                // Same folder under a new name: the registry can't hold one folder under two names, so it's a rename.
                var updated = wanted
                updated.createdAt = renamed.createdAt
                plan.toRename.append(ProjectChange(old: renamed, new: updated))
            } else {
                // If the folder belongs to another project in the registry, that project
                // moved to another path in the file (folders are unique there); the update is applied first.
                plan.toAdd.append(wanted)
            }
        }

        let leftovers = absentByPath.values.sorted { $0.name < $1.name }
        if prune { plan.toRemove = leftovers } else { plan.untracked = leftovers }
        return plan
    }

    /// Applies the plan: updates the registry, removes old environments, and writes
    /// the new ones to every instance.
    ///
    /// When a project's folder, extra folders or name change, its environment in each
    /// instance is deleted and rewritten (Desktop settings in it, like the model, are reset).
    /// If only the permission mode changed, the environment is left alone and the mode is updated in place.
    public func apply(_ plan: ProjectPlan) throws -> ProjectApplyResult {
        guard plan.hasChanges else {
            return ProjectApplyResult(plan: plan, synced: [], withdrawn: [])
        }
        var config = try store.load()
        let replaced = plan.toUpdate.map(\.old) + plan.toRename.map(\.old)
        for project in plan.toRemove + replaced {
            config.projects.removeValue(forKey: project.name)
        }
        let written = plan.toAdd + plan.toUpdate.map(\.new) + plan.toRename.map(\.new)
        for project in written {
            config.projects[project.name] = project
        }
        try store.save(config)

        // Environments to rewrite: projects whose definition changed (other than the mode).
        let rewritten = plan.toUpdate
            .filter { $0.old.path != $0.new.path || $0.old.additionalFolders != $0.new.additionalFolders }
            .map(\.old) + plan.toRename.map(\.old)
        let withdrawn = withdraw(plan.toRemove + rewritten, remaining: config)

        // Permission modes removed from the file are removed from Desktop too.
        let clearedModes = plan.toUpdate
            .filter { $0.old.permissionMode != nil && $0.new.permissionMode == nil }
            .map(\.new.path)
        if !clearedModes.isEmpty {
            for endpoint in try instanceEndpoints() {
                try? seeder.removePermissionModes(cwds: clearedModes, profileDir: endpoint.profileDir)
            }
        }

        let synced = try syncProjects(only: written)
        return ProjectApplyResult(plan: plan, synced: synced, withdrawn: withdrawn)
    }

    // MARK: - Export

    /// Returns the registered projects in projects-file format (home directory as `~`).
    ///
    /// Field order is fixed for readability: name, path, folders.
    public func exportManifest() throws -> String {
        try Self.renderManifest(projects())
    }

    public static func renderManifest(_ projects: [Project]) -> String {
        func quoted(_ text: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])
            let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            return String(array.dropFirst().dropLast())
        }
        func tilde(_ path: String) -> String {
            let home = NSHomeDirectory()
            return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
        let items = projects.map { project -> String in
            var fields = ["\"name\": \(quoted(project.name))", "\"path\": \(quoted(tilde(project.path)))"]
            if !project.additionalFolders.isEmpty {
                let folders = project.additionalFolders.map { quoted(tilde($0)) }.joined(separator: ", ")
                fields.append("\"folders\": [\(folders)]")
            }
            if let mode = project.permissionMode {
                fields.append("\"permissionMode\": \(quoted(mode))")
            }
            return "    { " + fields.joined(separator: ", ") + " }"
        }
        return "{\n  \"projects\": [\n" + items.joined(separator: ",\n") + "\n  ]\n}\n"
    }
}
