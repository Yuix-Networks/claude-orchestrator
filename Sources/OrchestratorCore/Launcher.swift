import Foundation

/// Everything needed to launch a Claude instance.
public struct LaunchRequest: Equatable {
    /// Path of the target app bundle (e.g. `/Applications/Claude.app`).
    public var appPath: String
    /// Electron profile (`--user-data-dir`).
    public var profileDir: String
    /// Claude Code config directory (`CLAUDE_CONFIG_DIR`).
    public var codeDir: String
    /// Extra arguments passed to the app (e.g. a folder to open).
    public var extraArgs: [String]

    public init(appPath: String, profileDir: String, codeDir: String, extraArgs: [String] = []) {
        self.appPath = appPath
        self.profileDir = profileDir
        self.codeDir = codeDir
        self.extraArgs = extraArgs
    }
}

/// Instance launch behaviour. Tests can supply a fake.
public protocol Launching: AnyObject {
    func launchArguments(_ request: LaunchRequest) -> [String]
    func isProfileLocked(profileDir: URL) -> Bool
    func lockHolderPid(profileDir: URL) -> Int32?
    func runningPid(profileDir: URL) -> Int32?
    func launch(_ request: LaunchRequest) throws
    /// Pid of the Claude running without `--user-data-dir` (the default profile).
    func runningDefaultPid() -> Int32?
}

public extension Launching {
    func runningDefaultPid() -> Int32? { nil }
}

/// Launches Claude Desktop instances, finds their processes and checks profile locks.
public final class Launcher {
    public static let defaultAppPath = "/Applications/Claude.app"

    private let appPath: String
    private let processListing: ProcessListing
    private let fileManager: FileManager
    private let openPath: String

    public init(
        appPath: String = Launcher.defaultAppPath,
        processListing: ProcessListing = PsProcessListing(),
        fileManager: FileManager = .default,
        openPath: String = "/usr/bin/open"
    ) {
        self.appPath = appPath
        self.processListing = processListing
        self.fileManager = fileManager
        self.openPath = openPath
    }

    /// Argument list for the `open` command (including the program name).
    ///
    /// Order matters: `--env` must come **before** `--args`. Everything after
    /// `open --args` is passed to the app as argv; if `--env` ends up in the
    /// wrong place, the app sees `--env` and its value in its argv.
    public func launchArguments(_ request: LaunchRequest) -> [String] {
        var arguments = [
            "open", "-n", "-a", request.appPath,
            "--env", "CLAUDE_CONFIG_DIR=\(request.codeDir)",
            "--args", "--user-data-dir=\(request.profileDir)"
        ]
        arguments.append(contentsOf: request.extraArgs)
        return arguments
    }

    /// Arguments for the `open` program (excluding the program name).
    public func openArguments(_ request: LaunchRequest) -> [String] {
        Array(launchArguments(request).dropFirst())
    }

    /// Is the profile in use by another process? (Chromium `SingletonLock`)
    ///
    /// The Chromium lock is a **symbolic link** (pointing at `<hostname>-<pid>`);
    /// its target doesn't exist on disk, so `fileExists` follows the link and
    /// returns `false`. That's why the link itself is checked.
    public func isProfileLocked(profileDir: URL) -> Bool {
        let lock = profileDir.appendingPathComponent("SingletonLock").path
        if (try? fileManager.destinationOfSymbolicLink(atPath: lock)) != nil {
            return true
        }
        return fileManager.fileExists(atPath: lock)
    }

    /// Pid of the process holding the lock (the `SingletonLock` target is `<hostname>-<pid>`).
    ///
    /// `nil` if there is no lock or its target can't be read.
    public func lockHolderPid(profileDir: URL) -> Int32? {
        let lock = profileDir.appendingPathComponent("SingletonLock")
        let target = try? fileManager.destinationOfSymbolicLink(atPath: lock.path)
        guard let target else { return nil }
        let suffix = target.split(separator: "-").last.map(String.init) ?? ""
        return Int32(suffix)
    }

    /// Pid of the **main** Claude process using the given profile (`nil` if none).
    ///
    /// Helper processes (renderer/gpu) carry the same `--user-data-dir` marker,
    /// so the first argv token has to match exactly.
    public func runningPid(profileDir: URL) -> Int32? {
        let marker = "--user-data-dir=\(profileDir.path)"
        let executable = "\(appPath)/Contents/MacOS/Claude"
        let matches = processListing.processes().filter { entry in
            executableName(of: entry.command) == executable && containsExactMarker(entry.command, marker)
        }
        return matches.map(\.pid).min()
    }

    /// Pid of the main Claude process using the default profile (not an instance).
    public func runningDefaultPid() -> Int32? {
        let executable = "\(appPath)/Contents/MacOS/Claude"
        return processListing.processes()
            .filter { executableName(of: $0.command) == executable && !$0.command.contains("--user-data-dir=") }
            .map(\.pid)
            .min()
    }

    /// Launches the instance.
    public func launch(_ request: LaunchRequest) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openPath)
        process.arguments = openArguments(request)

        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw OrchestratorError.runtime("couldn't start instance: \(error.localizedDescription)")
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = message.isEmpty ? "open exited with \(process.terminationStatus)" : message
            throw OrchestratorError.runtime("couldn't start instance: \(detail)")
        }
    }

    /// First token of the command line (the executable path).
    private func executableName(of command: String) -> String {
        guard let space = command.firstIndex(of: " ") else { return command }
        return String(command[command.startIndex..<space])
    }

    /// Checks that the `--user-data-dir=<path>` marker appears in the command as an exact token.
    ///
    /// `--user-data-dir=/a` must not be confused with `--user-data-dir=/ab`.
    private func containsExactMarker(_ command: String, _ marker: String) -> Bool {
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

extension Launcher: Launching {}
