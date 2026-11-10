import XCTest
@testable import OrchestratorCore

final class ProfileSeederTests: XCTestCase {
    private var root: URL!
    private var profileDir: URL!
    private var workdir: URL!
    private var seeder: ProfileSeeder!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-ctl-test-\(UUID().uuidString)")
        profileDir = root.appendingPathComponent("profile")
        workdir = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        seeder = ProfileSeeder(paths: Paths(root: root))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func trustedFolders() throws -> [String] {
        let config = try readJSON(profileDir.appendingPathComponent("claude_desktop_config.json"))
        let preferences = try XCTUnwrap(config["preferences"] as? [String: Any])
        return try XCTUnwrap(preferences["localAgentModeTrustedFolders"] as? [String])
    }

    // MARK: - Tests

    func testSeedAddsWorkdirToTrustedFolders() throws {
        let result = try seeder.seed(profileDir: profileDir, workdir: workdir.path)

        XCTAssertTrue(result.trustedFolderAdded)
        XCTAssertEqual(try trustedFolders(), [workdir.path])
    }

    func testSeedPreservesExistingConfigContent() throws {
        let configURL = profileDir.appendingPathComponent("claude_desktop_config.json")
        try writeJSON([
            "mcpServers": ["x": ["command": "y"]],
            "preferences": ["menuBarEnabled": false]
        ], to: configURL)

        _ = try seeder.seed(profileDir: profileDir, workdir: workdir.path)

        let config = try readJSON(configURL)
        XCTAssertNotNil(config["mcpServers"], "mcpServers should be preserved")
        let preferences = try XCTUnwrap(config["preferences"] as? [String: Any])
        XCTAssertEqual(preferences["menuBarEnabled"] as? Bool, false, "existing preferences should be preserved")
        XCTAssertEqual(preferences["localAgentModeTrustedFolders"] as? [String], [workdir.path])
    }

    func testSeedIsIdempotent() throws {
        _ = try seeder.seed(profileDir: profileDir, workdir: workdir.path)
        let configURL = profileDir.appendingPathComponent("claude_desktop_config.json")
        let firstPass = try Data(contentsOf: configURL)

        let secondResult = try seeder.seed(profileDir: profileDir, workdir: workdir.path)

        let secondPass = try Data(contentsOf: configURL)
        XCTAssertEqual(firstPass, secondPass, "a second seed should not change the file")
        XCTAssertFalse(secondResult.trustedFolderAdded)
        XCTAssertEqual(try trustedFolders(), [workdir.path])
    }

    func testSeedAddsSessionPresetForKnownAccount() throws {
        try writeJSON([
            "byAccount": ["acct-1": ["presets": []]]
        ], to: profileDir.appendingPathComponent("ccd-session-presets.json"))

        let result = try seeder.seed(profileDir: profileDir, workdir: workdir.path)

        XCTAssertEqual(result.accountUUID, "acct-1")
        XCTAssertTrue(result.presetAdded)

        let presets = try readJSON(profileDir.appendingPathComponent("ccd-session-presets.json"))
        let byAccount = try XCTUnwrap(presets["byAccount"] as? [String: Any])
        let account = try XCTUnwrap(byAccount["acct-1"] as? [String: Any])
        let list = try XCTUnwrap(account["presets"] as? [[String: Any]])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0]["name"] as? String, "work")
        let target = try XCTUnwrap(list[0]["target"] as? [String: Any])
        XCTAssertEqual(target["kind"] as? String, "local")
        XCTAssertEqual(target["cwd"] as? String, workdir.path)
    }

    func testSeedSkipsPresetWhenNoAccountIsKnown() throws {
        // `byAccount` must be a JSON object (not an empty array).
        try writeJSON(
            ["byAccount": [String: Any]() as [String: Any]],
            to: profileDir.appendingPathComponent("ccd-session-presets.json")
        )

        let result = try seeder.seed(profileDir: profileDir, workdir: workdir.path)

        XCTAssertNil(result.accountUUID)
        XCTAssertFalse(result.presetAdded)
        let presets = try readJSON(profileDir.appendingPathComponent("ccd-session-presets.json"))
        let byAccount = try XCTUnwrap(presets["byAccount"] as? [String: Any])
        XCTAssertTrue(byAccount.isEmpty)
    }

    func testSeedDiscoversAccountFromBridgeState() throws {
        try writeJSON(
            ["byAccount": [String: Any]() as [String: Any]],
            to: profileDir.appendingPathComponent("ccd-session-presets.json")
        )
        try writeJSON(["ws-1:acct-9": [:]], to: profileDir.appendingPathComponent("bridge-state.json"))

        let result = try seeder.seed(profileDir: profileDir, workdir: workdir.path)

        XCTAssertEqual(result.accountUUID, "acct-9")
        XCTAssertTrue(result.presetAdded)
    }

    func testSeedPrefersLastKnownAccountOverAlphabeticalFirst() throws {
        try writeJSON(
            ["byAccount": ["aaa-old": ["presets": []], "zzz-active": ["presets": []]]],
            to: profileDir.appendingPathComponent("ccd-session-presets.json")
        )
        try writeJSON(["lastKnownAccountUuid": "zzz-active"], to: profileDir.appendingPathComponent("config.json"))

        let result = try seeder.seed(profileDir: profileDir, workdir: workdir.path)

        XCTAssertEqual(result.accountUUID, "zzz-active")
        XCTAssertTrue(result.presetAdded)
    }

    func testSeedSkipsPresetWhenSeveralAccountsAndNoneIsActive() throws {
        try writeJSON(
            ["byAccount": ["acct-1": ["presets": []], "acct-2": ["presets": []]]],
            to: profileDir.appendingPathComponent("ccd-session-presets.json")
        )

        let result = try seeder.seed(profileDir: profileDir, workdir: workdir.path)

        XCTAssertNil(result.accountUUID, "should not guess when the active account is unknown")
        XCTAssertFalse(result.presetAdded)
    }

    func testActiveAccountFallsBackToBootSideSessions() throws {
        try writeJSON(
            ["bootSideSessions": ["accountUuid": "acct-boot"]],
            to: profileDir.appendingPathComponent("config.json")
        )

        XCTAssertEqual(ProfileSeeder.activeAccountUUID(profileDir: profileDir), "acct-boot")
    }

    func testSeedHandlesWorkdirWithSpacesAndUnicode() throws {
        let unicodeDir = root.appendingPathComponent("with spaces and ü é")
        try FileManager.default.createDirectory(at: unicodeDir, withIntermediateDirectories: true)

        _ = try seeder.seed(profileDir: profileDir, workdir: unicodeDir.path)

        XCTAssertEqual(try trustedFolders(), [unicodeDir.path])
        let config = try readJSON(profileDir.appendingPathComponent("claude_desktop_config.json"))
        XCTAssertNotNil(config["preferences"])
    }

    func testSeedThrowsWhenWorkdirDoesNotExist() throws {
        let missing = root.appendingPathComponent("missing-\(UUID().uuidString)").path

        XCTAssertThrowsError(try seeder.seed(profileDir: profileDir, workdir: missing)) { error in
            guard case .runtime = error as? OrchestratorError else {
                return XCTFail("expected runtime: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: profileDir.appendingPathComponent("claude_desktop_config.json").path),
            "a failed seed should not write a file"
        )
    }

    // MARK: - Data loss protection

    func testSeedRefusesToOverwriteConfigWithUnexpectedShape() throws {
        let configURL = profileDir.appendingPathComponent("claude_desktop_config.json")
        try writeJSON([["array", "element"]], to: configURL)
        let before = try Data(contentsOf: configURL)

        XCTAssertThrowsError(try seeder.seed(profileDir: profileDir, workdir: workdir.path)) { error in
            guard case .runtime = error as? OrchestratorError else {
                return XCTFail("expected runtime: \(error)")
            }
        }

        let after = try Data(contentsOf: configURL)
        XCTAssertEqual(before, after, "a file with an unexpected shape should not be overwritten")
    }

    func testSeedRefusesToOverwritePresetsWithUnexpectedShape() throws {
        let presetsURL = profileDir.appendingPathComponent("ccd-session-presets.json")
        try writeJSON(["byAccount": "text"], to: presetsURL)
        let before = try Data(contentsOf: presetsURL)

        XCTAssertThrowsError(try seeder.seed(profileDir: profileDir, workdir: workdir.path)) { error in
            guard case .runtime = error as? OrchestratorError else {
                return XCTFail("expected runtime: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: presetsURL), before, "the presets file should not be overwritten")
    }

    func testSeedKeepsBackupOfExistingProfileFiles() throws {
        let configURL = profileDir.appendingPathComponent("claude_desktop_config.json")
        try writeJSON(["preferences": ["menuBarEnabled": true]], to: configURL)

        _ = try seeder.seed(profileDir: profileDir, workdir: workdir.path)

        let backup = profileDir.appendingPathComponent("claude_desktop_config.json.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "a backup file should be created")
        let backupJSON = try readJSON(backup)
        XCTAssertEqual((backupJSON["preferences"] as? [String: Any])?["menuBarEnabled"] as? Bool, true)
    }
}
