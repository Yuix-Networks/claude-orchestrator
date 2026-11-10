import OrchestratorCore
import Foundation

/// `claude-orchestrator new <name> [--workdir <path>] [--sessions-from <instance>]`
enum NewCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["workdir", "sessions-from"])
        let name = try parsed.requirePositional(0, name: "instance name", command: "new")
        let workdir = parsed.optionalFlag("workdir")
        if parsed.has("workdir"), workdir == nil {
            throw OrchestratorError.usage("new: --workdir needs a path")
        }
        let sessionsFrom = parsed.optionalFlag("sessions-from")

        let ctl = Orchestrator()
        if let sessionsFrom {
            // Validate the source before creating the instance, so no half-made instance is left behind.
            _ = try ctl.endpoint(sessionsFrom)
        }
        let instance = try ctl.new(name: name, workdir: workdir)

        if let workdir, !FileManager.default.fileExists(atPath: workdir) {
            Output.line("warning: workdir not found: \(workdir)")
        }
        Output.line("instance created: \(instance.name)")
        Output.line("  workdir:  \(instance.workdir ?? "-")")
        Output.line("  profile:  \(ctl.paths.profileDir(instance.name).path)")

        if let sessionsFrom {
            let (copied, skipped) = try ctl.copyAllSessions(from: sessionsFrom, to: instance.name)
            Output.line("  sessions: copied \(copied.count) from '\(sessionsFrom)'")
            for (id, reason) in skipped {
                Output.line("  warning:  skipped \(id): \(reason)")
            }
        }
        Output.line("  start:    claude-orchestrator start \(instance.name)")
    }
}
