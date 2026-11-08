import Foundation

/// Çalışan bir instance'ın durumu.
public struct InstanceState: Codable, Equatable {
    /// Claude ana sürecinin pid'i.
    public var pid: Int32
    /// Instance'ın başlatıldığı an.
    public var startedAt: Date
    /// Başlatma anında kurulu olan Claude sürümü.
    public var claudeVersion: String?

    public init(pid: Int32, startedAt: Date = Date(), claudeVersion: String? = nil) {
        self.pid = pid
        self.startedAt = startedAt
        self.claudeVersion = claudeVersion
    }
}
