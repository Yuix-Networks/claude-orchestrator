import XCTest
@testable import OrchestratorCore

final class NameValidatorTests: XCTestCase {
    func testAcceptsLowercaseAlphanumericName() throws {
        XCTAssertNoThrow(try NameValidator.validate("work"))
    }

    func testAcceptsNameStartingWithDigit() throws {
        XCTAssertNoThrow(try NameValidator.validate("2work"))
    }

    func testAcceptsNameWithHyphen() throws {
        XCTAssertNoThrow(try NameValidator.validate("work-2"))
    }

    func testAcceptsNameOfExactly32Characters() throws {
        XCTAssertNoThrow(try NameValidator.validate(String(repeating: "a", count: 32)))
    }

    func testRejectsEmptyName() {
        assertInvalidName("")
    }

    func testRejectsUppercaseLetters() {
        assertInvalidName("Work")
    }

    func testRejectsSlash() {
        assertInvalidName("a/b")
    }

    func testRejectsParentTraversal() {
        assertInvalidName("../x")
    }

    func testRejectsSpace() {
        assertInvalidName("a b")
    }

    func testRejectsNameLongerThan32Characters() {
        assertInvalidName(String(repeating: "a", count: 33))
    }

    func testErrorMessageContainsTheRejectedName() {
        do {
            try NameValidator.validate("Bad Name")
            XCTFail("the invalid name should have been rejected")
        } catch let error as OrchestratorError {
            guard case let .invalidName(message) = error else {
                return XCTFail("expected invalidName, got: \(error)")
            }
            XCTAssertTrue(message.contains("Bad Name"), "message should contain the instance name: \(message)")
        } catch {
            XCTFail("expected OrchestratorError: \(error)")
        }
    }

    private func assertInvalidName(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        do {
            try NameValidator.validate(name)
            XCTFail("'\(name)' should have been rejected", file: file, line: line)
        } catch let error as OrchestratorError {
            guard case .invalidName = error else {
                return XCTFail("expected invalidName, got: \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("expected OrchestratorError: \(error)", file: file, line: line)
        }
    }
}
