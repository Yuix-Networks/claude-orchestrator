import Foundation

/// State of a running instance.
public struct InstanceState: Codable, Equatable {
    /// Pid of the main Claude process.
    public var pid: Int32
    /// When the instance was started.
    public var startedAt: Date
    /// Claude version installed at launch time.
    public var claudeVersion: String?

    public init(pid: Int32, startedAt: Date = Date(), claudeVersion: String? = nil) {
        self.pid = pid
        self.startedAt = startedAt
        self.claudeVersion = claudeVersion
    }
}
