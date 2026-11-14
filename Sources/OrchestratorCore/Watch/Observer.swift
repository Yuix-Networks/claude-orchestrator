import Foundation

/// Takes one sample of every instance: processes, profile lock, account identity.
public final class Observer {
    private let paths: Paths
    private let store: InstanceStore
    private let table: ProcessTable
    private let scanner: ClaudeProcessScanner
    private let fileManager: FileManager

    public init(
        paths: Paths,
        appPath: String = ClaudeApp.defaultPath,
        table: ProcessTable = PsProcessTable(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.store = InstanceStore(paths: paths)
        self.table = table
        self.scanner = ClaudeProcessScanner(appPath: appPath)
        self.fileManager = fileManager
    }

    public func sample(now: Date = Date()) -> Snapshot {
        let entries = table.entries()
        let byPid = Dictionary(entries.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let claude = entries.filter { scanner.isMain($0) || scanner.isHelper($0) }
        let names = ((try? store.load())?.instances.keys).map { Array($0).sorted() } ?? []

        var claimed = Set<Int32>()
        var observations: [String: InstanceObservation] = [:]
        for name in names {
            let profile = paths.profileDir(name)
            let mine = claude.filter { scanner.usesProfile($0, profilePath: profile.path) }
            claimed.formUnion(mine.map(\.pid))
            let main = mine.filter(scanner.isMain).min { $0.pid < $1.pid }
            let lockPid = Self.lockPid(profileDir: profile, fileManager: fileManager)

            var observation = InstanceObservation(name: name)
            observation.mainPid = main?.pid
            observation.uptime = main?.uptime
            observation.parent = main.flatMap { byPid[$0.ppid] }.map { Self.commandName($0.command) }
                ?? main.map { $0.ppid == 1 ? "launchd" : "pid \($0.ppid)" }
            observation.helperCount = mine.filter(scanner.isHelper).count
            observation.lockPid = lockPid
            observation.lockAlive = lockPid.map(ProcessSignal.isAlive) ?? false
            observation.accountUuid = Self.accountUuid(profileDir: profile)
            observation.signedIn = fileManager.fileExists(atPath: profile.appendingPathComponent("Cookies").path)
            observations[name] = observation
        }

        let rest = claude.filter { !claimed.contains($0.pid) && scanner.isMain($0) }
        let defaults = rest.filter { !scanner.hasProfileMarker($0) }.map(\.pid).sorted()
        var strays: [String: Int32] = [:]
        for entry in rest where scanner.hasProfileMarker(entry) {
            if let path = scanner.looseProfilePath(entry) { strays[path] = entry.pid }
        }

        return Snapshot(takenAt: now, instances: observations, defaultMainPids: defaults, strayProfiles: strays)
    }

    // MARK: - Helpers

    /// Pid named by the Chromium `SingletonLock` symlink (`<hostname>-<pid>`).
    static func lockPid(profileDir: URL, fileManager: FileManager = .default) -> Int32? {
        let lock = profileDir.appendingPathComponent("SingletonLock").path
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: lock) else { return nil }
        return Int32(target.split(separator: "-").last.map(String.init) ?? "")
    }

    /// The account that last signed in to this profile.
    static func accountUuid(profileDir: URL) -> String? {
        let url = profileDir.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uuid = object["lastKnownAccountUuid"] as? String, !uuid.isEmpty
        else { return nil }
        return uuid
    }

    /// Executable name of a command line (`/usr/bin/foo --bar` → `foo`).
    static func commandName(_ command: String) -> String {
        let executable = ClaudeProcessScanner.executable(of: command)
        return (executable as NSString).lastPathComponent
    }
}
