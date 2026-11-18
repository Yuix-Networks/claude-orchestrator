import Foundation

/// The watcher's update check: notices a staged Claude update and tells the user,
/// once per version and again after a snooze, before Claude restarts itself.
public final class UpdateWatch {
    public let paths: Paths
    private let system: UpdateSystem
    /// Called with the update, the instances that would restart, and those that already closed.
    private let announce: (PendingUpdate, [String], [String]) -> Void
    private let runningInstances: () -> [String]
    public var checkEvery: TimeInterval = 60
    public var remindEvery: TimeInterval = 6 * 3600
    private var lastCheck: Date?

    public init(
        paths: Paths,
        system: UpdateSystem,
        runningInstances: @escaping () -> [String],
        announce: @escaping (PendingUpdate, [String], [String]) -> Void
    ) {
        self.paths = paths
        self.system = system
        self.runningInstances = runningInstances
        self.announce = announce
    }

    /// - Parameter closedByUpdate: instances that just quit to install an update; they force
    ///   an immediate notification and are reopened by the next controlled update.
    public func tick(now: Date = Date(), closedByUpdate: [String] = []) -> [WatchEvent] {
        var state = UpdateState.read(paths: paths)
        if !closedByUpdate.isEmpty {
            for name in closedByUpdate where !state.closedByUpdate.contains(name) { state.closedByUpdate.append(name) }
            state.write(paths: paths)
        }
        let forced = !closedByUpdate.isEmpty
        if !forced, let lastCheck, now.timeIntervalSince(lastCheck) < checkEvery { return [] }
        lastCheck = now

        // A controlled update is running (it holds the lock): it closes and reopens
        // instances on purpose. A record without the lock is an interrupted run; keep notifying.
        if state.inProgress != nil, SingletonLock(url: paths.updateLockFile) == nil { return [] }

        guard let pending = system.pending() else {
            if state.notifiedVersion != nil || state.snoozedUntil != nil || !state.closedByUpdate.isEmpty {
                state.notifiedVersion = nil
                state.notifiedAt = nil
                state.snoozedUntil = nil
                state.write(paths: paths)
            }
            return []
        }

        let newVersion = state.notifiedVersion != pending.stagedVersion
        let remindAt = state.snoozedUntil ?? state.notifiedAt.map { $0.addingTimeInterval(remindEvery) } ?? now
        guard forced || newVersion || now >= remindAt else { return [] }

        let running = runningInstances()
        announce(pending, running, state.closedByUpdate)
        state.notifiedVersion = pending.stagedVersion
        state.notifiedAt = now
        state.snoozedUntil = now.addingTimeInterval(remindEvery)
        state.write(paths: paths)

        var details = [
            "installed": pending.installedVersion,
            "staged": pending.stagedVersion,
            "running": running.joined(separator: ",")
        ]
        if !state.closedByUpdate.isEmpty { details["closedByUpdate"] = state.closedByUpdate.joined(separator: ",") }
        return [WatchEvent(
            time: now, severity: .warning, kind: "update-pending",
            message: "Claude \(pending.stagedVersion) is staged (installed \(pending.installedVersion)); "
                + "notified the user — `claude-orchestrator update apply` restarts every instance onto it",
            details: details
        )]
    }
}
