import XCTest
@testable import OrchestratorCore

/// Fixed process list for tests.
struct FakeProcessListing: ProcessListing {
    var entries: [(pid: Int32, command: String)]

    func processes() -> [(pid: Int32, command: String)] { entries }
}

final class LauncherTests: XCTestCase {
    private var profileDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        profileDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-ctl-test-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let profileDir { try? FileManager.default.removeItem(at: profileDir) }
        try super.tearDownWithError()
    }

    private func makeLauncher(entries: [(pid: Int32, command: String)] = []) -> Launcher {
        Launcher(processListing: FakeProcessListing(entries: entries))
    }

    func testLaunchArgumentsUseOpenWithNewInstanceAndSeparatedPaths() {
        let request = LaunchRequest(appPath: "/Applications/Claude.app", profileDir: "/p", codeDir: "/c")
        let arguments = makeLauncher().launchArguments(request)

        XCTAssertEqual(arguments, [
            "open", "-n", "-a", "/Applications/Claude.app",
            "--env", "CLAUDE_CONFIG_DIR=/c",
            "--args", "--user-data-dir=/p"
        ])
    }

    func testEnvironmentOptionComesBeforeArgsSoOpenConsumesIt() throws {
        let request = LaunchRequest(appPath: "/Applications/Claude.app", profileDir: "/p", codeDir: "/c")
        let arguments = makeLauncher().launchArguments(request)

        // Everything after `open --args` goes to the app as argv.
        // --env must come before that point, otherwise the app sees `--env` and its
        // value in its argv (Electron treats it as a file to open).
        let envIndex = try XCTUnwrap(arguments.firstIndex(of: "--env"))
        let argsIndex = try XCTUnwrap(arguments.firstIndex(of: "--args"))
        XCTAssertLessThan(envIndex, argsIndex, "--env should come before --args")
    }

    func testLaunchArgumentsAppendExtraArgsAfterArgs() {
        let request = LaunchRequest(
            appPath: "/Applications/Claude.app",
            profileDir: "/p",
            codeDir: "/c",
            extraArgs: ["/tmp/project"]
        )
        let arguments = makeLauncher().launchArguments(request)

        XCTAssertEqual(arguments, [
            "open", "-n", "-a", "/Applications/Claude.app",
            "--env", "CLAUDE_CONFIG_DIR=/c",
            "--args", "--user-data-dir=/p",
            "/tmp/project"
        ])
    }

    func testLaunchArgumentsKeepPathsWithSpacesInSingleArgument() {
        let request = LaunchRequest(
            appPath: "/Applications/Claude.app",
            profileDir: "/Users/me/Library/Application Support/claude-ctl/instances/x/profile",
            codeDir: "/Users/me/Library/Application Support/claude-ctl/instances/x/claude-code"
        )
        let arguments = makeLauncher().launchArguments(request)

        XCTAssertTrue(arguments.contains("--user-data-dir=/Users/me/Library/Application Support/claude-ctl/instances/x/profile"))
        XCTAssertTrue(arguments.contains("CLAUDE_CONFIG_DIR=/Users/me/Library/Application Support/claude-ctl/instances/x/claude-code"))
    }

    func testOpenArgumentsDoNotRepeatTheProgramName() {
        let request = LaunchRequest(appPath: "/Applications/Claude.app", profileDir: "/p", codeDir: "/c")
        let arguments = makeLauncher().openArguments(request)

        XCTAssertEqual(arguments.first, "-n", "the program name should not be repeated in the arguments")
        XCTAssertFalse(arguments.contains("open"))
        XCTAssertEqual(arguments, [
            "-n", "-a", "/Applications/Claude.app",
            "--env", "CLAUDE_CONFIG_DIR=/c",
            "--args", "--user-data-dir=/p"
        ])
    }

    func testRunningPidIgnoresElectronHelperProcesses() {
        let launcher = makeLauncher(entries: [
            (100, "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=gpu-process --user-data-dir=\(profileDir.path)")
        ])

        XCTAssertNil(
            launcher.runningPid(profileDir: profileDir),
            "helper processes should not count as the main process"
        )
    }

    func testLockHolderPidIsReadFromSingletonLockTarget() throws {
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let lock = profileDir.appendingPathComponent("SingletonLock")
        try FileManager.default.createSymbolicLink(
            at: lock,
            withDestinationURL: URL(fileURLWithPath: "macbook-4242")
        )

        XCTAssertEqual(makeLauncher().lockHolderPid(profileDir: profileDir), 4242)
    }

    func testLockHolderPidIsNilWhenLockIsMissing() {
        XCTAssertNil(makeLauncher().lockHolderPid(profileDir: profileDir))
    }

    func testLaunchSurfacesOpenErrorMessage() throws {
        let failingOpen = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-ctl-fake-open-\(UUID().uuidString)")
        try "#!/bin/sh\necho 'Unable to find application named Fake' >&2\nexit 1\n".write(
            to: failingOpen,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failingOpen.path)

        let launcher = Launcher(appPath: "/Applications/Claude.app", openPath: failingOpen.path)
        let request = LaunchRequest(appPath: "/Applications/Claude.app", profileDir: "/p", codeDir: "/c")

        XCTAssertThrowsError(try launcher.launch(request)) { error in
            guard case let .runtime(message) = error as? OrchestratorError else {
                return XCTFail("expected runtime: \(error)")
            }
            XCTAssertTrue(message.contains("Unable to find application"), "the open error should be surfaced: \(message)")
        }
    }

    func testIsProfileLockedReturnsTrueWhenSingletonLockExists() throws {
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try Data().write(to: profileDir.appendingPathComponent("SingletonLock"))

        XCTAssertTrue(makeLauncher().isProfileLocked(profileDir: profileDir))
    }

    func testIsProfileLockedReturnsFalseWhenSingletonLockIsMissing() {
        XCTAssertFalse(makeLauncher().isProfileLocked(profileDir: profileDir))
    }

    func testRunningPidFindsProcessWithMatchingUserDataDir() {
        let launcher = makeLauncher(entries: [
            (100, "/usr/bin/other --user-data-dir=\(profileDir.path)"),
            (123, "/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=\(profileDir.path) --no-sandbox")
        ])

        XCTAssertEqual(launcher.runningPid(profileDir: profileDir), 123)
    }

    func testRunningPidReturnsNilWhenNoProcessMatches() {
        let launcher = makeLauncher(entries: [
            (100, "/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/other")
        ])

        XCTAssertNil(launcher.runningPid(profileDir: profileDir))
    }

    func testRunningPidRequiresExactProfilePath() {
        let launcher = makeLauncher(entries: [
            (100, "/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=\(profileDir.path)2")
        ])

        XCTAssertNil(launcher.runningPid(profileDir: profileDir), "a different profile should not match")
    }

    func testRunningPidIgnoresProcessesThatAreNotClaude() {
        let launcher = makeLauncher(entries: [
            (100, "/usr/local/bin/other --user-data-dir=/p")
        ])

        XCTAssertNil(launcher.runningPid(profileDir: profileDir))
    }
}
