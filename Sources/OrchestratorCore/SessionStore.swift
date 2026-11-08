import Foundation

/// Bir Claude Code oturumunun özeti.
///
/// Oturumlar instance'ın `CLAUDE_CONFIG_DIR` (= `claude-code/`) altında yaşar:
///
/// ```
/// <config-dir>/
/// ├── projects/<cwd-slug>/
/// │   ├── <session-id>.jsonl              # transcript (her kayıt bir satır)
/// │   ├── <session-id>/                   # alt ajanlar, araç çıktıları
/// │   └── sessions-index.json             # proje oturum indeksi (varsa)
/// └── todos/<session-id>*.json            # oturumun TODO dosyaları
/// ```
///
/// Claude Desktop'un Code sekmesi ayrıca profilde bir üst veri dosyası tutar:
/// `<profil>/claude-code-sessions/<hesap>/<org>/local_<id>.json` (`cliSessionId`
/// alanı transcript'e işaret eder; başlık buradan okunur).
public struct SessionSummary: Equatable, Codable {
    /// Claude Code oturum kimliği (transcript dosya adı).
    public var id: String
    /// `projects/` altındaki dizin adı.
    public var projectSlug: String
    /// Transcript'teki gerçek çalışma dizini (bulunamazsa `nil`).
    public var cwd: String?
    public var startedAt: Date?
    public var endedAt: Date?
    /// Kullanıcı + asistan mesajı sayısı (meta kayıtlar hariç).
    public var messageCount: Int
    public var firstPrompt: String?
    public var lastPrompt: String?
    /// Oturumu yazan Claude Code sürümü (son görülen).
    public var cliVersion: String?
    /// Claude Desktop'taki başlık (üst veri varsa).
    public var title: String?
    public var transcript: URL
    public var sizeBytes: Int64

    /// Sıralama ve "son oturum" seçimi için kullanılan zaman.
    public var lastActivity: Date {
        endedAt ?? startedAt ?? .distantPast
    }
}

/// Tek bir config dizinindeki (ve isteğe bağlı profildeki) oturumları okur.
public struct SessionStore {
    /// `CLAUDE_CONFIG_DIR`.
    public let codeDir: URL
    /// Electron profili (Desktop üst verisi için; yoksa `nil`).
    public let profileDir: URL?
    /// Transcript özet önbelleği (yoksa her seferinde taranır).
    public let cacheFile: URL?

    public init(codeDir: URL, profileDir: URL? = nil, cacheFile: URL? = nil) {
        self.codeDir = codeDir
        self.profileDir = profileDir
        self.cacheFile = cacheFile
    }

    public var projectsDir: URL { codeDir.appendingPathComponent("projects") }
    public var todosDir: URL { codeDir.appendingPathComponent("todos") }

    /// Claude Code'un proje dizini adı: alfasayısal olmayan her karakter `-` olur.
    ///
    /// Dönüşüm tek yönlüdür: `/a/b-c` ile `/a/b/c` aynı slug'a düşer. Bu yüzden
    /// transfer sırasında hedef dizinin gerçek yolu (`sessions-index.json` →
    /// `originalPath`) ayrıca doğrulanır.
    public static func slug(for path: String) -> String {
        String(path.unicodeScalars.map { scalar -> Character in
            let isAlphanumeric = (scalar.value < 128) && CharacterSet.alphanumerics.contains(scalar)
            return isAlphanumeric ? Character(scalar) : "-"
        })
    }

    /// Tüm oturumlar (en son etkinlik önce).
    public func sessions() -> [SessionSummary] {
        let fm = FileManager.default
        guard let slugs = try? fm.contentsOfDirectory(atPath: projectsDir.path) else { return [] }
        let titles = desktopTitles()
        let cache = SummaryCache(url: cacheFile)

        var result: [SessionSummary] = []
        for slug in slugs {
            let dir = projectsDir.appendingPathComponent(slug)
            guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let id = String(file.dropLast(".jsonl".count))
                guard Self.isValidID(id) else { continue }
                let transcript = dir.appendingPathComponent(file)
                var summary = cache.summary(for: transcript) {
                    Self.summarize(transcript: transcript, id: id, slug: slug)
                }
                summary.title = titles[id]
                result.append(summary)
            }
        }
        cache.save()
        return result.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Kimliğe (veya benzersiz bir önekine) göre oturum.
    ///
    /// - Throws: Önek birden çok oturumla eşleşirse `usage`.
    public func find(_ idOrPrefix: String) throws -> SessionSummary? {
        let all = sessions()
        if let exact = all.first(where: { $0.id == idOrPrefix }) { return exact }
        let matches = all.filter { $0.id.hasPrefix(idOrPrefix) }
        if matches.count > 1 {
            throw OrchestratorError.usage(
                "oturum öneki belirsiz: '\(idOrPrefix)' — \(matches.count) oturumla eşleşiyor"
            )
        }
        return matches.first
    }

    /// Bir oturuma ait tüm dosyalar (transcript, alt dizin, TODO'lar).
    public func files(for session: SessionSummary) -> [URL] {
        let fm = FileManager.default
        var urls = [session.transcript]
        let sidecar = session.transcript.deletingPathExtension()
        if fm.fileExists(atPath: sidecar.path) { urls.append(sidecar) }
        urls.append(contentsOf: todoFiles(for: session.id))
        return urls
    }

    func todoFiles(for id: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: todosDir.path)) ?? []
        return names
            .filter { $0.hasPrefix(id) && $0.hasSuffix(".json") }
            .sorted()
            .map { todosDir.appendingPathComponent($0) }
    }

    /// Oturum kimliği dosya adı olarak güvenli mi? (yol ayırıcı / `..` yok)
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128
            && id.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*\\z", options: .regularExpression) != nil
    }

    // MARK: - Transcript özeti

    /// Transcript özetini çıkarır.
    ///
    /// Transcript'ler yüzlerce MB olabilir; her satırı JSON olarak çözmek
    /// pahalıdır. Bu yüzden dosya belleğe eşlenir (mmap) ve satırlar önce bayt
    /// düzeyinde süzülür; yalnızca gereken birkaç satır çözülür:
    /// - mesaj sayısı: üst düzey `"type":"user"`/`"type":"assistant"` kalıbı
    ///   (meta ve yan zincir kayıtları hariç) — JSON dizelerinde tırnaklar kaçışlı
    ///   olduğundan bu kalıp yalnızca yapısal düzeyde geçer
    /// - başlangıç/`cwd`: baştan ilk zaman damgalı kayıt
    /// - bitiş/sürüm: sondan ilk zaman damgalı kayıt
    /// - ilk/son istem: baştan/sondan araç sonucu içermeyen ilk kullanıcı satırı
    static func summarize(transcript: URL, id: String, slug: String) -> SessionSummary {
        let size = (try? FileManager.default.attributesOfItem(atPath: transcript.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        var summary = SessionSummary(
            id: id, projectSlug: slug, cwd: nil, startedAt: nil, endedAt: nil,
            messageCount: 0, firstPrompt: nil, lastPrompt: nil, cliVersion: nil,
            title: nil, transcript: transcript, sizeBytes: size
        )
        guard let data = try? Data(contentsOf: transcript, options: .alwaysMapped) else { return summary }

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        func date(_ record: [String: Any]) -> Date? {
            guard let stamp = record["timestamp"] as? String else { return nil }
            return isoFractional.date(from: stamp) ?? iso.date(from: stamp)
        }

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let lines = lineRanges(base: base, count: raw.count)

            func line(_ range: Range<Int>) -> UnsafeRawBufferPointer {
                UnsafeRawBufferPointer(start: base + range.lowerBound, count: range.count)
            }
            func record(_ range: Range<Int>) -> [String: Any]? {
                let bytes = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + range.lowerBound),
                                 count: range.count, deallocator: .none)
                return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            }
            func isMessage(_ bytes: UnsafeRawBufferPointer) -> Bool {
                (contains(bytes, Pattern.typeUser) || contains(bytes, Pattern.typeAssistant))
                    && !contains(bytes, Pattern.isMeta) && !contains(bytes, Pattern.isSidechain)
            }
            func isPromptCandidate(_ bytes: UnsafeRawBufferPointer) -> Bool {
                contains(bytes, Pattern.typeUser) && !contains(bytes, Pattern.isMeta)
                    && !contains(bytes, Pattern.isSidechain) && !contains(bytes, Pattern.toolResult)
            }

            summary.messageCount = lines.reduce(0) { $0 + (isMessage(line($1)) ? 1 : 0) }

            for range in lines where contains(line(range), Pattern.timestamp) {
                guard let object = record(range), let start = date(object) else { continue }
                summary.startedAt = start
                summary.cwd = object["cwd"] as? String
                break
            }
            if summary.cwd == nil {
                for range in lines where contains(line(range), Pattern.cwd) {
                    if let cwd = record(range)?["cwd"] as? String { summary.cwd = cwd; break }
                }
            }
            for range in lines.reversed() where contains(line(range), Pattern.timestamp) {
                guard let object = record(range), let end = date(object) else { continue }
                summary.endedAt = end
                break
            }
            for range in lines.reversed() where contains(line(range), Pattern.version) {
                if let version = record(range)?["version"] as? String { summary.cliVersion = version; break }
            }
            for range in lines where isPromptCandidate(line(range)) {
                if let object = record(range), let prompt = promptText(object) { summary.firstPrompt = prompt; break }
            }
            for range in lines.reversed() where isPromptCandidate(line(range)) {
                if let object = record(range), let prompt = promptText(object) { summary.lastPrompt = prompt; break }
            }
        }
        return summary
    }

    /// Bayt kalıpları (JSON'da ayraçlardan sonra boşluk olmadığı varsayılır —
    /// Claude Code transcript'leri sıkıştırılmış JSON yazar).
    enum Pattern {
        static let typeUser = Array(#""type":"user""#.utf8)
        static let typeAssistant = Array(#""type":"assistant""#.utf8)
        static let isMeta = Array(#""isMeta":true"#.utf8)
        static let isSidechain = Array(#""isSidechain":true"#.utf8)
        static let toolResult = Array(#""type":"tool_result""#.utf8)
        static let timestamp = Array(#""timestamp":""#.utf8)
        static let cwd = Array(#""cwd":""#.utf8)
        static let version = Array(#""version":""#.utf8)
    }

    /// Satır aralıkları (boş satırlar hariç).
    static func lineRanges(base: UnsafePointer<UInt8>, count: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        while start < count {
            let remaining = count - start
            let end: Int
            if let found = memchr(base + start, Int32(UInt8(ascii: "\n")), remaining) {
                end = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
            } else {
                end = count
            }
            if end > start { ranges.append(start..<end) }
            start = end + 1
        }
        return ranges
    }

    static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { pattern in
            memmem(base, haystack.count, pattern.baseAddress!, pattern.count) != nil
        }
    }

    /// Kullanıcının yazdığı metin (araç sonuçları ve komut kayıtları hariç).
    static func promptText(_ record: [String: Any]) -> String? {
        guard let message = record["message"] as? [String: Any] else { return nil }
        var text: String?
        if let content = message["content"] as? String {
            text = content
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: " ")
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        let singleLine = trimmed.split(whereSeparator: \.isNewline).joined(separator: " ")
        return singleLine.count > 200 ? String(singleLine.prefix(199)) + "…" : singleLine
    }

    // MARK: - Claude Desktop üst verisi

    /// `cliSessionId` → Desktop üst veri dosyası.
    public func desktopMetadataFiles() -> [String: URL] {
        guard let root = profileDir?.appendingPathComponent("claude-code-sessions") else { return [:] }
        let fm = FileManager.default
        var result: [String: URL] = [:]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("local_"), name.hasSuffix(".json"),
                  let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let cliID = object["cliSessionId"] as? String
            else { continue }
            result[cliID] = url
        }
        return result
    }

    private func desktopTitles() -> [String: String] {
        var titles: [String: String] = [:]
        for (cliID, url) in desktopMetadataFiles() {
            guard let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let title = object["title"] as? String, !title.isEmpty
            else { continue }
            titles[cliID] = title
        }
        return titles
    }

    /// Bu profilde Desktop oturum üst verisinin yazılacağı dizin
    /// (`claude-code-sessions/<etkin hesap>/<org>`). Belirlenemiyorsa `nil`.
    public func desktopMetadataDirectory() -> URL? {
        guard let profileDir,
              let account = ProfileSeeder.activeAccountUUID(profileDir: profileDir)
        else { return nil }
        let accountDir = profileDir.appendingPathComponent("claude-code-sessions/\(account)")
        let orgs = ((try? FileManager.default.contentsOfDirectory(atPath: accountDir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        // Birden çok org varsa hangisinin etkin olduğu bilinmiyor: tahmin yapılmaz.
        guard orgs.count == 1 else { return nil }
        return accountDir.appendingPathComponent(orgs[0])
    }
}

/// Transcript özetlerinin disk önbelleği.
///
/// Anahtar transcript'in mutlak yolu; dosyanın boyutu ve değişiklik zamanı
/// değişmediyse özet yeniden hesaplanmaz. Önbellek bozuk/okunamazsa sessizce
/// yok sayılır (yalnızca hız kazancıdır, doğruluk kaynağı değildir).
final class SummaryCache {
    struct Entry: Codable {
        var size: Int64
        var modified: Double
        var summary: SessionSummary
    }

    struct Contents: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    static let version = 1

    private let url: URL?
    private var contents: Contents
    private var dirty = false

    init(url: URL?) {
        self.url = url
        if let url,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Contents.self, from: data),
           decoded.version == Self.version {
            contents = decoded
        } else {
            contents = Contents(version: Self.version, entries: [:])
        }
    }

    func summary(for transcript: URL, compute: () -> SessionSummary) -> SessionSummary {
        guard url != nil else { return compute() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: transcript.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let key = transcript.path

        if let entry = contents.entries[key], entry.size == size, entry.modified == modified {
            return entry.summary
        }
        let summary = compute()
        contents.entries[key] = Entry(size: size, modified: modified, summary: summary)
        dirty = true
        return summary
    }

    func save() {
        guard dirty, let url else { return }
        // Silinmiş transcript'lerin kayıtları atılır.
        contents.entries = contents.entries.filter { FileManager.default.fileExists(atPath: $0.key) }
        guard let data = try? JSONEncoder().encode(contents) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        // İstem özetleri içerir: transcript'ler gibi yalnızca kullanıcıya açık.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        dirty = false
    }
}
