import Darwin
import OrchestratorAgent
import OrchestratorCore
import Foundation

/// `claude-orchestrator watch [--interval N] [--json] [--quiet]`
/// `claude-orchestrator watch status [--json]`
/// `claude-orchestrator watch report [--since 24h] [--all] [--json]`
/// `claude-orchestrator watch --install | --uninstall`
enum WatchCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(
            args, allowed: ["interval", "json", "quiet", "install", "uninstall", "since", "all"]
        )
        switch parsed.positionals.first {
        case nil: break
        case "status": return try status(parsed)
        case "report": return try report(parsed)
        case let other?: throw OrchestratorError.usage("watch: unknown subcommand '\(other)' (status, report)")
        }

        if parsed.has("uninstall") {
            try LaunchAgentInstaller(label: LaunchAgentInstaller.watchLabel).uninstall()
            Output.line("watcher login item removed (the journal is kept)")
            return
        }
        if parsed.has("install") {
            let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "/usr/local/bin/claude-orchestrator")
                .standardizedFileURL.path
            let url = try LaunchAgentInstaller(label: LaunchAgentInstaller.watchLabel)
                .install(executablePath: executable, arguments: ["watch", "--quiet"], processType: "Background")
            Output.line("watcher installed: \(url.path)")
            Output.line("  it runs in the background from login on and restarts if it dies")
            Output.line("  see what it found: claude-orchestrator watch report")
            return
        }
        try foreground(parsed)
    }

    // MARK: - Foreground watcher

    private static func foreground(_ parsed: Arguments) throws {
        let interval = try parseInterval(parsed.optionalFlag("interval"))
        let ctl = Orchestrator()
        guard let lock = SingletonLock(url: ctl.paths.watchLockFile) else {
            let pid = WatcherStatus.read(paths: ctl.paths).map { " (pid \($0.pid))" } ?? ""
            Output.line("a watcher is already running\(pid); see it with: claude-orchestrator watch status")
            exit(ExitCode.success)
        }
        _ = lock  // held until the process exits

        let json = parsed.has("json")
        let quiet = parsed.has("quiet")
        let watcher = Watcher(paths: ctl.paths, interval: interval)
        let notifier = UpdateNotifier(appPath: ctl.appPath)
        watcher.updateWatch = UpdateWatch(
            paths: ctl.paths,
            system: SquirrelUpdateSystem(appPath: ctl.appPath),
            runningInstances: { ((try? ctl.list(includeSizes: false)) ?? []).filter(\.isRunning).map(\.name) },
            announce: { pending, running, closed in
                notifier.announce(pending, instances: running, closedByUpdate: closed)
            }
        )
        watcher.onEvent = { event in
            if json {
                if let data = try? JSONLines.encode(event), let line = String(data: data, encoding: .utf8) { print(line) }
            } else if !quiet {
                print(format(event))
            }
            fflush(stdout)
        }

        var stop: sig_atomic_t = 0
        let sources = [SIGINT, SIGTERM].map { signalNumber -> DispatchSourceSignal in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { stop = 1 }
            source.resume()
            return source
        }
        _ = sources

        if !json, !quiet {
            Output.line("Watching every \(Int(interval))s — Ctrl-C to stop. Journal: \(ctl.paths.watchEventsFile.path)")
        }
        watcher.run(shouldStop: { stop != 0 })
    }

    private static func parseInterval(_ text: String?) throws -> TimeInterval {
        guard let text else { return 3 }
        guard let value = TimeInterval(text), value >= 1, value <= 300 else {
            throw OrchestratorError.usage("watch: --interval must be between 1 and 300 seconds")
        }
        return value
    }

    // MARK: - status

    private static func status(_ parsed: Arguments) throws {
        let ctl = Orchestrator()
        let snapshot = ctl.observer.sample()
        let conditions = Detector.conditions(for: snapshot)
        let watcher = WatcherStatus.read(paths: ctl.paths)
        let live = watcher?.isLive() ?? false

        if parsed.has("json") {
            let enc = JSONLines.encoder()
            struct Out: Encodable {
                var schemaVersion = 1
                var watcherRunning: Bool
                var watcherPid: Int32?
                var snapshot: Snapshot
                var conditions: [Condition]
            }
            let out = Out(watcherRunning: live, watcherPid: live ? watcher?.pid : nil, snapshot: snapshot, conditions: conditions)
            print(String(decoding: try enc.encode(out), as: UTF8.self))
            return
        }

        Output.line(live
            ? "watcher:   running (pid \(watcher?.pid ?? 0), up \(formatDuration(Date().timeIntervalSince(watcher?.startedAt ?? Date()))))"
            : "watcher:   NOT running — nothing is being recorded. Start it: claude-orchestrator watch --install")
        Output.line("")
        for name in snapshot.instances.keys.sorted() {
            guard let item = snapshot.instances[name] else { continue }
            let state = item.mainPid.map { "running  pid \($0)  up \(formatDuration(item.uptime ?? 0))" } ?? "stopped"
            let account = item.accountUuid.map { String($0.prefix(8)) } ?? "-"
            Output.line("\(name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(state.padding(toLength: 34, withPad: " ", startingAt: 0)) account \(account)")
        }
        if !snapshot.defaultMainPids.isEmpty {
            Output.line("\n(default Claude, not an instance: pid \(snapshot.defaultMainPids.map(String.init).joined(separator: ", ")))")
        }
        Output.line("")
        if conditions.isEmpty {
            Output.line("no faults right now")
        } else {
            for condition in conditions { Output.line("\(mark(condition.severity)) \(condition.message)") }
        }
    }

    // MARK: - report

    private static func report(_ parsed: Arguments) throws {
        let ctl = Orchestrator()
        let window = try parseSince(parsed.optionalFlag("since") ?? "24h")
        let now = Date()
        let events = EventJournal(paths: ctl.paths).events(since: now.addingTimeInterval(-window))
        let summary = WatchReport(events: events, from: events.first?.time ?? now, to: now)

        if parsed.has("json") {
            let shown = parsed.has("all") ? events : summary.notable
            print(String(decoding: try JSONLines.encoder().encode(shown), as: UTF8.self))
            return
        }

        guard !events.isEmpty else {
            Output.line("no events in the last \(formatDuration(window)).")
            if !(WatcherStatus.read(paths: ctl.paths)?.isLive() ?? false) {
                Output.line("The watcher is not running. Start it: claude-orchestrator watch --install")
            }
            return
        }

        Output.line("Observed \(formatDuration(now.timeIntervalSince(summary.from))) "
            + "(\(events.count) events: \(summary.severities[.error] ?? 0) errors, \(summary.severities[.warning] ?? 0) warnings)")
        if !summary.exits.isEmpty {
            Output.line("\nExits by cause:")
            for name in summary.exits.keys.sorted() {
                let causes = summary.exits[name]!.sorted { $0.key < $1.key }.map { "\($0.value)× \($0.key)" }
                Output.line("  \(name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(causes.joined(separator: ", "))")
            }
        }
        let faultKinds = ["hidden-instance", "identity-collision", "account-changed", "morphed-to-default",
                          "simultaneous-exit", "restarted", "update-pending", "lock-stale", "lock-mismatch", "stray-profile"]
        let faults = faultKinds.compactMap { kind in summary.counts[kind].map { "\($0)× \(kind)" } }
        if !faults.isEmpty { Output.line("\nFaults: \(faults.joined(separator: ", "))") }

        let listed = parsed.has("all") ? events : summary.notable
        Output.line("\n\(parsed.has("all") ? "All events" : "Warnings and errors") (oldest first):")
        for event in listed.suffix(parsed.has("all") ? 500 : 100) { Output.line("  " + format(event)) }
        if !parsed.has("all"), events.count > listed.count {
            Output.line("\n(\(events.count - listed.count) routine events hidden; --all shows everything)")
        }
    }

    private static func parseSince(_ text: String) throws -> TimeInterval {
        guard let unit = text.last, let number = Double(text.dropLast()), number > 0 else {
            throw OrchestratorError.usage("watch: --since looks like 30m, 24h or 7d")
        }
        switch unit {
        case "m": return number * 60
        case "h": return number * 3600
        case "d": return number * 86_400
        default: throw OrchestratorError.usage("watch: --since looks like 30m, 24h or 7d")
        }
    }

    // MARK: - Formatting

    private static func mark(_ severity: Severity) -> String {
        switch severity {
        case .info: return " "
        case .warning: return "⚠"
        case .error: return "✖"
        }
    }

    static func format(_ event: WatchEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        let who = event.instance.map { "[\($0)] " } ?? ""
        return "\(formatter.string(from: event.time)) \(mark(event.severity)) \(event.kind.padding(toLength: 18, withPad: " ", startingAt: 0)) \(who)\(event.message)"
    }
}
