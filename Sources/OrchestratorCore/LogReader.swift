import Foundation

/// Reads Claude's shared log file.
///
/// All instances share one log (`~/Library/Logs/Claude/main.log`), so lines
/// are filtered by the instance's start time and pid.
public struct LogReader {
    public static let defaultLogDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Claude")

    /// Block size used when reading backwards from the end.
    static let chunkSize: UInt64 = 64 * 1024

    public let logDirectory: URL

    public init(logDirectory: URL = LogReader.defaultLogDirectory) {
        self.logDirectory = logDirectory
    }

    public var logFile: URL { logDirectory.appendingPathComponent("main.log") }

    /// Filters log lines.
    ///
    /// The file is read backwards in blocks; reading stops once `limit` matches
    /// are found or a line older than `since` is reached, so a large `main.log`
    /// is never loaded into memory in full.
    ///
    /// - Parameters:
    ///   - since: Lines older than this are dropped (lines without a timestamp are kept).
    ///   - pid: If given, only lines from this process (`electron_main:<pid>`) are returned.
    ///   - limit: At most this many lines (the newest). `0` or negative means no limit.
    public func lines(since: Date, pid: Int32? = nil, limit: Int = 50) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: logFile) else { return [] }
        defer { try? handle.close() }

        let formatter = Self.makeFormatter()
        let fileSize = (try? handle.seekToEnd()) ?? 0

        var collected: [String] = []   // newest first
        var offset = fileSize
        var carry = Data()             // partial line at the start of the previous block
        var reachedOlder = false

        while offset > 0, !reachedOlder, limit <= 0 || collected.count < limit {
            let readSize = min(Self.chunkSize, offset)
            offset -= readSize
            try? handle.seek(toOffset: offset)
            var block = (try? handle.read(upToCount: Int(readSize))) ?? Data()
            block.append(carry)

            var parts = block.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            // Unless we've reached the start of the file, the first part is a partial line; keep it for the next round.
            carry = offset > 0 ? Data(parts.removeFirst()) : Data()

            for part in parts.reversed() {
                guard let line = String(data: Data(part), encoding: .utf8), !line.isEmpty else { continue }
                if let timestamp = formatter.date(from: String(line.prefix(19))), timestamp < since {
                    reachedOlder = true
                    break
                }
                if let pid, !line.contains("electron_main:\(pid)") { continue }
                collected.append(line)
                if limit > 0, collected.count >= limit { break }
            }
        }

        return collected.reversed()
    }

    static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }
}

/// Log file follower for `logs -f`.
///
/// Detects log rotation: if the file's inode changes or its size drops below
/// the last read position, the file is read from the start again, so
/// following never silently stops.
public final class LogFollower {
    public let url: URL
    private var position: UInt64
    private var inode: UInt64?

    /// - Parameter fromEnd: If `true`, only lines written from now on are returned.
    public init(url: URL, fromEnd: Bool = true) {
        self.url = url
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        position = fromEnd ? ((attributes?[.size] as? NSNumber)?.uint64Value ?? 0) : 0
    }

    /// Complete lines added since the last call.
    public func poll() -> [String] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            // The file can briefly disappear during rotation.
            return []
        }
        let currentInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0

        if currentInode != inode || size < position {
            inode = currentInode
            position = 0
        }
        guard size > position, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        try? handle.seek(toOffset: position)
        let data = (try? handle.read(upToCount: Int(size - position))) ?? Data()
        // Only complete lines are consumed; a partial line waits for the next round.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let complete = data[data.startIndex...lastNewline]
        position += UInt64(complete.count)

        return String(decoding: complete, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }
}
