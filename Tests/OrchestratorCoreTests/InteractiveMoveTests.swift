import XCTest
@testable import OrchestratorCore

final class FuzzyMatchTests: XCTestCase {
    func testMatchesSubsequenceIgnoringCaseAndTurkishLetters() {
        XCTAssertNotNil(FuzzyMatch.match("api river", in: "Add API keys from river"))
        // Turkish dotless ı / dotted İ fold to plain "i" (session titles are often Turkish).
        XCTAssertNotNil(FuzzyMatch.match("anahtarlari", in: "API ANAHTARLARI"))
        XCTAssertNotNil(FuzzyMatch.match("isik", in: "Işık"))
        XCTAssertNotNil(FuzzyMatch.match("hairpin", in: "Proxmox3 hairpin issue"))
        XCTAssertNotNil(FuzzyMatch.match("pxhp", in: "Proxmox3 hairpin issue"))
        XCTAssertNil(FuzzyMatch.match("zzz", in: "Proxmox3 hairpin issue"))
        XCTAssertNil(FuzzyMatch.match("api xyz", in: "Add API keys from river"))
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertEqual(FuzzyMatch.match("  ", in: "anything"), FuzzyMatch.Result(score: 0, positions: []))
    }

    func testPositionsPointAtMatchedCharacters() throws {
        let result = try XCTUnwrap(FuzzyMatch.match("hrp", in: "hairpin"))
        XCTAssertEqual(result.positions, [0, 3, 4])
    }

    func testConsecutiveAndWordStartMatchesRankHigher() {
        let ranked = FuzzyMatch.filter(
            ["Claude-orchestrator session transfer", "Proxmox3 hairpin issue", "Add API keys from river"],
            query: "ses"
        ) { $0 }.map(\.item)
        XCTAssertEqual(ranked.first, "Claude-orchestrator session transfer")
    }

    func testEqualScoresKeepOriginalOrder() {
        let ranked = FuzzyMatch.filter(["b one", "a one", "c one"], query: "one") { $0 }.map(\.item)
        XCTAssertEqual(ranked, ["b one", "a one", "c one"])
    }
}

final class PickerModelTests: XCTestCase {
    private let items = ["Claude-orchestrator session transfer", "Proxmox3 hairpin issue", "Add API keys from river"]

    func testTypingFiltersAndResetsSelection() {
        var picker = PickerModel(items: items)
        XCTAssertEqual(picker.visible.count, 3)
        _ = picker.handle(.down)
        XCTAssertEqual(picker.selection, 1)
        for character in "river" { _ = picker.handle(.character(character)) }
        XCTAssertEqual(picker.visible.map(\.index), [2])
        XCTAssertEqual(picker.selection, 0)
        XCTAssertEqual(picker.handle(.enter), .select(2))
    }

    func testArrowsAreClampedToTheList() {
        var picker = PickerModel(items: items)
        _ = picker.handle(.up)
        XCTAssertEqual(picker.selection, 0)
        for _ in 0..<5 { _ = picker.handle(.down) }
        XCTAssertEqual(picker.selection, 2)
        XCTAssertEqual(picker.handle(.enter), .select(2))
    }

    func testBackspaceAndEscapeClearQueryBeforeGoingBack() {
        var picker = PickerModel(items: items)
        _ = picker.handle(.character("z"))
        XCTAssertTrue(picker.visible.isEmpty)
        XCTAssertEqual(picker.handle(.enter), .none)
        _ = picker.handle(.backspace)
        XCTAssertEqual(picker.visible.count, 3)
        _ = picker.handle(.character("x"))
        XCTAssertEqual(picker.handle(.escape), .none)
        XCTAssertEqual(picker.query, "")
        XCTAssertEqual(picker.handle(.escape), .back)
        XCTAssertEqual(picker.handle(.interrupt), .cancel)
    }

    func testNonSearchableListIgnoresTyping() {
        var picker = PickerModel(items: ["client", "school"], searchable: false)
        _ = picker.handle(.character("m"))
        XCTAssertEqual(picker.visible.count, 2)
        _ = picker.handle(.down)
        XCTAssertEqual(picker.handle(.enter), .select(1))
    }
}

final class SessionMovePlanTests: XCTestCase {
    private func result() -> TransferResult {
        let session = SessionSummary(
            id: "s1", projectSlug: "-p", cwd: nil, startedAt: nil, endedAt: nil, messageCount: 0,
            firstPrompt: nil, lastPrompt: nil, cliVersion: nil, title: nil,
            transcript: URL(fileURLWithPath: "/tmp/s1.jsonl"), sizeBytes: 0
        )
        return TransferResult(session: session, copiedFiles: [], desktopMetadata: nil, backup: nil, warnings: [])
    }

    func testStopsRunningInstancesInOrderThenMovesThenRestarts() throws {
        var running: Set = ["work", "school"]
        var log: [String] = []
        let plan = SessionMovePlan(
            instances: ["work", "school"],
            isRunning: { running.contains($0) },
            stop: { log.append("stop \($0)"); running.remove($0) },
            start: { log.append("start \($0)"); running.insert($0) },
            transfer: { log.append("move (running: \(running.count))"); return self.result() }
        )
        let outcome = try plan.run()
        XCTAssertEqual(log, ["stop work", "stop school", "move (running: 0)", "start work", "start school"])
        XCTAssertEqual(outcome.restarted, ["work", "school"])
    }

    func testOnlyRestartsWhatWasRunning() throws {
        var log: [String] = []
        let plan = SessionMovePlan(
            instances: ["work", "school"],
            isRunning: { $0 == "school" },
            stop: { log.append("stop \($0)") },
            start: { log.append("start \($0)") },
            transfer: { self.result() }
        )
        let outcome = try plan.run()
        XCTAssertEqual(log, ["stop school", "start school"])
        XCTAssertEqual(outcome.stopped, ["school"])
    }

    func testRestartsEvenWhenTransferFails() {
        var log: [String] = []
        let plan = SessionMovePlan(
            instances: ["work", "school"],
            isRunning: { _ in true },
            stop: { log.append("stop \($0)") },
            start: { log.append("start \($0)") },
            transfer: { throw OrchestratorError.runtime("boom") }
        )
        XCTAssertThrowsError(try plan.run()) { XCTAssertEqual($0 as? OrchestratorError, .runtime("boom")) }
        XCTAssertEqual(log, ["stop work", "stop school", "start work", "start school"])
    }

    func testRestartsAlreadyStoppedInstancesWhenSecondStopFails() {
        var log: [String] = []
        let plan = SessionMovePlan(
            instances: ["work", "school"],
            isRunning: { _ in true },
            stop: { name in
                if name == "school" { throw OrchestratorError.runtime("stuck") }
                log.append("stop \(name)")
            },
            start: { log.append("start \($0)") },
            transfer: { log.append("move"); return self.result() }
        )
        XCTAssertThrowsError(try plan.run())
        XCTAssertEqual(log, ["stop work", "start work"])
    }

    func testRestartFailureIsReportedNotThrown() throws {
        let plan = SessionMovePlan(
            instances: ["work"],
            isRunning: { _ in true },
            stop: { _ in },
            start: { _ in throw OrchestratorError.runtime("no app") },
            transfer: { self.result() }
        )
        let outcome = try plan.run()
        XCTAssertEqual(outcome.restartFailures.map(\.name), ["work"])
    }
}
