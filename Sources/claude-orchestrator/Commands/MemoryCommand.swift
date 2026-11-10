import OrchestratorCore
import Foundation

/// `claude-orchestrator memory <link|unlink|status>` — shared CLAUDE.md.
enum MemoryCommand {
    static let usage = """
    memory status
    memory link [--instance <name>] [--force]
    memory unlink [--instance <name>]
    """

    static func run(_ args: [String]) throws {
        guard let sub = args.first else {
            throw OrchestratorError.usage("memory: a subcommand is required\n\(usage)")
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
            throw OrchestratorError.usage("memory: unknown subcommand: \(sub)\n\(usage)")
        }

        Output.line("shared file: \(ctl.sharedMemoryFile.path)")
        if results.isEmpty { Output.line("  no instances yet") }
        for result in results {
            Output.line("  \(result.instance): \(describe(result))")
        }
        if results.contains(where: { $0.state == .ownFile }) {
            Output.line("to back up and link the ones with their own CLAUDE.md: claude-orchestrator memory link --force")
        }
    }

    static func describe(_ result: MemoryLinkResult) -> String {
        switch result.state {
        case .linked:
            return result.backup.map { "linked (old file: \($0.lastPathComponent))" } ?? "linked"
        case .alreadyLinked: return "linked"
        case .ownFile: return "has its own CLAUDE.md, left as is"
        case .missing: return "not linked"
        case .unlinked: return "unlinked"
        }
    }
}
