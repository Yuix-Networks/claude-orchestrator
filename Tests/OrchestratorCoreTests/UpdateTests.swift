import XCTest
@testable import OrchestratorCore

private func makeApp(at url: URL, version: String) throws {
    let contents = url.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleShortVersionString": version]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
}

final class VersionOrderTests: XCTestCase {
    func testComparesNumerically() {
        XCTAssertTrue(VersionOrder.isNewer("6.6395.1", than: "5.11492.5"))
        XCTAssertTrue(VersionOrder.isNewer("6.10.0", than: "6.9.3"))
        XCTAssertTrue(VersionOrder.isNewer("6.1", than: "6.0.9"))
        XCTAssertFalse(VersionOrder.isNewer("6.0", than: "6.0.0"))
        XCTAssertFalse(VersionOrder.isNewer("5.9", than: "6.0"))
    }
}

final class UpdateInspectorTests: XCTestCase {
    private var root: URL!
    private var appPath: String!
    private var shipIt: URL!
    private var inspector: UpdateInspector!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("update-test-\(UUID().uuidString)")
        appPath = root.appendingPathComponent("Applications/Claude.app").path
        shipIt = root.appendingPathComponent("ShipIt")
        try makeApp(at: URL(fileURLWithPath: appPath), version: "5.11492.5")
        inspector = UpdateInspector(appPath: appPath, shipItDirectory: shipIt, table: FakeTable())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Squirrel writes the state as JSON with escaped slashes, despite the `.plist` name.
    private func writeState(staged: String?, target: String? = nil) throws {
        let bundle = shipIt.appendingPathComponent("update.Ab12/Claude.app")
        if let staged { try makeApp(at: bundle, version: staged) }
        let state: [String: Any] = [
            "launchAfterInstallation": true,
            "updateBundleURL": bundle.absoluteString,
            "targetBundleURL": target ?? URL(fileURLWithPath: appPath).absoluteString + "/",
            "bundleIdentifier": "com.anthropic.claudefordesktop",
            "useUpdateBundleName": true
        ]
        try FileManager.default.createDirectory(at: shipIt, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: state).write(to: inspector.stateFile)
    }

    func testNoStateMeansNoUpdate() {
        XCTAssertNil(inspector.pending())
    }

    func testFindsANewerStagedBundle() throws {
        try writeState(staged: "6.6395.1")
        let pending = try XCTUnwrap(inspector.pending())
        XCTAssertEqual(pending.installedVersion, "5.11492.5")
        XCTAssertEqual(pending.stagedVersion, "6.6395.1")
    }

    func testIgnoresAStagedBundleThatIsAlreadyInstalled() throws {
        try writeState(staged: "5.11492.5")
        XCTAssertNil(inspector.pending())
    }

    func testIgnoresAMissingStagedBundle() throws {
        try writeState(staged: nil)
        XCTAssertNil(inspector.pending())
    }

    func testIgnoresAnUpdateForAnotherCopyOfTheApp() throws {
        try writeState(staged: "6.6395.1", target: "file:///Applications/Other.app/")
        XCTAssertNil(inspector.pending())
    }

    func testDisablingTheRelaunchKeepsTheStateAsJSON() throws {
        try writeState(staged: "6.6395.1")
        try inspector.disableLaunchAfterInstallation()
        let data = try Data(contentsOf: inspector.stateFile)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["launchAfterInstallation"] as? Bool, false)
        XCTAssertNotNil(object["updateBundleURL"])
        XCTAssertNotNil(inspector.pending())
    }

    func testFindsWaitingShipItProcesses() {
        let table = FakeTable()
        table.list = [
            ProcessEntry(pid: 81898, ppid: 1, uptime: 10, command: "/Applications/Claude.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt com.anthropic.claudefordesktop.ShipIt /Users/x/Library/Caches/com.anthropic.claudefordesktop.ShipIt/ShipItState.plist"),
            ProcessEntry(pid: 500, ppid: 1, uptime: 10, command: "/Applications/Bitwarden.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt com.bitwarden.desktop.ShipIt /x")
        ]
        let inspector = UpdateInspector(appPath: appPath, shipItDirectory: shipIt, table: table)
        XCTAssertEqual(inspector.waitingShipItPids(), [81898])
    }

    func testReadsTheUpdateAttemptMarker() throws {
        let profile = root.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data(#"{"fromVersion":"5.11492.5","toVersion":"Claude 6.6395.1","ts":1795044342770}"#.utf8)
            .write(to: profile.appendingPathComponent("update-attempt"))
        XCTAssertEqual(UpdateMarker.attemptTime(profileDir: profile)?.timeIntervalSince1970 ?? 0, 1_795_044_342.77, accuracy: 0.01)
    }
}

/// In-memory update system: never touches the real app or ShipIt.
final class FakeUpdateSystem: UpdateSystem {
    var installed = "5.0"
    var staged: String? = "6.0"
    var installSucceeds = true
    var openPids: [Int32] = []
    var prepared = false
    var installCalls = 0
    var terminated: [Int32] = []
    var openedDefault = 0
    /// Processes ignore every signal and never leave the list.
    var stubborn = false

    func pending() -> PendingUpdate? {
        guard let staged, VersionOrder.isNewer(staged, than: installed) else { return nil }
        return PendingUpdate(installedVersion: installed, stagedVersion: staged, stagedBundle: "/tmp/Claude.app")
    }
    func installedVersion() -> String? { installed }
    func prepareInstaller() throws { prepared = true }
    func openClaudePids() -> [Int32] { openPids }
    func terminate(pid: Int32, force: Bool) {
        terminated.append(pid)
        if !stubborn { openPids.removeAll { $0 == pid } }
    }
    func install(expecting version: String, timeout: TimeInterval) -> Bool {
        installCalls += 1
        if installSucceeds { installed = version }
        return installSucceeds
    }
    func openDefaultClaude() throws { openedDefault += 1 }
}

final class ApplyUpdateTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var launcher: FakeLauncher!
    private var ctl: Orchestrator!
    private var system: FakeUpdateSystem!
    private var children: [Process] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("apply-test-\(UUID().uuidString)")
        paths = Paths(root: root)
        launcher = FakeLauncher()
        ctl = Orchestrator(paths: paths, processTable: FakeTable(), launcher: launcher)
        system = FakeUpdateSystem()
        for name in ["serdar", "derin", "merve"] { _ = try ctl.new(name: name, workdir: nil) }
    }

    override func tearDownWithError() throws {
        for child in children where child.isRunning { child.terminate() }
        try? FileManager.default.removeItem(at: root)
    }

    /// A real, harmless process standing in for a running instance, so `stop` has something to signal.
    private func markRunning(_ name: String) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        children.append(child)
        launcher.runningPids[paths.profileDir(name).path] = child.processIdentifier
    }

    func testClosesInstallsAndReopensEveryRunningInstance() throws {
        try markRunning("serdar")
        try markRunning("derin")
        let outcome = try ctl.applyUpdate(system: system, quitTimeout: 2)

        XCTAssertTrue(system.prepared)
        XCTAssertEqual(system.installCalls, 1)
        XCTAssertTrue(outcome.installed)
        XCTAssertEqual(outcome.finalVersion, "6.0")
        XCTAssertEqual(outcome.reopened, ["derin", "serdar"])
        XCTAssertTrue(outcome.failed.isEmpty)
        // `stop` really signalled both stand-in processes before the install.
        children.forEach { $0.waitUntilExit() }
        XCTAssertTrue(children.allSatisfy { !$0.isRunning })
        XCTAssertNil(UpdateState.read(paths: paths).inProgress)
    }

    func testReopensAnInstanceThatAlreadyQuitToInstallTheUpdate() throws {
        try markRunning("serdar")
        UpdateState(closedByUpdate: ["merve"]).write(paths: paths)

        let plan = try ctl.updatePlan(system: system)
        XCTAssertEqual(plan.instances, ["serdar", "merve"])
        XCTAssertEqual(plan.closedByUpdate, ["merve"])

        let outcome = try ctl.applyUpdate(system: system, quitTimeout: 2)
        XCTAssertEqual(Set(outcome.reopened), ["serdar", "merve"])
        XCTAssertEqual(UpdateState.read(paths: paths).closedByUpdate, [])
    }

    func testReopensInstancesEvenWhenTheInstallerFails() throws {
        try markRunning("derin")
        system.installSucceeds = false
        let outcome = try ctl.applyUpdate(system: system, quitTimeout: 2)
        XCTAssertFalse(outcome.installed)
        XCTAssertEqual(outcome.finalVersion, "5.0")
        XCTAssertEqual(outcome.reopened, ["derin"])
        XCTAssertNil(UpdateState.read(paths: paths).inProgress)
    }

    func testDoesNotInstallWhileAClaudeRefusesToQuit() throws {
        try markRunning("derin")
        let stubborn = FakeUpdateSystem()
        stubborn.stubborn = true
        stubborn.openPids = [999_999]
        XCTAssertThrowsError(try ctl.applyUpdate(system: stubborn, quitTimeout: 0.5))
        XCTAssertEqual(stubborn.installCalls, 0)
        // derin was closed for the update and reopened anyway: nothing is left in progress.
        children.forEach { $0.waitUntilExit() }
        XCTAssertFalse(children[0].isRunning)
        XCTAssertNil(UpdateState.read(paths: paths).inProgress)
    }

    func testReopensTheDefaultClaudeIfItWasOpen() throws {
        launcher.defaultPid = 777
        let outcome = try ctl.applyUpdate(system: system, quitTimeout: 2)
        XCTAssertEqual(system.terminated.first, 777)
        XCTAssertTrue(outcome.reopenedDefault)
        XCTAssertEqual(system.openedDefault, 1)
    }

    func testRefusesWhenNothingIsStaged() {
        system.staged = nil
        XCTAssertThrowsError(try ctl.applyUpdate(system: system))
    }

    func testAnInterruptedUpdateIsFinishedByReopeningItsInstances() throws {
        system.staged = nil
        UpdateState(inProgress: UpdateRun(
            startedAt: Date(), fromVersion: "5.0", toVersion: "6.0", instances: ["merve"], defaultWasRunning: false
        )).write(paths: paths)
        let outcome = try ctl.applyUpdate(system: system)
        XCTAssertEqual(outcome.reopened, ["merve"])
        XCTAssertEqual(system.installCalls, 0)
        XCTAssertNil(UpdateState.read(paths: paths).inProgress)
    }
}

final class UpdateWatchTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var system: FakeUpdateSystem!
    private var announcements: [(PendingUpdate, [String], [String])] = []
    private var watch: UpdateWatch!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("updatewatch-test-\(UUID().uuidString)")
        paths = Paths(root: root)
        system = FakeUpdateSystem()
        announcements = []
        watch = UpdateWatch(paths: paths, system: system, runningInstances: { ["derin", "serdar"] }) { [unowned self] in
            self.announcements.append(($0, $1, $2))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAnnouncesANewVersionOnceThenRemindsAfterTheSnooze() {
        let start = Date()
        let events = watch.tick(now: start)
        XCTAssertEqual(events.map(\.kind), ["update-pending"])
        XCTAssertEqual(announcements.count, 1)
        XCTAssertEqual(announcements[0].1, ["derin", "serdar"])

        XCTAssertTrue(watch.tick(now: start.addingTimeInterval(120)).isEmpty)
        XCTAssertTrue(watch.tick(now: start.addingTimeInterval(3600)).isEmpty)
        XCTAssertEqual(announcements.count, 1)

        _ = watch.tick(now: start.addingTimeInterval(6 * 3600 + 1))
        XCTAssertEqual(announcements.count, 2)
    }

    func testAnInstanceClosingForTheUpdateAnnouncesRightAway() {
        let start = Date()
        _ = watch.tick(now: start)
        _ = watch.tick(now: start.addingTimeInterval(5), closedByUpdate: ["merve"])
        XCTAssertEqual(announcements.count, 2)
        XCTAssertEqual(announcements[1].2, ["merve"])
        XCTAssertEqual(UpdateState.read(paths: paths).closedByUpdate, ["merve"])
    }

    func testANewerStagedVersionIsAnnouncedEvenWhileSnoozed() {
        let start = Date()
        _ = watch.tick(now: start)
        system.staged = "7.0"
        _ = watch.tick(now: start.addingTimeInterval(61))
        XCTAssertEqual(announcements.count, 2)
        XCTAssertEqual(announcements[1].0.stagedVersion, "7.0")
    }

    func testStaysQuietWhileAControlledUpdateRuns() {
        UpdateState(inProgress: UpdateRun(
            startedAt: Date(), fromVersion: "5.0", toVersion: "6.0", instances: [], defaultWasRunning: false
        )).write(paths: paths)
        let lock = SingletonLock(url: paths.updateLockFile)
        XCTAssertNotNil(lock)
        XCTAssertTrue(watch.tick().isEmpty)
        withExtendedLifetime(lock) {}
        XCTAssertTrue(announcements.isEmpty)
    }

    func testClearsTheReminderOnceTheUpdateIsInstalled() {
        _ = watch.tick(now: Date())
        system.installed = "6.0"
        _ = watch.tick(now: Date().addingTimeInterval(61))
        XCTAssertNil(UpdateState.read(paths: paths).notifiedVersion)
    }
}

final class UpdateExitDiagnosisTests: XCTestCase {
    func testAnExitRightAfterAnUpdateAttemptIsBlamedOnTheUpdate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diag-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(root: root)
        let profile = paths.profileDir("merve")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let exitTime = Date()
        let millis = Int((exitTime.timeIntervalSince1970 - 2) * 1000)
        try Data(#"{"ts":\#(millis)}"#.utf8).write(to: profile.appendingPathComponent("update-attempt"))

        let diagnoser = ExitDiagnoser(paths: paths, logReader: LogReader(logDirectory: root), diagnosticReports: root)
        let result = diagnoser.diagnose(instance: "merve", lastSeen: exitTime.addingTimeInterval(-3), now: exitTime)
        XCTAssertEqual(result.cause, .updateRelaunch)
    }
}
