import OrchestratorCore
import Foundation

/// `claude-orchestrator stop <ad>`
enum StopCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: [])
        let name = try parsed.requirePositional(0, name: "instance adı", command: "stop")

        let ctl = Orchestrator()
        let result = try ctl.stop(name: name)

        if result.wasRunning {
            Output.line(result.forced ? "instance zorla kapatıldı: \(name)" : "instance durduruldu: \(name)")
        } else {
            Output.line("instance çalışmıyordu: \(name)")
        }
    }
}
