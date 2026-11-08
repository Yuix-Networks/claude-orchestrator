import XCTest
@testable import OrchestratorAgent
@testable import OrchestratorCore

/// Agent testleri için sahte launcher.
final class FakeLauncher: Launching {
    var runningPids: [String: Int32] = [:]

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
    func runningPid(profileDir: URL) -> Int32? { runningPids[profileDir.path] }
    func launch(_ request: LaunchRequest) throws { runningPids[request.profileDir] = 4242 }
}

final class AgentModelTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var launcher: FakeLauncher!
    private var ctl: Orchestrator!
    private var model: AgentModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-ctl-test-\(UUID().uuidString)")
        paths = Paths(root: root)
        launcher = FakeLauncher()
        ctl = Orchestrator(paths: paths, launcher: launcher)
        model = AgentModel(ctl: ctl)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    func testRefreshReportsRunningState() throws {
        try ctl.new(name: "work", workdir: nil)
        launcher.runningPids[paths.profileDir("work").path] = 777

        let statuses = model.refresh()

        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses.first?.name, "work")
        XCTAssertTrue(statuses.first?.isRunning == true)
        XCTAssertEqual(statuses.first?.pid, 777)
    }

    func testRefreshReportsStoppedState() throws {
        try ctl.new(name: "work", workdir: nil)

        let statuses = model.refresh()

        XCTAssertEqual(statuses.first?.isRunning, false)
        XCTAssertNil(statuses.first?.pid)
    }

    func testMenuForRunningInstanceEnablesActivateAndStop() throws {
        try ctl.new(name: "work", workdir: nil)
        launcher.runningPids[paths.profileDir("work").path] = 777
        let status = try XCTUnwrap(model.refresh().first)

        let items = model.menuItems(for: status)

        let activate = items.first { $0.action == .activate }
        let stop = items.first { $0.action == .stop }
        XCTAssertEqual(activate?.isEnabled, true)
        XCTAssertEqual(stop?.isEnabled, true)
    }

    func testMenuForStoppedInstanceDisablesStop() throws {
        try ctl.new(name: "work", workdir: nil)
        let status = try XCTUnwrap(model.refresh().first)

        let items = model.menuItems(for: status)

        XCTAssertEqual(items.first { $0.action == .stop }?.isEnabled, false)
        XCTAssertEqual(items.first { $0.action == .activate }?.isEnabled, false)
        XCTAssertEqual(items.first { $0.action == .start }?.isEnabled, true)
    }

    func testMenuForRunningInstanceDisablesStart() throws {
        try ctl.new(name: "work", workdir: nil)
        launcher.runningPids[paths.profileDir("work").path] = 777
        let status = try XCTUnwrap(model.refresh().first)

        XCTAssertEqual(model.menuItems(for: status).first { $0.action == .start }?.isEnabled, false)
    }

    func testSingletonLockIsExclusiveAndReleasable() throws {
        let first = StatusItemController(model: model, paths: paths)
        let second = StatusItemController(model: model, paths: paths)

        XCTAssertTrue(first.acquireSingleton())
        XCTAssertFalse(second.acquireSingleton(), "ikinci örnek kilidi alamamalı")

        first.releaseSingleton()
        XCTAssertTrue(second.acquireSingleton(), "kilit bırakılınca alınabilmeli")
        second.releaseSingleton()
    }

    func testStalePidFileDoesNotBlockSingleton() throws {
        // Eski sürümün bıraktığı, canlı bir pid'e (kendi pid'imiz) işaret eden dosya.
        try FileManager.default.createDirectory(at: paths.stateDirectory, withIntermediateDirectories: true)
        try Data("\(getpid())".utf8).write(to: paths.stateDirectory.appendingPathComponent("agent.pid"))

        let controller = StatusItemController(model: model, paths: paths)
        XCTAssertTrue(controller.acquireSingleton())
        controller.releaseSingleton()
    }

    func testMenuAlwaysContainsWorkdirLogsAndSigninItems() throws {
        try ctl.new(name: "work", workdir: nil)
        let status = try XCTUnwrap(model.refresh().first)

        let items = model.menuItems(for: status)

        XCTAssertNotNil(items.first { $0.action == .openWorkdir })
        XCTAssertNotNil(items.first { $0.action == .openProfile })
        XCTAssertNotNil(items.first { $0.action == .showLogs })
        XCTAssertNotNil(items.first { $0.action == .signinHelp })
    }

    func testMenuItemTitlesAreDistinct() throws {
        try ctl.new(name: "work", workdir: nil)
        let status = try XCTUnwrap(model.refresh().first)

        let titles = model.menuItems(for: status).map(\.title)

        XCTAssertEqual(Set(titles).count, titles.count, "menü başlıkları benzersiz olmalı")
    }
}
