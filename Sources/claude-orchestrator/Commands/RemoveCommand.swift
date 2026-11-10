import OrchestratorCore
import Foundation

/// `claude-orchestrator remove|delete|rm <name> [--purge [--permanent]] [--force] [--yes]`
enum RemoveCommand {
    static func run(_ args: [String], command: String = "remove") throws {
        let parsed = try Arguments(args, allowed: ["purge", "force", "permanent", "yes"])
        let name = try parsed.requirePositional(0, name: "instance name", command: command)
        let purge = parsed.has("purge")
        var force = parsed.has("force")
        let permanent = parsed.has("permanent")

        if permanent && !purge {
            throw OrchestratorError.usage("\(command): --permanent only works with --purge")
        }

        let ctl = Orchestrator()
        let status = try ctl.status(name: name)
        let assumeYes = parsed.has("yes")

        // Confirm when data will be deleted or a running instance will be stopped.
        if (purge || (status.isRunning && !force)) && !assumeYes {
            var lines: [String] = []
            if status.isRunning {
                lines.append("'\(name)' is running and will be stopped.")
            }
            if purge {
                let what = permanent ? "will be deleted PERMANENTLY (cannot be undone)" : "will be moved to the Trash"
                lines.append("The sign-in, settings and all sessions of profile '\(name)' \(what).")
            } else {
                lines.append("The data will be kept (to delete it: --purge).")
            }
            guard Confirm.ask(lines.joined(separator: "\n")) else {
                throw OrchestratorError.runtime("cancelled")
            }
            force = force || status.isRunning
        } else if status.isRunning && assumeYes {
            force = true
        }

        let trashed = try ctl.remove(name: name, purge: purge, force: force, permanent: permanent)
        if status.isRunning { Output.line("stopped: \(name)") }
        if !purge {
            Output.line("profile removed (data kept; 'new' with the same name brings it back): \(name)")
        } else if let trashed {
            Output.line("profile removed; data is in the Trash: \(trashed.path)")
        } else {
            Output.line("profile removed (data included): \(name)")
        }
    }
}
