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

    // MARK: - Yardımcılar

    /// Instance profilini "giriş yapılmış" hale getirir.
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
        _ = try ctl.new(name: "is", workdir: nil)
        _ = try ctl.new(name: "okul", workdir: nil)
        try signIn("is", account: "acct-is")
        try signIn("okul", account: "acct-okul")

        let (project, results) = try ctl.addProject(name: "VPN", path: vpn.path, additionalFolders: [site.path])

        XCTAssertEqual(project.path, vpn.path)
        XCTAssertEqual(results.map(\.instance), ["is", "okul"])
        XCTAssertEqual(cwds(try presets(paths.profileDir("is"))["acct-is"]), [vpn.path])
        XCTAssertEqual(cwds(try presets(paths.profileDir("okul"))["acct-okul"]), [vpn.path])

        let preset = try XCTUnwrap(try presets(paths.profileDir("is"))["acct-is"]?.first)
        XCTAssertEqual(preset["name"] as? String, "VPN")
        XCTAssertEqual((preset["target"] as? [String: Any])?["additionalFolders"] as? [String], [site.path])
        XCTAssertEqual(Set(try trusted("is")), [vpn.path, site.path])
    }

    func testAddWritesToAllAccountsInOneProfile() throws {
        _ = try ctl.new(name: "is", workdir: nil)
        try signIn("is", account: "acct-yeni")
        let presetsURL = paths.profileDir("is").appendingPathComponent("ccd-session-presets.json")
        try JSONSerialization.data(withJSONObject: ["byAccount": ["acct-eski": ["presets": []]]]).write(to: presetsURL)

        _ = try ctl.addProject(name: nil, path: vpn.path)

        let all = try presets(paths.profileDir("is"))
        XCTAssertEqual(cwds(all["acct-eski"]), [vpn.path])
        XCTAssertEqual(cwds(all["acct-yeni"]), [vpn.path])
        XCTAssertEqual(all["acct-yeni"]?.first?["name"] as? String, "vpn", "ad verilmezse klasör adı")
    }

    func testAddBeforeSignInAddsTrustedFolderAndStartCompletesLater() throws {
        _ = try ctl.new(name: "is", workdir: nil)

        let (_, results) = try ctl.addProject(name: "VPN", path: vpn.path)

        XCTAssertEqual(results.first?.applied?.accounts, [])
        XCTAssertEqual(try trusted("is"), [vpn.path])
        XCTAssertEqual(try ctl.projectPresence(try XCTUnwrap(try ctl.projects().first)).first?.presence, .pendingSignIn)

        // Giriş yapıldı; bir sonraki start ortamı yazar.
        try signIn("is", account: "acct-is")
        _ = try ctl.start(name: "is", folder: nil)

        XCTAssertEqual(cwds(try presets(paths.profileDir("is"))["acct-is"]), [vpn.path])
        XCTAssertEqual(try ctl.projectPresence(try XCTUnwrap(try ctl.projects().first)).first?.presence, .synced)
    }

    func testNewInstanceReceivesRegisteredProjects() throws {
        _ = try ctl.addProject(name: "VPN", path: vpn.path)

        _ = try ctl.new(name: "yeni", workdir: nil)

        XCTAssertEqual(try trusted("yeni"), [vpn.path])
    }

    func testAddIsIdempotentAndKeepsUserSettings() throws {
        _ = try ctl.new(name: "is", workdir: nil)
        try signIn("is", account: "acct-is")
        let presetsURL = paths.profileDir("is").appendingPathComponent("ccd-session-presets.json")
        try JSONSerialization.data(withJSONObject: ["byAccount": ["acct-is": ["presets": [[
            "id": "x", "name": "Benim VPN", "target": ["kind": "local", "cwd": vpn.path],
            "settings": ["modelId": "claude-opus-5-5"]
        ]]]]]).write(to: presetsURL)

        _ = try ctl.addProject(name: "VPN", path: vpn.path)
        _ = try ctl.syncProjects()

        let list = try XCTUnwrap(try presets(paths.profileDir("is"))["acct-is"])
        XCTAssertEqual(list.count, 1, "aynı klasör için ikinci ortam yazılmamalı")
        XCTAssertEqual(list.first?["name"] as? String, "Benim VPN", "kullanıcının ortamı değiştirilmemeli")
        XCTAssertNotNil(list.first?["settings"])
    }

    func testAddRejectsDuplicateNameOrPathAndMissingFolder() throws {
        _ = try ctl.addProject(name: "VPN", path: vpn.path)

        XCTAssertThrowsError(try ctl.addProject(name: "VPN", path: site.path))
        XCTAssertNoThrow(try ctl.addProject(name: "VPN", path: site.path, replace: true))
        XCTAssertThrowsError(try ctl.addProject(name: "Başka", path: site.path), "aynı klasör iki adla kaydedilemez")
        XCTAssertThrowsError(try ctl.addProject(name: "Yok", path: root.appendingPathComponent("yok").path))
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
        _ = try ctl.new(name: "is", workdir: site.path)
        try signIn("is", account: "acct-is")
        _ = try ctl.addProject(name: "VPN", path: vpn.path, additionalFolders: [site.path])

        let results = try ctl.removeProject(name: "VPN")

        XCTAssertEqual(results.first?.removed?.presetsRemoved, 1)
        XCTAssertFalse(cwds(try presets(paths.profileDir("is"))["acct-is"]).contains(vpn.path))
        XCTAssertFalse(try trusted("is").contains(vpn.path))
        XCTAssertTrue(try trusted("is").contains(site.path), "instance workdir'i güvenli klasörlerden çıkarılmamalı")
        XCTAssertEqual(try ctl.projects(), [])
    }

    func testRemoveWithKeepLeavesInstancesUntouched() throws {
        _ = try ctl.new(name: "is", workdir: nil)
        try signIn("is", account: "acct-is")
        _ = try ctl.addProject(name: "VPN", path: vpn.path)

        XCTAssertEqual(try ctl.removeProject(name: "VPN", keepInInstances: true), [])
        XCTAssertEqual(cwds(try presets(paths.profileDir("is"))["acct-is"]), [vpn.path])
        XCTAssertThrowsError(try ctl.removeProject(name: "VPN"))
    }

    // MARK: - import

    func testImportTakesNewestNamePerFolderAndSkipsMissing() throws {
        let profile = root.appendingPathComponent("home/Claude")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["byAccount": [
            "acct-1": ["presets": [
                ["name": "vpn eski", "lastUsedAt": 1, "target": ["kind": "local", "cwd": vpn.path]],
                ["name": "silinmiş", "lastUsedAt": 5, "target": ["kind": "local", "cwd": "/yok/boyle/bir/yer"]]
            ]],
            "acct-2": ["presets": [
                ["name": "vpn yeni", "lastUsedAt": 9, "target": ["kind": "local", "cwd": vpn.path]],
                ["name": "uzak", "target": ["kind": "remote", "cwd": site.path]]
            ]]
        ]]).write(to: profile.appendingPathComponent("ccd-session-presets.json"))

        let result = try ctl.importProjects(from: "default")

        XCTAssertEqual(result.imported.map(\.name), ["vpn yeni"])
        XCTAssertEqual(result.skipped.map(\.path), ["/yok/boyle/bir/yer"])
        XCTAssertEqual(try ctl.projects().map(\.path), [vpn.path])

        let again = try ctl.importProjects(from: "default")
        XCTAssertEqual(again.imported, [], "ikinci içe aktarma tekrar eklememeli")
    }
}
