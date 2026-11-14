import OrchestratorCore
import Foundation

/// What the interactive screens show live, refreshed about once a second.
///
/// One process listing per refresh, however many profiles there are. A fault is
/// shown only once it has been seen in two refreshes in a row, so the moment a
/// window is opening or closing never flashes a warning.
final class LiveTracker {
    private let ctl: Orchestrator
    private var previousKeys: Set<String> = []
    private var recentAt = Date.distantPast

    private(set) var snapshot: Snapshot
    private(set) var issues: [Condition] = []
    /// The background watcher's heartbeat, only while it is alive.
    private(set) var watcher: WatcherStatus?
    /// The latest warnings and errors from the journal (newest last).
    private(set) var recent: [WatchEvent] = []
    private(set) var refreshedAt = Date()

    init(ctl: Orchestrator) {
        self.ctl = ctl
        snapshot = ctl.observer.sample()
        previousKeys = Set(Detector.conditions(for: snapshot).map(\.key))
        refreshWatcher()
    }

    func refresh() {
        snapshot = ctl.observer.sample()
        refreshedAt = snapshot.takenAt
        let conditions = Detector.conditions(for: snapshot)
        issues = conditions.filter { previousKeys.contains($0.key) }
        previousKeys = Set(conditions.map(\.key))
        refreshWatcher()
    }

    func issues(for name: String) -> [Condition] {
        issues.filter { $0.instance == name }
    }

    private func refreshWatcher() {
        let status = WatcherStatus.read(paths: ctl.paths)
        watcher = (status?.isLive() ?? false) ? status : nil
        // Reading the journal parses every line; do it every few seconds, not every refresh.
        if Date().timeIntervalSince(recentAt) >= 10 {
            recentAt = Date()
            recent = Array(
                EventJournal(paths: ctl.paths)
                    .events(since: Date().addingTimeInterval(-24 * 3600))
                    .filter { $0.severity >= .warning }
                    .suffix(3)
            )
        }
    }

    // MARK: - Rendering

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func clockText(_ date: Date) -> String { clock.string(from: date) }

    /// Short label for the end of a profile row.
    static func badge(_ condition: Condition) -> String {
        switch condition.kind {
        case "hidden-instance": return "✖ alive but not detected"
        case "lock-stale": return "⚠ stale lock"
        case "lock-mismatch": return "⚠ lock/pid mismatch"
        default: return "⚠ \(condition.kind)"
        }
    }

    /// Lines for the bottom of the home screen: default app, watcher, faults, recent events.
    func footerLines(width: Int) -> [String] {
        let rule = Style.dim + String(repeating: "─", count: max(0, min(width, 72) - 1)) + Style.reset
        var lines = [rule]

        if !snapshot.defaultMainPids.isEmpty {
            let pids = snapshot.defaultMainPids.map(String.init).joined(separator: ", ")
            lines.append(Style.dim + "Default Claude (not a profile)  " + Style.reset + Style.accent + "● running" + Style.reset
                + Style.dim + "  pid \(pids)" + Style.reset)
        }
        if let watcher {
            let faults = watcher.conditions.count
            lines.append(Style.dim + "Watcher  " + Style.reset + Style.accent + "● live" + Style.reset
                + Style.dim + " · pid \(watcher.pid) · " + Style.reset
                + (faults == 0 ? Style.dim + "no faults" : Style.warning + "\(faults) fault\(faults == 1 ? "" : "s")") + Style.reset)
        } else {
            lines.append(Style.dim + "Watcher  " + Style.reset + Style.warning + "○ not running" + Style.reset
                + Style.dim + " — nothing is being recorded. Run: claude-orchestrator watch --install" + Style.reset)
        }

        for issue in issues {
            let color = issue.severity == .error ? Style.warning : Style.dim
            let text = (issue.severity == .error ? "✖ " : "⚠ ") + issue.message
            for (index, part) in text.wrapped(max(20, min(width, 100) - 2)).enumerated() {
                lines.append(color + (index == 0 ? "" : "  ") + part + Style.reset)
            }
        }

        if !recent.isEmpty {
            lines.append(Style.dim + "Recent problems (last 24h):" + Style.reset)
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            for event in recent {
                let who = event.instance.map { "[\(WatchEventText.display($0))] " } ?? ""
                let text = "\(formatter.string(from: event.time)) \(event.severity == .error ? "✖" : "⚠") \(who)\(event.message)"
                lines.append(Style.dim + "  " + text.fitted(max(20, min(width, 100) - 2)) + Style.reset)
            }
        }
        return lines
    }
}

enum WatchEventText {
    static func display(_ name: String) -> String { SessionMoveInteractive.display(name) }
}
