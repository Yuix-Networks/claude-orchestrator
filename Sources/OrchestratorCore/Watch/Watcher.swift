import Darwin
import Foundation

/// Samples the instances on a timer, records what changed and keeps a live status file.
public final class Watcher {
    public let paths: Paths
    public let interval: TimeInterval
    private let observer: Observer
    private let diagnoser: ExitDiagnoser
    private let journal: EventJournal
    private var detector = Detector()
    private let startedAt: Date
    private var lastSample: Date?
    /// Called for every event, after it has been journaled.
    public var onEvent: ((WatchEvent) -> Void)?
    /// Staged-update check; `nil` turns it off (tests, `--no-update-check`).
    public var updateWatch: UpdateWatch?

    public init(
        paths: Paths = .default,
        appPath: String = ClaudeApp.defaultPath,
        interval: TimeInterval = 3,
        table: ProcessTable = PsProcessTable(),
        logReader: LogReader = LogReader(),
        diagnosticReports: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DiagnosticReports"),
        now: Date = Date()
    ) {
        self.paths = paths
        self.interval = interval
        self.observer = Observer(paths: paths, appPath: appPath, table: table)
        self.diagnoser = ExitDiagnoser(paths: paths, logReader: logReader, diagnosticReports: diagnosticReports)
        self.journal = EventJournal(paths: paths)
        self.startedAt = now
    }

    /// One sample. Returns the events it produced (already journaled).
    @discardableResult
    public func tick(now: Date = Date()) -> [WatchEvent] {
        let snapshot = observer.sample(now: now)
        let raw = detector.process(snapshot, interval: interval)
        let crowded = raw.filter { $0.kind == "exited" }.count > 1
        var events = raw.map { $0.kind == "exited" ? diagnose($0, crowded: crowded) : $0 }
        if let updateWatch {
            let closedByUpdate = events
                .filter { $0.kind == "exited" && $0.details["cause"] == ExitCause.updateRelaunch.rawValue }
                .compactMap(\.instance)
            events += updateWatch.tick(now: now, closedByUpdate: closedByUpdate)
        }
        for event in events {
            journal.append(event)
            onEvent?(event)
        }
        lastSample = now
        writeStatus(snapshot, at: now)
        return events
    }

    /// Records the start, notes any period in which no watcher was running, then samples until `shouldStop`.
    public func run(shouldStop: () -> Bool) {
        let previous = WatcherStatus.read(paths: paths)
        let now = Date()
        if let previous, previous.pid != getpid() {
            let silent = now.timeIntervalSince(previous.updatedAt)
            if silent > max(15, previous.interval * 4) {
                emit(WatchEvent(
                    time: now, severity: .warning, kind: "watcher-restarted",
                    message: "the watcher was not running for \(formatDuration(silent)) (since the last heartbeat); "
                        + "anything that happened in that period went unobserved"
                ))
            }
        }
        emit(WatchEvent(
            time: now, severity: .info, kind: "watcher-start",
            message: "watching every \(Int(interval))s",
            details: ["pid": String(getpid()), "interval": String(Int(interval))]
        ))

        while !shouldStop() {
            tick()
            let deadline = Date().addingTimeInterval(interval)
            while Date() < deadline, !shouldStop() { Thread.sleep(forTimeInterval: 0.25) }
        }
        emit(WatchEvent(time: Date(), severity: .info, kind: "watcher-stop", message: "stopped"))
    }

    // MARK: - Helpers

    private func emit(_ event: WatchEvent) {
        journal.append(event)
        onEvent?(event)
    }

    private func diagnose(_ event: WatchEvent, crowded: Bool) -> WatchEvent {
        guard let instance = event.instance,
              let seen = event.details["lastSeen"].flatMap(TimeInterval.init)
        else { return event }
        let diagnosis = diagnoser.diagnose(
            instance: instance, lastSeen: Date(timeIntervalSince1970: seen), now: event.time, crowded: crowded
        )
        var enriched = event
        enriched.details["cause"] = diagnosis.cause.rawValue
        enriched.details["evidence"] = diagnosis.detail
        switch diagnosis.cause {
        case .orchestratorStop: enriched.severity = .info
        case .gracefulQuit, .updateRelaunch: enriched.severity = .warning
        case .crash, .abrupt: enriched.severity = .error
        }
        enriched.message = "exited (pid \(event.details["pid"] ?? "?"), up \(formatDuration(TimeInterval(event.details["uptime"] ?? "0") ?? 0))): "
            + diagnosis.detail
        return enriched
    }

    private func writeStatus(_ snapshot: Snapshot, at now: Date) {
        let status = WatcherStatus(
            pid: getpid(), startedAt: startedAt, updatedAt: now, interval: interval,
            snapshot: snapshot, conditions: detector.activeConditions
        )
        try? JSONFile.write(status, to: paths.watchStatusFile)
    }
}

/// Summary of a stretch of the event journal.
public struct WatchReport: Equatable {
    public var from: Date
    public var to: Date
    public var counts: [String: Int]
    public var severities: [Severity: Int]
    /// Exit causes per instance.
    public var exits: [String: [String: Int]]
    public var notable: [WatchEvent]

    public init(events: [WatchEvent], from: Date, to: Date) {
        self.from = from
        self.to = to
        counts = [:]
        severities = [:]
        exits = [:]
        for event in events {
            counts[event.kind, default: 0] += 1
            severities[event.severity, default: 0] += 1
            if event.kind == "exited", let instance = event.instance {
                exits[instance, default: [:]][event.details["cause"] ?? "unknown", default: 0] += 1
            }
        }
        notable = events.filter { $0.severity >= .warning }
    }
}
