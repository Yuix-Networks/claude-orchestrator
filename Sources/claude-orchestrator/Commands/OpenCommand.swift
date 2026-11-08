import OrchestratorCore
import Foundation

/// `claude-orchestrator open <ad> [--target workdir|profile]`
enum OpenCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["target"])
        let name = try parsed.requirePositional(0, name: "instance adı", command: "open")
        let rawTarget = parsed.optionalFlag("target") ?? "workdir"
        guard let target = OpenTarget(rawValue: rawTarget) else {
            Output.error("open: --target yalnızca 'workdir' veya 'profile' olabilir (verilen: \(rawTarget))", code: ExitCode.usage)
        }

        try Orchestrator().open(name: name, target: target)
        Output.line("açıldı (\(target.rawValue)): \(name)")
    }
}
