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
        _ = try ctl.new(name: "job", workdir: nil)
        _ = try ctl.new(name: "school", workdir: nil)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func record(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Writes a fake session into the instance's config directory.
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
                    "message": ["role": "user", "content": "Fix the VPN configuration"]]),
            record(["type": "assistant", "cwd": cwd, "sessionId": id, "version": version,
                    "timestamp": "2026-11-08T10:05:00.000Z",
                    "message": ["role": "assistant", "content": [["type": "text", "text": "OK"]]]]),
            record(["type": "user", "cwd": cwd, "sessionId": id, "version": version, "timestamp": end,
                    "message": ["role": "user", "content": [["type": "tool_result", "content": "output"]]]]),
            record(["type": "user", "cwd": cwd, "sessionId": id, "version": version, "timestamp": end,
                    "message": ["role": "user", "content": [["type": "text", "text": "Now test it"]]]]),
            "{\"half a line"
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
        XCTAssertEqual(SessionStore.slug(for: "/a/b-c"), SessionStore.slug(for: "/a/b/c"), "slug is one-way (may collide)")
        XCTAssertEqual(SessionStore.slug(for: "/tmp/üé"), "-tmp---")
    }

    // MARK: - Listeleme

    func testSummaryParsesTranscript() throws {
        try writeSession(instance: "job")

        let sessions = SessionStore(codeDir: paths.codeDir("job")).sessions()

        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.cwd, cwd)
        XCTAssertEqual(session.messageCount, 4, "meta entries are not counted")
        XCTAssertEqual(session.firstPrompt, "Fix the VPN configuration")
        XCTAssertEqual(session.lastPrompt, "Now test it", "a tool result is not counted as a prompt")
        XCTAssertEqual(session.cliVersion, "2.1.29")
        XCTAssertEqual(session.startedAt, ISO8601DateFormatter().date(from: "2026-11-08T10:00:00Z"))
        XCTAssertEqual(session.endedAt, ISO8601DateFormatter().date(from: "2026-11-08T11:30:00Z"))
    }

    func testListSortsAcrossInstancesByLastActivity() throws {
        try writeSession(instance: "job", id: "aaaa", end: "2026-11-08T09:00:00.000Z")
        try writeSession(instance: "school", id: "bbbb", end: "2026-11-08T12:00:00.000Z")

        let sessions = try ctl.sessions()

        XCTAssertEqual(sessions.map(\.session.id), ["bbbb", "aaaa"])
        XCTAssertEqual(sessions.map(\.endpoint.name), ["school", "job"])
    }

    func testListFiltersByProjectAndRunningState() throws {
        try writeSession(instance: "job", id: "aaaa")
        try writeSession(instance: "school", id: "bbbb", cwd: "/Users/x/school")
        launcher.runningPids[paths.profileDir("school").path] = 99

        XCTAssertEqual(try ctl.sessions(project: "/Users/x/school").map(\.session.id), ["bbbb"])
        XCTAssertEqual(try ctl.sessions(runningOnly: true).map(\.session.id), ["bbbb"])
        XCTAssertEqual(try ctl.sessions(instance: "job").map(\.session.id), ["aaaa"])
    }

    func testFindByUniquePrefixAndRejectsAmbiguousPrefix() throws {
        try writeSession(instance: "job", id: "abc111")
        try writeSession(instance: "job", id: "abc222")

        XCTAssertEqual(try ctl.findSession("abc1").session.id, "abc111")
        XCTAssertThrowsError(try ctl.findSession("abc")) { error in
            guard case .usage = error as? OrchestratorError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try ctl.findSession("missing")) { error in
            guard case .notFound = error as? OrchestratorError else { return XCTFail("\(error)") }
        }
    }

    func testFindRejectsSessionPresentInSeveralInstances() throws {
        try writeSession(instance: "job")
        try writeSession(instance: "school")

        XCTAssertThrowsError(try ctl.findSession(sessionID))
        XCTAssertEqual(try ctl.findSession(sessionID, instance: "school").endpoint.name, "school")
    }

    func testIgnoresTranscriptsWithUnsafeNames() throws {
        try writeSession(instance: "job")
        let projectDir = paths.codeDir("job").appendingPathComponent("projects/\(SessionStore.slug(for: cwd))")
        try "{}".write(to: projectDir.appendingPathComponent(".gizli.jsonl"), atomically: true, encoding: .utf8)

        XCTAssertEqual(SessionStore(codeDir: paths.codeDir("job")).sessions().count, 1)
    }

    // MARK: - Kopyalama

    func testCopyTransfersAllFilesAndKeepsSource() throws {
        let sourceTranscript = try writeSession(instance: "job")

        let result = try ctl.transferSession(sessionID, to: "school", move: false)

        let target = paths.codeDir("school")
        let projectDir = target.appendingPathComponent("projects/\(SessionStore.slug(for: cwd))")
        XCTAssertTrue(exists(projectDir.appendingPathComponent("\(sessionID).jsonl")))
        XCTAssertTrue(exists(projectDir.appendingPathComponent("\(sessionID)/subagents/agent-a.jsonl")))
        XCTAssertTrue(exists(target.appendingPathComponent("todos/\(sessionID)-agent-\(sessionID).json")))
        XCTAssertTrue(exists(sourceTranscript), "copy must not delete the source")
        XCTAssertNil(result.backup)
        XCTAssertEqual(try Data(contentsOf: projectDir.appendingPathComponent("\(sessionID).jsonl")),
                       try Data(contentsOf: sourceTranscript))

        // The target config directory should see the session (verification).
        XCTAssertEqual(try ctl.sessions(instance: "school").first?.session.id, sessionID)
    }

    func testCopyMergesIndexEntryAndRewritesConfigPaths() throws {
        try writeSession(instance: "job")

        try ctl.transferSession(sessionID, to: "school", move: false)

        let index = paths.codeDir("school")
            .appendingPathComponent("projects/\(SessionStore.slug(for: cwd))/sessions-index.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        XCTAssertEqual(object["originalPath"] as? String, cwd)
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        let fullPath = try XCTUnwrap(entries.first?["fullPath"] as? String)
        XCTAssertTrue(fullPath.hasPrefix(paths.codeDir("school").path), "path should be rewritten to the target config directory: \(fullPath)")
    }

    func testCopyRefusesExistingSessionUnlessForced() throws {
        try writeSession(instance: "job")
        try writeSession(instance: "school", extras: false)

        XCTAssertThrowsError(try ctl.transferSession(sessionID, from: "job", to: "school", move: false))
        XCTAssertNoThrow(try ctl.transferSession(sessionID, from: "job", to: "school", move: false, force: true))
    }

    func testCopyRefusesSlugCollisionWithDifferentPath() throws {
        // `/a/b-c` and `/a/b/c` map to the same slug; the directory in the target belongs to the other path.
        try writeSession(instance: "job", cwd: "/a/b-c")
        let targetDir = paths.codeDir("school").appendingPathComponent("projects/\(SessionStore.slug(for: "/a/b/c"))")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let index = try JSONSerialization.data(withJSONObject: ["version": 1, "originalPath": "/a/b/c", "entries": []])
        try index.write(to: targetDir.appendingPathComponent("sessions-index.json"))

        XCTAssertThrowsError(try ctl.transferSession(sessionID, to: "school", move: false)) { error in
            XCTAssertTrue("\(error)".contains("directory clash"), "\(error)")
        }
    }

    func testCopyRefusesRunningTargetUnlessForced() throws {
        try writeSession(instance: "job")
        launcher.runningPids[paths.profileDir("school").path] = 7

        XCTAssertThrowsError(try ctl.transferSession(sessionID, to: "school", move: false))
        XCTAssertNoThrow(try ctl.transferSession(sessionID, to: "school", move: false, force: true))
    }

    func testCopyToSameInstanceIsRejected() throws {
        try writeSession(instance: "job")
        XCTAssertThrowsError(try ctl.transferSession(sessionID, to: "job", move: false))
    }

    func testCopyLeavesNoTemporaryFiles() throws {
        try writeSession(instance: "job")
        try ctl.transferSession(sessionID, to: "school", move: false)

        let projectDir = paths.codeDir("school").appendingPathComponent("projects/\(SessionStore.slug(for: cwd))")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: projectDir.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])
    }

    func testWarnsWhenTargetCLIIsOlderThanSession() throws {
        try writeSession(instance: "job", version: "2.1.300")
        let cli = paths.profileDir("school").appendingPathComponent("claude-code/2.1.29")
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)

        let result = try ctl.transferSession(sessionID, to: "school", move: false)

        XCTAssertEqual(result.warnings.filter { $0.contains("2.1.300") }.count, 1, "\(result.warnings)")
    }

    func testVersionComparisonIsNumeric() {
        XCTAssertEqual(SessionTransfer.compareVersions("2.1.29", "2.1.308"), .orderedAscending)
        XCTAssertEqual(SessionTransfer.compareVersions("2.10.0", "2.9.9"), .orderedDescending)
    }

    // MARK: - Move

    func testMoveRemovesSourceIntoBackup() throws {
        let sourceTranscript = try writeSession(instance: "job")

        let result = try ctl.transferSession(sessionID, to: "school", move: true)

        XCTAssertFalse(exists(sourceTranscript))
        XCTAssertFalse(exists(sourceTranscript.deletingPathExtension()), "the subagent directory should be moved too")
        let backup = try XCTUnwrap(result.backup)
        XCTAssertTrue(backup.path.hasPrefix(paths.backupsDir.path))
        XCTAssertTrue(exists(backup.appendingPathComponent("\(sessionID).jsonl")))
        XCTAssertTrue(exists(backup.appendingPathComponent("manifest.json")))
        XCTAssertEqual(try ctl.sessions(instance: "job").count, 0)
        XCTAssertEqual(try ctl.sessions(instance: "school").count, 1)

        let sourceIndex = sourceTranscript.deletingLastPathComponent().appendingPathComponent("sessions-index.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sourceIndex)) as? [String: Any])
        XCTAssertEqual((object["entries"] as? [Any])?.count, 0, "the source index entry should be removed")
    }

    func testMoveRefusesRunningSourceUnlessForced() throws {
        try writeSession(instance: "job")
        launcher.runningPids[paths.profileDir("job").path] = 7

        XCTAssertThrowsError(try ctl.transferSession(sessionID, to: "school", move: true))
        XCTAssertNoThrow(try ctl.transferSession(sessionID, to: "school", move: false), "copy is allowed from a running source")
    }

    func testLastSessionPicksMostRecent() throws {
        try writeSession(instance: "job", id: "old", end: "2026-11-07T10:00:00.000Z")
        try writeSession(instance: "job", id: "new", end: "2026-11-08T20:00:00.000Z")

        XCTAssertEqual(try ctl.lastSession(instance: "job").session.id, "new")
        XCTAssertThrowsError(try ctl.lastSession(instance: "school"))
    }

    // MARK: - Desktop metadata

    private func writeDesktopMetadata(instance: String, account: String, org: String, cliID: String?) throws -> URL {
        let profile = paths.profileDir(instance)
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": account])
            .write(to: profile.appendingPathComponent("config.json"))
        let dir = profile.appendingPathComponent("claude-code-sessions/\(account)/\(org)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let cliID else { return dir }
        let file = dir.appendingPathComponent("local_src.json")
        try JSONSerialization.data(withJSONObject: [
            "sessionId": "local_src", "cliSessionId": cliID, "title": "VPN fix",
            "cwd": cwd, "envScopeId": "hesaba-bagli", "remoteMcpServersConfig": []
        ]).write(to: file)
        return file
    }

    func testTitleComesFromDesktopMetadata() throws {
        try writeSession(instance: "job")
        _ = try writeDesktopMetadata(instance: "job", account: "acct-job", org: "org-job", cliID: sessionID)

        XCTAssertEqual(try ctl.findSession(sessionID).session.title, "VPN fix")
    }

    func testCopyWritesSanitizedDesktopMetadataForTargetAccount() throws {
        try writeSession(instance: "job")
        _ = try writeDesktopMetadata(instance: "job", account: "acct-job", org: "org-job", cliID: sessionID)
        let targetDir = try writeDesktopMetadata(instance: "school", account: "acct-school", org: "org-school", cliID: nil)

        let result = try ctl.transferSession(sessionID, to: "school", move: false)

        let file = try XCTUnwrap(result.desktopMetadata)
        XCTAssertEqual(file.deletingLastPathComponent().path, targetDir.path)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(object["cliSessionId"] as? String, sessionID)
        XCTAssertEqual(object["title"] as? String, "VPN fix")
        XCTAssertNotEqual(object["sessionId"] as? String, "local_src", "a new local id should be assigned")
        XCTAssertNil(object["envScopeId"], "account-bound fields should be dropped")
        XCTAssertNil(object["remoteMcpServersConfig"])
    }

    func testCopyWarnsWhenTargetAccountUnknown() throws {
        try writeSession(instance: "job")
        _ = try writeDesktopMetadata(instance: "job", account: "acct-job", org: "org-job", cliID: sessionID)

        let result = try ctl.transferSession(sessionID, to: "school", move: false)

        XCTAssertNil(result.desktopMetadata)
        XCTAssertTrue(result.warnings.contains { $0.contains("claude --resume") }, "\(result.warnings)")
    }

    // MARK: - Default installation

    func testDefaultEndpointUsesDefaultInstallation() throws {
        let home = root.appendingPathComponent("home/.claude")
        let projectDir = home.appendingPathComponent("projects/\(SessionStore.slug(for: cwd))")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try writeSession(instance: "job", id: "fromdefault", extras: false),
                                         to: projectDir.appendingPathComponent("fromdefault.jsonl"))

        XCTAssertEqual(try ctl.sessions(instance: "default").map(\.session.id), ["fromdefault"])

        launcher.defaultPid = 1
        XCTAssertThrowsError(try ctl.transferSession("fromdefault", from: "job", to: "default", move: false),
                             "should be rejected as a target while the default Claude is running")
    }

    func testDefaultIsReservedForNewInstances() {
        XCTAssertThrowsError(try ctl.new(name: "default", workdir: nil)) { error in
            guard case .invalidName = error as? OrchestratorError else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Cloning and new --sessions-from

    func testCloneCopiesProfileConfigAndSessions() throws {
        try writeSession(instance: "job")
        let profile = paths.profileDir("job")
        try "cerez".write(to: profile.appendingPathComponent("Cookies"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: profile.appendingPathComponent("SingletonLock").path,
                                                   withDestinationPath: "host-123")
        try JSONFile.write(InstanceState(pid: 123), to: paths.stateFile("job"))

        let result = try ctl.clone("job", as: "job2")

        XCTAssertEqual(result.sessionCount, 1)
        XCTAssertTrue(exists(paths.profileDir("job2").appendingPathComponent("Cookies")))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: paths.profileDir("job2").appendingPathComponent("SingletonLock").path), "the lock must not be copied")
        XCTAssertFalse(exists(paths.stateFile("job2")))
        XCTAssertEqual(try ctl.store.instance(named: "job2").name, "job2")
    }

    func testCloneRefusesRunningSourceAndExistingTarget() throws {
        launcher.runningPids[paths.profileDir("job").path] = 5
        XCTAssertThrowsError(try ctl.clone("job", as: "job2"))
        launcher.runningPids = [:]
        XCTAssertThrowsError(try ctl.clone("job", as: "school"))
    }

    func testCopyAllSessionsForNewInstance() throws {
        try writeSession(instance: "job", id: "aaaa")
        try writeSession(instance: "job", id: "bbbb", cwd: "/Users/x/other")
        _ = try ctl.new(name: "fresh", workdir: nil)

        let (copied, skipped) = try ctl.copyAllSessions(from: "job", to: "fresh")

        XCTAssertEqual(copied.count, 2)
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(Set(try ctl.sessions(instance: "fresh").map(\.session.id)), ["aaaa", "bbbb"])
    }

    // MARK: - Cache

    func testSummaryCacheIsUsedAndInvalidatedOnChange() throws {
        let transcript = try writeSession(instance: "job", extras: false)
        let cache = root.appendingPathComponent("cache.json")
        let store = SessionStore(codeDir: paths.codeDir("job"), cacheFile: cache)

        XCTAssertEqual(store.sessions().first?.messageCount, 4)
        XCTAssertTrue(exists(cache))
        let permissions = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)

        // When the file changes (different size), the summary should be recomputed.
        let extra = "\n" + record(["type": "assistant", "timestamp": "2026-11-08T12:00:00.000Z",
                                   "message": ["role": "assistant", "content": "ek"]])
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(extra.utf8))
        try handle.close()

        XCTAssertEqual(store.sessions().first?.messageCount, 5)
    }

    func testCorruptCacheIsIgnored() throws {
        try writeSession(instance: "job", extras: false)
        let cache = root.appendingPathComponent("cache.json")
        try "bozuk".write(to: cache, atomically: true, encoding: .utf8)

        XCTAssertEqual(SessionStore(codeDir: paths.codeDir("job"), cacheFile: cache).sessions().count, 1)
    }
}
