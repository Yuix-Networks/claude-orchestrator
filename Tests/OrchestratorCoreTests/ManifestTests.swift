import XCTest
@testable import OrchestratorCore

final class ManifestTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var ctl: Orchestrator!
    private var manifest: URL!
    private var a: URL!, b: URL!, c: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-ctl-test-\(UUID().uuidString)")
        paths = Paths(root: root)
        ctl = Orchestrator(
            paths: paths,
            launcher: FakeLauncher(),
            defaultCodeDir: root.appendingPathComponent("home/.claude"),
            defaultProfileDir: root.appendingPathComponent("home/Claude")
        )
        a = root.appendingPathComponent("work/a")
        b = root.appendingPathComponent("work/b")
        c = root.appendingPathComponent("work/c")
        for dir in [a!, b!, c!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        manifest = root.appendingPathComponent("work/projects.json")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func write(_ text: String) throws {
        try text.write(to: manifest, atomically: true, encoding: .utf8)
    }

    private func signIn(_ instance: String) throws {
        _ = try ctl.new(name: instance, workdir: nil)
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": "acct-\(instance)"])
            .write(to: paths.profileDir(instance).appendingPathComponent("config.json"))
    }

    private func presetNames(_ instance: String) throws -> [String: String] {
        let url = paths.profileDir(instance).appendingPathComponent("ccd-session-presets.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let account = (object["byAccount"] as? [String: Any])?["acct-\(instance)"] as? [String: Any]
        var result: [String: String] = [:]
        for preset in account?["presets"] as? [[String: Any]] ?? [] {
            let cwd = (preset["target"] as? [String: Any])?["cwd"] as? String ?? ""
            result[cwd] = preset["name"] as? String
        }
        return result
    }

    // MARK: - Okuma

    func testLoadsRelativeTildeOptionalNameAndJSON5() throws {
        try write("""
        {
          // hand-written note
          "//": "note field",
          "projects": [
            { "name": "A", "path": "a", "folders": ["b", "./b", "a"] },
            { "path": "\(c.path)", },
          ],
        }
        """)

        let projects = try Orchestrator.loadManifest(manifest)

        XCTAssertEqual(projects.map(\.name), ["A", "c"])
        XCTAssertEqual(projects[0].path, a.path, "relative path resolves against the file's folder")
        XCTAssertEqual(projects[0].additionalFolders, [b.path], "duplicates and the main folder are dropped from extra folders")
        XCTAssertEqual(try Orchestrator.resolveDirectory("~"), NSHomeDirectory())
    }

    func testReportsAllProblemsAtOnce() throws {
        try write("""
        { "projects": [
            { "name": "A", "path": "a", "folder": ["b"] },
            { "name": "A", "path": "b" },
            { "name": "C", "path": "missing" },
            { "name": "D", "path": "c", "folders": ["missing-extra"] },
            { "name": "E", "path": "a" },
            { "name": "" , "path": "c" },
            "text"
        ], "projets": [] }
        """)

        XCTAssertThrowsError(try Orchestrator.loadManifest(manifest)) { error in
            let text = "\(error)"
            for fragment in ["\"projets\"", "\"folder\"", "as projects[0]", "folder not found",
                             "extra folder", "projects[5]: invalid \"name\"", "projects[6]: must be an object"] {
                XCTAssertTrue(text.contains(fragment), "expected '\(fragment)':\n\(text)")
            }
            XCTAssertTrue(text.contains("nothing was changed"))
        }
    }

    func testRejectsInvalidJSONWithLocation() throws {
        try write("{ \"projects\": [ { \"path\": \"a\" } ")
        XCTAssertThrowsError(try Orchestrator.loadManifest(manifest)) { error in
            XCTAssertTrue("\(error)".contains("isn't valid JSON"), "\(error)")
        }
    }

    // MARK: - Plan and apply

    func testApplyAddsUpdatesRenamesAndKeepsUntrackedWithoutPrune() throws {
        try signIn("job")
        _ = try ctl.addProject(name: "A", path: a.path)
        _ = try ctl.addProject(name: "B", path: b.path)
        _ = try ctl.addProject(name: "Old", path: c.path)

        try write("""
        { "projects": [
            { "name": "A", "path": "a", "folders": ["b"] },
            { "name": "New", "path": "c" }
        ] }
        """)
        let plan = try ctl.planApply(try Orchestrator.loadManifest(manifest), prune: false)

        XCTAssertEqual(plan.toUpdate.map(\.new.name), ["A"])
        XCTAssertEqual(plan.toRename.map { "\($0.old.name)>\($0.new.name)" }, ["Old>New"])
        XCTAssertEqual(plan.untracked.map(\.name), ["B"])
        XCTAssertEqual(plan.toRemove, [])

        let result = try ctl.apply(plan)

        XCTAssertEqual(try ctl.projects().map(\.name), ["A", "B", "New"])
        XCTAssertEqual(try ctl.projects().first?.additionalFolders, [b.path])
        XCTAssertEqual(result.synced.first?.error, nil)
        XCTAssertEqual(try presetNames("job")[c.path], "New", "rename should also be reflected in the Desktop environment")
    }

    func testPruneRemovesProjectsMissingFromFileAndTheirEnvironments() throws {
        try signIn("job")
        _ = try ctl.addProject(name: "A", path: a.path)
        _ = try ctl.addProject(name: "B", path: b.path)
        try write(#"{ "projects": [ { "name": "A", "path": "a" } ] }"#)

        let plan = try ctl.planApply(try Orchestrator.loadManifest(manifest), prune: true)
        XCTAssertEqual(plan.toRemove.map(\.name), ["B"])
        _ = try ctl.apply(plan)

        XCTAssertEqual(try ctl.projects().map(\.name), ["A"])
        XCTAssertNil(try presetNames("job")[b.path])
        XCTAssertEqual(try presetNames("job")[a.path], "A")
    }

    func testApplyIsIdempotent() throws {
        try write(#"{ "projects": [ { "name": "A", "path": "a" }, { "path": "b" } ] }"#)
        _ = try ctl.apply(try ctl.planApply(try Orchestrator.loadManifest(manifest), prune: true))

        let again = try ctl.planApply(try Orchestrator.loadManifest(manifest), prune: true)

        XCTAssertFalse(again.hasChanges)
        XCTAssertEqual(again.unchanged.count, 2)
    }

    func testMovingAPathBetweenProjectsInOneApply() throws {
        _ = try ctl.addProject(name: "A", path: a.path)
        // A moves to another folder; new project B takes over its old folder.
        try write(#"{ "projects": [ { "name": "A", "path": "c" }, { "name": "B", "path": "a" } ] }"#)

        _ = try ctl.apply(try ctl.planApply(try Orchestrator.loadManifest(manifest), prune: false))

        let byName = Dictionary(uniqueKeysWithValues: try ctl.projects().map { ($0.name, $0.path) })
        XCTAssertEqual(byName, ["A": c.path, "B": a.path])
    }

    func testDryRunPlanWritesNothing() throws {
        try write(#"{ "projects": [ { "path": "a" } ] }"#)
        _ = try ctl.planApply(try Orchestrator.loadManifest(manifest), prune: true)
        XCTAssertEqual(try ctl.projects(), [])
    }

    // MARK: - Export

    func testExportRoundTripsAndKeepsFieldOrder() throws {
        _ = try ctl.addProject(name: "A \"quoted\"", path: a.path, additionalFolders: [b.path])
        _ = try ctl.addProject(name: "C", path: c.path)

        let text = try ctl.exportManifest()
        XCTAssertTrue(text.contains(#"{ "name": "A \"quoted\"", "path": "#), text)
        try write(text)

        let loaded = try Orchestrator.loadManifest(manifest)
        XCTAssertEqual(loaded.map(\.name), ["A \"quoted\"", "C"])
        XCTAssertEqual(loaded.first?.additionalFolders, [b.path])
        XCTAssertFalse(try ctl.planApply(loaded, prune: true).hasChanges)
    }

    func testExportAbbreviatesHomeDirectory() {
        let home = NSHomeDirectory()
        let text = Orchestrator.renderManifest([Project(name: "x", path: home + "/workspace/x")])
        XCTAssertTrue(text.contains(#""path": "~/workspace/x""#), text)
    }

    // MARK: - defaults and permission mode

    private func desktopPreferences(_ instance: String) throws -> [String: Any] {
        let url = paths.profileDir(instance).appendingPathComponent("claude_desktop_config.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return object["preferences"] as? [String: Any] ?? [:]
    }

    private func folderModes(_ instance: String) throws -> [String: String] {
        let epitaxy = try desktopPreferences(instance)["epitaxyPrefs"] as? [String: Any]
        return epitaxy?["epitaxy-folder-permission-mode-v2.acct-\(instance)"] as? [String: String] ?? [:]
    }

    func testDefaultsAddFoldersAndModeToEveryProject() throws {
        try write("""
        {
          "defaults": { "folders": ["c"], "permissionMode": "bypassPermissions" },
          "projects": [
            { "name": "A", "path": "a", "folders": ["b"] },
            { "name": "B", "path": "b", "permissionMode": "acceptEdits" },
            { "name": "C", "path": "c" }
          ]
        }
        """)

        let projects = try Orchestrator.loadManifest(manifest)

        XCTAssertEqual(projects[0].additionalFolders, [b.path, c.path])
        XCTAssertEqual(projects[0].permissionMode, "bypassPermissions")
        XCTAssertEqual(projects[1].permissionMode, "acceptEdits", "projedeki mod ortak modu ezer")
        XCTAssertEqual(projects[2].additionalFolders, [], "a shared folder is not added to the project that owns it")
    }

    func testRejectsInvalidPermissionModeAndDefaultsKeys() throws {
        try write("""
        { "defaults": { "folder": [], "permissionMode": "yolo" },
          "projects": [ { "path": "a", "permissionMode": 3 } ] }
        """)
        XCTAssertThrowsError(try Orchestrator.loadManifest(manifest)) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("defaults: unknown field \"folder\""), text)
            XCTAssertTrue(text.contains("yolo"), text)
            XCTAssertTrue(text.contains("projects[0] \"a\": invalid \"permissionMode\""), text)
        }
    }

    func testBypassModeIsWrittenPerAccountAndFolderWithoutTouchingOrgGate() throws {
        try signIn("job")
        let configURL = paths.profileDir("job").appendingPathComponent("claude_desktop_config.json")
        try JSONSerialization.data(withJSONObject: ["preferences": [
            "bypassPermissionsGateByAccount": ["acct-job": false],
            "menuBarEnabled": true
        ]]).write(to: configURL)
        try write(#"{ "defaults": { "permissionMode": "bypassPermissions" }, "projects": [ { "name": "A", "path": "a" } ] }"#)

        let result = try ctl.apply(try ctl.planApply(try Orchestrator.loadManifest(manifest), prune: false))

        XCTAssertEqual(try folderModes("job"), [a.path: "bypassPermissions"])
        let preferences = try desktopPreferences("job")
        XCTAssertEqual(preferences["bypassPermissionsModeEnabled"] as? Bool, true)
        XCTAssertEqual((preferences["bypassPermissionsOptInByAccount"] as? [String: Bool])?["acct-job"], true)
        XCTAssertEqual((preferences["bypassPermissionsGateByAccount"] as? [String: Bool])?["acct-job"], false,
                       "organization policy must not be changed")
        XCTAssertEqual(preferences["menuBarEnabled"] as? Bool, true, "other preferences should be preserved")
        let acks = (preferences["epitaxyPrefs"] as? [String: Any])?["epitaxy-perm-mode-acks-v2.acct-job"] as? [String]
        XCTAssertEqual(acks, ["\(a.path):bypassPermissions"])
        XCTAssertEqual(result.synced.first?.applied?.bypassBlockedAccounts, ["acct-job"])
    }

    func testModeOnlyChangeKeepsEnvironmentAndRemovingModeClearsIt() throws {
        try signIn("job")
        try write(#"{ "projects": [ { "name": "A", "path": "a", "permissionMode": "acceptEdits" } ] }"#)
        _ = try ctl.apply(try ctl.planApply(try Orchestrator.loadManifest(manifest), prune: false))

        // The user added a setting to the environment in Desktop.
        let presetsURL = paths.profileDir("job").appendingPathComponent("ccd-session-presets.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: presetsURL)) as? [String: Any])
        var byAccount = try XCTUnwrap(object["byAccount"] as? [String: Any])
        var account = try XCTUnwrap(byAccount["acct-job"] as? [String: Any])
        var list = try XCTUnwrap(account["presets"] as? [[String: Any]])
        list[0]["settings"] = ["modelId": "claude-opus-5-5"]
        account["presets"] = list; byAccount["acct-job"] = account; object["byAccount"] = byAccount
        try JSONSerialization.data(withJSONObject: object).write(to: presetsURL)

        try write(#"{ "projects": [ { "name": "A", "path": "a", "permissionMode": "bypassPermissions" } ] }"#)
        let plan = try ctl.planApply(try Orchestrator.loadManifest(manifest), prune: false)
        XCTAssertEqual(plan.toUpdate.count, 1)
        _ = try ctl.apply(plan)

        XCTAssertEqual(try folderModes("job")[a.path], "bypassPermissions")
        let after = try String(contentsOf: presetsURL, encoding: .utf8)
        XCTAssertTrue(after.contains("claude-opus-5-5"), "environment settings should be preserved when only the mode changes")

        try write(#"{ "projects": [ { "name": "A", "path": "a" } ] }"#)
        _ = try ctl.apply(try ctl.planApply(try Orchestrator.loadManifest(manifest), prune: false))
        XCTAssertNil(try folderModes("job")[a.path], "a mode removed from the file should also be removed from Desktop")
    }

    func testPruneClearsPermissionModeOfRemovedProject() throws {
        try signIn("job")
        try write(#"{ "projects": [ { "name": "A", "path": "a", "permissionMode": "bypassPermissions" } ] }"#)
        _ = try ctl.apply(try ctl.planApply(try Orchestrator.loadManifest(manifest), prune: false))

        try write(#"{ "projects": [] }"#)
        _ = try ctl.apply(try ctl.planApply(try Orchestrator.loadManifest(manifest), prune: true))

        XCTAssertEqual(try folderModes("job"), [:])
    }

    func testExportIncludesPermissionMode() throws {
        try write(#"{ "projects": [ { "name": "A", "path": "a", "permissionMode": "auto" } ] }"#)
        _ = try ctl.apply(try ctl.planApply(try Orchestrator.loadManifest(manifest), prune: false))
        XCTAssertTrue(try ctl.exportManifest().contains(#""permissionMode": "auto""#))
    }
}
