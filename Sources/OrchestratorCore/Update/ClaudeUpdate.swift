import Foundation

/// A Claude Desktop update that Squirrel has downloaded and staged but not installed yet.
///
/// Claude updates itself with Squirrel.Mac: the new bundle is unpacked under
/// `~/Library/Caches/com.anthropic.claudefordesktop.ShipIt/update.*/Claude.app`
/// and `ShipItState.plist` points at it. `ShipIt` then waits until **every**
/// Claude process has quit, swaps the bundle and launches the app again —
/// without `--user-data-dir`, so the relaunched app is the default profile, not
/// the instance that asked for the update. With several instances open the
/// result is an instance that disappears or turns into another account.
public struct PendingUpdate: Codable, Equatable {
    public var installedVersion: String
    public var stagedVersion: String
    /// Path of the staged `Claude.app`.
    public var stagedBundle: String

    public init(installedVersion: String, stagedVersion: String, stagedBundle: String) {
        self.installedVersion = installedVersion
        self.stagedVersion = stagedVersion
        self.stagedBundle = stagedBundle
    }
}

/// Compares dotted version strings numerically (`6.10.0` > `6.9.3`).
public enum VersionOrder {
    public static func components(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = components(candidate)
        let rhs = components(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}

/// Reads Squirrel's state to find a staged update, and the ShipIt processes waiting to install it.
public struct UpdateInspector {
    /// Squirrel's job label for Claude (also the name of its cache directory).
    public static let shipItLabel = "com.anthropic.claudefordesktop.ShipIt"
    public static var defaultShipItDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/\(shipItLabel)")
    }

    public let appPath: String
    public let shipItDirectory: URL
    private let table: ProcessTable

    public init(
        appPath: String = ClaudeApp.defaultPath,
        shipItDirectory: URL = UpdateInspector.defaultShipItDirectory,
        table: ProcessTable = PsProcessTable()
    ) {
        self.appPath = appPath
        self.shipItDirectory = shipItDirectory
        self.table = table
    }

    public var stateFile: URL { shipItDirectory.appendingPathComponent("ShipItState.plist") }
    public var logFile: URL { shipItDirectory.appendingPathComponent("ShipIt_stderr.log") }

    /// The installer Squirrel ships inside the app bundle.
    public var shipItExecutable: URL {
        URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Frameworks/Squirrel.framework/Resources/ShipIt")
    }

    /// The staged update, if one exists, targets this app and is newer than what is installed.
    public func pending() -> PendingUpdate? {
        guard let state = readState(),
              let updateText = state["updateBundleURL"] as? String,
              let updateURL = URL(string: updateText), updateURL.isFileURL
        else { return nil }
        if let targetText = state["targetBundleURL"] as? String, let target = URL(string: targetText),
           target.standardizedFileURL.path != URL(fileURLWithPath: appPath).standardizedFileURL.path {
            return nil
        }
        let stagedPath = updateURL.standardizedFileURL.path
        guard let staged = ClaudeApp.version(appPath: stagedPath),
              let installed = ClaudeApp.version(appPath: appPath),
              VersionOrder.isNewer(staged, than: installed)
        else { return nil }
        return PendingUpdate(installedVersion: installed, stagedVersion: staged, stagedBundle: stagedPath)
    }

    /// ShipIt processes currently waiting for Claude to quit.
    public func waitingShipItPids() -> [Int32] {
        table.entries()
            .filter { $0.command.contains("Squirrel.framework/Resources/ShipIt") && $0.command.contains(Self.shipItLabel) }
            .map(\.pid)
            .sorted()
    }

    /// Makes the next ShipIt run install without launching the app afterwards
    /// (a launch from ShipIt has no `--user-data-dir`, so it would open the default profile).
    public func disableLaunchAfterInstallation() throws {
        guard var state = readState() else {
            throw OrchestratorError.runtime("Squirrel state not found: \(stateFile.path)")
        }
        state["launchAfterInstallation"] = false
        // Write it back in the format it came in: Squirrel writes JSON despite the `.plist` name.
        let data: Data
        if let raw = try? Data(contentsOf: stateFile), (try? JSONSerialization.jsonObject(with: raw)) != nil {
            data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        } else {
            data = try PropertyListSerialization.data(fromPropertyList: state, format: .xml, options: 0)
        }
        try data.write(to: stateFile, options: .atomic)
    }

    /// Squirrel stores this as JSON (despite the `.plist` name); a property list is accepted too.
    func readState() -> [String: Any]? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return object }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

/// Claude writes `update-attempt` into a profile right before it quits itself to install an update.
public enum UpdateMarker {
    public static func attemptTime(profileDir: URL) -> Date? {
        let url = profileDir.appendingPathComponent("update-attempt")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let millis = (object["ts"] as? NSNumber)?.doubleValue
        else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}

/// What claude-orchestrator remembers about updates between runs (`state/update.json`).
public struct UpdateState: Codable, Equatable {
    /// Version the user was last told about.
    public var notifiedVersion: String?
    public var notifiedAt: Date?
    /// No reminder before this time (the user chose "Later").
    public var snoozedUntil: Date?
    /// Instances that quit by themselves to install an update; they are reopened after the update.
    public var closedByUpdate: [String]
    /// Written before instances are closed and cleared once they are open again, so an
    /// interrupted update can still reopen what it closed.
    public var inProgress: UpdateRun?

    public init(
        notifiedVersion: String? = nil,
        notifiedAt: Date? = nil,
        snoozedUntil: Date? = nil,
        closedByUpdate: [String] = [],
        inProgress: UpdateRun? = nil
    ) {
        self.notifiedVersion = notifiedVersion
        self.notifiedAt = notifiedAt
        self.snoozedUntil = snoozedUntil
        self.closedByUpdate = closedByUpdate
        self.inProgress = inProgress
    }

    public static func read(paths: Paths) -> UpdateState {
        ((try? JSONFile.read(UpdateState.self, from: paths.updateStateFile)) ?? nil) ?? UpdateState()
    }

    public func write(paths: Paths) {
        try? JSONFile.write(self, to: paths.updateStateFile)
    }
}

/// One controlled update, as recorded before anything was closed.
public struct UpdateRun: Codable, Equatable {
    public var startedAt: Date
    public var fromVersion: String
    public var toVersion: String
    /// Instances to open again afterwards.
    public var instances: [String]
    /// Was the default (non-instance) Claude open?
    public var defaultWasRunning: Bool

    public init(startedAt: Date, fromVersion: String, toVersion: String, instances: [String], defaultWasRunning: Bool) {
        self.startedAt = startedAt
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.instances = instances
        self.defaultWasRunning = defaultWasRunning
    }
}
