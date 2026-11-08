import OrchestratorCore
import Foundation

/// `claude-orchestrator memory <link|unlink|status>` — ortak CLAUDE.md.
enum MemoryCommand {
    static let usage = """
    memory status
    memory link [--instance <ad>] [--force]
    memory unlink [--instance <ad>]
    """

    static func run(_ args: [String]) throws {
        guard let sub = args.first else {
            throw OrchestratorError.usage("memory: alt komut gerekli\n\(usage)")
        }
        let ctl = Orchestrator()
        let rest = Array(args.dropFirst())
        let results: [MemoryLinkResult]
        switch sub {
        case "status":
            _ = try Arguments(rest, allowed: [])
            results = try ctl.sharedMemoryStatus()
        case "link":
            let parsed = try Arguments(rest, allowed: ["instance", "force"])
            results = try ctl.linkSharedMemory(instance: parsed.optionalFlag("instance"), force: parsed.has("force"))
        case "unlink":
            let parsed = try Arguments(rest, allowed: ["instance"])
            results = try ctl.unlinkSharedMemory(instance: parsed.optionalFlag("instance"))
        default:
            throw OrchestratorError.usage("memory: bilinmeyen alt komut: \(sub)\n\(usage)")
        }

        Output.line("ortak dosya: \(ctl.sharedMemoryFile.path)")
        if results.isEmpty { Output.line("  henüz instance yok") }
        for result in results {
            Output.line("  \(result.instance): \(describe(result))")
        }
        if results.contains(where: { $0.state == .ownFile }) {
            Output.line("kendi CLAUDE.md'si olanları yedekleyip bağlamak için: claude-orchestrator memory link --force")
        }
    }

    static func describe(_ result: MemoryLinkResult) -> String {
        switch result.state {
        case .linked:
            return result.backup.map { "bağlandı (eski dosya: \($0.lastPathComponent))" } ?? "bağlandı"
        case .alreadyLinked: return "bağlı"
        case .ownFile: return "kendi CLAUDE.md'si var, dokunulmadı"
        case .missing: return "bağlı değil"
        case .unlinked: return "bağ kaldırıldı"
        }
    }
}
