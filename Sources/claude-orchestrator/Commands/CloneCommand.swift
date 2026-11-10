import OrchestratorCore
import Foundation

/// `claude-orchestrator clone <source> --as <new-name> [--workdir <path>]`
enum CloneCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["as", "workdir"])
        let source = try parsed.requirePositional(0, name: "source instance", command: "clone")
        let name = try parsed.requireFlag("as", command: "clone")

        let result = try Orchestrator().clone(source, as: name, workdir: parsed.optionalFlag("workdir"))
        Output.line("instance cloned: \(source) → \(result.instance.name)")
        Output.line("  sessions: \(result.sessionCount)")
        Output.line("  workdir:  \(result.instance.workdir ?? "-")")
        Output.line("  note:     the profile was copied, sign-in included; to use another account, sign out in the instance and sign in again")
        Output.line("  start:    claude-orchestrator start \(result.instance.name)")
    }
}
