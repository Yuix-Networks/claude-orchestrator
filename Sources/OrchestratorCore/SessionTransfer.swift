import Foundation

/// Oturum transferinin sonucu.
public struct TransferResult: Equatable {
    public var session: SessionSummary
    /// Hedefe yazılan dosyalar.
    public var copiedFiles: [URL]
    /// Hedef profile yazılan Desktop üst veri dosyası (yazılamadıysa `nil`).
    public var desktopMetadata: URL?
    /// `move` sırasında kaynak dosyaların taşındığı yedek dizini.
    public var backup: URL?
    public var warnings: [String]
}

/// Oturumları iki config dizini (instance) arasında kopyalar/taşır.
///
/// Kurallar:
/// - Hedefte aynı kimlikte oturum varsa reddedilir (`force` ile üzerine yazılır).
/// - Hedef proje dizini başka bir gerçek yola aitse (slug çakışması) reddedilir.
/// - Her dosya önce hedef dizinde geçici bir ada kopyalanır, sonra `rename`
///   ile yerine konur: yarım kalmış transcript oluşmaz.
/// - `move`, kaynak dosyaları silmez; `backupsDir` altına taşır (geri alınabilir).
public struct SessionTransfer {
    public let source: SessionStore
    public let target: SessionStore
    /// `move` yedeklerinin kökü.
    public let backupsDir: URL
    /// Hedef instance'ın kurulu Claude Code CLI sürümü (bilinmiyorsa `nil`).
    public let targetCLIVersion: String?

    /// Desktop üst verisinde hesaba/ortama bağlı alanlar: başka bir hesaba
    /// taşındığında geçersiz kalırlar, bu yüzden kopyalanmazlar.
    static let accountBoundMetadataKeys: Set<String> = [
        "remoteMcpServersConfig", "envScopeId", "startedFromEnvironmentId",
        "toolSurfaceSnapshot", "promptAppendSnapshot", "spawnSeed",
        "cliMcpAppServerNames", "remoteControlAutoEligible", "steeredByRemoteClient",
        "sessionPermissionUpdates", "alwaysAllowedReasons"
    ]

    public init(source: SessionStore, target: SessionStore, backupsDir: URL, targetCLIVersion: String? = nil) {
        self.source = source
        self.target = target
        self.backupsDir = backupsDir
        self.targetCLIVersion = targetCLIVersion
    }

    // MARK: - Ön kontrol

    /// Transferi engelleyen sorunlar (boşsa transfer yapılabilir).
    public func blockers(for session: SessionSummary, force: Bool) -> [String] {
        var problems: [String] = []
        if source.codeDir.standardizedFileURL == target.codeDir.standardizedFileURL {
            problems.append("kaynak ve hedef aynı instance")
            return problems
        }
        let targetTranscript = targetProjectDir(session).appendingPathComponent("\(session.id).jsonl")
        if !force, FileManager.default.fileExists(atPath: targetTranscript.path) {
            problems.append("hedefte aynı kimlikte oturum var: \(session.id) (üzerine yazmak için --force)")
        }
        if !force, let cwd = session.cwd, let original = originalPath(of: targetProjectDir(session)), original != cwd {
            problems.append(
                "proje dizini çakışması: hedefte '\(session.projectSlug)' dizini '\(original)' yoluna ait, "
                + "oturum '\(cwd)' yolunda (zorlamak için --force)"
            )
        }
        return problems
    }

    /// Transferi engellemeyen ama kullanıcıya gösterilmesi gereken uyarılar.
    public func warnings(for session: SessionSummary) -> [String] {
        var notes: [String] = []
        if let sessionVersion = session.cliVersion, let targetCLIVersion,
           Self.compareVersions(sessionVersion, targetCLIVersion) == .orderedDescending {
            notes.append(
                "oturum Claude Code \(sessionVersion) ile yazılmış, hedefteki CLI \(targetCLIVersion) — "
                + "transcript biçimi farklı olabilir"
            )
        }
        return notes
    }

    // MARK: - Transfer

    /// Oturumu kopyalar; `move` ise kaynak yedeğe taşınır.
    @discardableResult
    public func transfer(_ session: SessionSummary, move: Bool, force: Bool) throws -> TransferResult {
        let problems = blockers(for: session, force: force)
        guard problems.isEmpty else {
            throw OrchestratorError.runtime(problems.joined(separator: "; "))
        }

        let fm = FileManager.default
        let targetDir = targetProjectDir(session)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        var copied: [URL] = []
        // Transcript en son yazılır: yarıda kalan bir transfer hedefte
        // görünür (yarım) bir oturum bırakmasın.
        let sidecar = session.transcript.deletingPathExtension()
        if fm.fileExists(atPath: sidecar.path) {
            copied.append(try atomicCopy(sidecar, to: targetDir.appendingPathComponent(sidecar.lastPathComponent)))
        }
        for todo in source.todoFiles(for: session.id) {
            try fm.createDirectory(at: target.todosDir, withIntermediateDirectories: true)
            copied.append(try atomicCopy(todo, to: target.todosDir.appendingPathComponent(todo.lastPathComponent)))
        }
        copied.append(try atomicCopy(session.transcript, to: targetDir.appendingPathComponent("\(session.id).jsonl")))

        try mergeIndexEntry(for: session, into: targetDir)

        var notes = warnings(for: session)
        let metadata = try copyDesktopMetadata(for: session, force: force, warnings: &notes)

        // Doğrulama: hedef config dizini oturumu görebiliyor mu?
        guard (try? target.find(session.id)) != nil else {
            throw OrchestratorError.runtime("transfer doğrulanamadı: hedefte oturum görünmüyor (\(session.id))")
        }

        var backup: URL?
        if move {
            backup = try moveSourceToBackup(session)
        }

        return TransferResult(
            session: session,
            copiedFiles: copied,
            desktopMetadata: metadata,
            backup: backup,
            warnings: notes
        )
    }

    // MARK: - Yardımcılar

    func targetProjectDir(_ session: SessionSummary) -> URL {
        target.projectsDir.appendingPathComponent(session.projectSlug)
    }

    /// `sessions-index.json` → `originalPath` (yoksa `nil`).
    func originalPath(of projectDir: URL) -> String? {
        let url = projectDir.appendingPathComponent("sessions-index.json")
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object["originalPath"] as? String
    }

    /// Dosya veya dizini geçici ada kopyalayıp `rename` ile yerine koyar.
    @discardableResult
    func atomicCopy(_ from: URL, to destination: URL) throws -> URL {
        let fm = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: from, to: temporary)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fm.removeItem(at: temporary)
            throw OrchestratorError.runtime(
                "kopyalanamadı: \(from.path) → \(destination.path) — \(error.localizedDescription)"
            )
        }
        return destination
    }

    /// Kaynak indeksindeki kaydı hedef indekse ekler (aynı kimlik varsa değiştirir).
    ///
    /// Kayıtlardaki kaynak config yolu hedef config yoluyla değiştirilir
    /// (`fullPath` gibi alanlar mutlak yol taşır).
    func mergeIndexEntry(for session: SessionSummary, into targetDir: URL) throws {
        let sourceIndex = session.transcript.deletingLastPathComponent().appendingPathComponent("sessions-index.json")
        let targetIndex = targetDir.appendingPathComponent("sessions-index.json")

        let sourceObject = readObject(sourceIndex)
        let sourceEntries = sourceObject?["entries"] as? [[String: Any]] ?? []
        guard let entry = sourceEntries.first(where: { $0["sessionId"] as? String == session.id }) else {
            return // Kaynakta kayıt yok: Claude Code transcript'leri dizinden de bulur.
        }

        var targetObject = readObject(targetIndex) ?? [
            "version": sourceObject?["version"] ?? 1,
            "originalPath": session.cwd ?? sourceObject?["originalPath"] ?? NSNull()
        ]
        var entries = (targetObject["entries"] as? [[String: Any]] ?? [])
            .filter { $0["sessionId"] as? String != session.id }
        entries.append(rewritePaths(entry) as? [String: Any] ?? entry)
        targetObject["entries"] = entries

        let data = try JSONSerialization.data(withJSONObject: targetObject, options: [.prettyPrinted, .sortedKeys])
        try writeAtomically(data, to: targetIndex)
    }

    private func rewritePaths(_ value: Any) -> Any {
        let from = source.codeDir.standardizedFileURL.path
        let to = target.codeDir.standardizedFileURL.path
        switch value {
        case let string as String:
            return string.hasPrefix(from + "/") ? to + string.dropFirst(from.count) : string
        case let dictionary as [String: Any]:
            return dictionary.mapValues { rewritePaths($0) }
        case let array as [Any]:
            return array.map { rewritePaths($0) }
        default:
            return value
        }
    }

    /// Desktop Code sekmesinin kenar çubuğunda görünmesi için üst veri kopyası.
    ///
    /// Hesaba bağlı alanlar atılır; yeni bir `local_<uuid>` kimliği verilir.
    /// Hedef profilde etkin hesap/org belirlenemiyorsa yazılmaz (uyarı eklenir).
    func copyDesktopMetadata(for session: SessionSummary, force: Bool, warnings: inout [String]) throws -> URL? {
        guard let sourceFile = source.desktopMetadataFiles()[session.id],
              var object = readObject(sourceFile)
        else { return nil }

        let resumeHint = "Claude Desktop kenar çubuğunda görünmeyebilir; terminalden açmak için: "
            + "CLAUDE_CONFIG_DIR=\"\(target.codeDir.path)\" claude --resume \(session.id)"
        guard let directory = target.desktopMetadataDirectory() else {
            warnings.append("hedef profilde etkin hesap/org belirlenemedi (giriş yapılmamış olabilir) — " + resumeHint)
            return nil
        }

        if let existing = target.desktopMetadataFiles()[session.id] {
            guard force else { return existing }
            try? FileManager.default.removeItem(at: existing)
        }

        let localID = "local_\(UUID().uuidString.lowercased())"
        for key in Self.accountBoundMetadataKeys { object.removeValue(forKey: key) }
        object["sessionId"] = localID
        object["cliSessionId"] = session.id

        let destination = directory.appendingPathComponent("\(localID).json")
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try writeAtomically(data, to: destination)
        return destination
    }

    /// `move`: kaynak dosyalarını yedek dizinine taşır ve indeks kaydını siler.
    func moveSourceToBackup(_ session: SessionSummary) throws -> URL {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let backup = backupsDir.appendingPathComponent("\(stamp)-\(session.id)")
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)

        var items = source.files(for: session)
        if let metadata = source.desktopMetadataFiles()[session.id] { items.append(metadata) }
        for item in items {
            try fm.moveItem(at: item, to: backup.appendingPathComponent(item.lastPathComponent))
        }

        // Kaynak indeks kaydı yedeğe yazılır, indeksten silinir.
        let index = session.transcript.deletingLastPathComponent().appendingPathComponent("sessions-index.json")
        if var object = readObject(index), let entries = object["entries"] as? [[String: Any]] {
            let kept = entries.filter { $0["sessionId"] as? String != session.id }
            if kept.count != entries.count {
                try fm.copyItem(at: index, to: backup.appendingPathComponent("sessions-index.json"))
                object["entries"] = kept
                let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                try writeAtomically(data, to: index)
            }
        }

        // Geri yükleme için nereden geldiğini kaydet.
        let manifest: [String: Any] = [
            "sessionId": session.id,
            "sourceConfigDir": source.codeDir.path,
            "targetConfigDir": target.codeDir.path,
            "projectSlug": session.projectSlug,
            "movedAt": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: backup.appendingPathComponent("manifest.json"))
        return backup
    }

    private func readObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw OrchestratorError.runtime("yazılamadı: \(url.path) — \(error.localizedDescription)")
        }
    }

    /// Noktalı sürüm karşılaştırması (`2.1.29` < `2.1.308`).
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }
}
