import OrchestratorCore
import Foundation

/// `claude-orchestrator update [status] [--json]`
/// `claude-orchestrator update apply [--yes] [--dialog] [--foreground]`
/// `claude-orchestrator update notify`
enum UpdateCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["json", "yes", "dialog", "foreground", "notify"])
        switch parsed.positionals.first {
        case nil, "status": try status(parsed)
        case "apply": try apply(parsed)
        case "notify": try notify()
        case let other?: throw OrchestratorError.usage("update: unknown subcommand '\(other)' (status, apply, notify)")
        }
    }

    // MARK: - status

    private static func status(_ parsed: Arguments) throws {
        let ctl = Orchestrator()
        let system = SquirrelUpdateSystem(appPath: ctl.appPath)
        let plan = try ctl.updatePlan(system: system)
        let state = UpdateState.read(paths: ctl.paths)
        let installed = system.installedVersion()
        let waiting = system.inspector.waitingShipItPids()

        if parsed.has("json") {
            var out: [String: Any] = [
                "installedVersion": installed ?? NSNull(),
                "stagedVersion": plan.pending?.stagedVersion ?? NSNull(),
                "updatePending": plan.pending != nil,
                "willReopen": plan.instances,
                "running": plan.running,
                "closedByUpdate": plan.closedByUpdate,
                "defaultRunning": plan.defaultPid != nil,
                "waitingInstallerPids": waiting,
                "interrupted": plan.interrupted != nil
            ]
            if let notified = state.notifiedVersion { out["notifiedVersion"] = notified }
            Output.json(out)
            return
        }

        Output.line("installed:  Claude \(installed ?? "?")")
        guard let pending = plan.pending else {
            Output.line("staged:     none — Claude is up to date")
            if let interrupted = plan.interrupted {
                Output.line("")
                Output.line("⚠ an update started \(formatDuration(Date().timeIntervalSince(interrupted.startedAt))) ago never reopened: "
                    + interrupted.instances.joined(separator: ", "))
                Output.line("  reopen them: claude-orchestrator update apply")
            }
            return
        }
        Output.line("staged:     Claude \(pending.stagedVersion)  (\(pending.stagedBundle))")
        if !waiting.isEmpty {
            Output.line("installer:  ShipIt pid \(waiting.map(String.init).joined(separator: ", ")) is waiting for every Claude to quit")
        }
        Output.line("")
        Output.line("A controlled update closes every Claude, installs \(pending.stagedVersion) and reopens:")
        Output.line("  \(plan.instances.isEmpty ? "(no instances)" : plan.instances.joined(separator: ", "))")
        if !plan.closedByUpdate.isEmpty {
            Output.line("  (\(plan.closedByUpdate.joined(separator: ", ")) already closed itself to update; it is reopened too)")
        }
        if plan.defaultPid != nil { Output.line("  plus the default Claude (not an instance)") }
        if !plan.strays.isEmpty {
            Output.line("⚠ blocked by Claude open with an unknown profile: "
                + plan.strays.map { "pid \($0.value)" }.sorted().joined(separator: ", "))
        }
        Output.line("")
        Output.line("Run it: claude-orchestrator update apply")
    }

    // MARK: - notify

    private static func notify() throws {
        let ctl = Orchestrator()
        let system = SquirrelUpdateSystem(appPath: ctl.appPath)
        let plan = try ctl.updatePlan(system: system)
        guard let pending = plan.pending else {
            Output.line("no Claude update is staged (installed: \(system.installedVersion() ?? "?")); nothing to notify")
            return
        }
        UpdateNotifier(appPath: ctl.appPath).announce(pending, instances: plan.running, closedByUpdate: plan.closedByUpdate)
        var state = UpdateState.read(paths: ctl.paths)
        state.notifiedVersion = pending.stagedVersion
        state.notifiedAt = Date()
        state.write(paths: ctl.paths)
        Output.line("notification sent for Claude \(pending.stagedVersion)")
    }

    // MARK: - apply

    private static func apply(_ parsed: Arguments) throws {
        let ctl = Orchestrator()
        let system = SquirrelUpdateSystem(appPath: ctl.appPath)
        let notifier = UpdateNotifier(appPath: ctl.appPath)
        let plan = try ctl.updatePlan(system: system)

        guard let pending = plan.pending else {
            if plan.interrupted != nil {
                return try perform(ctl: ctl, system: system, notifier: notifier, parsed: parsed)
            }
            if !parsed.has("dialog") {
                Output.line("no Claude update is staged (installed: \(system.installedVersion() ?? "?"))")
            }
            return
        }

        if parsed.has("dialog") {
            // From a notification click or the watcher: ask in a dialog, then run detached.
            switch notifier.confirm(pending, instances: plan.running, closedByUpdate: plan.closedByUpdate) {
            case .later:
                var state = UpdateState.read(paths: ctl.paths)
                state.snoozedUntil = Date().addingTimeInterval(6 * 3600)
                state.write(paths: ctl.paths)
                return
            case .update:
                detach(ctl: ctl)
                return
            }
        }

        if !parsed.has("yes") {
            let reopen = plan.instances.isEmpty ? "no instances" : plan.instances.joined(separator: ", ")
            guard Confirm.ask(
                "Claude \(pending.installedVersion) → \(pending.stagedVersion): every Claude closes, the update installs, "
                    + "then these reopen: \(reopen). Claude Code work in progress is interrupted."
            ) else {
                Output.line("cancelled")
                return
            }
        }

        // Closing the instance this terminal runs in would kill this process mid-update.
        if !parsed.has("foreground"), SelfExecutable.runsInsideClaude(appPath: ctl.appPath) {
            detach(ctl: ctl)
            Output.line("This terminal runs inside a Claude instance, so the update continues in the background.")
            Output.line("You'll get a notification when it's done. Log: \(ctl.paths.updateLogFile.path)")
            return
        }
        try perform(ctl: ctl, system: system, notifier: notifier, parsed: parsed)
    }

    private static func detach(ctl: Orchestrator) {
        Detached.spawn(
            SelfExecutable.path,
            ["update", "apply", "--yes", "--foreground", "--notify"],
            log: ctl.paths.updateLogFile
        )
    }

    private static func perform(ctl: Orchestrator, system: SquirrelUpdateSystem, notifier: UpdateNotifier, parsed: Arguments) throws {
        let banners = parsed.has("notify")
        let stamp = ISO8601DateFormatter()
        if banners { notifier.banner(title: "Updating Claude", message: "Closing every instance, installing, then reopening them…") }
        do {
            let outcome = try ctl.applyUpdate(system: system) { step in
                Output.line("\(stamp.string(from: Date()))  \(step)")
                fflush(stdout)
            }
            let reopened = outcome.reopened.isEmpty ? "none" : outcome.reopened.joined(separator: ", ")
            let headline = outcome.installed
                ? "Claude \(outcome.finalVersion ?? outcome.toVersion) installed"
                : "Update not installed (still \(outcome.finalVersion ?? outcome.fromVersion))"
            var detail = "Reopened: \(reopened)."
            if !outcome.failed.isEmpty {
                detail += " Failed to open: " + outcome.failed.keys.sorted().joined(separator: ", ") + "."
            }
            Output.line(headline)
            Output.line(detail)
            for (name, error) in outcome.failed.sorted(by: { $0.key < $1.key }) { Output.line("  \(name): \(error)") }
            if !outcome.installed {
                Output.line("ShipIt log: \(UpdateInspector.defaultShipItDirectory.appendingPathComponent("ShipIt_stderr.log").path)")
            }
            if banners { notifier.banner(title: headline, message: detail) }
            if !outcome.installed || !outcome.failed.isEmpty { exit(ExitCode.runtime) }
        } catch {
            if banners { notifier.banner(title: "Claude update failed", message: "\(error)") }
            throw error
        }
    }
}
