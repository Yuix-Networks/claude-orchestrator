import Foundation

public enum Severity: String, Codable, Comparable {
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .error: return 2
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
}

/// What the observer saw of one instance at one moment.
public struct InstanceObservation: Codable, Equatable {
    public var name: String
    /// Main Claude process carrying this profile's `--user-data-dir` (`nil` if none).
    public var mainPid: Int32?
    /// Command name of the main process's parent (who started it).
    public var parent: String?
    /// Seconds the main process has been running.
    public var uptime: TimeInterval?
    /// Renderer/GPU/utility processes carrying this profile's flag.
    public var helperCount: Int
    /// Pid named by the profile's `SingletonLock` (`nil` if there is no lock).
    public var lockPid: Int32?
    public var lockAlive: Bool
    /// `lastKnownAccountUuid` of the profile's `config.json`.
    public var accountUuid: String?
    /// Does the profile have a cookie file (has it ever signed in)?
    public var signedIn: Bool

    public init(
        name: String,
        mainPid: Int32? = nil,
        parent: String? = nil,
        uptime: TimeInterval? = nil,
        helperCount: Int = 0,
        lockPid: Int32? = nil,
        lockAlive: Bool = false,
        accountUuid: String? = nil,
        signedIn: Bool = false
    ) {
        self.name = name
        self.mainPid = mainPid
        self.parent = parent
        self.uptime = uptime
        self.helperCount = helperCount
        self.lockPid = lockPid
        self.lockAlive = lockAlive
        self.accountUuid = accountUuid
        self.signedIn = signedIn
    }

    public var isRunning: Bool { mainPid != nil }
}

/// Everything the observer saw in one sample.
public struct Snapshot: Codable, Equatable {
    public var takenAt: Date
    public var instances: [String: InstanceObservation]
    /// Main Claude processes started **without** `--user-data-dir` (the default profile).
    public var defaultMainPids: [Int32]
    /// Main Claude processes whose `--user-data-dir` is not a registered instance (profile path → pid).
    public var strayProfiles: [String: Int32]

    public init(
        takenAt: Date,
        instances: [String: InstanceObservation] = [:],
        defaultMainPids: [Int32] = [],
        strayProfiles: [String: Int32] = [:]
    ) {
        self.takenAt = takenAt
        self.instances = instances
        self.defaultMainPids = defaultMainPids
        self.strayProfiles = strayProfiles
    }
}

/// Something worth remembering, one line of `events.jsonl`.
public struct WatchEvent: Codable, Equatable {
    public var time: Date
    public var severity: Severity
    /// Short machine-readable name (`started`, `exited`, `hidden-instance`, …).
    public var kind: String
    public var instance: String?
    public var message: String
    public var details: [String: String]

    public init(
        time: Date,
        severity: Severity,
        kind: String,
        instance: String? = nil,
        message: String,
        details: [String: String] = [:]
    ) {
        self.time = time
        self.severity = severity
        self.kind = kind
        self.instance = instance
        self.message = message
        self.details = details
    }
}

/// A fault that is true *now* (as opposed to a one-off event).
public struct Condition: Codable, Equatable {
    public var key: String
    public var kind: String
    public var severity: Severity
    public var instance: String?
    public var message: String

    public init(key: String, kind: String, severity: Severity, instance: String?, message: String) {
        self.key = key
        self.kind = kind
        self.severity = severity
        self.instance = instance
        self.message = message
    }
}

/// How long ago, in a few characters (`45s`, `12m`, `3h05m`, `2d04h`).
public func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds))
    if total < 60 { return "\(total)s" }
    if total < 3600 { return "\(total / 60)m" }
    if total < 86_400 { return "\(total / 3600)h" + String(format: "%02dm", (total % 3600) / 60) }
    return "\(total / 86_400)d" + String(format: "%02dh", (total % 86_400) / 3600)
}
