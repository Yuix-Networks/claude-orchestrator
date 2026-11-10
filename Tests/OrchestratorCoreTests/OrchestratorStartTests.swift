import XCTest
@testable import OrchestratorCore

/// Fake launcher so tests never start the real Claude.
final class FakeLauncher: Launching {
    var runningPids: [String: Int32] = [:]
    var launchCount = 0
    var lastRequest: LaunchRequest?
    var launchShouldFail = false
    var defaultPid: Int32?

    func runningDefaultPid() -> Int32? { defaultPid }

    func launchArguments(_ request: LaunchRequest) -> [String] { [] }

    func isProfileLocked(profileDir: URL) -> Bool {
        let lock = profileDir.appendingPathComponent("SingletonLock").path
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: lock)) != nil {
            return true
        }
        return FileManager.default.fileExists(atPath: lock)
    }

    func lockHolderPid(profileDir: URL) -> Int32? {
        let lock = profileDir.appendingPathComponent("SingletonLock")
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lock.path) else {
            return nil
        }
        return Int32(target.split(separator: "-").last.map(String.init) ?? "")
    }

    /// If set, `runningPid` only reports a pid while this returns `true`.
    var runningPidCheck: (() -> Bool)?

    func runningPid(profileDir: URL) -> Int32? {
        if let runningPidCheck, !runningPidCheck() { return nil }
        return runningPids[profileDir.path]
    }

    func launch(_ request: LaunchRequest) throws {
        launchCount += 1
        lastRequest = request
        if launchShouldFail {
            throw OrchestratorError.runtime("fake launch failure")
        }
        runningPids[request.profileDir] = 4242
    }
}

final class OrchestratorStartTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var launcher: FakeLauncher!
    private var ctl: Orchestrator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-ctl-test-\(UUID().uuidString)")
        paths = Paths(root: root)
        launcher = FakeLauncher()
        ctl = Orchestrator(paths: paths, launcher: launcher)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func makeWorkdir(_ name: String = "proj") throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - new

    func testNewCreatesInstanceAndItsDirectories() throws {
        let workdir = try makeWorkdir()

        let instance = try ctl.new(name: "work", workdir: workdir.path)

        XCTAssertEqual(instance.name, "work")
        XCTAssertEqual(instance.workdir, workdir.path)
        let config = try XCTUnwrap(JSONFile.read(Config.self, from: paths.configFile))
        XCTAssertEqual(config.instances["work"]?.workdir, workdir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.profileDir("work").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.codeDir("work").path))
    }

    func testNewRejectsDuplicateName() throws {
        try ctl.new(name: "work", workdir: nil)

        XCTAssertThrowsError(try ctl.new(name: "work", workdir: nil)) { error in
            guard case let .runtime(message) = error as? OrchestratorError else {
                return XCTFail("expected runtime: \(error)")
            }
            XCTAssertTrue(message.contains("already exists"), "message should contain 'already exists': \(message)")
        }
    }

    func testNewRejectsInvalidName() throws {
        XCTAssertThrowsError(try ctl.new(name: "../x", workdir: nil)) { error in
            guard case .invalidName = error as? OrchestratorError else {
                return XCTFail("expected invalidName: \(error)")
            }
        }
    }

    // MARK: - start

    func testStartReturnsAlreadyRunningWithoutLaunching() throws {
        try ctl.new(name: "work", workdir: nil)
        launcher.runningPids[paths.profileDir("work").path] = 777

        let result = try ctl.start(name: "work", folder: nil)

        XCTAssertTrue(result.alreadyRunning)
        XCTAssertEqual(result.pid, 777)
        XCTAssertEqual(launcher.launchCount, 0, "a running instance must not be restarted")
    }

    func testStartFailsWhenProfileIsLockedByALiveProcess() throws {
        try ctl.new(name: "work", workdir: nil)
        let profile = paths.profileDir("work")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let lock = profile.appendingPathComponent("SingletonLock")
        try FileManager.default.createSymbolicLink(
            at: lock,
            withDestinationURL: URL(fileURLWithPath: "host-\(ProcessInfo.processInfo.processIdentifier)")
        )

        XCTAssertThrowsError(try ctl.start(name: "work", folder: nil)) { error in
            guard case let .runtime(message) = error as? OrchestratorError else {
                return XCTFail("expected runtime: \(error)")
            }
            XCTAssertTrue(message.contains("SingletonLock"), "message should contain 'SingletonLock': \(message)")
            XCTAssertTrue(message.contains("pid"), "message should contain the pid holding the lock: \(message)")
        }
        XCTAssertEqual(launcher.launchCount, 0)
    }

    func testStartProceedsWhenProfileHasStaleLock() throws {
        try ctl.new(name: "work", workdir: nil)
        let profile = paths.profileDir("work")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let lock = profile.appendingPathComponent("SingletonLock")
        try FileManager.default.createSymbolicLink(
            at: lock,
            withDestinationURL: URL(fileURLWithPath: "host-999999")
        )

        let result = try ctl.start(name: "work", folder: nil)

        XCTAssertFalse(result.alreadyRunning)
        XCTAssertEqual(launcher.launchCount, 1, "the stale lock should be cleared and the instance opened")
    }

    func testStartWarnsWhenWorkdirIsMissing() throws {
        let missing = root.appendingPathComponent("missing-\(UUID().uuidString)").path
        try ctl.new(name: "work", workdir: missing)

        let result = try ctl.start(name: "work", folder: nil)

        XCTAssertFalse(result.alreadyRunning)
        XCTAssertNotNil(result.warning)
        XCTAssertTrue(result.warning?.contains("workdir") == true, "warning should contain 'workdir': \(result.warning ?? "-")")
        XCTAssertNil(result.seed, "seeding should be skipped")
        XCTAssertEqual(launcher.launchCount, 1, "the instance should still be opened")
    }

    func testStartSeedsWorkdirAndRecordsState() throws {
        let workdir = try makeWorkdir()
        try ctl.new(name: "work", workdir: workdir.path)

        let result = try ctl.start(name: "work", folder: nil)

        XCTAssertFalse(result.alreadyRunning)
        XCTAssertEqual(result.pid, 4242)
        XCTAssertNotNil(result.seed)
        XCTAssertNil(result.warning)

        // Seeding happens during both `new` and `start`; as a result
        // the workdir should be among the profile's trusted folders.
        let configData = try Data(contentsOf: paths.profileDir("work").appendingPathComponent("claude_desktop_config.json"))
        let configJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: configData) as? [String: Any])
        let preferences = try XCTUnwrap(configJSON["preferences"] as? [String: Any])
        let trusted = try XCTUnwrap(preferences["localAgentModeTrustedFolders"] as? [String])
        XCTAssertTrue(trusted.contains(workdir.path), "workdir should be in the trusted folders: \(trusted)")

        let state = try XCTUnwrap(JSONFile.read(InstanceState.self, from: paths.stateFile("work")))
        XCTAssertEqual(state.pid, 4242)
        XCTAssertEqual(state.claudeVersion, ClaudeApp.version())
    }

    func testStartPassesFolderAsExtraArgument() throws {
        try ctl.new(name: "work", workdir: nil)

        _ = try ctl.start(name: "work", folder: "/tmp/project")

        XCTAssertEqual(launcher.lastRequest?.extraArgs, ["/tmp/project"])
    }

    func testStartThrowsWhenLaunchFails() throws {
        try ctl.new(name: "work", workdir: nil)
        launcher.launchShouldFail = true

        XCTAssertThrowsError(try ctl.start(name: "work", folder: nil))
    }

    func testStartThrowsNotFoundForUnknownInstance() throws {
        XCTAssertThrowsError(try ctl.start(name: "missing", folder: nil)) { error in
            guard case .notFound = error as? OrchestratorError else {
                return XCTFail("expected notFound: \(error)")
            }
        }
    }

    // MARK: - stop

    func testStopTerminatesRunningProcess() throws {
        // The process is started in the background via a shell: when the shell exits the
        // process is reparented to init, so it never becomes a zombie during the test
        // (kill(pid, 0) also succeeds on a zombie).
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Output goes to /dev/null so the background job doesn't hold the pipe's write end.
        shell.arguments = ["-c", "sleep 60 >/dev/null 2>&1 & echo $!"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        let pidData = pipe.fileHandleForReading.availableData
        shell.waitUntilExit()
        let pidText = String(data: pidData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pid = try XCTUnwrap(Int32(pidText))
        XCTAssertTrue(ProcessSignal.isAlive(pid))

        try ctl.new(name: "work", workdir: nil)
        try JSONFile.write(
            InstanceState(pid: pid, startedAt: Date(), claudeVersion: nil),
            to: paths.stateFile("work")
        )
        // Only a process verified via the marker is terminated.
        launcher.runningPids[paths.profileDir("work").path] = pid

        let result = try ctl.stop(name: "work")

        XCTAssertTrue(result.wasRunning)
        XCTAssertFalse(result.forced, "a normal shutdown should not need force")
        XCTAssertFalse(ProcessSignal.isAlive(pid), "the process should terminate")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.stateFile("work").path),
            "the state file should be removed"
        )
    }

    func testStopReportsNotRunningWhenStateFileIsMissing() throws {
        try ctl.new(name: "work", workdir: nil)

        let result = try ctl.stop(name: "work")

        XCTAssertFalse(result.wasRunning)
        XCTAssertFalse(result.forced)
    }

    func testStopReportsNotRunningForDeadProcess() throws {
        try ctl.new(name: "work", workdir: nil)
        try JSONFile.write(
            InstanceState(pid: 999_999, startedAt: Date(), claudeVersion: nil),
            to: paths.stateFile("work")
        )

        let result = try ctl.stop(name: "work")

        XCTAssertFalse(result.wasRunning)
    }

    // MARK: - remove

    func testRemoveDeletesInstanceFromConfig() throws {
        try ctl.new(name: "work", workdir: nil)

        try ctl.remove(name: "work", purge: false)

        XCTAssertTrue(try JSONFile.read(Config.self, from: paths.configFile)?.instances.isEmpty ?? true)
    }

    func testRemoveKeepsProfileDirectoryByDefault() throws {
        try ctl.new(name: "work", workdir: nil)
        let profile = paths.profileDir("work")
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.path))

        try ctl.remove(name: "work", purge: false)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: profile.path),
            "the profile folder should be kept by default"
        )
    }

    func testRemoveWithPurgeDeletesProfileDirectory() throws {
        try ctl.new(name: "work", workdir: nil)
        let profile = paths.profileDir("work")

        try ctl.remove(name: "work", purge: true, permanent: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.path))
    }

    func testRemoveThrowsNotFoundForUnknownInstance() throws {
        XCTAssertThrowsError(try ctl.remove(name: "missing", purge: false)) { error in
            guard case .notFound = error as? OrchestratorError else {
                return XCTFail("expected notFound: \(error)")
            }
        }
    }

    // MARK: - stop safety

    func testStopDoesNotKillUnrelatedProcessRecordedInState() throws {
        // The pid in state.json is no longer Claude; since it isn't verified via the marker
        // it must not be killed (PID reuse scenario).
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 60 >/dev/null 2>&1 & echo $!"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        let pidData = pipe.fileHandleForReading.availableData
        shell.waitUntilExit()
        let pidText = String(data: pidData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pid = try XCTUnwrap(Int32(pidText))

        try ctl.new(name: "work", workdir: nil)
        try JSONFile.write(
            InstanceState(pid: pid, startedAt: Date(), claudeVersion: nil),
            to: paths.stateFile("work")
        )

        let result = try ctl.stop(name: "work")

        XCTAssertFalse(result.wasRunning, "an unverified pid must not be killed")
        XCTAssertTrue(ProcessSignal.isAlive(pid), "an unrelated process must not be killed")
        _ = try? ProcessSignal.terminate(pid)
    }

    func testStopUsesMarkerVerifiedPidEvenWithoutStateFile() throws {
        try ctl.new(name: "work", workdir: nil)
        launcher.runningPids[paths.profileDir("work").path] = 4242

        let result = try ctl.stop(name: "work")

        XCTAssertTrue(result.wasRunning)
    }

    // MARK: - seeding failure

    func testStartWarnsWhenSeedingFailsButStillLaunches() throws {
        let workdir = try makeWorkdir()
        try ctl.new(name: "work", workdir: workdir.path)
        // A corrupt profile config makes seeding fail.
        try "{{{{ bozuk".write(
            to: paths.profileDir("work").appendingPathComponent("claude_desktop_config.json"),
            atomically: true,
            encoding: .utf8
        )

        let result = try ctl.start(name: "work", folder: nil)

        XCTAssertNil(result.seed)
        XCTAssertNotNil(result.warning)
        XCTAssertTrue(result.warning?.contains("seeding failed") == true, "warning should contain 'seeding failed': \(result.warning ?? "-")")
        XCTAssertEqual(launcher.launchCount, 1, "the instance should still be opened")
    }

    // MARK: - remove safety

    func testRemoveRefusesWhileInstanceIsRunning() throws {
        try ctl.new(name: "work", workdir: nil)
        launcher.runningPids[paths.profileDir("work").path] = 4242

        XCTAssertThrowsError(try ctl.remove(name: "work", purge: true)) { error in
            guard case let .runtime(message) = error as? OrchestratorError else {
                return XCTFail("expected runtime: \(error)")
            }
            XCTAssertTrue(message.contains("is running"), "message should contain 'is running': \(message)")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paths.profileDir("work").path),
            "a running instance's profile must not be deleted"
        )
    }

    func testRemoveWithForceStopsRunningInstanceBeforeDeletingData() throws {
        try ctl.new(name: "work", workdir: nil)
        // Send signals to a real process: a `sleep` we start ourselves instead of a fake pid.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        let profile = paths.profileDir("work").path
        launcher.runningPids[profile] = sleeper.processIdentifier
        // Once the process dies, the fake launcher should also report "not running".
        launcher.runningPidCheck = { [weak sleeper] in sleeper?.isRunning == true }

        try ctl.remove(name: "work", purge: true, force: true, permanent: true)

        sleeper.waitUntilExit()
        XCTAssertFalse(sleeper.isRunning, "should be stopped first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile))
        XCTAssertThrowsError(try ctl.store.instance(named: "work"))
    }

    func testRemoveClearsStateFile() throws {
        try ctl.new(name: "work", workdir: nil)
        try JSONFile.write(
            InstanceState(pid: 42, startedAt: Date(), claudeVersion: nil),
            to: paths.stateFile("work")
        )

        try ctl.remove(name: "work", purge: false)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.stateFile("work").path),
            "the state file should be removed"
        )
    }

    // MARK: - logs

    func testLogsReturnsOnlyLinesSinceInstanceStart() throws {
        let logDirectory = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let before = formatter.string(from: Date(timeIntervalSince1970: 1_699_999_000))
        let after = formatter.string(from: Date(timeIntervalSince1970: 1_700_000_500))
        try "\(before) [info] [A] old line\n\(after) [info] [A] new line\n"
            .write(to: logDirectory.appendingPathComponent("main.log"), atomically: true, encoding: .utf8)

        let reader = LogReader(logDirectory: logDirectory)
        let scoped = Orchestrator(paths: paths, launcher: launcher, logReader: reader)
        try scoped.new(name: "work", workdir: nil)
        try JSONFile.write(
            InstanceState(pid: 42, startedAt: start, claudeVersion: nil),
            to: paths.stateFile("work")
        )

        let lines = try scoped.logs(name: "work", lines: 50)

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("new line"))
    }
}
