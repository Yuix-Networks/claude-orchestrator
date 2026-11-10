import OrchestratorCore
import Foundation

/// `claude-orchestrator open <name> [--target workdir|profile]`
enum OpenCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["target"])
        let name = try parsed.requirePositional(0, name: "instance name", command: "open")
        let rawTarget = parsed.optionalFlag("target") ?? "workdir"
        guard let target = OpenTarget(rawValue: rawTarget) else {
            Output.error("open: --target must be 'workdir' or 'profile' (got: \(rawTarget))", code: ExitCode.usage)
        }

        try Orchestrator().open(name: name, target: target)
        Output.line("opened (\(target.rawValue)): \(name)")
    }
}
