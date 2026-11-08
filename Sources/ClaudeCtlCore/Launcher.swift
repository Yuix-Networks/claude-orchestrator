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

/// Instance başlatma davranışı. Testlerde sahte uygulanabilir.
public protocol Launching: AnyObject {
    func launchArguments(_ request: LaunchRequest) -> [String]
    func isProfileLocked(profileDir: URL) -> Bool
    func lockHolderPid(profileDir: URL) -> Int32?
    func runningPid(profileDir: URL) -> Int32?
    func launch(_ request: LaunchRequest) throws
    /// `--user-data-dir` olmadan çalışan (varsayılan profilli) Claude'un pid'i.
    func runningDefaultPid() -> Int32?
}

public extension Launching {
    func runningDefaultPid() -> Int32? { nil }
}

/// Claude Desktop instance'larını başlatır, süreçlerini bulur ve kilitleri denetler.
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

    /// `open` komutunun argüman listesi (program adı dahil).
    ///
    /// Sıra önemlidir: `--env` `--args`'tan **önce** gelmelidir. `open --args`
    /// sonrasındaki her şey uygulamaya argv olarak gider; `--env` yanlış yerde
    /// kalırsa uygulama `--env` ve değerini argv'sında görür.
    public func launchArguments(_ request: LaunchRequest) -> [String] {
        var arguments = [
            "open", "-n", "-a", request.appPath,
            "--env", "CLAUDE_CONFIG_DIR=\(request.codeDir)",
            "--args", "--user-data-dir=\(request.profileDir)"
        ]
        arguments.append(contentsOf: request.extraArgs)
        return arguments
    }

    /// `open` programına verilecek argümanlar (program adı hariç).
    public func openArguments(_ request: LaunchRequest) -> [String] {
        Array(launchArguments(request).dropFirst())
    }

    /// Profil başka bir süreç tarafından kullanılıyor mu? (Chromium `SingletonLock`)
    ///
    /// Chromium kilidi bir **sembolik bağdır** (`<hostname>-<pid>` hedefine
    /// işaret eder); hedefi diskte var olmadığı için `fileExists` bağı takip
    /// edip `false` döner. Bu yüzden bağın kendisi kontrol edilir.
    public func isProfileLocked(profileDir: URL) -> Bool {
        let lock = profileDir.appendingPathComponent("SingletonLock").path
        if (try? fileManager.destinationOfSymbolicLink(atPath: lock)) != nil {
            return true
        }
        return fileManager.fileExists(atPath: lock)
    }

    /// Kilidi tutan sürecin pid'i (`SingletonLock` hedefi `<hostname>-<pid>`).
    ///
    /// Kilit yoksa veya hedefi okunamıyorsa `nil`.
    public func lockHolderPid(profileDir: URL) -> Int32? {
        let lock = profileDir.appendingPathComponent("SingletonLock")
        let target = try? fileManager.destinationOfSymbolicLink(atPath: lock.path)
        guard let target else { return nil }
        let suffix = target.split(separator: "-").last.map(String.init) ?? ""
        return Int32(suffix)
    }

    /// Verilen profili kullanan Claude **ana** sürecinin pid'i (yoksa `nil`).
    ///
    /// Yardımcı süreçler (renderer/gpu) aynı `--user-data-dir` işaretini taşır;
    /// bu yüzden argv'nin ilk token'ı tam olarak eşleşmelidir.
    public func runningPid(profileDir: URL) -> Int32? {
        let marker = "--user-data-dir=\(profileDir.path)"
        let executable = "\(appPath)/Contents/MacOS/Claude"
        let matches = processListing.processes().filter { entry in
            executableName(of: entry.command) == executable && containsExactMarker(entry.command, marker)
        }
        return matches.map(\.pid).min()
    }

    /// Varsayılan profili kullanan (instance olmayan) Claude ana sürecinin pid'i.
    public func runningDefaultPid() -> Int32? {
        let executable = "\(appPath)/Contents/MacOS/Claude"
        return processListing.processes()
            .filter { executableName(of: $0.command) == executable && !$0.command.contains("--user-data-dir=") }
            .map(\.pid)
            .min()
    }

    /// Instance'ı başlatır.
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
            throw ClaudeCtlError.runtime("instance başlatılamadı: \(error.localizedDescription)")
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = message.isEmpty ? "open \(process.terminationStatus) ile sonlandı" : message
            throw ClaudeCtlError.runtime("instance başlatılamadı: \(detail)")
        }
    }

    /// Komut satırının ilk token'ı (executable yolu).
    private func executableName(of command: String) -> String {
        guard let space = command.firstIndex(of: " ") else { return command }
        return String(command[command.startIndex..<space])
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

extension Launcher: Launching {}
