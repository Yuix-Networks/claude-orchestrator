import OrchestratorCore
import Foundation

/// `claude-orchestrator stop <name>`
enum StopCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: [])
        let name = try parsed.requirePositional(0, name: "instance name", command: "stop")

        let ctl = Orchestrator()
        let result = try ctl.stop(name: name)

        if result.wasRunning {
            Output.line(result.forced ? "instance force-quit: \(name)" : "instance stopped: \(name)")
        } else {
            Output.line("instance was not running: \(name)")
        }
    }
}
