import Foundation

/// Recognises Claude Desktop's processes in the process table.
public struct ClaudeProcessScanner {
    public let appPath: String

    public init(appPath: String = ClaudeApp.defaultPath) {
        self.appPath = appPath
    }

    public var mainExecutable: String { "\(appPath)/Contents/MacOS/Claude" }

    /// Is this the **main** Claude process (the one that owns the windows)?
    public func isMain(_ entry: ProcessEntry) -> Bool {
        Self.executable(of: entry.command) == mainExecutable
    }

    /// Renderer / GPU / utility helpers live inside the app's Frameworks folder.
    public func isHelper(_ entry: ProcessEntry) -> Bool {
        entry.command.hasPrefix("\(appPath)/Contents/Frameworks/")
    }

    /// Does the command carry exactly `--user-data-dir=<profilePath>`?
    public func usesProfile(_ entry: ProcessEntry, profilePath: String) -> Bool {
        Self.containsExactMarker(entry.command, "--user-data-dir=\(profilePath)")
    }

    /// Does the command carry any `--user-data-dir=`?
    public func hasProfileMarker(_ entry: ProcessEntry) -> Bool {
        entry.command.contains("--user-data-dir=")
    }

    /// Best-effort profile path of an unregistered process (the path may contain spaces).
    public func looseProfilePath(_ entry: ProcessEntry) -> String? {
        guard let range = entry.command.range(of: "--user-data-dir=") else { return nil }
        var value = entry.command[range.upperBound...]
        if let next = value.range(of: " --") { value = value[value.startIndex..<next.lowerBound] }
        let path = value.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    // MARK: - Shared parsing

    /// First token of the command line (the executable path).
    static func executable(of command: String) -> String {
        guard let space = command.firstIndex(of: " ") else { return command }
        return String(command[command.startIndex..<space])
    }

    /// Checks that the marker appears as an exact token: `--user-data-dir=/a`
    /// must not be confused with `--user-data-dir=/ab`.
    static func containsExactMarker(_ command: String, _ marker: String) -> Bool {
        var searchRange = command.startIndex..<command.endIndex
        while let range = command.range(of: marker, range: searchRange) {
            let after = range.upperBound
            if after == command.endIndex || command[after] == " " {
                return true
            }
            searchRange = after..<command.endIndex
        }
        return false
    }
}
