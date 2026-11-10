import Foundation

/// Summary of a Claude Code session.
///
/// Sessions live under the instance's `CLAUDE_CONFIG_DIR` (= `claude-code/`):
///
/// ```
/// <config-dir>/
/// ├── projects/<cwd-slug>/
/// │   ├── <session-id>.jsonl              # transcript (one record per line)
/// │   ├── <session-id>/                   # subagents, tool output
/// │   └── sessions-index.json             # project session index (if any)
/// └── todos/<session-id>*.json            # the session's TODO files
/// ```
///
/// Claude Desktop's Code tab also keeps a metadata file in the profile:
/// `<profile>/claude-code-sessions/<account>/<org>/local_<id>.json` (its
/// `cliSessionId` field points at the transcript; the title is read from here).
public struct SessionSummary: Equatable, Codable {
    /// Claude Code session id (the transcript file name).
    public var id: String
    /// Directory name under `projects/`.
    public var projectSlug: String
    /// The real working directory from the transcript (`nil` if not found).
    public var cwd: String?
    public var startedAt: Date?
    public var endedAt: Date?
    /// Number of user + assistant messages (excluding meta records).
    public var messageCount: Int
    public var firstPrompt: String?
    public var lastPrompt: String?
    /// Claude Code version that wrote the session (the last one seen).
    public var cliVersion: String?
    /// Title in Claude Desktop (if there is metadata).
    public var title: String?
    public var transcript: URL
    public var sizeBytes: Int64

    /// Time used for sorting and for picking the "latest session".
    public var lastActivity: Date {
        endedAt ?? startedAt ?? .distantPast
    }
}

/// Reads the sessions in a single config directory (and, optionally, profile).
public struct SessionStore {
    /// `CLAUDE_CONFIG_DIR`.
    public let codeDir: URL
    /// Electron profile (for Desktop metadata; `nil` if none).
    public let profileDir: URL?
    /// Transcript summary cache (without it, transcripts are scanned every time).
    public let cacheFile: URL?

    public init(codeDir: URL, profileDir: URL? = nil, cacheFile: URL? = nil) {
        self.codeDir = codeDir
        self.profileDir = profileDir
        self.cacheFile = cacheFile
    }

    public var projectsDir: URL { codeDir.appendingPathComponent("projects") }
    public var todosDir: URL { codeDir.appendingPathComponent("todos") }

    /// Claude Code's project directory name: every non-alphanumeric character becomes `-`.
    ///
    /// The mapping is one-way: `/a/b-c` and `/a/b/c` produce the same slug. That's
    /// why a transfer also checks the real path of the target directory
    /// (`sessions-index.json` → `originalPath`).
    public static func slug(for path: String) -> String {
        String(path.unicodeScalars.map { scalar -> Character in
            let isAlphanumeric = (scalar.value < 128) && CharacterSet.alphanumerics.contains(scalar)
            return isAlphanumeric ? Character(scalar) : "-"
        })
    }

    /// All sessions (most recent activity first).
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

    /// Session by id (or a unique id prefix).
    ///
    /// - Throws: `usage` if the prefix matches more than one session.
    public func find(_ idOrPrefix: String) throws -> SessionSummary? {
        let all = sessions()
        if let exact = all.first(where: { $0.id == idOrPrefix }) { return exact }
        let matches = all.filter { $0.id.hasPrefix(idOrPrefix) }
        if matches.count > 1 {
            throw OrchestratorError.usage(
                "ambiguous session prefix '\(idOrPrefix)': matches \(matches.count) sessions"
            )
        }
        return matches.first
    }

    /// All files belonging to a session (transcript, subdirectory, TODOs).
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

    /// Is the session id safe to use as a file name? (no path separators or `..`)
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128
            && id.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*\\z", options: .regularExpression) != nil
    }

    // MARK: - Transcript summary

    /// Builds the transcript summary.
    ///
    /// Transcripts can be hundreds of MB, and decoding every line as JSON is
    /// expensive. So the file is memory-mapped and lines are first filtered at
    /// the byte level; only the few lines that matter are decoded:
    /// - message count: the top-level `"type":"user"`/`"type":"assistant"` pattern
    ///   (excluding meta and sidechain records). Quotes inside JSON strings are
    ///   escaped, so this pattern only matches at the structural level
    /// - start/`cwd`: the first timestamped record from the top
    /// - end/version: the first timestamped record from the bottom
    /// - first/last prompt: the first user line without a tool result, from the top/bottom
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

    /// Byte patterns (assumes no whitespace after JSON separators, since
    /// Claude Code writes transcripts as compact JSON).
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

    /// Line ranges (excluding empty lines).
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

    /// Text the user typed (excluding tool results and command records).
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

    // MARK: - Claude Desktop metadata

    /// `cliSessionId` → Desktop metadata file.
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

    /// Directory in this profile where Desktop session metadata is written
    /// (`claude-code-sessions/<active account>/<org>`). `nil` if it can't be determined.
    public func desktopMetadataDirectory() -> URL? {
        guard let profileDir,
              let account = ProfileSeeder.activeAccountUUID(profileDir: profileDir)
        else { return nil }
        let accountDir = profileDir.appendingPathComponent("claude-code-sessions/\(account)")
        let orgs = ((try? FileManager.default.contentsOfDirectory(atPath: accountDir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        // With more than one org we can't tell which is active, so we don't guess.
        guard orgs.count == 1 else { return nil }
        return accountDir.appendingPathComponent(orgs[0])
    }
}

/// On-disk cache of transcript summaries.
///
/// Keyed by the transcript's absolute path; the summary isn't recomputed if the
/// file's size and modification time are unchanged. A corrupt or unreadable
/// cache is silently ignored (it's only a speed-up, not a source of truth).
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
        // Drop entries for deleted transcripts.
        contents.entries = contents.entries.filter { FileManager.default.fileExists(atPath: $0.key) }
        guard let data = try? JSONEncoder().encode(contents) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        // Contains prompt excerpts: readable by the user only, like the transcripts.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        dirty = false
    }
}
