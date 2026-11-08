import Foundation

/// Bir Claude instance'ı başlatmak için gereken bilgiler.
public struct LaunchRequest: Equatable {
    /// Hedef uygulama bundle yolu (örn. `/Applications/Claude.app`).
    public var appPath: String
    /// Electron profili (`--user-data-dir`).
    public var profileDir: String
    /// Claude Code yapılandırma dizini (`CLAUDE_CONFIG_DIR`).
    public var codeDir: String
    /// Uygulamaya ek olarak geçirilecek argümanlar (örn. açılacak klasör).
    public var extraArgs: [String]

    public init(appPath: String, profileDir: String, codeDir: String, extraArgs: [String] = []) {
        self.appPath = appPath
        self.profileDir = profileDir
        self.codeDir = codeDir
        self.extraArgs = extraArgs
    }
}

/// Claude Desktop instance'larını başlatır, süreçlerini bulur ve kilitleri denetler.
public final class Launcher {
    public static let defaultAppPath = "/Applications/Claude.app"

    private let appPath: String
    private let processListing: ProcessListing
    private let fileManager: FileManager

    public init(
        appPath: String = Launcher.defaultAppPath,
        processListing: ProcessListing = PsProcessListing(),
        fileManager: FileManager = .default
    ) {
        self.appPath = appPath
        self.processListing = processListing
        self.fileManager = fileManager
    }

    /// `open` komutunun argüman listesi.
    ///
    /// Sıra önemlidir: `open -n -a <app> --args --user-data-dir=… --env CLAUDE_CONFIG_DIR=…`
    public func launchArguments(_ request: LaunchRequest) -> [String] {
        var arguments = [
            "open", "-n", "-a", request.appPath,
            "--args", "--user-data-dir=\(request.profileDir)",
            "--env", "CLAUDE_CONFIG_DIR=\(request.codeDir)"
        ]
        arguments.append(contentsOf: request.extraArgs)
        return arguments
    }

    /// Profil başka bir süreç tarafından kullanılıyor mu? (Chromium `SingletonLock`)
    public func isProfileLocked(profileDir: URL) -> Bool {
        fileManager.fileExists(atPath: profileDir.appendingPathComponent("SingletonLock").path)
    }

    /// Verilen profili kullanan Claude sürecinin pid'i (yoksa `nil`).
    public func runningPid(profileDir: URL) -> Int32? {
        let marker = "--user-data-dir=\(profileDir.path)"
        let matches = processListing.processes().filter { entry in
            entry.command.contains("/Contents/MacOS/Claude") && containsExactMarker(entry.command, marker)
        }
        return matches.map(\.pid).min()
    }

    /// Instance'ı başlatır.
    public func launch(_ request: LaunchRequest) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = launchArguments(request)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ClaudeCtlError.runtime("instance başlatılamadı: \(error.localizedDescription)")
        }
    }

    /// `--user-data-dir=<yol>` işaretinin komut içinde tam olarak geçtiğini kontrol eder.
    ///
    /// `--user-data-dir=/a` ile `--user-data-dir=/ab` birbirine karışmamalıdır.
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
