import OrchestratorCore
import Foundation

/// `claude-orchestrator project <add|list|remove|sync|import> …`
///
/// Projeler merkezi olarak kaydedilir ve her instance'ın Code sekmesine ortam
/// ("environment") olarak yazılır; böylece tüm hesaplarda aynı projeler görünür.
enum ProjectCommand {
    static let usage = """
    project add <yol> [--name <ad>] [--folder <ek-yol>]... [--replace] [--json]
    project list [--json]
    project remove <ad> [--keep] [--json]
    project sync [--instance <ad>] [--json]
    project import --from <instance|default> [--json]
    project apply [<dosya>] [--prune] [--dry-run] [--json]
    project export [<dosya>] [--force]
    (varsayılan dosya: ~/.config/claude-orchestrator/projects.json)
    """

    static func run(_ args: [String]) throws {
        guard let sub = args.first else {
            throw OrchestratorError.usage("project: alt komut gerekli\n\(usage)")
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
            throw OrchestratorError.usage("project: bilinmeyen alt komut: \(sub)\n\(usage)")
        }
    }

    // MARK: - add

    static func add(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["name", "folder", "replace", "json"])
        let path = try parsed.requirePositional(0, name: "proje klasörü", command: "project add")
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
        Output.line("proje kaydedildi: \(project.name) → \(project.path)")
        for folder in project.additionalFolders { Output.line("  ek klasör: \(folder)") }
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
            Output.line("kayıtlı proje yok — eklemek için: claude-orchestrator project add <yol>")
            Output.line("var olan ortamları almak için: claude-orchestrator project import --from default")
            return
        }
        Output.line(ListCommand.pad("PROJE", 28) + ListCommand.pad("KLASÖR", 40) + "INSTANCE'LAR")
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
        Output.line("✓ senkron   ✗ eksik (project sync)   … giriş bekleniyor (ilk girişten sonraki start ile yazılır)")
    }

    // MARK: - remove

    static func remove(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["keep", "json"])
        let name = try parsed.requirePositional(0, name: "proje adı", command: "project remove")
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
        Output.line("proje kayıttan silindi: \(name)")
        for result in results {
            if let error = result.error {
                Output.line("  \(result.instance): hata — \(error)")
            } else if let removed = result.removed, removed.presetsRemoved > 0 {
                Output.line("  \(result.instance): ortam kaldırıldı\(result.isRunning ? " (çalışıyor — yeniden başlatınca görünür)" : "")")
            }
        }
    }

    // MARK: - sync

    static func sync(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["instance", "json"])
        let results = try Orchestrator().syncProjects(instance: parsed.optionalFlag("instance"))
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
        Output.line("\(result.imported.count) proje '\(source)' kaynağından alındı")
        for project in result.imported {
            Output.line("  + \(project.name) → \(SessionCommand.shortPath(project.path, width: 60))")
        }
        for skipped in result.skipped {
            Output.line("  atlandı: \(SessionCommand.shortPath(skipped.path, width: 60)) (\(skipped.reason))")
        }
        if !result.imported.isEmpty { report(sync) }
    }

    // MARK: - apply

    static func applyManifest(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["prune", "dry-run", "json"])
        let url = manifestURL(parsed.positionals.first)
        let ctl = Orchestrator()
        let plan = try ctl.planApply(try Orchestrator.loadManifest(url), prune: parsed.has("prune"))
        let dryRun = parsed.has("dry-run")
        let result = dryRun ? nil : try ctl.apply(plan)

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

        Output.line("\(dryRun ? "plan" : "uygulandı"): \(url.path)")
        for project in plan.toAdd { Output.line("  + \(project.name)  \(SessionCommand.shortPath(project.path, width: 60))") }
        for change in plan.toRename { Output.line("  ~ \(change.old.name) → \(change.new.name)") }
        for change in plan.toUpdate { Output.line("  ~ \(change.new.name)  \(describe(change))") }
        for project in plan.toRemove { Output.line("  - \(project.name)") }
        if !plan.hasChanges { Output.line("  değişiklik yok (\(plan.unchanged.count) proje güncel)") }
        if !plan.untracked.isEmpty {
            let names = plan.untracked.map(\.name).joined(separator: ", ")
            Output.line("  not: dosyada olmayan \(plan.untracked.count) kayıtlı proje kaldı (\(names)) — silmek için --prune")
        }
        if let result, plan.hasChanges {
            Output.line("")
            report(result.synced)
            for failure in result.withdrawn where failure.error != nil {
                Output.line("  \(failure.instance): eski ortam kaldırılamadı — \(failure.error ?? "")")
            }
        } else if dryRun, plan.hasChanges {
            Output.line("")
            Output.line("uygulamak için: claude-orchestrator project apply\(parsed.positionals.first.map { " \($0)" } ?? "")\(parsed.has("prune") ? " --prune" : "")")
        }
    }

    static func describe(_ change: ProjectChange) -> String {
        var parts: [String] = []
        if change.old.path != change.new.path {
            parts.append("klasör: \(SessionCommand.shortPath(change.new.path, width: 50))")
        }
        let added = change.new.additionalFolders.filter { !change.old.additionalFolders.contains($0) }
        let removed = change.old.additionalFolders.filter { !change.new.additionalFolders.contains($0) }
        if !added.isEmpty { parts.append("+\(added.count) ek klasör") }
        if !removed.isEmpty { parts.append("-\(removed.count) ek klasör") }
        if change.old.permissionMode != change.new.permissionMode {
            parts.append("izin modu: \(change.old.permissionMode ?? "-") → \(change.new.permissionMode ?? "-")")
        }
        if parts.isEmpty { parts.append("ek klasör sırası") }
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
            throw OrchestratorError.runtime("dosya zaten var: \(url.path) — üzerine yazmak için --force")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        Output.line("yazıldı: \(url.path)")
    }

    /// Verilen yol (`~` dahil) ya da varsayılan proje dosyası.
    static func manifestURL(_ raw: String?) -> URL {
        guard let raw else { return Orchestrator.defaultManifestURL }
        let expanded = (raw as NSString).expandingTildeInPath
        return expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded)
    }

    // MARK: - Çıktı

    static func report(_ results: [ProjectSyncResult]) {
        if results.isEmpty {
            Output.line("henüz instance yok — projeler oluşturulan her instance'a otomatik eklenir")
            return
        }
        for result in results {
            let line: String
            if let error = result.error {
                line = "hata — \(error)"
            } else if let applied = result.applied {
                if applied.accounts.isEmpty {
                    line = "güvenli klasörler eklendi; ortamlar ilk girişten sonra 'start' ile yazılacak"
                } else if applied.addedCount == 0 {
                    line = applied.permissionModesSet > 0 ? "güncel (izin modları yazıldı)" : "güncel"
                } else {
                    line = "\(applied.addedCount) ortam eklendi (\(applied.accounts.count) hesap)"
                        + (result.isRunning ? " — çalışıyor, yeniden başlatınca görünür" : "")
                }
            } else {
                line = "-"
            }
            Output.line("  \(result.instance): \(line)")
            if let blocked = result.applied?.bypassBlockedAccounts, !blocked.isEmpty {
                Output.line("    uyarı: \(blocked.count) hesapta organizasyon politikası bypass modunu kapatmış; orada çalışmaz")
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
