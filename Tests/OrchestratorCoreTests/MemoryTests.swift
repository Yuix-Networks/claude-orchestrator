import XCTest
@testable import OrchestratorCore

final class MemoryTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var ctl: Orchestrator!
    private var shared: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-ctl-test-\(UUID().uuidString)")
        paths = Paths(root: root)
        let home = root.appendingPathComponent("home/.claude")
        ctl = Orchestrator(
            paths: paths,
            launcher: FakeLauncher(),
            defaultCodeDir: home,
            defaultProfileDir: root.appendingPathComponent("home/Claude")
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        shared = home.appendingPathComponent("CLAUDE.md")
        try "# rules\nKB = ~/workspace/yuix-networks-kb\n".write(to: shared, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func memory(_ instance: String) -> URL {
        paths.codeDir(instance).appendingPathComponent("CLAUDE.md")
    }

    func testNewInstanceGetsSharedMemoryLink() throws {
        _ = try ctl.new(name: "job", workdir: nil)

        XCTAssertEqual(try String(contentsOf: memory("job"), encoding: .utf8), try String(contentsOf: shared, encoding: .utf8))
        XCTAssertEqual(try ctl.sharedMemoryStatus().map(\.state), [.alreadyLinked])

        // A change to the shared file shows up in the instance (a link, not a copy).
        try "new rule\n".write(to: shared, atomically: false, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: memory("job"), encoding: .utf8), "new rule\n")
    }

    func testOwnFileIsKeptUnlessForcedThenBackedUp() throws {
        _ = try ctl.new(name: "job", workdir: nil)
        try FileManager.default.removeItem(at: memory("job"))
        try "my own notes".write(to: memory("job"), atomically: true, encoding: .utf8)

        XCTAssertEqual(try ctl.linkSharedMemory().map(\.state), [.ownFile])
        XCTAssertEqual(try String(contentsOf: memory("job"), encoding: .utf8), "my own notes")

        // start must not overwrite the instance's own file either.
        _ = try ctl.start(name: "job", folder: nil)
        XCTAssertEqual(try String(contentsOf: memory("job"), encoding: .utf8), "my own notes")

        let forced = try ctl.linkSharedMemory(force: true)
        XCTAssertEqual(forced.map(\.state), [.linked])
        let backup = try XCTUnwrap(forced.first?.backup)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "my own notes")
        XCTAssertEqual(try ctl.sharedMemoryStatus().map(\.state), [.alreadyLinked])
    }

    func testUnlinkRemovesOnlyTheLink() throws {
        _ = try ctl.new(name: "job", workdir: nil)
        _ = try ctl.new(name: "school", workdir: nil)
        try FileManager.default.removeItem(at: memory("school"))
        try "own".write(to: memory("school"), atomically: true, encoding: .utf8)

        let results = try ctl.unlinkSharedMemory()

        XCTAssertEqual(results.map(\.state), [.unlinked, .ownFile])
        XCTAssertFalse(FileManager.default.fileExists(atPath: memory("job").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path), "the shared file should not be deleted")
        XCTAssertEqual(try String(contentsOf: memory("school"), encoding: .utf8), "own")
    }

    func testMissingSharedFileIsReportedAndNewStillWorks() throws {
        try FileManager.default.removeItem(at: shared)
        XCTAssertNoThrow(try ctl.new(name: "job", workdir: nil))
        XCTAssertEqual(try ctl.sharedMemoryStatus().map(\.state), [.missing])
        XCTAssertThrowsError(try ctl.linkSharedMemory())
    }
}
