import OrchestratorCore
import Foundation

/// `claude-orchestrator doctor [<name>] [--json]`
enum DoctorCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["json"])
        let name = parsed.positionals.first
        let checks = try Orchestrator().doctor(name: name)

        if parsed.has("json") {
            Output.json([
                "checks": checks.map { check in
                    [
                        "name": check.name,
                        "status": check.status.rawValue,
                        "detail": check.detail
                    ] as [String: Any]
                }
            ])
        } else {
            for check in checks {
                let marker: String
                switch check.status {
                case .ok: marker = "ok  "
                case .warn: marker = "warn"
                case .fail: marker = "FAIL"
                }
                Output.line("\(marker)  \(check.name): \(check.detail)")
            }
        }

        if checks.contains(where: { $0.status == .fail }) {
            exit(ExitCode.runtime)
        }
    }
}
