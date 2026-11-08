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
                    line = "güncel"
                } else {
                    line = "\(applied.addedCount) ortam eklendi (\(applied.accounts.count) hesap)"
                        + (result.isRunning ? " — çalışıyor, yeniden başlatınca görünür" : "")
                }
            } else {
                line = "-"
            }
            Output.line("  \(result.instance): \(line)")
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
