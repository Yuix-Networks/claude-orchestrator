import OrchestratorCore
import Foundation

/// `claude-orchestrator logs <ad> [-n N] [-f]`
enum LogsCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["lines", "follow"])
        let name = try parsed.requirePositional(0, name: "instance adı", command: "logs")
        let limit = Int(parsed.optionalFlag("lines") ?? "50") ?? 50
        let ctl = Orchestrator()

        for line in try ctl.logs(name: name, lines: limit) {
            Output.line(line)
        }

        guard parsed.has("follow") else { return }

        // Canlı takip: yeni satırları yazdır (dosya döndürme algılanır).
        let follower = LogFollower(url: LogReader().logFile)
        while true {
            Thread.sleep(forTimeInterval: 1)
            for line in follower.poll() {
                Output.line(line)
            }
        }
    }
}
