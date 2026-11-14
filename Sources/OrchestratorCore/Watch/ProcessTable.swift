import Foundation

/// One line of the process table.
public struct ProcessEntry: Equatable {
    public var pid: Int32
    public var ppid: Int32
    /// Seconds since the process started.
    public var uptime: TimeInterval
    public var command: String

    public init(pid: Int32, ppid: Int32, uptime: TimeInterval, command: String) {
        self.pid = pid
        self.ppid = ppid
        self.uptime = uptime
        self.command = command
    }
}

/// The whole process table in one call. Tests can supply a fake.
public protocol ProcessTable {
    func entries() -> [ProcessEntry]
}

/// Process table backed by `/bin/ps`.
public struct PsProcessTable: ProcessTable {
    public init() {}

    public func entries() -> [ProcessEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,etime=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Self.parse(String(decoding: data, as: UTF8.self))
    }

    /// Parses `ps -axo pid=,ppid=,etime=,command=` output.
    public static func parse(_ output: String) -> [ProcessEntry] {
        output.split(separator: "\n").compactMap { line in
            var rest = Substring(line)
            guard let pidText = nextToken(&rest), let pid = Int32(pidText),
                  let ppidText = nextToken(&rest), let ppid = Int32(ppidText),
                  let elapsedText = nextToken(&rest), let uptime = parseElapsed(elapsedText)
            else { return nil }
            let command = rest.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return nil }
            return ProcessEntry(pid: pid, ppid: ppid, uptime: uptime, command: command)
        }
    }

    private static func nextToken(_ rest: inout Substring) -> String? {
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })
        guard !rest.isEmpty else { return nil }
        let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) ?? rest.endIndex
        let token = String(rest[rest.startIndex..<end])
        rest = rest[end...]
        return token
    }

    /// `ps` elapsed time: `mm:ss`, `hh:mm:ss` or `d-hh:mm:ss`.
    static func parseElapsed(_ text: String) -> TimeInterval? {
        var days = 0.0
        var clock = Substring(text)
        if let dash = text.firstIndex(of: "-") {
            guard let value = Double(text[text.startIndex..<dash]) else { return nil }
            days = value
            clock = text[text.index(after: dash)...]
        }
        let pieces = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(pieces.count) else { return nil }
        var seconds = 0.0
        for piece in pieces {
            guard let value = Double(piece) else { return nil }
            seconds = seconds * 60 + value
        }
        return days * 86_400 + seconds
    }
}
