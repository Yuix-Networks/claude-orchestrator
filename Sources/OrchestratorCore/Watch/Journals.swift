import Darwin
import Foundation

/// Reads and writes JSON-lines files (one compact JSON object per line).
public enum JSONLines {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder().encode(value) }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func append<T: Encodable>(_ value: T, to url: URL) {
        guard var data = try? encoder().encode(value) else { return }
        data.append(UInt8(ascii: "\n"))
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = decoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(type, from: Data($0)) }
    }

    /// Keeps `url` under `maxBytes` by shifting `name.jsonl` → `name.1.jsonl` → … (`keep` files).
    static func rotateIfNeeded(_ url: URL, maxBytes: Int, keep: Int) {
        let fileManager = FileManager.default
        let size = ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard size >= maxBytes else { return }
        for index in stride(from: keep - 1, through: 1, by: -1) {
            let from = rotated(url, index)
            let to = rotated(url, index + 1)
            try? fileManager.removeItem(at: to)
            try? fileManager.moveItem(at: from, to: to)
        }
        try? fileManager.removeItem(at: rotated(url, 1))
        try? fileManager.moveItem(at: url, to: rotated(url, 1))
    }

    static func rotated(_ url: URL, _ index: Int) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(base).\(index).\(url.pathExtension)")
    }
}

/// The permanent record of everything the watcher noticed.
public struct EventJournal {
    public static let maxBytes = 5 * 1024 * 1024
    public static let keepFiles = 4

    public let url: URL

    public init(paths: Paths) {
        self.url = paths.watchEventsFile
    }

    public func append(_ event: WatchEvent) {
        JSONLines.rotateIfNeeded(url, maxBytes: Self.maxBytes, keep: Self.keepFiles)
        JSONLines.append(event, to: url)
    }

    /// Events newest-last, from the rotated files and the current one.
    public func events(since: Date = .distantPast) -> [WatchEvent] {
        var all: [WatchEvent] = []
        for index in stride(from: Self.keepFiles, through: 1, by: -1) {
            all += JSONLines.read(WatchEvent.self, from: JSONLines.rotated(url, index))
        }
        all += JSONLines.read(WatchEvent.self, from: url)
        return all.filter { $0.time >= since }
    }
}

/// What claude-orchestrator itself did to an instance.
public struct ActionRecord: Codable, Equatable {
    public var time: Date
    public var action: String
    public var instance: String
    /// The command line that caused it (`start work`, `signin school --exclusive`, the menu bar agent, …).
    public var via: String

    public init(time: Date, action: String, instance: String, via: String) {
        self.time = time
        self.action = action
        self.instance = instance
        self.via = via
    }
}

public struct ActionJournal {
    public let url: URL

    public init(paths: Paths) {
        self.url = paths.actionsFile
    }

    public func record(action: String, instance: String, at time: Date = Date()) {
        let arguments = ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " ")
        let via = arguments.isEmpty ? "interactive menu" : String(arguments.prefix(120))
        JSONLines.rotateIfNeeded(url, maxBytes: 512 * 1024, keep: 2)
        JSONLines.append(ActionRecord(time: time, action: action, instance: instance, via: via), to: url)
    }

    public func records(since: Date) -> [ActionRecord] {
        let all = JSONLines.read(ActionRecord.self, from: JSONLines.rotated(url, 1))
            + JSONLines.read(ActionRecord.self, from: url)
        return all.filter { $0.time >= since }
    }
}

/// Heartbeat and last sample, rewritten every tick. Lets other processes (the
/// interactive menu, `watch status`) see the watcher's view without asking it.
public struct WatcherStatus: Codable, Equatable {
    public var pid: Int32
    public var startedAt: Date
    public var updatedAt: Date
    public var interval: TimeInterval
    public var snapshot: Snapshot
    public var conditions: [Condition]

    public init(
        pid: Int32, startedAt: Date, updatedAt: Date, interval: TimeInterval,
        snapshot: Snapshot, conditions: [Condition]
    ) {
        self.pid = pid
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.interval = interval
        self.snapshot = snapshot
        self.conditions = conditions
    }

    /// The watcher is alive if it wrote its heartbeat recently and its process exists.
    public func isLive(now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) <= max(10, interval * 4) && ProcessSignal.isAlive(pid)
    }

    public static func read(paths: Paths) -> WatcherStatus? {
        (try? JSONFile.read(WatcherStatus.self, from: paths.watchStatusFile)) ?? nil
    }
}

/// `flock` on a file: held until the object is released or the process dies, so a
/// stale pid file can never keep a second copy out.
public final class SingletonLock {
    private var descriptor: Int32

    /// `nil` when another process holds the lock.
    public init?(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}
