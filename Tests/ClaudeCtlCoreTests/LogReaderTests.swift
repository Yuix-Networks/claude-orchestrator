import XCTest
@testable import ClaudeCtlCore

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
            "2026-11-08 10:00:00 [info] [A] eski satır",
            "2026-11-08 12:00:00 [info] [B] yeni satır",
            "2026-11-08 14:00:00 [info] [C] daha yeni satır"
        ])

        let lines = LogReader(logDirectory: logDirectory).lines(
            since: date("2026-11-08 11:00:00"),
            pid: nil,
            limit: 50
        )

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("yeni satır"))
        XCTAssertTrue(lines[1].contains("daha yeni satır"))
    }

    func testFiltersLinesByPid() throws {
        try writeLog([
            "2026-11-08 10:00:00 [info] [proc] electron_main:1111 rss=1MB",
            "2026-11-08 10:00:01 [info] [proc] electron_main:2222 rss=2MB",
            "2026-11-08 10:00:02 [info] [other] pid yok"
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
        try writeLog((1...10).map { "2026-11-08 10:00:0\($0 % 10) [info] [A] satır \($0)" })

        let lines = LogReader(logDirectory: logDirectory).lines(
            since: Date.distantPast,
            pid: nil,
            limit: 3
        )

        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[2].contains("satır 10"))
    }

    func testKeepsLinesWithoutTimestampButAppliesPidFilter() throws {
        try writeLog([
            "2026-11-08 10:00:00 [info] [A] zaman damgalı",
            "zaman damgasız satır electron_main:2222"
        ])

        let lines = LogReader(logDirectory: logDirectory).lines(
            since: date("2026-11-08 11:00:00"),
            pid: nil,
            limit: 50
        )

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("zaman damgasız"))
    }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)!
    }
}
