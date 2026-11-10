import OrchestratorCore
import Foundation

/// `claude-orchestrator status <name> [--json]`
enum StatusCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["json"])
        let name = try parsed.requirePositional(0, name: "instance name", command: "status")
        let ctl = Orchestrator()
        let status = try ctl.status(name: name)

        if parsed.has("json") {
            Output.json([
                "name": status.name,
                "workdir": status.workdir ?? NSNull(),
                "isRunning": status.isRunning,
                "pid": status.pid.map { Int($0) } ?? NSNull(),
                "startedAt": status.startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                "profileSizeBytes": status.profileSizeBytes,
                "accountSignedIn": status.accountSignedIn,
                "profileDir": ctl.paths.profileDir(name).path
            ])
            return
        }

        Output.line("instance:   \(status.name)")
        Output.line("status:     \(status.isRunning ? "running" : "stopped")\(status.pid.map { " (pid \($0))" } ?? "")")
        if let startedAt = status.startedAt {
            Output.line("started:    \(ISO8601DateFormatter().string(from: startedAt))")
        }
        Output.line("workdir:    \(status.workdir ?? "-")")
        Output.line("profile:    \(ctl.paths.profileDir(name).path)")
        Output.line("size:       \(ByteCountFormatter.string(fromByteCount: status.profileSizeBytes, countStyle: .file))")
        Output.line("signed in:  \(status.accountSignedIn ? "yes" : "no (sign-in may be needed)")")
    }
}
