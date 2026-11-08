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
          // elle yazılmış not
          "//": "not alanı",
          "projects": [
            { "name": "A", "path": "a", "folders": ["b", "./b", "a"] },
            { "path": "\(c.path)", },
          ],
        }
        """)

        let projects = try Orchestrator.loadManifest(manifest)

        XCTAssertEqual(projects.map(\.name), ["A", "c"])
        XCTAssertEqual(projects[0].path, a.path, "göreli yol dosyanın klasörüne göre")
        XCTAssertEqual(projects[0].additionalFolders, [b.path], "tekrar ve ana klasör ek klasörlerden atılır")
        XCTAssertEqual(try Orchestrator.resolveDirectory("~"), NSHomeDirectory())
    }

    func testReportsAllProblemsAtOnce() throws {
        try write("""
        { "projects": [
            { "name": "A", "path": "a", "folder": ["b"] },
            { "name": "A", "path": "b" },
            { "name": "C", "path": "yok" },
            { "name": "D", "path": "c", "folders": ["yok-ek"] },
            { "name": "E", "path": "a" },
            { "name": "" , "path": "c" },
            "metin"
        ], "proje": [] }
        """)

        XCTAssertThrowsError(try Orchestrator.loadManifest(manifest)) { error in
            let text = "\(error)"
            for fragment in ["\"proje\"", "\"folder\"", "projects[0] ile aynı", "klasör bulunamadı",
                             "ek klasör", "projects[5]: \"name\" geçersiz", "projects[6]: bir nesne"] {
                XCTAssertTrue(text.contains(fragment), "'\(fragment)' bekleniyordu:\n\(text)")
            }
            XCTAssertTrue(text.contains("hiçbir şey değiştirilmedi"))
        }
    }

    func testRejectsInvalidJSONWithLocation() throws {
        try write("{ \"projects\": [ { \"path\": \"a\" } ")
        XCTAssertThrowsError(try Orchestrator.loadManifest(manifest)) { error in
            XCTAssertTrue("\(error)".contains("geçerli JSON değil"), "\(error)")
        }
    }

    // MARK: - Plan ve uygulama

    func testApplyAddsUpdatesRenamesAndKeepsUntrackedWithoutPrune() throws {
        try signIn("is")
        _ = try ctl.addProject(name: "A", path: a.path)
        _ = try ctl.addProject(name: "B", path: b.path)
        _ = try ctl.addProject(name: "Eski", path: c.path)

        try write("""
        { "projects": [
            { "name": "A", "path": "a", "folders": ["b"] },
            { "name": "Yeni", "path": "c" }
        ] }
        """)
        let plan = try ctl.planApply(try Orchestrator.loadManifest(manifest), prune: false)

        XCTAssertEqual(plan.toUpdate.map(\.new.name), ["A"])
        XCTAssertEqual(plan.toRename.map { "\($0.old.name)>\($0.new.name)" }, ["Eski>Yeni"])
        XCTAssertEqual(plan.untracked.map(\.name), ["B"])
        XCTAssertEqual(plan.toRemove, [])

        let result = try ctl.apply(plan)

        XCTAssertEqual(try ctl.projects().map(\.name), ["A", "B", "Yeni"])
        XCTAssertEqual(try ctl.projects().first?.additionalFolders, [b.path])
        XCTAssertEqual(result.synced.first?.error, nil)
        XCTAssertEqual(try presetNames("is")[c.path], "Yeni", "yeniden adlandırma Desktop ortamına da yansımalı")
    }

    func testPruneRemovesProjectsMissingFromFileAndTheirEnvironments() throws {
        try signIn("is")
        _ = try ctl.addProject(name: "A", path: a.path)
        _ = try ctl.addProject(name: "B", path: b.path)
        try write(#"{ "projects": [ { "name": "A", "path": "a" } ] }"#)

        let plan = try ctl.planApply(try Orchestrator.loadManifest(manifest), prune: true)
        XCTAssertEqual(plan.toRemove.map(\.name), ["B"])
        _ = try ctl.apply(plan)

        XCTAssertEqual(try ctl.projects().map(\.name), ["A"])
        XCTAssertNil(try presetNames("is")[b.path])
        XCTAssertEqual(try presetNames("is")[a.path], "A")
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
        // A başka klasöre taşınıyor, eski klasörü yeni proje B alıyor.
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

    // MARK: - Dışa aktarma

    func testExportRoundTripsAndKeepsFieldOrder() throws {
        _ = try ctl.addProject(name: "A \"tırnaklı\"", path: a.path, additionalFolders: [b.path])
        _ = try ctl.addProject(name: "C", path: c.path)

        let text = try ctl.exportManifest()
        XCTAssertTrue(text.contains(#"{ "name": "A \"tırnaklı\"", "path": "#), text)
        try write(text)

        let loaded = try Orchestrator.loadManifest(manifest)
        XCTAssertEqual(loaded.map(\.name), ["A \"tırnaklı\"", "C"])
        XCTAssertEqual(loaded.first?.additionalFolders, [b.path])
        XCTAssertFalse(try ctl.planApply(loaded, prune: true).hasChanges)
    }

    func testExportAbbreviatesHomeDirectory() {
        let home = NSHomeDirectory()
        let text = Orchestrator.renderManifest([Project(name: "x", path: home + "/workspace/x")])
        XCTAssertTrue(text.contains(#""path": "~/workspace/x""#), text)
    }
}
