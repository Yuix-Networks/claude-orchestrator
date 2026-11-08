import XCTest
@testable import OrchestratorCore

final class DoctorTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var profileDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-ctl-test-\(UUID().uuidString)")
        paths = Paths(root: root)
        profileDir = paths.profileDir("work")
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func makeDoctor(
        diskWarningBytes: Int64 = 5 * 1024 * 1024 * 1024,
        version: String? = "4.4212.0"
    ) -> Doctor {
        Doctor(paths: paths, diskWarningBytes: diskWarningBytes, versionProvider: { version })
    }

    func testWarnsWhenClaudeVersionChangedSinceStart() throws {
        let instance = Instance(name: "work", workdir: nil)
        let state = InstanceState(pid: 42, startedAt: Date(), claudeVersion: "1.0.0")

        let checks = makeDoctor(version: "4.4212.0").checks(for: instance, state: state)

        let version = checks.first { $0.name == "claude-version" }
        XCTAssertEqual(version?.status, .warn)
        XCTAssertTrue(version?.detail.contains("1.0.0") == true, "eski sürüm belirtilmeli")
    }

    func testReportsOkWhenClaudeVersionUnchanged() throws {
        let instance = Instance(name: "work", workdir: nil)
        let state = InstanceState(pid: 42, startedAt: Date(), claudeVersion: "4.4212.0")

        let checks = makeDoctor(version: "4.4212.0").checks(for: instance, state: state)

        XCTAssertEqual(checks.first { $0.name == "claude-version" }?.status, .ok)
    }

    func testFailsWhenProfileDirectoryIsMissing() {
        let instance = Instance(name: "yok", workdir: nil)

        let checks = makeDoctor().checks(for: instance, state: nil)

        XCTAssertEqual(checks.first { $0.name == "profile-dir" }?.status, .fail)
    }

    func testWarnsWhenProfileIsLocked() throws {
        let instance = Instance(name: "work", workdir: nil)
        try Data().write(to: profileDir.appendingPathComponent("SingletonLock"))

        let checks = makeDoctor().checks(for: instance, state: nil)

        XCTAssertEqual(checks.first { $0.name == "profile-lock" }?.status, .warn)
    }

    func testWarnsWhenProfileExceedsDiskThreshold() throws {
        let instance = Instance(name: "work", workdir: nil)
        try Data(repeating: 0, count: 2048).write(to: profileDir.appendingPathComponent("Cookies"))

        let checks = makeDoctor(diskWarningBytes: 1024).checks(for: instance, state: nil)

        XCTAssertEqual(checks.first { $0.name == "disk" }?.status, .warn)
    }

    func testReportsOkForSmallProfile() throws {
        let instance = Instance(name: "work", workdir: nil)

        let checks = makeDoctor(diskWarningBytes: 1024 * 1024 * 1024).checks(for: instance, state: nil)

        XCTAssertEqual(checks.first { $0.name == "disk" }?.status, .ok)
    }

    func testWarnsWhenWorkdirIsMissing() {
        let instance = Instance(name: "work", workdir: "/tmp/yok-boyle-bir-klasor-\(UUID().uuidString)")

        let checks = makeDoctor().checks(for: instance, state: nil)

        XCTAssertEqual(checks.first { $0.name == "workdir" }?.status, .warn)
    }

    func testReportsOkWhenWorkdirExists() throws {
        let workdir = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        let instance = Instance(name: "work", workdir: workdir.path)

        let checks = makeDoctor().checks(for: instance, state: nil)

        XCTAssertEqual(checks.first { $0.name == "workdir" }?.status, .ok)
    }

    func testAppChecksReportMissingClaudeApp() {
        let checks = makeDoctor().appChecks(appPath: "/tmp/yok-boyle-bir-uygulama.app")

        XCTAssertEqual(checks.first { $0.name == "claude-app" }?.status, .fail)
    }
}
