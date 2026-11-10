import OrchestratorCore
import Foundation

/// `claude-orchestrator project <add|list|remove|sync|import> …`
///
/// Projects are registered centrally and written to each instance's Code tab as
/// an "environment", so every account sees the same projects.
enum ProjectCommand {
    static let usage = """
    project add <path> [--name <name>] [--folder <extra-path>]... [--replace] [--json]
    project list [--json]
    project remove <name> [--keep] [--json]
    project sync [--instance <name>] [--reset-desktop] [--json]
    project import --from <instance|default> [--json]
    project apply [<file>] [--prune] [--dry-run] [--reset-desktop] [--json]
    (--reset-desktop: backs up the profiles' UI storage so Claude re-imports the list
     from the file; the profiles must be closed)
    project export [<file>] [--force]
    (default file: ~/.config/claude-orchestrator/projects.json)
    """

    static func run(_ args: [String]) throws {
        guard let sub = args.first else {
            throw OrchestratorError.usage("project: a subcommand is required\n\(usage)")
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "add": try add(rest)
        case "list", "ls": try list(rest)
        case "remove", "rm": try remove(rest)
        case "sync": try sync(rest)
        case "import": try importFrom(rest)
        case "apply": try applyManifest(rest)
        case "export": try exportManifest(rest)
        default:
            throw OrchestratorError.usage("project: unknown subcommand: \(sub)\n\(usage)")
        }
    }

    // MARK: - add

    static func add(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["name", "folder", "replace", "json"])
        let path = try parsed.requirePositional(0, name: "project folder", command: "project add")
        let (project, results) = try Orchestrator().addProject(
            name: parsed.optionalFlag("name"),
            path: path,
            additionalFolders: parsed.values("folder"),
            replace: parsed.has("replace")
        )

        if parsed.has("json") {
            Output.json(["project": dictionary(project), "instances": results.map(dictionary)])
            return
        }
        Output.line("project registered: \(project.name) → \(project.path)")
        for folder in project.additionalFolders { Output.line("  extra folder: \(folder)") }
        report(results)
    }

    // MARK: - list

    static func list(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["json"])
        let ctl = Orchestrator()
        let projects = try ctl.projects()

        if parsed.has("json") {
            var items: [[String: Any]] = []
            for project in projects {
                var item = dictionary(project)
                var presence: [String: String] = [:]
                for entry in try ctl.projectPresence(project) { presence[entry.instance] = entry.presence.rawValue }
                item["instances"] = presence
                items.append(item)
            }
            Output.json(["projects": items])
            return
        }
        if projects.isEmpty {
            Output.line("no registered projects. Add one with: claude-orchestrator project add <path>")
            Output.line("to import your existing environments: claude-orchestrator project import --from default")
            return
        }
        Output.line(ListCommand.pad("PROJECT", 28) + ListCommand.pad("FOLDER", 40) + "INSTANCES")
        for project in projects {
            let presence = try ctl.projectPresence(project)
                .map { "\($0.instance) \(symbol($0.presence))" }
                .joined(separator: "  ")
            Output.line(
                ListCommand.pad(SessionCommand.truncate(project.name, 27), 28)
                + ListCommand.pad(SessionCommand.shortPath(project.path, width: 39), 40)
                + (presence.isEmpty ? "-" : presence)
            )
        }
        Output.line("")
        Output.line("✓ in sync   ✗ missing (project sync)   … waiting for sign-in (written on the first start after sign-in)")
    }

    // MARK: - remove

    static func remove(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["keep", "json"])
        let name = try parsed.requirePositional(0, name: "project name", command: "project remove")
        let results = try Orchestrator().removeProject(name: name, keepInInstances: parsed.has("keep"))

        if parsed.has("json") {
            Output.json([
                "removed": name,
                "instances": results.map { result -> [String: Any] in
                    [
                        "instance": result.instance,
                        "isRunning": result.isRunning,
                        "presetsRemoved": result.removed?.presetsRemoved ?? 0,
                        "error": result.error ?? NSNull()
                    ]
                }
            ])
            return
        }
        Output.line("project unregistered: \(name)")
        for result in results {
            if let error = result.error {
                Output.line("  \(result.instance): error: \(error)")
            } else if let removed = result.removed, removed.presetsRemoved > 0 {
                Output.line("  \(result.instance): environment removed\(result.isRunning ? " (running: shows after a restart)" : "")")
            }
        }
    }

    // MARK: - sync

    static func sync(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["instance", "reset-desktop", "json"])
        let ctl = Orchestrator()
        let results: [ProjectSyncResult]
        if parsed.has("reset-desktop") {
            let (backups, synced) = try ctl.reimportProjects(instance: parsed.optionalFlag("instance"))
            reportBackups(backups, json: parsed.has("json"))
            results = synced
        } else {
            results = try ctl.syncProjects(instance: parsed.optionalFlag("instance"))
        }
        if parsed.has("json") {
            Output.json(["instances": results.map(dictionary)])
            return
        }
        report(results)
    }

    // MARK: - import

    static func importFrom(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["from", "json"])
        let source = try parsed.requireFlag("from", command: "project import")
        let ctl = Orchestrator()
        let result = try ctl.importProjects(from: source)
        let sync = try ctl.syncProjects(only: result.imported)

        if parsed.has("json") {
            Output.json([
                "imported": result.imported.map(dictionary),
                "skipped": result.skipped.map { ["path": $0.path, "reason": $0.reason] },
                "instances": sync.map(dictionary)
            ])
            return
        }
        Output.line("imported \(result.imported.count) project(s) from '\(source)'")
        for project in result.imported {
            Output.line("  + \(project.name) → \(SessionCommand.shortPath(project.path, width: 60))")
        }
        for skipped in result.skipped {
            Output.line("  skipped: \(SessionCommand.shortPath(skipped.path, width: 60)) (\(skipped.reason))")
        }
        if !result.imported.isEmpty { report(sync) }
    }

    // MARK: - apply

    static func applyManifest(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["prune", "dry-run", "reset-desktop", "json"])
        let url = manifestURL(parsed.positionals.first)
        let ctl = Orchestrator()
        let plan = try ctl.planApply(try Orchestrator.loadManifest(url), prune: parsed.has("prune"))
        let dryRun = parsed.has("dry-run")
        let reset = parsed.has("reset-desktop")
        if reset, !dryRun {
            // Stop before touching the registry if any instance is running.
            let running = try ctl.instanceEndpoints().filter(\.isRunning).map(\.name)
            guard running.isEmpty else {
                throw OrchestratorError.runtime(
                    "instances are running: \(running.joined(separator: ", ")). Stop them first (a running Claude writes the list back)"
                )
            }
        }
        var result = dryRun ? nil : try ctl.apply(plan)
        if reset, !dryRun {
            let (backups, synced) = try ctl.reimportProjects()
            reportBackups(backups, json: parsed.has("json"))
            result?.synced = synced
        }

        if parsed.has("json") {
            Output.json([
                "file": url.path,
                "dryRun": dryRun,
                "added": plan.toAdd.map(\.name),
                "updated": plan.toUpdate.map(\.new.name),
                "renamed": plan.toRename.map { ["from": $0.old.name, "to": $0.new.name] },
                "removed": plan.toRemove.map(\.name),
                "untracked": plan.untracked.map(\.name),
                "unchanged": plan.unchanged.count,
                "instances": (result?.synced ?? []).map(dictionary)
            ])
            return
        }

        Output.line("\(dryRun ? "plan" : "applied"): \(url.path)")
        for project in plan.toAdd { Output.line("  + \(project.name)  \(SessionCommand.shortPath(project.path, width: 60))") }
        for change in plan.toRename { Output.line("  ~ \(change.old.name) → \(change.new.name)") }
        for change in plan.toUpdate { Output.line("  ~ \(change.new.name)  \(describe(change))") }
        for project in plan.toRemove { Output.line("  - \(project.name)") }
        if !plan.hasChanges { Output.line("  no changes (\(plan.unchanged.count) project(s) up to date)") }
        if !plan.untracked.isEmpty {
            let names = plan.untracked.map(\.name).joined(separator: ", ")
            Output.line("  note: \(plan.untracked.count) registered project(s) not in the file were kept (\(names)); use --prune to remove them")
        }
        if let result, plan.hasChanges || reset {
            Output.line("")
            report(result.synced)
            for failure in result.withdrawn where failure.error != nil {
                Output.line("  \(failure.instance): could not remove the old environment: \(failure.error ?? "")")
            }
        } else if dryRun, plan.hasChanges {
            Output.line("")
            Output.line("to apply: claude-orchestrator project apply\(parsed.positionals.first.map { " \($0)" } ?? "")\(parsed.has("prune") ? " --prune" : "")")
        }
    }

    static func describe(_ change: ProjectChange) -> String {
        var parts: [String] = []
        if change.old.path != change.new.path {
            parts.append("folder: \(SessionCommand.shortPath(change.new.path, width: 50))")
        }
        let added = change.new.additionalFolders.filter { !change.old.additionalFolders.contains($0) }
        let removed = change.old.additionalFolders.filter { !change.new.additionalFolders.contains($0) }
        if !added.isEmpty { parts.append("+\(added.count) extra folder(s)") }
        if !removed.isEmpty { parts.append("-\(removed.count) extra folder(s)") }
        if change.old.permissionMode != change.new.permissionMode {
            parts.append("permission mode: \(change.old.permissionMode ?? "-") → \(change.new.permissionMode ?? "-")")
        }
        if parts.isEmpty { parts.append("extra folder order") }
        return parts.joined(separator: ", ")
    }

    // MARK: - export

    static func exportManifest(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["force"])
        let text = try Orchestrator().exportManifest()
        guard let target = parsed.positionals.first else {
            print(text, terminator: "")
            return
        }
        let url = manifestURL(target)
        if FileManager.default.fileExists(atPath: url.path), !parsed.has("force") {
            throw OrchestratorError.runtime("file already exists: \(url.path) (use --force to overwrite)")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        Output.line("written: \(url.path)")
    }

    /// The given path (`~` allowed) or the default projects file.
    static func manifestURL(_ raw: String?) -> URL {
        guard let raw else { return Orchestrator.defaultManifestURL }
        let expanded = (raw as NSString).expandingTildeInPath
        return expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded)
    }

    static func reportBackups(_ backups: [String: URL], json: Bool) {
        guard !json else { return }
        for (instance, backup) in backups.sorted(by: { $0.key < $1.key }) {
            Output.line("  \(instance): UI storage backed up → \(backup.lastPathComponent)")
        }
        if !backups.isEmpty {
            Output.line("  Claude will import the environment list from the file on its next launch")
        }
    }

    // MARK: - Output

    static func report(_ results: [ProjectSyncResult]) {
        if results.isEmpty {
            Output.line("no instances yet. Projects are added automatically to every instance you create")
            return
        }
        for result in results {
            let line: String
            if let error = result.error {
                line = "error: \(error)"
            } else if let applied = result.applied {
                if applied.accounts.isEmpty {
                    line = "trusted folders added; environments will be written by 'start' after the first sign-in"
                } else if applied.addedCount == 0 {
                    line = applied.permissionModesSet > 0 ? "up to date (permission modes written)" : "up to date"
                } else {
                    line = "\(applied.addedCount) environment(s) added (\(applied.accounts.count) account(s))"
                }
            } else {
                line = "-"
            }
            Output.line("  \(result.instance): \(line)")
            if result.needsDesktopReimport {
                Output.line("    warning: Claude keeps the list in its own storage in this profile, so new environments won't show."
                    + " Close the profile, then run: claude-orchestrator project sync --instance \(result.instance) --reset-desktop")
            }
            if let blocked = result.applied?.bypassBlockedAccounts, !blocked.isEmpty {
                Output.line("    warning: organization policy disables bypass mode in \(blocked.count) account(s); it won't work there")
            }
        }
    }

    static func symbol(_ presence: ProjectPresence) -> String {
        switch presence {
        case .synced: return "✓"
        case .missing: return "✗"
        case .pendingSignIn: return "…"
        }
    }

    static func dictionary(_ project: Project) -> [String: Any] {
        [
            "name": project.name,
            "path": project.path,
            "additionalFolders": project.additionalFolders,
            "createdAt": ISO8601DateFormatter().string(from: project.createdAt)
        ]
    }

    static func dictionary(_ result: ProjectSyncResult) -> [String: Any] {
        [
            "instance": result.instance,
            "isRunning": result.isRunning,
            "accounts": result.applied?.accounts ?? [],
            "presetsAdded": result.applied?.addedCount ?? 0,
            "trustedFoldersAdded": result.applied?.trustedFoldersAdded ?? [],
            "error": result.error ?? NSNull()
        ]
    }
}
