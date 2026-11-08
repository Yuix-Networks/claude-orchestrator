import XCTest
@testable import ClaudeCtlCore

/// Testler için sabit süreç listesi.
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
            "--args", "--user-data-dir=/p",
            "--env", "CLAUDE_CONFIG_DIR=/c"
        ])
    }

    func testLaunchArgumentsAppendExtraArgsAfterEnvironment() {
        let request = LaunchRequest(
            appPath: "/Applications/Claude.app",
            profileDir: "/p",
            codeDir: "/c",
            extraArgs: ["/tmp/proje"]
        )
        let arguments = makeLauncher().launchArguments(request)

        XCTAssertEqual(arguments, [
            "open", "-n", "-a", "/Applications/Claude.app",
            "--args", "--user-data-dir=/p",
            "--env", "CLAUDE_CONFIG_DIR=/c",
            "/tmp/proje"
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
            (100, "/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/başka")
        ])

        XCTAssertNil(launcher.runningPid(profileDir: profileDir))
    }

    func testRunningPidRequiresExactProfilePath() {
        let launcher = makeLauncher(entries: [
            (100, "/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=\(profileDir.path)2")
        ])

        XCTAssertNil(launcher.runningPid(profileDir: profileDir), "farklı profil eşleşmemeli")
    }

    func testRunningPidIgnoresProcessesThatAreNotClaude() {
        let launcher = makeLauncher(entries: [
            (100, "/usr/local/bin/other --user-data-dir=/p")
        ])

        XCTAssertNil(launcher.runningPid(profileDir: profileDir))
    }
}
