import XCTest
@testable import OrchestratorCore

final class ProjectTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var launcher: FakeLauncher!
    private var ctl: Orchestrator!
    private var vpn: URL!
    private var site: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-ctl-test-\(UUID().uuidString)")
        paths = Paths(root: root)
        launcher = FakeLauncher()
        ctl = Orchestrator(
            paths: paths,
            launcher: launcher,
            defaultCodeDir: root.appendingPathComponent("home/.claude"),
            defaultProfileDir: root.appendingPathComponent("home/Claude")
        )
        vpn = root.appendingPathComponent("work/vpn")
        site = root.appendingPathComponent("work/site")
        for dir in [vpn!, site!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Puts the instance profile into a "signed in" state.
    private func signIn(_ instance: String, account: String) throws {
        let profile = paths.profileDir(instance)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": account])
            .write(to: profile.appendingPathComponent("config.json"))
    }

    private func presets(_ profile: URL) throws -> [String: [[String: Any]]] {
        let url = profile.appendingPathComponent("ccd-session-presets.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let byAccount = object["byAccount"] as? [String: Any] ?? [:]
        return byAccount.mapValues { (($0 as? [String: Any])?["presets"] as? [[String: Any]]) ?? [] }
    }

    private func cwds(_ list: [[String: Any]]?) -> [String] {
        (list ?? []).compactMap { ($0["target"] as? [String: Any])?["cwd"] as? String }
    }

    private func trusted(_ instance: String) throws -> [String] {
        let url = paths.profileDir(instance).appendingPathComponent("claude_desktop_config.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return (object["preferences"] as? [String: Any])?["localAgentModeTrustedFolders"] as? [String] ?? []
    }

    // MARK: - add

    func testAddWritesEnvironmentToEverySignedInInstance() throws {
        _ = try ctl.new(name: "job", workdir: nil)
        _ = try ctl.new(name: "school", workdir: nil)
        try signIn("job", account: "acct-job")
        try signIn("school", account: "acct-school")

        let (project, results) = try ctl.addProject(name: "VPN", path: vpn.path, additionalFolders: [site.path])

        XCTAssertEqual(project.path, vpn.path)
        XCTAssertEqual(results.map(\.instance), ["job", "school"])
        XCTAssertEqual(cwds(try presets(paths.profileDir("job"))["acct-job"]), [vpn.path])
        XCTAssertEqual(cwds(try presets(paths.profileDir("school"))["acct-school"]), [vpn.path])

        let preset = try XCTUnwrap(try presets(paths.profileDir("job"))["acct-job"]?.first)
        XCTAssertEqual(preset["name"] as? String, "VPN")
        XCTAssertEqual((preset["target"] as? [String: Any])?["additionalFolders"] as? [String], [site.path])
        XCTAssertEqual(Set(try trusted("job")), [vpn.path, site.path])
    }

    func testAddWritesToAllAccountsInOneProfile() throws {
        _ = try ctl.new(name: "job", workdir: nil)
        try signIn("job", account: "acct-new")
        let presetsURL = paths.profileDir("job").appendingPathComponent("ccd-session-presets.json")
        try JSONSerialization.data(withJSONObject: ["byAccount": ["acct-old": ["presets": []]]]).write(to: presetsURL)

        _ = try ctl.addProject(name: nil, path: vpn.path)

        let all = try presets(paths.profileDir("job"))
        XCTAssertEqual(cwds(all["acct-old"]), [vpn.path])
        XCTAssertEqual(cwds(all["acct-new"]), [vpn.path])
        XCTAssertEqual(all["acct-new"]?.first?["name"] as? String, "vpn", "folder name when no name is given")
    }

    func testAddBeforeSignInAddsTrustedFolderAndStartCompletesLater() throws {
        _ = try ctl.new(name: "job", workdir: nil)

        let (_, results) = try ctl.addProject(name: "VPN", path: vpn.path)

        XCTAssertEqual(results.first?.applied?.accounts, [])
        XCTAssertEqual(try trusted("job"), [vpn.path])
        XCTAssertEqual(try ctl.projectPresence(try XCTUnwrap(try ctl.projects().first)).first?.presence, .pendingSignIn)

        // Signed in; the next start writes the environment.
        try signIn("job", account: "acct-job")
        _ = try ctl.start(name: "job", folder: nil)

        XCTAssertEqual(cwds(try presets(paths.profileDir("job"))["acct-job"]), [vpn.path])
        XCTAssertEqual(try ctl.projectPresence(try XCTUnwrap(try ctl.projects().first)).first?.presence, .synced)
    }

    func testNewInstanceReceivesRegisteredProjects() throws {
        _ = try ctl.addProject(name: "VPN", path: vpn.path)

        _ = try ctl.new(name: "fresh", workdir: nil)

        XCTAssertEqual(try trusted("fresh"), [vpn.path])
    }

    func testAddIsIdempotentAndKeepsUserSettings() throws {
        _ = try ctl.new(name: "job", workdir: nil)
        try signIn("job", account: "acct-job")
        let presetsURL = paths.profileDir("job").appendingPathComponent("ccd-session-presets.json")
        try JSONSerialization.data(withJSONObject: ["byAccount": ["acct-job": ["presets": [[
            "id": "x", "name": "My VPN", "target": ["kind": "local", "cwd": vpn.path],
            "settings": ["modelId": "claude-opus-5-5"]
        ]]]]]).write(to: presetsURL)

        _ = try ctl.addProject(name: "VPN", path: vpn.path)
        _ = try ctl.syncProjects()

        let list = try XCTUnwrap(try presets(paths.profileDir("job"))["acct-job"])
        XCTAssertEqual(list.count, 1, "no second environment should be written for the same folder")
        XCTAssertEqual(list.first?["name"] as? String, "My VPN", "the user's environment should not be modified")
        XCTAssertNotNil(list.first?["settings"])
    }

    func testAddRejectsDuplicateNameOrPathAndMissingFolder() throws {
        _ = try ctl.addProject(name: "VPN", path: vpn.path)

        XCTAssertThrowsError(try ctl.addProject(name: "VPN", path: site.path))
        XCTAssertNoThrow(try ctl.addProject(name: "VPN", path: site.path, replace: true))
        XCTAssertThrowsError(try ctl.addProject(name: "Other", path: site.path), "the same folder cannot be registered under two names")
        XCTAssertThrowsError(try ctl.addProject(name: "Missing", path: root.appendingPathComponent("missing").path))
        XCTAssertThrowsError(try ctl.addProject(name: "  ", path: vpn.path))
    }

    func testAddResolvesTildeAndRelativePaths() throws {
        XCTAssertEqual(try Orchestrator.resolveDirectory("~"), NSHomeDirectory())
        XCTAssertEqual(try Orchestrator.resolveDirectory(vpn.path + "/../vpn/"), vpn.path)
    }

    func testOldConfigWithoutProjectsStillLoads() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"version":1,"instances":{}}"#.write(to: paths.configFile, atomically: true, encoding: .utf8)

        XCTAssertEqual(try ctl.projects(), [])
    }

    // MARK: - remove

    func testRemoveDeletesEnvironmentButKeepsFoldersStillInUse() throws {
        _ = try ctl.new(name: "job", workdir: site.path)
        try signIn("job", account: "acct-job")
        _ = try ctl.addProject(name: "VPN", path: vpn.path, additionalFolders: [site.path])

        let results = try ctl.removeProject(name: "VPN")

        XCTAssertEqual(results.first?.removed?.presetsRemoved, 1)
        XCTAssertFalse(cwds(try presets(paths.profileDir("job"))["acct-job"]).contains(vpn.path))
        XCTAssertFalse(try trusted("job").contains(vpn.path))
        XCTAssertTrue(try trusted("job").contains(site.path), "the instance workdir should not be removed from trusted folders")
        XCTAssertEqual(try ctl.projects(), [])
    }

    func testRemoveWithKeepLeavesInstancesUntouched() throws {
        _ = try ctl.new(name: "job", workdir: nil)
        try signIn("job", account: "acct-job")
        _ = try ctl.addProject(name: "VPN", path: vpn.path)

        XCTAssertEqual(try ctl.removeProject(name: "VPN", keepInInstances: true), [])
        XCTAssertEqual(cwds(try presets(paths.profileDir("job"))["acct-job"]), [vpn.path])
        XCTAssertThrowsError(try ctl.removeProject(name: "VPN"))
    }

    // MARK: - import

    func testImportTakesNewestNamePerFolderAndSkipsMissing() throws {
        let profile = root.appendingPathComponent("home/Claude")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["byAccount": [
            "acct-1": ["presets": [
                ["name": "vpn old", "lastUsedAt": 1, "target": ["kind": "local", "cwd": vpn.path]],
                ["name": "deleted", "lastUsedAt": 5, "target": ["kind": "local", "cwd": "/no/such/place"]]
            ]],
            "acct-2": ["presets": [
                ["name": "vpn new", "lastUsedAt": 9, "target": ["kind": "local", "cwd": vpn.path]],
                ["name": "remote", "target": ["kind": "remote", "cwd": site.path]]
            ]]
        ]]).write(to: profile.appendingPathComponent("ccd-session-presets.json"))

        let result = try ctl.importProjects(from: "default")

        XCTAssertEqual(result.imported.map(\.name), ["vpn new"])
        XCTAssertEqual(result.skipped.map(\.path), ["/no/such/place"])
        XCTAssertEqual(try ctl.projects().map(\.path), [vpn.path])

        let again = try ctl.importProjects(from: "default")
        XCTAssertEqual(again.imported, [], "a second import should not add again")
    }

    // MARK: - Desktop catalog format

    func testCatalogIsMarkedInitializedSoDesktopDoesNotWipeIt() throws {
        _ = try ctl.new(name: "job", workdir: nil)
        try signIn("job", account: "acct-job")
        // The format Desktop writes on first launch: marker false, empty list.
        let presetsURL = paths.profileDir("job").appendingPathComponent("ccd-session-presets.json")
        try JSONSerialization.data(withJSONObject: ["byAccount": ["acct-job": [
            "presets": [], "builtIns": ["local": ["settings": ["modelId": "x"]]], "seededFromDraft": false
        ]]]).write(to: presetsURL)

        _ = try ctl.addProject(name: "VPN", path: vpn.path)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: presetsURL)) as? [String: Any])
        let catalog = try XCTUnwrap((object["byAccount"] as? [String: Any])?["acct-job"] as? [String: Any])
        XCTAssertEqual(catalog["seededFromDraft"] as? Bool, true)
        XCTAssertEqual(((catalog["builtIns"] as? [String: Any])?["local"] as? [String: Any]) != nil, true,
                       "Desktop's builtIns settings should be preserved")
        XCTAssertEqual(cwds(catalog["presets"] as? [[String: Any]]), [vpn.path])
    }

    func testSyncRepairsOldCatalogWithoutMarkerEvenWhenNothingIsAdded() throws {
        _ = try ctl.new(name: "job", workdir: nil)
        try signIn("job", account: "acct-job")
        _ = try ctl.addProject(name: "VPN", path: vpn.path)
        // The format written by v0.2.6 and earlier: no marker.
        let presetsURL = paths.profileDir("job").appendingPathComponent("ccd-session-presets.json")
        let list = try XCTUnwrap(try presets(paths.profileDir("job"))["acct-job"])
        try JSONSerialization.data(withJSONObject: ["byAccount": ["acct-job": ["presets": list]]]).write(to: presetsURL)

        let results = try ctl.syncProjects()

        XCTAssertEqual(results.first?.applied?.addedCount, 0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: presetsURL)) as? [String: Any])
        let catalog = (object["byAccount"] as? [String: Any])?["acct-job"] as? [String: Any]
        XCTAssertEqual(catalog?["seededFromDraft"] as? Bool, true)
    }

    // MARK: - Desktop UI storage

    func testResetDesktopStateMovesLocalStorageAsideAndKeepsLogin() throws {
        _ = try ctl.new(name: "job", workdir: nil)
        try signIn("job", account: "acct-job")
        let profile = paths.profileDir("job")
        let storage = profile.appendingPathComponent("Local Storage/leveldb")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try "state".write(to: storage.appendingPathComponent("000001.log"), atomically: true, encoding: .utf8)
        try "cookie".write(to: profile.appendingPathComponent("Cookies"), atomically: true, encoding: .utf8)
        _ = try ctl.addProject(name: "VPN", path: vpn.path)

        let (backups, synced) = try ctl.reimportProjects()

        let backup = try XCTUnwrap(backups["job"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.appendingPathComponent("Local Storage").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("leveldb/000001.log").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.appendingPathComponent("Cookies").path), "sign-in should be preserved")
        XCTAssertEqual(synced.first?.error, nil)
        XCTAssertEqual(cwds(try presets(profile)["acct-job"]), [vpn.path])
    }

    func testResetDesktopStateRefusesWhenAnyInstanceIsRunning() throws {
        _ = try ctl.new(name: "job", workdir: nil)
        _ = try ctl.new(name: "school", workdir: nil)
        for name in ["job", "school"] {
            try FileManager.default.createDirectory(
                at: paths.profileDir(name).appendingPathComponent("Local Storage"), withIntermediateDirectories: true)
        }
        launcher.runningPids[paths.profileDir("school").path] = 7

        XCTAssertThrowsError(try ctl.reimportProjects()) { error in
            XCTAssertTrue("\(error)".contains("school"), "\(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.profileDir("job").appendingPathComponent("Local Storage").path),
                      "if any is running, none should be touched")
    }

    func testResetDesktopStateIsNoOpWithoutLocalStorage() throws {
        _ = try ctl.new(name: "job", workdir: nil)
        XCTAssertNil(try ctl.resetDesktopState(instance: "job"))
    }
}
