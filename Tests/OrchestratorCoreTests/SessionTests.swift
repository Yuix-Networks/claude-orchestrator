import XCTest
@testable import OrchestratorCore

final class SessionTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var launcher: FakeLauncher!
    private var ctl: Orchestrator!

    private let cwd = "/Users/x/workspace/vpn"
    private let sessionID = "11111111-2222-3333-4444-555555555555"

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
        _ = try ctl.new(name: "is", workdir: nil)
        _ = try ctl.new(name: "okul", workdir: nil)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Yardımcılar

    private func record(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Instance config dizinine sahte bir oturum yazar.
    @discardableResult
    private func writeSession(
        instance: String,
        id: String? = nil,
        cwd: String? = nil,
        start: String = "2026-11-08T10:00:00.000Z",
        end: String = "2026-11-08T11:30:00.000Z",
        version: String = "2.1.29",
        extras: Bool = true
    ) throws -> URL {
        let id = id ?? sessionID
        let cwd = cwd ?? self.cwd
        let codeDir = paths.codeDir(instance)
        let projectDir = codeDir.appendingPathComponent("projects/\(SessionStore.slug(for: cwd))")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines = [
            record(["type": "file-history-snapshot", "messageId": "m0"]),
            record(["type": "user", "isMeta": true, "cwd": cwd, "sessionId": id, "version": version,
                    "timestamp": start, "message": ["role": "user", "content": "<local-command-caveat>x</local-command-caveat>"]]),
            record(["type": "user", "cwd": cwd, "sessionId": id, "version": version, "timestamp": start,
                    "message": ["role": "user", "content": "VPN yapılandırmasını düzelt"]]),
            record(["type": "assistant", "cwd": cwd, "sessionId": id, "version": version,
                    "timestamp": "2026-11-08T10:05:00.000Z",
                    "message": ["role": "assistant", "content": [["type": "text", "text": "Tamam"]]]]),
            record(["type": "user", "cwd": cwd, "sessionId": id, "version": version, "timestamp": end,
                    "message": ["role": "user", "content": [["type": "tool_result", "content": "çıktı"]]]]),
            record(["type": "user", "cwd": cwd, "sessionId": id, "version": version, "timestamp": end,
                    "message": ["role": "user", "content": [["type": "text", "text": "Şimdi test et"]]]]),
            "{\"yarım satır"
        ]
        let transcript = projectDir.appendingPathComponent("\(id).jsonl")
        try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        if extras {
            let subagents = projectDir.appendingPathComponent("\(id)/subagents")
            try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
            try "{}".write(to: subagents.appendingPathComponent("agent-a.jsonl"), atomically: true, encoding: .utf8)

            let todos = codeDir.appendingPathComponent("todos")
            try FileManager.default.createDirectory(at: todos, withIntermediateDirectories: true)
            try "[]".write(to: todos.appendingPathComponent("\(id)-agent-\(id).json"), atomically: true, encoding: .utf8)

            let index: [String: Any] = [
                "version": 1,
                "originalPath": cwd,
                "entries": [["sessionId": id, "fullPath": transcript.path, "firstPrompt": "VPN"]]
            ]
            let data = try JSONSerialization.data(withJSONObject: index)
            try data.write(to: projectDir.appendingPathComponent("sessions-index.json"))
        }
        return transcript
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: - Slug

    func testSlugReplacesNonAlphanumericCharacters() {
        XCTAssertEqual(SessionStore.slug(for: "/Users/x/workspace/vpn"), "-Users-x-workspace-vpn")
        XCTAssertEqual(SessionStore.slug(for: "/Users/x/.claude"), "-Users-x--claude")
        XCTAssertEqual(SessionStore.slug(for: "/a/b-c"), SessionStore.slug(for: "/a/b/c"), "slug tek yönlü (çakışabilir)")
        XCTAssertEqual(SessionStore.slug(for: "/tmp/ğü"), "-tmp---")
    }

    // MARK: - Listeleme

    func testSummaryParsesTranscript() throws {
        try writeSession(instance: "is")

        let sessions = SessionStore(codeDir: paths.codeDir("is")).sessions()

        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.cwd, cwd)
        XCTAssertEqual(session.messageCount, 4, "meta kayıt sayılmaz")
        XCTAssertEqual(session.firstPrompt, "VPN yapılandırmasını düzelt")
        XCTAssertEqual(session.lastPrompt, "Şimdi test et", "araç sonucu istem sayılmaz")
        XCTAssertEqual(session.cliVersion, "2.1.29")
        XCTAssertEqual(session.startedAt, ISO8601DateFormatter().date(from: "2026-11-08T10:00:00Z"))
        XCTAssertEqual(session.endedAt, ISO8601DateFormatter().date(from: "2026-11-08T11:30:00Z"))
    }

    func testListSortsAcrossInstancesByLastActivity() throws {
        try writeSession(instance: "is", id: "aaaa", end: "2026-11-08T09:00:00.000Z")
        try writeSession(instance: "okul", id: "bbbb", end: "2026-11-08T12:00:00.000Z")

        let sessions = try ctl.sessions()

        XCTAssertEqual(sessions.map(\.session.id), ["bbbb", "aaaa"])
        XCTAssertEqual(sessions.map(\.endpoint.name), ["okul", "is"])
    }

    func testListFiltersByProjectAndRunningState() throws {
        try writeSession(instance: "is", id: "aaaa")
        try writeSession(instance: "okul", id: "bbbb", cwd: "/Users/x/okul")
        launcher.runningPids[paths.profileDir("okul").path] = 99

        XCTAssertEqual(try ctl.sessions(project: "/Users/x/okul").map(\.session.id), ["bbbb"])
        XCTAssertEqual(try ctl.sessions(runningOnly: true).map(\.session.id), ["bbbb"])
        XCTAssertEqual(try ctl.sessions(instance: "is").map(\.session.id), ["aaaa"])
    }

    func testFindByUniquePrefixAndRejectsAmbiguousPrefix() throws {
        try writeSession(instance: "is", id: "abc111")
        try writeSession(instance: "is", id: "abc222")

        XCTAssertEqual(try ctl.findSession("abc1").session.id, "abc111")
        XCTAssertThrowsError(try ctl.findSession("abc")) { error in
            guard case .usage = error as? OrchestratorError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try ctl.findSession("yok")) { error in
            guard case .notFound = error as? OrchestratorError else { return XCTFail("\(error)") }
        }
    }

    func testFindRejectsSessionPresentInSeveralInstances() throws {
        try writeSession(instance: "is")
        try writeSession(instance: "okul")

        XCTAssertThrowsError(try ctl.findSession(sessionID))
        XCTAssertEqual(try ctl.findSession(sessionID, instance: "okul").endpoint.name, "okul")
    }

    func testIgnoresTranscriptsWithUnsafeNames() throws {
        try writeSession(instance: "is")
        let projectDir = paths.codeDir("is").appendingPathComponent("projects/\(SessionStore.slug(for: cwd))")
        try "{}".write(to: projectDir.appendingPathComponent(".gizli.jsonl"), atomically: true, encoding: .utf8)

        XCTAssertEqual(SessionStore(codeDir: paths.codeDir("is")).sessions().count, 1)
    }

    // MARK: - Kopyalama

    func testCopyTransfersAllFilesAndKeepsSource() throws {
        let sourceTranscript = try writeSession(instance: "is")

        let result = try ctl.transferSession(sessionID, to: "okul", move: false)

        let target = paths.codeDir("okul")
        let projectDir = target.appendingPathComponent("projects/\(SessionStore.slug(for: cwd))")
        XCTAssertTrue(exists(projectDir.appendingPathComponent("\(sessionID).jsonl")))
        XCTAssertTrue(exists(projectDir.appendingPathComponent("\(sessionID)/subagents/agent-a.jsonl")))
        XCTAssertTrue(exists(target.appendingPathComponent("todos/\(sessionID)-agent-\(sessionID).json")))
        XCTAssertTrue(exists(sourceTranscript), "copy kaynağı silmemeli")
        XCTAssertNil(result.backup)
        XCTAssertEqual(try Data(contentsOf: projectDir.appendingPathComponent("\(sessionID).jsonl")),
                       try Data(contentsOf: sourceTranscript))

        // Hedef config dizini oturumu görmeli (doğrulama).
        XCTAssertEqual(try ctl.sessions(instance: "okul").first?.session.id, sessionID)
    }

    func testCopyMergesIndexEntryAndRewritesConfigPaths() throws {
        try writeSession(instance: "is")

        try ctl.transferSession(sessionID, to: "okul", move: false)

        let index = paths.codeDir("okul")
            .appendingPathComponent("projects/\(SessionStore.slug(for: cwd))/sessions-index.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        XCTAssertEqual(object["originalPath"] as? String, cwd)
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        let fullPath = try XCTUnwrap(entries.first?["fullPath"] as? String)
        XCTAssertTrue(fullPath.hasPrefix(paths.codeDir("okul").path), "yol hedef config dizinine çevrilmeli: \(fullPath)")
    }

    func testCopyRefusesExistingSessionUnlessForced() throws {
        try writeSession(instance: "is")
        try writeSession(instance: "okul", extras: false)

        XCTAssertThrowsError(try ctl.transferSession(sessionID, from: "is", to: "okul", move: false))
        XCTAssertNoThrow(try ctl.transferSession(sessionID, from: "is", to: "okul", move: false, force: true))
    }

    func testCopyRefusesSlugCollisionWithDifferentPath() throws {
        // `/a/b-c` ve `/a/b/c` aynı slug'a düşer; hedefteki dizin diğer yola ait.
        try writeSession(instance: "is", cwd: "/a/b-c")
        let targetDir = paths.codeDir("okul").appendingPathComponent("projects/\(SessionStore.slug(for: "/a/b/c"))")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let index = try JSONSerialization.data(withJSONObject: ["version": 1, "originalPath": "/a/b/c", "entries": []])
        try index.write(to: targetDir.appendingPathComponent("sessions-index.json"))

        XCTAssertThrowsError(try ctl.transferSession(sessionID, to: "okul", move: false)) { error in
            XCTAssertTrue("\(error)".contains("çakışması"), "\(error)")
        }
    }

    func testCopyRefusesRunningTargetUnlessForced() throws {
        try writeSession(instance: "is")
        launcher.runningPids[paths.profileDir("okul").path] = 7

        XCTAssertThrowsError(try ctl.transferSession(sessionID, to: "okul", move: false))
        XCTAssertNoThrow(try ctl.transferSession(sessionID, to: "okul", move: false, force: true))
    }

    func testCopyToSameInstanceIsRejected() throws {
        try writeSession(instance: "is")
        XCTAssertThrowsError(try ctl.transferSession(sessionID, to: "is", move: false))
    }

    func testCopyLeavesNoTemporaryFiles() throws {
        try writeSession(instance: "is")
        try ctl.transferSession(sessionID, to: "okul", move: false)

        let projectDir = paths.codeDir("okul").appendingPathComponent("projects/\(SessionStore.slug(for: cwd))")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: projectDir.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])
    }

    func testWarnsWhenTargetCLIIsOlderThanSession() throws {
        try writeSession(instance: "is", version: "2.1.300")
        let cli = paths.profileDir("okul").appendingPathComponent("claude-code/2.1.29")
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)

        let result = try ctl.transferSession(sessionID, to: "okul", move: false)

        XCTAssertEqual(result.warnings.filter { $0.contains("2.1.300") }.count, 1, "\(result.warnings)")
    }

    func testVersionComparisonIsNumeric() {
        XCTAssertEqual(SessionTransfer.compareVersions("2.1.29", "2.1.308"), .orderedAscending)
        XCTAssertEqual(SessionTransfer.compareVersions("2.10.0", "2.9.9"), .orderedDescending)
    }

    // MARK: - Taşıma

    func testMoveRemovesSourceIntoBackup() throws {
        let sourceTranscript = try writeSession(instance: "is")

        let result = try ctl.transferSession(sessionID, to: "okul", move: true)

        XCTAssertFalse(exists(sourceTranscript))
        XCTAssertFalse(exists(sourceTranscript.deletingPathExtension()), "alt ajan dizini de taşınmalı")
        let backup = try XCTUnwrap(result.backup)
        XCTAssertTrue(backup.path.hasPrefix(paths.backupsDir.path))
        XCTAssertTrue(exists(backup.appendingPathComponent("\(sessionID).jsonl")))
        XCTAssertTrue(exists(backup.appendingPathComponent("manifest.json")))
        XCTAssertEqual(try ctl.sessions(instance: "is").count, 0)
        XCTAssertEqual(try ctl.sessions(instance: "okul").count, 1)

        let sourceIndex = sourceTranscript.deletingLastPathComponent().appendingPathComponent("sessions-index.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sourceIndex)) as? [String: Any])
        XCTAssertEqual((object["entries"] as? [Any])?.count, 0, "kaynak indeks kaydı silinmeli")
    }

    func testMoveRefusesRunningSourceUnlessForced() throws {
        try writeSession(instance: "is")
        launcher.runningPids[paths.profileDir("is").path] = 7

        XCTAssertThrowsError(try ctl.transferSession(sessionID, to: "okul", move: true))
        XCTAssertNoThrow(try ctl.transferSession(sessionID, to: "okul", move: false), "copy çalışan kaynaktan yapılabilir")
    }

    func testLastSessionPicksMostRecent() throws {
        try writeSession(instance: "is", id: "eski", end: "2026-11-07T10:00:00.000Z")
        try writeSession(instance: "is", id: "yeni", end: "2026-11-08T20:00:00.000Z")

        XCTAssertEqual(try ctl.lastSession(instance: "is").session.id, "yeni")
        XCTAssertThrowsError(try ctl.lastSession(instance: "okul"))
    }

    // MARK: - Desktop üst verisi

    private func writeDesktopMetadata(instance: String, account: String, org: String, cliID: String?) throws -> URL {
        let profile = paths.profileDir(instance)
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": account])
            .write(to: profile.appendingPathComponent("config.json"))
        let dir = profile.appendingPathComponent("claude-code-sessions/\(account)/\(org)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let cliID else { return dir }
        let file = dir.appendingPathComponent("local_src.json")
        try JSONSerialization.data(withJSONObject: [
            "sessionId": "local_src", "cliSessionId": cliID, "title": "VPN düzeltmesi",
            "cwd": cwd, "envScopeId": "hesaba-bagli", "remoteMcpServersConfig": []
        ]).write(to: file)
        return file
    }

    func testTitleComesFromDesktopMetadata() throws {
        try writeSession(instance: "is")
        _ = try writeDesktopMetadata(instance: "is", account: "acct-is", org: "org-is", cliID: sessionID)

        XCTAssertEqual(try ctl.findSession(sessionID).session.title, "VPN düzeltmesi")
    }

    func testCopyWritesSanitizedDesktopMetadataForTargetAccount() throws {
        try writeSession(instance: "is")
        _ = try writeDesktopMetadata(instance: "is", account: "acct-is", org: "org-is", cliID: sessionID)
        let targetDir = try writeDesktopMetadata(instance: "okul", account: "acct-okul", org: "org-okul", cliID: nil)

        let result = try ctl.transferSession(sessionID, to: "okul", move: false)

        let file = try XCTUnwrap(result.desktopMetadata)
        XCTAssertEqual(file.deletingLastPathComponent().path, targetDir.path)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(object["cliSessionId"] as? String, sessionID)
        XCTAssertEqual(object["title"] as? String, "VPN düzeltmesi")
        XCTAssertNotEqual(object["sessionId"] as? String, "local_src", "yeni local kimliği verilmeli")
        XCTAssertNil(object["envScopeId"], "hesaba bağlı alanlar atılmalı")
        XCTAssertNil(object["remoteMcpServersConfig"])
    }

    func testCopyWarnsWhenTargetAccountUnknown() throws {
        try writeSession(instance: "is")
        _ = try writeDesktopMetadata(instance: "is", account: "acct-is", org: "org-is", cliID: sessionID)

        let result = try ctl.transferSession(sessionID, to: "okul", move: false)

        XCTAssertNil(result.desktopMetadata)
        XCTAssertTrue(result.warnings.contains { $0.contains("claude --resume") }, "\(result.warnings)")
    }

    // MARK: - Varsayılan kurulum

    func testDefaultEndpointUsesDefaultInstallation() throws {
        let home = root.appendingPathComponent("home/.claude")
        let projectDir = home.appendingPathComponent("projects/\(SessionStore.slug(for: cwd))")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try writeSession(instance: "is", id: "varsayilan", extras: false),
                                         to: projectDir.appendingPathComponent("varsayilan.jsonl"))

        XCTAssertEqual(try ctl.sessions(instance: "default").map(\.session.id), ["varsayilan"])

        launcher.defaultPid = 1
        XCTAssertThrowsError(try ctl.transferSession("varsayilan", from: "is", to: "default", move: false),
                             "varsayılan Claude çalışıyorsa hedef olarak reddedilmeli")
    }

    func testDefaultIsReservedForNewInstances() {
        XCTAssertThrowsError(try ctl.new(name: "default", workdir: nil)) { error in
            guard case .invalidName = error as? OrchestratorError else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Klonlama ve new --sessions-from

    func testCloneCopiesProfileConfigAndSessions() throws {
        try writeSession(instance: "is")
        let profile = paths.profileDir("is")
        try "cerez".write(to: profile.appendingPathComponent("Cookies"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: profile.appendingPathComponent("SingletonLock").path,
                                                   withDestinationPath: "host-123")
        try JSONFile.write(InstanceState(pid: 123), to: paths.stateFile("is"))

        let result = try ctl.clone("is", as: "is2")

        XCTAssertEqual(result.sessionCount, 1)
        XCTAssertTrue(exists(paths.profileDir("is2").appendingPathComponent("Cookies")))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: paths.profileDir("is2").appendingPathComponent("SingletonLock").path), "kilit kopyalanmamalı")
        XCTAssertFalse(exists(paths.stateFile("is2")))
        XCTAssertEqual(try ctl.store.instance(named: "is2").name, "is2")
    }

    func testCloneRefusesRunningSourceAndExistingTarget() throws {
        launcher.runningPids[paths.profileDir("is").path] = 5
        XCTAssertThrowsError(try ctl.clone("is", as: "is2"))
        launcher.runningPids = [:]
        XCTAssertThrowsError(try ctl.clone("is", as: "okul"))
    }

    func testCopyAllSessionsForNewInstance() throws {
        try writeSession(instance: "is", id: "aaaa")
        try writeSession(instance: "is", id: "bbbb", cwd: "/Users/x/baska")
        _ = try ctl.new(name: "yeni", workdir: nil)

        let (copied, skipped) = try ctl.copyAllSessions(from: "is", to: "yeni")

        XCTAssertEqual(copied.count, 2)
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(Set(try ctl.sessions(instance: "yeni").map(\.session.id)), ["aaaa", "bbbb"])
    }

    // MARK: - Önbellek

    func testSummaryCacheIsUsedAndInvalidatedOnChange() throws {
        let transcript = try writeSession(instance: "is", extras: false)
        let cache = root.appendingPathComponent("cache.json")
        let store = SessionStore(codeDir: paths.codeDir("is"), cacheFile: cache)

        XCTAssertEqual(store.sessions().first?.messageCount, 4)
        XCTAssertTrue(exists(cache))
        let permissions = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)

        // Dosya değişince (boyut farklı) özet yeniden hesaplanmalı.
        let extra = "\n" + record(["type": "assistant", "timestamp": "2026-11-08T12:00:00.000Z",
                                   "message": ["role": "assistant", "content": "ek"]])
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(extra.utf8))
        try handle.close()

        XCTAssertEqual(store.sessions().first?.messageCount, 5)
    }

    func testCorruptCacheIsIgnored() throws {
        try writeSession(instance: "is", extras: false)
        let cache = root.appendingPathComponent("cache.json")
        try "bozuk".write(to: cache, atomically: true, encoding: .utf8)

        XCTAssertEqual(SessionStore(codeDir: paths.codeDir("is"), cacheFile: cache).sessions().count, 1)
    }
}
