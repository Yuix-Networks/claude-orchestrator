import XCTest
@testable import OrchestratorCore

final class ArgumentsTests: XCTestCase {
    func testParsesLongFlagWithSeparateValue() throws {
        let args = try Arguments(["work", "--workdir", "/tmp/project"], allowed: ["workdir"])

        XCTAssertEqual(args.positionals, ["work"])
        XCTAssertEqual(args.flags["workdir"], "/tmp/project")
    }

    func testParsesLongFlagWithInlineValue() throws {
        let args = try Arguments(["--workdir=/tmp/project"], allowed: ["workdir"])

        XCTAssertEqual(args.flags["workdir"], "/tmp/project")
    }

    func testParsesShortFlagWithValue() throws {
        let args = try Arguments(["-n", "5"], allowed: ["lines"])

        XCTAssertEqual(args.flags["lines"], "5")
    }

    func testParsesShortBooleanFlag() throws {
        let args = try Arguments(["-f"], allowed: ["follow"])

        XCTAssertTrue(args.has("follow"))
    }

    func testParsesShortBooleanFlagFollowedByPositional() throws {
        let args = try Arguments(["-f", "work"], allowed: ["follow"])

        XCTAssertTrue(args.has("follow"))
        XCTAssertEqual(args.positionals, ["work"])
    }

    func testRejectsUnknownLongFlag() {
        XCTAssertThrowsError(try Arguments(["--bogus"], allowed: ["workdir"])) { error in
            guard case .usage = error as? OrchestratorError else {
                return XCTFail("expected usage: \(error)")
            }
        }
    }

    func testRejectsUnknownShortFlag() {
        XCTAssertThrowsError(try Arguments(["-z"], allowed: ["workdir"])) { error in
            guard case .usage = error as? OrchestratorError else {
                return XCTFail("expected usage: \(error)")
            }
        }
    }

    func testPositionalArgumentsAreCollected() throws {
        let args = try Arguments(["one", "two"], allowed: [])

        XCTAssertEqual(args.positionals, ["one", "two"])
    }

    func testRepeatedFlagCollectsAllValues() throws {
        let parsed = try Arguments(["path", "--folder", "/a", "--folder=/b"], allowed: ["folder"])
        XCTAssertEqual(parsed.values("folder"), ["/a", "/b"])
        XCTAssertEqual(parsed.optionalFlag("folder"), "/b")
    }
}
