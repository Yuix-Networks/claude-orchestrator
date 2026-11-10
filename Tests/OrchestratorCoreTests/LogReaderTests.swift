import XCTest
@testable import OrchestratorCore

final class LogReaderTests: XCTestCase {
    private var logDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-ctl-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let logDirectory { try? FileManager.default.removeItem(at: logDirectory) }
        try super.tearDownWithError()
    }

    private func writeLog(_ lines: [String]) throws {
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(
            to: logDirectory.appendingPathComponent("main.log"),
            atomically: true,
            encoding: .utf8
        )
    }

    func testReturnsEmptyWhenLogFileIsMissing() {
        let reader = LogReader(logDirectory: logDirectory)
        XCTAssertEqual(reader.lines(since: Date.distantPast, pid: nil, limit: 10), [])
    }

    func testFiltersOutLinesOlderThanSince() throws {
        try writeLog([
            "2026-11-08 10:00:00 [info] [A] old line",
            "2026-11-08 12:00:00 [info] [B] new line",
            "2026-11-08 14:00:00 [info] [C] newer line"
        ])

        let lines = LogReader(logDirectory: logDirectory).lines(
            since: date("2026-11-08 11:00:00"),
            pid: nil,
            limit: 50
        )

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("new line"))
        XCTAssertTrue(lines[1].contains("newer line"))
    }

    func testFiltersLinesByPid() throws {
        try writeLog([
            "2026-11-08 10:00:00 [info] [proc] electron_main:1111 rss=1MB",
            "2026-11-08 10:00:01 [info] [proc] electron_main:2222 rss=2MB",
            "2026-11-08 10:00:02 [info] [other] no pid"
        ])

        let lines = LogReader(logDirectory: logDirectory).lines(
            since: Date.distantPast,
            pid: 2222,
            limit: 50
        )

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("electron_main:2222"))
    }

    func testReturnsLastNLine() throws {
        try writeLog((1...10).map { "2026-11-08 10:00:0\($0 % 10) [info] [A] line \($0)" })

        let lines = LogReader(logDirectory: logDirectory).lines(
            since: Date.distantPast,
            pid: nil,
            limit: 3
        )

        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[2].contains("line 10"))
    }

    func testKeepsLinesWithoutTimestampButAppliesPidFilter() throws {
        try writeLog([
            "2026-11-08 10:00:00 [info] [A] timestamped",
            "untimestamped line electron_main:2222"
        ])

        let lines = LogReader(logDirectory: logDirectory).lines(
            since: date("2026-11-08 11:00:00"),
            pid: nil,
            limit: 50
        )

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("untimestamped"))
    }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)!
    }

    // MARK: - Large file (reading from the end)

    func testReadsTailOfLargeFileAcrossChunkBoundaries() throws {
        // A file several times the chunk size: lines get split at chunk boundaries.
        let count = 5_000
        let lines = (0..<count).map { "2026-11-08 12:00:00 [info] line \($0) " + String(repeating: "x", count: 40) }
        try writeLog(lines)

        let result = LogReader(logDirectory: logDirectory).lines(since: Date.distantPast, limit: 3)

        XCTAssertEqual(result, Array(lines.suffix(3)))
    }

    func testUnlimitedReturnsAllLinesInOrder() throws {
        let lines = (0..<3_000).map { "line \($0) " + String(repeating: "y", count: 50) }
        try writeLog(lines)

        let result = LogReader(logDirectory: logDirectory).lines(since: Date.distantPast, limit: 0)

        XCTAssertEqual(result, lines)
    }

    // MARK: - Follow

    private func append(_ text: String) throws {
        let url = logDirectory.appendingPathComponent("main.log")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func testFollowerReturnsOnlyNewCompleteLines() throws {
        try writeLog(["old"])
        let follower = LogFollower(url: logDirectory.appendingPathComponent("main.log"))

        XCTAssertEqual(follower.poll(), [])
        try append("new 1\npartial")
        XCTAssertEqual(follower.poll(), ["new 1"], "a partial line should not be consumed")
        try append(" line\n")
        XCTAssertEqual(follower.poll(), ["partial line"])
    }

    func testFollowerDetectsRotation() throws {
        try writeLog(["old 1", "old 2", "old 3"])
        let follower = LogFollower(url: logDirectory.appendingPathComponent("main.log"))

        // Rotation: the file is replaced with a new one (atomic write → new inode).
        try writeLog(["rotated"])

        XCTAssertEqual(follower.poll(), ["rotated"])
    }
}
