import XCTest
@testable import OrchestratorCore

final class InstanceStoreTests: XCTestCase {
    private var root: URL!
    private var store: InstanceStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-ctl-test-\(UUID().uuidString)")
        store = InstanceStore(paths: Paths(root: root))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    func testLoadReturnsEmptyConfigWhenFileIsMissing() throws {
        let config = try store.load()
        XCTAssertEqual(config.version, 1)
        XCTAssertTrue(config.instances.isEmpty)
    }

    func testUpsertPersistsInstanceAndLoadReturnsIt() throws {
        let instance = Instance(name: "work", workdir: "/tmp/work", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.upsert(instance)

        let loaded = try store.load()
        XCTAssertEqual(loaded.instances["work"], instance)
        XCTAssertEqual(loaded.version, 1)
    }

    func testUpsertCreatesRootDirectoryWhenMissing() throws {
        try store.upsert(Instance(name: "work"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths.configFile.path))
    }

    func testInstanceLookupThrowsNotFoundForUnknownName() throws {
        XCTAssertThrowsError(try store.instance(named: "missing")) { error in
            guard case .notFound = error as? OrchestratorError else {
                return XCTFail("expected notFound: \(error)")
            }
        }
    }

    func testRemoveDeletesInstance() throws {
        try store.upsert(Instance(name: "work"))
        try store.remove(named: "work")
        XCTAssertTrue(try store.load().instances.isEmpty)
    }

    func testRemoveThrowsNotFoundForUnknownName() throws {
        XCTAssertThrowsError(try store.remove(named: "missing")) { error in
            guard case .notFound = error as? OrchestratorError else {
                return XCTFail("expected notFound: \(error)")
            }
        }
    }

    func testLoadThrowsCorruptConfigAndLeavesFileUntouched() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let broken = "{{{{ corrupt"
        try broken.write(to: store.paths.configFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try store.load()) { error in
            guard case let .corruptConfig(url) = error as? OrchestratorError else {
                return XCTFail("expected corruptConfig: \(error)")
            }
            XCTAssertEqual(url, store.paths.configFile)
        }

        let contentAfter = try String(contentsOf: store.paths.configFile, encoding: .utf8)
        XCTAssertEqual(contentAfter, broken, "the corrupt config file should not be modified")
    }

    func testUpsertRejectsInvalidNameWithoutWritingConfig() throws {
        XCTAssertThrowsError(try store.upsert(Instance(name: "../x"))) { error in
            guard case .invalidName = error as? OrchestratorError else {
                return XCTFail("expected invalidName: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.paths.configFile.path),
            "config should not be written for an invalid name"
        )
    }

    func testLoadRejectsConfigWithInstanceNameOutsideTheNamePolicy() throws {
        // Path traversal attempt in a hand-edited config.
        let raw = """
        {
          "version": 1,
          "instances": {
            "../../Documents": {
              "name": "../../Documents",
              "workdir": null,
              "createdAt": "2026-11-08T10:00:00Z",
              "autoStart": false,
              "iconBadge": null
            }
          }
        }
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try raw.write(to: store.paths.configFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try store.load()) { error in
            guard case .corruptConfig = error as? OrchestratorError else {
                return XCTFail("expected corruptConfig: \(error)")
            }
        }
    }

    func testLoadRejectsConfigWhereKeyAndNameDiffer() throws {
        let raw = """
        {
          "version": 1,
          "instances": {
            "work": {
              "name": "other",
              "workdir": null,
              "createdAt": "2026-11-08T10:00:00Z",
              "autoStart": false,
              "iconBadge": null
            }
          }
        }
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try raw.write(to: store.paths.configFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try store.load()) { error in
            guard case .corruptConfig = error as? OrchestratorError else {
                return XCTFail("expected corruptConfig: \(error)")
            }
        }
    }
}
