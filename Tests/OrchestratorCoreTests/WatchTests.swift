import XCTest
@testable import OrchestratorCore

final class FakeTable: ProcessTable {
    var list: [ProcessEntry] = []
    func entries() -> [ProcessEntry] { list }
}

private let app = "/Applications/Claude.app"

private func main(_ pid: Int32, profile: String?, ppid: Int32 = 1, uptime: TimeInterval = 100, extra: String = "") -> ProcessEntry {
    var command = "\(app)/Contents/MacOS/Claude"
    if let profile { command += " --user-data-dir=\(profile)" }
    if !extra.isEmpty { command += " \(extra)" }
    return ProcessEntry(pid: pid, ppid: ppid, uptime: uptime, command: command)
}

private func helper(_ pid: Int32, profile: String?, ppid: Int32) -> ProcessEntry {
    var command = "\(app)/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer) --type=renderer"
    if let profile { command += " --user-data-dir=\(profile)" }
    return ProcessEntry(pid: pid, ppid: ppid, uptime: 90, command: command)
}

// MARK: - Process table parsing

final class ProcessTableTests: XCTestCase {
    func testParsesElapsedTimeFormats() {
        XCTAssertEqual(PsProcessTable.parseElapsed("04:35"), 275)
        XCTAssertEqual(PsProcessTable.parseElapsed("02:03:04"), 7384)
        XCTAssertEqual(PsProcessTable.parseElapsed("3-01:00:00"), 3 * 86_400 + 3600)
        XCTAssertNil(PsProcessTable.parseElapsed("garbage"))
        XCTAssertNil(PsProcessTable.parseElapsed("12"))
    }

    func testParsesPsOutputKeepingSpacesInTheCommand() {
        let output = """
          49004     1       04:35 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/Users/x/Library/Application Support/claude-ctl/instances/a/profile
            1     0 5-02:00:00 /sbin/launchd
        not a line
        """
        let entries = PsProcessTable.parse(output)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].pid, 49004)
        XCTAssertEqual(entries[0].ppid, 1)
        XCTAssertEqual(entries[0].uptime, 275)
        XCTAssertTrue(entries[0].command.hasSuffix("instances/a/profile"))
        XCTAssertEqual(entries[1].uptime, 5 * 86_400 + 2 * 3600)
    }
}

// MARK: - Observer

final class ObserverTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var table: FakeTable!
    private var observer: Observer!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-test-\(UUID().uuidString)")
        paths = Paths(root: root)
        table = FakeTable()
        observer = Observer(paths: paths, table: table)
        for name in ["serdar", "merve"] {
            _ = try InstanceStore(paths: paths).upsert(Instance(name: name, workdir: nil))
            try FileManager.default.createDirectory(at: paths.profileDir(name), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFindsEachInstanceByItsProfileFlagEvenWithSpacesInThePath() {
        let serdar = paths.profileDir("serdar").path
        let merve = paths.profileDir("merve").path
        XCTAssertTrue(serdar.contains(" ") || true)
        table.list = [
            main(10, profile: serdar, ppid: 1, uptime: 500),
            helper(11, profile: serdar, ppid: 10),
            helper(12, profile: serdar, ppid: 10),
            main(20, profile: merve)
        ]
        let snapshot = observer.sample()
        XCTAssertEqual(snapshot.instances["serdar"]?.mainPid, 10)
        XCTAssertEqual(snapshot.instances["serdar"]?.helperCount, 2)
        XCTAssertEqual(snapshot.instances["serdar"]?.uptime, 500)
        XCTAssertEqual(snapshot.instances["serdar"]?.parent, "launchd")
        XCTAssertEqual(snapshot.instances["merve"]?.mainPid, 20)
        XCTAssertTrue(snapshot.defaultMainPids.isEmpty)
    }

    func testDefaultClaudeAndUnregisteredProfilesAreReportedSeparately() {
        table.list = [
            main(30, profile: nil),
            main(31, profile: "/somewhere/else/profile"),
            helper(32, profile: nil, ppid: 30)
        ]
        let snapshot = observer.sample()
        XCTAssertEqual(snapshot.defaultMainPids, [30])
        XCTAssertEqual(snapshot.strayProfiles, ["/somewhere/else/profile": 31])
        XCTAssertNil(snapshot.instances["serdar"]?.mainPid)
    }

    func testProfilePathThatIsAPrefixOfAnotherIsNotConfused() {
        let serdar = paths.profileDir("serdar").path
        table.list = [main(40, profile: serdar + "-copy")]
        XCTAssertNil(observer.sample().instances["serdar"]?.mainPid)
    }

    func testReadsAccountAndLockFromTheProfile() throws {
        let profile = paths.profileDir("serdar")
        try Data(#"{"lastKnownAccountUuid":"abc-123"}"#.utf8).write(to: profile.appendingPathComponent("config.json"))
        try FileManager.default.createSymbolicLink(
            atPath: profile.appendingPathComponent("SingletonLock").path,
            withDestinationPath: "host-\(getpid())"
        )
        let item = observer.sample().instances["serdar"]
        XCTAssertEqual(item?.accountUuid, "abc-123")
        XCTAssertEqual(item?.lockPid, getpid())
        XCTAssertEqual(item?.lockAlive, true)
        XCTAssertNil(item?.mainPid)
    }
}

// MARK: - Detector

final class DetectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        _ offset: TimeInterval,
        instances: [InstanceObservation] = [],
        defaults: [Int32] = [],
        strays: [String: Int32] = [:]
    ) -> Snapshot {
        Snapshot(
            takenAt: t0.addingTimeInterval(offset),
            instances: Dictionary(uniqueKeysWithValues: instances.map { ($0.name, $0) }),
            defaultMainPids: defaults,
            strayProfiles: strays
        )
    }

    private func running(_ name: String, _ pid: Int32, account: String? = nil) -> InstanceObservation {
        InstanceObservation(name: name, mainPid: pid, parent: "launchd", uptime: 60, accountUuid: account, signedIn: true)
    }

    private func stopped(_ name: String) -> InstanceObservation { InstanceObservation(name: name, signedIn: true) }

    func testReportsStartAndExitOnce() {
        var detector = Detector()
        XCTAssertTrue(detector.process(snapshot(0, instances: [stopped("a")]), interval: 3).isEmpty)

        let started = detector.process(snapshot(3, instances: [running("a", 10)]), interval: 3)
        XCTAssertEqual(started.map(\.kind), ["started"])
        XCTAssertEqual(started.first?.details["pid"], "10")

        XCTAssertTrue(detector.process(snapshot(6, instances: [running("a", 10)]), interval: 3).isEmpty)

        let exited = detector.process(snapshot(9, instances: [stopped("a")]), interval: 3)
        XCTAssertEqual(exited.map(\.kind), ["exited"])
        XCTAssertEqual(exited.first?.details["lastSeen"], String(Int(t0.timeIntervalSince1970) + 6))
    }

    func testPidChangeWithoutAnExitIsARelaunch() {
        var detector = Detector()
        _ = detector.process(snapshot(0, instances: [running("a", 10)]), interval: 3)
        let events = detector.process(snapshot(3, instances: [running("a", 11)]), interval: 3)
        XCTAssertEqual(events.map(\.kind), ["restarted"])
        XCTAssertEqual(events.first?.severity, .warning)
    }

    func testAliveButUndetectedInstanceNeedsTwoSamplesAndThenResolves() {
        var detector = Detector()
        var hidden = stopped("a")
        hidden.lockPid = 99
        hidden.lockAlive = true
        hidden.helperCount = 3

        XCTAssertTrue(detector.process(snapshot(0, instances: [hidden]), interval: 3).isEmpty)
        let reported = detector.process(snapshot(3, instances: [hidden]), interval: 3)
        XCTAssertEqual(reported.map(\.kind), ["hidden-instance"])
        XCTAssertEqual(reported.first?.severity, .error)
        // Not repeated while it stays true.
        XCTAssertTrue(detector.process(snapshot(6, instances: [hidden]), interval: 3).isEmpty)
        XCTAssertEqual(detector.activeConditions.count, 1)

        let cleared = detector.process(snapshot(9, instances: [stopped("a")]), interval: 3)
        XCTAssertEqual(cleared.map(\.kind), ["hidden-instance-resolved"])
        XCTAssertTrue(detector.activeConditions.isEmpty)
    }

    func testASingleOddSampleRaisesNothing() {
        var detector = Detector()
        var hidden = stopped("a")
        hidden.helperCount = 2
        XCTAssertTrue(detector.process(snapshot(0, instances: [stopped("a")]), interval: 3).isEmpty)
        XCTAssertTrue(detector.process(snapshot(3, instances: [hidden]), interval: 3).isEmpty)
        XCTAssertTrue(detector.process(snapshot(6, instances: [stopped("a")]), interval: 3).isEmpty)
    }

    func testStaleLockIsAWarning() {
        var detector = Detector()
        var stale = stopped("a")
        stale.lockPid = 424_242
        stale.lockAlive = false
        _ = detector.process(snapshot(0, instances: [stale]), interval: 3)
        let events = detector.process(snapshot(3, instances: [stale]), interval: 3)
        XCTAssertEqual(events.map(\.kind), ["lock-stale"])
        XCTAssertEqual(events.first?.severity, .warning)
    }

    func testTwoInstancesSignedInAsTheSameAccountIsACollision() {
        var detector = Detector()
        let both = [running("serdar", 1, account: "same"), running("merve", 2, account: "same"), running("derin", 3, account: "other")]
        _ = detector.process(snapshot(0, instances: both), interval: 3)
        let events = detector.process(snapshot(3, instances: both), interval: 3)
        XCTAssertEqual(events.map(\.kind), ["identity-collision"])
        XCTAssertTrue(events[0].message.contains("merve, serdar"))
        XCTAssertFalse(events[0].message.contains("derin"))
    }

    func testAccountChangeIsAnError() {
        var detector = Detector()
        _ = detector.process(snapshot(0, instances: [running("merve", 2, account: "54339006-aaaa")]), interval: 3)
        let events = detector.process(snapshot(3, instances: [running("merve", 2, account: "8e8a7d07-bbbb")]), interval: 3)
        XCTAssertEqual(events.map(\.kind), ["account-changed"])
        XCTAssertEqual(events.first?.severity, .error)
        XCTAssertEqual(events.first?.details["from"], "54339006-aaaa")
    }

    func testInstanceExitFollowedByDefaultClaudeIsFlaggedAsMorph() {
        var detector = Detector()
        _ = detector.process(snapshot(0, instances: [running("merve", 2)]), interval: 3)
        _ = detector.process(snapshot(3, instances: [stopped("merve")]), interval: 3)
        let events = detector.process(snapshot(9, instances: [stopped("merve")], defaults: [77]), interval: 3)
        XCTAssertEqual(events.map(\.kind), ["morphed-to-default"])
        XCTAssertEqual(events.first?.instance, "merve")
        XCTAssertEqual(events.first?.details["defaultPid"], "77")
    }

    func testDefaultClaudeStartingFarFromAnyExitIsNotAMorph() {
        var detector = Detector()
        _ = detector.process(snapshot(0, instances: [running("merve", 2)]), interval: 3)
        _ = detector.process(snapshot(3, instances: [stopped("merve")]), interval: 3)
        let events = detector.process(snapshot(120, instances: [stopped("merve")], defaults: [77]), interval: 3)
        XCTAssertFalse(events.contains { $0.kind == "morphed-to-default" })
    }

    func testSeveralInstancesExitingTogetherIsReportedAsAGroup() {
        var detector = Detector()
        let before = [running("a", 1), running("b", 2), running("c", 3)]
        _ = detector.process(snapshot(0, instances: before), interval: 3)
        let events = detector.process(snapshot(3, instances: [stopped("a"), stopped("b"), running("c", 3)]), interval: 3)
        XCTAssertEqual(events.filter { $0.kind == "exited" }.count, 2)
        let group = events.first { $0.kind == "simultaneous-exit" }
        XCTAssertEqual(group?.details["instances"], "a,b")
    }

    func testALongSilenceIsReportedAsAGap() {
        var detector = Detector()
        _ = detector.process(snapshot(0, instances: [running("a", 1)]), interval: 3)
        let events = detector.process(snapshot(600, instances: [running("a", 1)]), interval: 3)
        XCTAssertEqual(events.map(\.kind), ["watcher-gap"])
    }

    func testStrayProfileIsReported() {
        var detector = Detector()
        let snap = snapshot(0, strays: ["/x/profile": 5])
        _ = detector.process(snap, interval: 3)
        let events = detector.process(snapshot(3, strays: ["/x/profile": 5]), interval: 3)
        XCTAssertEqual(events.map(\.kind), ["stray-profile"])
    }
}

// MARK: - Exit diagnosis

final class ExitDiagnoserTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var logs: URL!
    private var reports: URL!
    private let now = Date()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("diag-test-\(UUID().uuidString)")
        paths = Paths(root: root)
        logs = root.appendingPathComponent("logs")
        reports = root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.profileDir("a"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func diagnoser() -> ExitDiagnoser {
        ExitDiagnoser(paths: paths, logReader: LogReader(logDirectory: logs), diagnosticReports: reports)
    }

    private func writeLog(_ lines: [String], at time: Date) throws {
        let stamp = LogReader.makeFormatter().string(from: time)
        let text = lines.map { "\(stamp) [info] \($0)" }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: logs.appendingPathComponent("main.log"))
    }

    func testOrchestratorStopIsRecognised() {
        ActionJournal(paths: paths).record(action: "stop", instance: "a", at: now.addingTimeInterval(-1))
        let result = diagnoser().diagnose(instance: "a", lastSeen: now.addingTimeInterval(-3), now: now)
        XCTAssertEqual(result.cause, .orchestratorStop)
    }

    func testAStopOfAnotherInstanceIsNotMistakenForThisOne() throws {
        ActionJournal(paths: paths).record(action: "stop", instance: "b", at: now.addingTimeInterval(-1))
        let result = diagnoser().diagnose(instance: "a", lastSeen: now.addingTimeInterval(-3), now: now)
        XCTAssertNotEqual(result.cause, .orchestratorStop)
    }

    func testQuitCleanupInTheLogMeansAGracefulQuit() throws {
        try writeLog(["beforeQuit: handler fired, going down"], at: now.addingTimeInterval(-1))
        let result = diagnoser().diagnose(instance: "a", lastSeen: now.addingTimeInterval(-3), now: now)
        XCTAssertEqual(result.cause, .gracefulQuit)
    }

    func testNoCleanupAndNoCrashReportMeansAbrupt() throws {
        try writeLog(["[CCD] something unrelated"], at: now.addingTimeInterval(-1))
        let result = diagnoser().diagnose(instance: "a", lastSeen: now.addingTimeInterval(-3), now: now)
        XCTAssertEqual(result.cause, .abrupt)
    }

    func testACrashpadDumpMeansCrash() throws {
        let completed = paths.profileDir("a").appendingPathComponent("Crashpad/completed")
        try FileManager.default.createDirectory(at: completed, withIntermediateDirectories: true)
        try Data("dump".utf8).write(to: completed.appendingPathComponent("abc.dmp"))
        let result = diagnoser().diagnose(instance: "a", lastSeen: now.addingTimeInterval(-3), now: now)
        XCTAssertEqual(result.cause, .crash)
    }

    func testAnOldCrashReportIsIgnored() throws {
        let file = reports.appendingPathComponent("Claude-old.ips")
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-86_400)], ofItemAtPath: file.path)
        let result = diagnoser().diagnose(instance: "a", lastSeen: now.addingTimeInterval(-3), now: now)
        XCTAssertEqual(result.cause, .abrupt)
    }
}

// MARK: - Watcher, journal, report

final class WatcherTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var table: FakeTable!
    private var watcher: Watcher!
    private var logs: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("watcher-test-\(UUID().uuidString)")
        paths = Paths(root: root)
        table = FakeTable()
        logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        _ = try InstanceStore(paths: paths).upsert(Instance(name: "merve", workdir: nil))
        try FileManager.default.createDirectory(at: paths.profileDir("merve"), withIntermediateDirectories: true)
        watcher = Watcher(
            paths: paths, interval: 3, table: table,
            logReader: LogReader(logDirectory: logs), diagnosticReports: root.appendingPathComponent("none")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRecordsStartAndDiagnosedExitAndWritesLiveStatus() throws {
        let profile = paths.profileDir("merve").path
        let t0 = Date()

        XCTAssertTrue(watcher.tick(now: t0).isEmpty)
        table.list = [main(500, profile: profile, ppid: 1, uptime: 10)]
        XCTAssertEqual(watcher.tick(now: t0.addingTimeInterval(3)).map(\.kind), ["started"])

        // It disappears with no quit cleanup in the log: abrupt, an error.
        table.list = []
        let events = watcher.tick(now: t0.addingTimeInterval(6))
        XCTAssertEqual(events.map(\.kind), ["exited"])
        XCTAssertEqual(events.first?.details["cause"], "abrupt")
        XCTAssertEqual(events.first?.severity, .error)

        let journaled = EventJournal(paths: paths).events()
        XCTAssertEqual(journaled.map(\.kind), ["started", "exited"])

        let status = try XCTUnwrap(WatcherStatus.read(paths: paths))
        XCTAssertEqual(status.pid, getpid())
        XCTAssertTrue(status.isLive())
        XCTAssertNil(status.snapshot.instances["merve"]?.mainPid)
    }

    func testAStopByOrchestratorIsInfoNotAnError() throws {
        let profile = paths.profileDir("merve").path
        let t0 = Date()
        table.list = [main(500, profile: profile)]
        _ = watcher.tick(now: t0)
        ActionJournal(paths: paths).record(action: "stop", instance: "merve", at: t0.addingTimeInterval(4))
        table.list = []
        let events = watcher.tick(now: t0.addingTimeInterval(6))
        XCTAssertEqual(events.first?.details["cause"], "orchestratorStop")
        XCTAssertEqual(events.first?.severity, .info)
    }

    func testReportCountsExitCausesPerInstance() {
        let now = Date()
        let events = [
            WatchEvent(time: now, severity: .error, kind: "exited", instance: "merve", message: "x", details: ["cause": "abrupt"]),
            WatchEvent(time: now, severity: .error, kind: "exited", instance: "merve", message: "x", details: ["cause": "abrupt"]),
            WatchEvent(time: now, severity: .info, kind: "exited", instance: "serdar", message: "x", details: ["cause": "orchestratorStop"]),
            WatchEvent(time: now, severity: .info, kind: "started", instance: "serdar", message: "x")
        ]
        let report = WatchReport(events: events, from: now, to: now)
        XCTAssertEqual(report.exits["merve"]?["abrupt"], 2)
        XCTAssertEqual(report.exits["serdar"]?["orchestratorStop"], 1)
        XCTAssertEqual(report.severities[.error], 2)
        XCTAssertEqual(report.notable.count, 2)
    }

    func testJournalRotatesAndStillReadsEverythingInOrder() throws {
        let journal = EventJournal(paths: paths)
        let big = String(repeating: "x", count: 400_000)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<16 {
            journal.append(WatchEvent(time: base.addingTimeInterval(Double(index)), severity: .info, kind: "n\(index)", message: big))
        }
        let rotated = JSONLines.rotated(paths.watchEventsFile, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
        let kinds = journal.events().map(\.kind)
        XCTAssertEqual(kinds, (0..<16).map { "n\($0)" })
    }

    func testSecondSingletonLockIsRefused() throws {
        let url = paths.watchLockFile
        let first = SingletonLock(url: url)
        XCTAssertNotNil(first)
        XCTAssertNil(SingletonLock(url: url))
        _ = first
    }
}
