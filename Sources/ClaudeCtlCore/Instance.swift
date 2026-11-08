import Foundation

/// Tek bir Claude instance tanımı.
public struct Instance: Codable, Equatable, Sendable {
    public var name: String
    /// Instance'ın çalışacağı proje klasörü. `nil` ise workdir atanmamıştır.
    public var workdir: String?
    public var createdAt: Date
    /// Sistem açılışında otomatik başlatılacak mı?
    public var autoStart: Bool
    /// Menü çubuğu ikonunda gösterilecek kısa etiket.
    public var iconBadge: String?

    public init(
        name: String,
        workdir: String? = nil,
        createdAt: Date = Date(),
        autoStart: Bool = false,
        iconBadge: String? = nil
    ) {
        self.name = name
        self.workdir = workdir
        self.createdAt = createdAt
        self.autoStart = autoStart
        self.iconBadge = iconBadge
    }
}

/// `config.json` içeriği.
public struct Config: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var instances: [String: Instance]

    public init(version: Int = Config.currentVersion, instances: [String: Instance] = [:]) {
        self.version = version
        self.instances = instances
    }
}
