import Foundation

/// The parts of a controlled update that touch the real system. Tests supply a fake.
public protocol UpdateSystem: AnyObject {
    func pending() -> PendingUpdate?
    func installedVersion() -> String?
    /// Stops ShipIt processes already waiting (they would relaunch the default profile)
    /// and tells the next run not to launch the app.
    func prepareInstaller() throws
    /// Pids of main Claude processes of this app that are still open, any profile.
    func openClaudePids() -> [Int32]
    func terminate(pid: Int32, force: Bool)
    /// Runs the installer and waits until the installed version is `version` or `timeout` passes.
    func install(expecting version: String, timeout: TimeInterval) -> Bool
    func openDefaultClaude() throws
}

/// Squirrel/ShipIt-backed update system.
public final class SquirrelUpdateSystem: UpdateSystem {
    public let inspector: UpdateInspector
    private let appPath: String
    private let table: ProcessTable
    private let scanner: ClaudeProcessScanner

    public init(appPath: String = ClaudeApp.defaultPath, inspector: UpdateInspector? = nil, table: ProcessTable = PsProcessTable()) {
        self.appPath = appPath
        self.table = table
        self.inspector = inspector ?? UpdateInspector(appPath: appPath, table: table)
        self.scanner = ClaudeProcessScanner(appPath: appPath)
    }

    public func pending() -> PendingUpdate? { inspector.pending() }

    public func installedVersion() -> String? { ClaudeApp.version(appPath: appPath) }

    public func prepareInstaller() throws {
        for pid in inspector.waitingShipItPids() { ProcessSignal.terminate(pid) }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !inspector.waitingShipItPids().isEmpty { Thread.sleep(forTimeInterval: 0.2) }
        for pid in inspector.waitingShipItPids() { ProcessSignal.forceKill(pid) }
        try inspector.disableLaunchAfterInstallation()
    }

    public func openClaudePids() -> [Int32] {
        table.entries().filter(scanner.isMain).map(\.pid).sorted()
    }

    public func terminate(pid: Int32, force: Bool) {
        force ? ProcessSignal.forceKill(pid) : ProcessSignal.terminate(pid)
    }

    public func install(expecting version: String, timeout: TimeInterval) -> Bool {
        let executable = inspector.shipItExecutable
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return false }
        let process = Process()
        process.executableURL = executable
        // Same arguments Squirrel uses: the job label and the state file.
        process.arguments = [UpdateInspector.shipItLabel, inspector.stateFile.path]
        process.standardOutput = FileHandle.nullDevice
        if let log = try? FileHandle(forWritingTo: inspector.logFile) {
            _ = try? log.seekToEnd()
            process.standardError = log
        } else {
            process.standardError = FileHandle.nullDevice
        }
        do { try process.run() } catch { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // ShipIt moves the old bundle out before the new one goes in: the version is
            // briefly unreadable, so only a readable, matching version counts.
            if installedVersion() == version, !process.isRunning { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if process.isRunning { process.terminate() }
        return installedVersion() == version
    }

    public func openDefaultClaude() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appPath]
        try process.run()
        process.waitUntilExit()
    }
}

/// Who is open now and what a controlled update would close and reopen.
public struct UpdatePlan: Equatable {
    public var pending: PendingUpdate?
    /// Running instances plus instances that already quit to install the update.
    public var instances: [String]
    public var running: [String]
    public var closedByUpdate: [String]
    public var defaultPid: Int32?
    /// Claude processes with a profile claude-orchestrator doesn't know; they block the update.
    public var strays: [String: Int32]
    /// An earlier update closed instances and never reopened them.
    public var interrupted: UpdateRun?
}

public struct UpdateOutcome: Equatable {
    public var fromVersion: String
    public var toVersion: String
    public var installed: Bool
    public var finalVersion: String?
    public var reopened: [String]
    public var failed: [String: String]
    public var reopenedDefault: Bool
}

extension Orchestrator {
    /// What `update apply` would do right now.
    public func updatePlan(system: UpdateSystem) throws -> UpdatePlan {
        let state = UpdateState.read(paths: paths)
        let names = try store.load().instances.keys.sorted()
        let running = names.filter { launcher.runningPid(profileDir: paths.profileDir($0)) != nil }
        let closed = state.closedByUpdate.filter { names.contains($0) && !running.contains($0) }
        let earlier = state.inProgress.map { $0.instances.filter(names.contains) } ?? []
        var instances = running
        for name in closed + earlier where !instances.contains(name) { instances.append(name) }
        return UpdatePlan(
            pending: system.pending(),
            instances: instances,
            running: running,
            closedByUpdate: closed,
            defaultPid: launcher.runningDefaultPid(),
            strays: observer.sample().strayProfiles,
            interrupted: state.inProgress
        )
    }

    /// Closes every Claude, installs the staged update with Claude's own installer and
    /// opens every instance again, each with its own profile.
    ///
    /// If anything goes wrong after instances were closed, they are reopened anyway
    /// (on whatever version is installed then); the update never leaves them closed.
    public func applyUpdate(
        system: UpdateSystem,
        installTimeout: TimeInterval = 180,
        quitTimeout: TimeInterval = 20,
        progress: (String) -> Void = { _ in }
    ) throws -> UpdateOutcome {
        guard let lock = SingletonLock(url: paths.updateLockFile) else {
            throw OrchestratorError.runtime("an update is already running")
        }
        defer { _ = lock }

        let plan = try updatePlan(system: system)
        guard let pending = plan.pending else {
            if let interrupted = plan.interrupted {
                progress("No update is waiting, but an earlier update left instances closed; reopening them.")
                return finish(run: interrupted, installed: false, system: system, progress: progress)
            }
            throw OrchestratorError.runtime("no Claude update is waiting to be installed")
        }
        if !plan.strays.isEmpty {
            let list = plan.strays.map { "pid \($0.value) (\($0.key))" }.sorted().joined(separator: ", ")
            throw OrchestratorError.runtime(
                "Claude is open with a profile that isn't an instance: \(list). Close it first; the installer waits for every Claude to quit."
            )
        }

        let run = UpdateRun(
            startedAt: Date(), fromVersion: pending.installedVersion, toVersion: pending.stagedVersion,
            instances: plan.instances, defaultWasRunning: plan.defaultPid != nil
        )
        var state = UpdateState.read(paths: paths)
        state.inProgress = run
        state.write(paths: paths)

        progress("Preparing the installer")
        try system.prepareInstaller()

        for name in plan.running {
            progress("Closing \(name)")
            _ = try? stop(name: name)
        }
        if let pid = plan.defaultPid {
            progress("Closing the default Claude (pid \(pid))")
            actions.record(action: "stop", instance: "default")
            system.terminate(pid: pid, force: false)
        }

        guard waitUntilClosed(system: system, timeout: quitTimeout) else {
            let left = system.openClaudePids().map(String.init).joined(separator: ", ")
            progress("Claude is still open (pid \(left)); not installing. Reopening instances.")
            _ = finish(run: run, installed: false, system: system, progress: progress)
            throw OrchestratorError.runtime("Claude didn't quit (pid \(left)); the update was not installed")
        }

        // A quitting Claude may hand the update to a fresh ShipIt (one that would relaunch
        // the default profile); take it over again now that nothing is left to quit.
        try? system.prepareInstaller()

        progress("Installing Claude \(pending.stagedVersion)")
        let installed = system.install(expecting: pending.stagedVersion, timeout: installTimeout)
        if !installed {
            progress("The installer did not finish; reopening instances on the current version.")
        }

        // ShipIt was told not to launch the app, but if a default-profile Claude shows
        // up anyway and none was open before, it is the installer's relaunch: close it.
        if plan.defaultPid == nil, let stray = launcher.runningDefaultPid() {
            system.terminate(pid: stray, force: false)
            _ = waitUntilClosed(system: system, timeout: 10)
        }

        return finish(run: run, installed: installed, system: system, progress: progress)
    }

    private func waitUntilClosed(system: UpdateSystem, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var forced = false
        while true {
            let open = system.openClaudePids()
            if open.isEmpty { return true }
            if Date() >= deadline {
                if forced { return false }
                // Last resort, same as `stop`: SIGKILL, then a short grace period.
                for pid in open { system.terminate(pid: pid, force: true) }
                forced = true
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private func finish(run: UpdateRun, installed: Bool, system: UpdateSystem, progress: (String) -> Void) -> UpdateOutcome {
        var reopened: [String] = []
        var failed: [String: String] = [:]
        for name in run.instances {
            progress("Opening \(name)")
            do {
                _ = try start(name: name, folder: nil)
                reopened.append(name)
            } catch {
                failed[name] = "\(error)"
            }
        }
        var reopenedDefault = false
        if run.defaultWasRunning {
            reopenedDefault = (try? system.openDefaultClaude()) != nil
        }

        var state = UpdateState.read(paths: paths)
        state.inProgress = nil
        state.closedByUpdate = state.closedByUpdate.filter { failed[$0] != nil }
        if installed {
            state.notifiedVersion = nil
            state.notifiedAt = nil
            state.snoozedUntil = nil
        }
        state.write(paths: paths)

        return UpdateOutcome(
            fromVersion: run.fromVersion, toVersion: run.toVersion, installed: installed,
            finalVersion: system.installedVersion(), reopened: reopened, failed: failed,
            reopenedDefault: reopenedDefault
        )
    }
}
