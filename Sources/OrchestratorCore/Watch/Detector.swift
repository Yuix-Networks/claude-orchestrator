import Foundation

/// Turns a stream of snapshots into events. Pure logic: no file or process access.
///
/// Two kinds of output:
/// - **transitions** (an instance started, exited, changed account, a default
///   Claude appeared right after an instance disappeared, …), reported once;
/// - **conditions** (a fault that is true *now*, like a lock held by a process
///   nobody can find), reported when they have lasted `persistTicks` samples and
///   again when they clear, so a single odd sample never raises an alarm.
public struct Detector {
    /// A condition must hold this many samples in a row before it is reported.
    public static let persistTicks = 2

    /// An instance exit and a default-profile Claude start closer than this are linked.
    public var morphWindow: TimeInterval = 20

    private var previous: Snapshot?
    private var counts: [String: Int] = [:]
    private var active: [String: Condition] = [:]
    private var recentExits: [(name: String, pid: Int32, at: Date)] = []
    private var recentDefaultStarts: [(pid: Int32, at: Date)] = []

    public init() {}

    /// Faults that have been confirmed and not yet cleared.
    public var activeConditions: [Condition] {
        active.values.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.key < $1.key }
    }

    public mutating func process(_ snapshot: Snapshot, interval: TimeInterval) -> [WatchEvent] {
        let now = snapshot.takenAt
        var events: [WatchEvent] = []

        if let previous {
            let gap = now.timeIntervalSince(previous.takenAt)
            if gap > max(15, interval * 4) {
                events.append(WatchEvent(
                    time: now, severity: .info, kind: "watcher-gap",
                    message: "No samples for \(formatDuration(gap)) (system sleep or the watcher was paused); "
                        + "changes in that period were not observed",
                    details: ["gapSeconds": String(Int(gap))]
                ))
            }
            events += transitions(from: previous, to: snapshot, gap: gap)
        }

        events += conditionEvents(for: snapshot)
        previous = snapshot
        return events
    }

    // MARK: - Transitions

    private mutating func transitions(from old: Snapshot, to new: Snapshot, gap: TimeInterval) -> [WatchEvent] {
        let now = new.takenAt
        var events: [WatchEvent] = []
        var exitedNames: [String] = []

        for name in new.instances.keys.sorted() {
            guard let current = new.instances[name] else { continue }
            let before = old.instances[name]

            switch (before?.mainPid, current.mainPid) {
            case (nil, let pid?):
                var details = ["pid": String(pid)]
                if let parent = current.parent { details["parent"] = parent }
                events.append(WatchEvent(
                    time: now, severity: .info, kind: "started", instance: name,
                    message: "started (pid \(pid)" + (current.parent.map { ", launched by \($0)" } ?? "") + ")",
                    details: details
                ))
            case let (oldPid?, nil):
                exitedNames.append(name)
                recentExits.append((name, oldPid, now))
                events.append(WatchEvent(
                    time: now, severity: .warning, kind: "exited", instance: name,
                    message: "main process (pid \(oldPid)) is gone",
                    details: [
                        "pid": String(oldPid),
                        "lastSeen": String(Int(old.takenAt.timeIntervalSince1970)),
                        "uptime": String(Int((before?.uptime ?? 0) + now.timeIntervalSince(old.takenAt)))
                    ]
                ))
            case let (oldPid?, newPid?) where oldPid != newPid:
                events.append(WatchEvent(
                    time: now, severity: .warning, kind: "restarted", instance: name,
                    message: "pid changed \(oldPid) → \(newPid) with no exit seen in between (it relaunched itself)",
                    details: ["oldPid": String(oldPid), "pid": String(newPid)]
                ))
            default:
                break
            }

            if let before {
                events += accountTransitions(name: name, before: before, current: current, at: now)
            }
        }

        if exitedNames.count >= 2 {
            events.append(WatchEvent(
                time: now, severity: .error, kind: "simultaneous-exit",
                message: "\(exitedNames.count) instances exited in the same sample (\(exitedNames.joined(separator: ", "))); "
                    + "a shared cause (logout, sleep, parent process, handler) is likely",
                details: ["instances": exitedNames.joined(separator: ",")]
            ))
        }

        for pid in new.defaultMainPids where !old.defaultMainPids.contains(pid) {
            recentDefaultStarts.append((pid, now))
        }
        events += linkMorphs(at: now)
        return events
    }

    private func accountTransitions(
        name: String, before: InstanceObservation, current: InstanceObservation, at now: Date
    ) -> [WatchEvent] {
        var events: [WatchEvent] = []
        if let was = before.accountUuid, let isNow = current.accountUuid, was != isNow {
            events.append(WatchEvent(
                time: now, severity: .error, kind: "account-changed", instance: name,
                message: "signed-in account changed \(was.prefix(8)) → \(isNow.prefix(8))",
                details: ["from": was, "to": isNow]
            ))
        } else if before.accountUuid != nil, current.accountUuid == nil {
            events.append(WatchEvent(
                time: now, severity: .warning, kind: "account-lost", instance: name,
                message: "profile no longer names a signed-in account (config.json lost it)"
            ))
        }
        if before.signedIn, !current.signedIn {
            events.append(WatchEvent(
                time: now, severity: .warning, kind: "signed-out", instance: name,
                message: "cookie file disappeared; the profile looks signed out"
            ))
        }
        return events
    }

    /// An instance vanished and a Claude **without** `--user-data-dir` appeared around
    /// the same time: the instance probably relaunched itself as the default profile
    /// (which is signed in as the default account), or something else opened the default app.
    private mutating func linkMorphs(at now: Date) -> [WatchEvent] {
        var events: [WatchEvent] = []
        var exits = recentExits
        var starts = recentDefaultStarts
        for exit in recentExits {
            guard let match = starts.firstIndex(where: { abs($0.at.timeIntervalSince(exit.at)) <= morphWindow }) else { continue }
            let start = starts.remove(at: match)
            exits.removeAll { $0.name == exit.name && $0.pid == exit.pid }
            events.append(WatchEvent(
                time: now, severity: .warning, kind: "morphed-to-default", instance: exit.name,
                message: "main process (pid \(exit.pid)) exited and a default-profile Claude (pid \(start.pid), "
                    + "no --user-data-dir) appeared within \(Int(morphWindow))s: the instance may have "
                    + "relaunched without its profile flag, which shows the default account",
                details: ["instancePid": String(exit.pid), "defaultPid": String(start.pid)]
            ))
        }
        let horizon = morphWindow * 2
        recentExits = exits.filter { now.timeIntervalSince($0.at) <= horizon }
        recentDefaultStarts = starts.filter { now.timeIntervalSince($0.at) <= horizon }
        return events
    }

    // MARK: - Conditions

    private mutating func conditionEvents(for snapshot: Snapshot) -> [WatchEvent] {
        let now = snapshot.takenAt
        let current = Dictionary(Self.conditions(for: snapshot).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [WatchEvent] = []

        for (key, condition) in current.sorted(by: { $0.key < $1.key }) {
            counts[key, default: 0] += 1
            if counts[key] == Self.persistTicks, active[key] == nil {
                active[key] = condition
                events.append(WatchEvent(
                    time: now, severity: condition.severity, kind: condition.kind,
                    instance: condition.instance, message: condition.message
                ))
            } else if active[key] != nil {
                active[key] = condition
            }
        }
        for key in counts.keys where current[key] == nil {
            counts[key] = nil
            if let cleared = active.removeValue(forKey: key) {
                events.append(WatchEvent(
                    time: now, severity: .info, kind: "\(cleared.kind)-resolved", instance: cleared.instance,
                    message: "no longer true: \(cleared.message)"
                ))
            }
        }
        return events
    }

    /// Faults visible in a single snapshot. Also used by the live screen, without the debounce.
    public static func conditions(for snapshot: Snapshot) -> [Condition] {
        var result: [Condition] = []

        for name in snapshot.instances.keys.sorted() {
            guard let item = snapshot.instances[name] else { continue }

            if item.mainPid == nil, item.lockAlive || item.helperCount > 0 {
                var evidence: [String] = []
                if item.lockAlive, let pid = item.lockPid { evidence.append("profile lock held by live pid \(pid)") }
                if item.helperCount > 0 { evidence.append("\(item.helperCount) helper process(es) running") }
                result.append(Condition(
                    key: "hidden-instance:\(name)", kind: "hidden-instance", severity: .error, instance: name,
                    message: "\(evidence.joined(separator: ", ")) but no main process carries the profile flag: "
                        + "the instance is alive yet shows as stopped"
                ))
            } else if item.mainPid == nil, let pid = item.lockPid, !item.lockAlive {
                result.append(Condition(
                    key: "lock-stale:\(name)", kind: "lock-stale", severity: .warning, instance: name,
                    message: "stale profile lock left by dead pid \(pid) (the previous run did not shut down cleanly)"
                ))
            } else if let main = item.mainPid, item.lockAlive, let lock = item.lockPid, lock != main {
                result.append(Condition(
                    key: "lock-mismatch:\(name)", kind: "lock-mismatch", severity: .warning, instance: name,
                    message: "profile lock names pid \(lock) but the main process is pid \(main)"
                ))
            }
        }

        var byAccount: [String: [String]] = [:]
        for (name, item) in snapshot.instances {
            if let uuid = item.accountUuid { byAccount[uuid, default: []].append(name) }
        }
        for (uuid, names) in byAccount where names.count > 1 {
            result.append(Condition(
                key: "identity-collision:\(uuid)", kind: "identity-collision", severity: .error, instance: nil,
                message: "\(names.sorted().joined(separator: ", ")) are all signed in as the same account (\(uuid.prefix(8)))"
            ))
        }

        for (path, pid) in snapshot.strayProfiles.sorted(by: { $0.key < $1.key }) {
            result.append(Condition(
                key: "stray-profile:\(path)", kind: "stray-profile", severity: .warning, instance: nil,
                message: "Claude pid \(pid) runs on an unregistered profile: \(path)"
            ))
        }
        return result
    }
}
