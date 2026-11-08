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
        try "# kurallar\nKB = ~/workspace/yuix-networks-kb\n".write(to: shared, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func memory(_ instance: String) -> URL {
        paths.codeDir(instance).appendingPathComponent("CLAUDE.md")
    }

    func testNewInstanceGetsSharedMemoryLink() throws {
        _ = try ctl.new(name: "is", workdir: nil)

        XCTAssertEqual(try String(contentsOf: memory("is"), encoding: .utf8), try String(contentsOf: shared, encoding: .utf8))
        XCTAssertEqual(try ctl.sharedMemoryStatus().map(\.state), [.alreadyLinked])

        // Ortak dosyadaki değişiklik instance'ta görünür (kopya değil bağ).
        try "yeni kural\n".write(to: shared, atomically: false, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: memory("is"), encoding: .utf8), "yeni kural\n")
    }

    func testOwnFileIsKeptUnlessForcedThenBackedUp() throws {
        _ = try ctl.new(name: "is", workdir: nil)
        try FileManager.default.removeItem(at: memory("is"))
        try "kendi notlarım".write(to: memory("is"), atomically: true, encoding: .utf8)

        XCTAssertEqual(try ctl.linkSharedMemory().map(\.state), [.ownFile])
        XCTAssertEqual(try String(contentsOf: memory("is"), encoding: .utf8), "kendi notlarım")

        // start da kendi dosyasının üzerine yazmamalı.
        _ = try ctl.start(name: "is", folder: nil)
        XCTAssertEqual(try String(contentsOf: memory("is"), encoding: .utf8), "kendi notlarım")

        let forced = try ctl.linkSharedMemory(force: true)
        XCTAssertEqual(forced.map(\.state), [.linked])
        let backup = try XCTUnwrap(forced.first?.backup)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "kendi notlarım")
        XCTAssertEqual(try ctl.sharedMemoryStatus().map(\.state), [.alreadyLinked])
    }

    func testUnlinkRemovesOnlyTheLink() throws {
        _ = try ctl.new(name: "is", workdir: nil)
        _ = try ctl.new(name: "okul", workdir: nil)
        try FileManager.default.removeItem(at: memory("okul"))
        try "kendi".write(to: memory("okul"), atomically: true, encoding: .utf8)

        let results = try ctl.unlinkSharedMemory()

        XCTAssertEqual(results.map(\.state), [.unlinked, .ownFile])
        XCTAssertFalse(FileManager.default.fileExists(atPath: memory("is").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path), "ortak dosya silinmemeli")
        XCTAssertEqual(try String(contentsOf: memory("okul"), encoding: .utf8), "kendi")
    }

    func testMissingSharedFileIsReportedAndNewStillWorks() throws {
        try FileManager.default.removeItem(at: shared)
        XCTAssertNoThrow(try ctl.new(name: "is", workdir: nil))
        XCTAssertEqual(try ctl.sharedMemoryStatus().map(\.state), [.missing])
        XCTAssertThrowsError(try ctl.linkSharedMemory())
    }
}
