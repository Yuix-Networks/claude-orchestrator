import XCTest
@testable import ClaudeCtlCore

/// Testlerde gerçek Claude başlatmamak için sahte launcher.
final class FakeLauncher: Launching {
    var runningPids: [String: Int32] = [:]
    var launchCount = 0
    var lastRequest: LaunchRequest?
    var launchShouldFail = false

    func launchArguments(_ request: LaunchRequest) -> [String] { [] }

    func isProfileLocked(profileDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: profileDir.appendingPathComponent("SingletonLock").path)
    }

    func runningPid(profileDir: URL) -> Int32? {
        runningPids[profileDir.path]
    }

    func launch(_ request: LaunchRequest) throws {
        launchCount += 1
        lastRequest = request
        if launchShouldFail {
            throw ClaudeCtlError.runtime("sahte başlatma hatası")
        }
        runningPids[request.profileDir] = 4242
    }
}

final class ClaudeCtlStartTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var launcher: FakeLauncher!
    private var ctl: ClaudeCtl!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-ctl-test-\(UUID().uuidString)")
        paths = Paths(root: root)
        launcher = FakeLauncher()
        ctl = ClaudeCtl(paths: paths, launcher: launcher)
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
            guard case let .runtime(message) = error as? ClaudeCtlError else {
                return XCTFail("runtime bekleniyordu: \(error)")
            }
            XCTAssertTrue(message.contains("zaten var"), "mesaj 'zaten var' içermeli: \(message)")
        }
    }

    func testNewRejectsInvalidName() throws {
        XCTAssertThrowsError(try ctl.new(name: "../x", workdir: nil)) { error in
            guard case .invalidName = error as? ClaudeCtlError else {
                return XCTFail("invalidName bekleniyordu: \(error)")
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
        XCTAssertEqual(launcher.launchCount, 0, "çalışan instance yeniden başlatılmamalı")
    }

    func testStartFailsWhenProfileIsLocked() throws {
        try ctl.new(name: "work", workdir: nil)
        let profile = paths.profileDir("work")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data().write(to: profile.appendingPathComponent("SingletonLock"))

        XCTAssertThrowsError(try ctl.start(name: "work", folder: nil)) { error in
            guard case let .runtime(message) = error as? ClaudeCtlError else {
                return XCTFail("runtime bekleniyordu: \(error)")
            }
            XCTAssertTrue(message.contains("SingletonLock"), "mesaj 'SingletonLock' içermeli: \(message)")
        }
        XCTAssertEqual(launcher.launchCount, 0)
    }

    func testStartWarnsWhenWorkdirIsMissing() throws {
        let missing = root.appendingPathComponent("yok-\(UUID().uuidString)").path
        try ctl.new(name: "work", workdir: missing)

        let result = try ctl.start(name: "work", folder: nil)

        XCTAssertFalse(result.alreadyRunning)
        XCTAssertNotNil(result.warning)
        XCTAssertTrue(result.warning?.contains("workdir") == true, "uyarı 'workdir' içermeli: \(result.warning ?? "-")")
        XCTAssertNil(result.seed, "tohumlama atlanmalı")
        XCTAssertEqual(launcher.launchCount, 1, "instance yine de açılmalı")
    }

    func testStartSeedsWorkdirAndRecordsState() throws {
        let workdir = try makeWorkdir()
        try ctl.new(name: "work", workdir: workdir.path)

        let result = try ctl.start(name: "work", folder: nil)

        XCTAssertFalse(result.alreadyRunning)
        XCTAssertEqual(result.pid, 4242)
        XCTAssertEqual(result.seed?.trustedFolderAdded, true)
        XCTAssertNil(result.warning)

        let state = try XCTUnwrap(JSONFile.read(InstanceState.self, from: paths.stateFile("work")))
        XCTAssertEqual(state.pid, 4242)
        XCTAssertEqual(state.claudeVersion, ClaudeApp.version())
    }

    func testStartPassesFolderAsExtraArgument() throws {
        try ctl.new(name: "work", workdir: nil)

        _ = try ctl.start(name: "work", folder: "/tmp/proje")

        XCTAssertEqual(launcher.lastRequest?.extraArgs, ["/tmp/proje"])
    }

    func testStartThrowsWhenLaunchFails() throws {
        try ctl.new(name: "work", workdir: nil)
        launcher.launchShouldFail = true

        XCTAssertThrowsError(try ctl.start(name: "work", folder: nil))
    }

    func testStartThrowsNotFoundForUnknownInstance() throws {
        XCTAssertThrowsError(try ctl.start(name: "yok", folder: nil)) { error in
            guard case .notFound = error as? ClaudeCtlError else {
                return XCTFail("notFound bekleniyordu: \(error)")
            }
        }
    }

    // MARK: - stop

    func testStopTerminatesRunningProcess() throws {
        // Süreç kabuk üzerinden arka planda başlatılır: kabuk çıkınca süreç init'e
        // devredilir, böylece test sırasında zombie olmaz (kill(pid, 0) zombie'da
        // de başarılıdır).
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Arka plan işi pipe'in yazma ucunu tutmasın diye çıktısı /dev/null'a gider.
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

        let result = try ctl.stop(name: "work")

        XCTAssertTrue(result.wasRunning)
        XCTAssertFalse(result.forced, "normal kapanışta zor kullanılmamalı")
        XCTAssertFalse(ProcessSignal.isAlive(pid), "süreç sonlanmalı")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.stateFile("work").path),
            "durum dosyası temizlenmeli"
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
}
