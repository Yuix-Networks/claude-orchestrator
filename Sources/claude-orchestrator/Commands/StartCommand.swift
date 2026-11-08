import OrchestratorCore
import Foundation

/// `claude-orchestrator start <ad> [--folder <yol>]`
enum StartCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["folder"])
        let name = try parsed.requirePositional(0, name: "instance adı", command: "start")

        let ctl = Orchestrator()
        let result = try ctl.start(name: name, folder: parsed.optionalFlag("folder"))

        if let warning = result.warning {
            Output.line("uyarı: \(warning)")
        }
        if result.alreadyRunning {
            Output.line("instance zaten çalışıyor: \(name) (pid \(result.pid))")
            return
        }
        Output.line("instance başlatıldı: \(name) (pid \(result.pid))")
        if let workdir = result.instance.workdir {
            Output.line("  workdir: \(workdir)")
        }
    }
}
