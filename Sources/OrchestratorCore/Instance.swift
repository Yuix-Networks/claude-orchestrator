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

/// Tüm instance'larda bulunması istenen bir proje (Claude Desktop'ta "environment").
///
/// Merkezi olarak `config.json`'da tutulur ve her instance profilinin Code
/// sekmesi ortamlarına (`ccd-session-presets.json`) senkronlanır.
public struct Project: Codable, Equatable, Sendable {
    /// Ortamın Claude Desktop'ta görünen adı (kayıttaki anahtar).
    public var name: String
    /// Ana çalışma klasörü (mutlak yol).
    public var path: String
    /// Ek klasörler (mutlak yollar).
    public var additionalFolders: [String]
    /// Bu projede açılan oturumların varsayılan izin modu
    /// (`bypassPermissions`, `acceptEdits`, …). `nil` → Desktop ayarına dokunulmaz.
    public var permissionMode: String?
    public var createdAt: Date

    public init(
        name: String,
        path: String,
        additionalFolders: [String] = [],
        permissionMode: String? = nil,
        createdAt: Date = Date()
    ) {
        self.name = name
        self.path = path
        self.additionalFolders = additionalFolders
        self.permissionMode = permissionMode
        self.createdAt = createdAt
    }

    public var presetSpec: PresetSpec {
        PresetSpec(name: name, cwd: path, additionalFolders: additionalFolders, permissionMode: permissionMode)
    }

    /// Kayıttaki tanım aynı mı? (oluşturma zamanı hariç)
    public func sameDefinition(as other: Project) -> Bool {
        name == other.name && path == other.path
            && additionalFolders == other.additionalFolders && permissionMode == other.permissionMode
    }

    private enum CodingKeys: String, CodingKey {
        case name, path, additionalFolders, permissionMode, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        additionalFolders = try container.decodeIfPresent([String].self, forKey: .additionalFolders) ?? []
        permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// `config.json` içeriği.
public struct Config: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var instances: [String: Instance]
    /// Tüm instance'lara senkronlanan projeler (ada göre).
    public var projects: [String: Project]

    public init(
        version: Int = Config.currentVersion,
        instances: [String: Instance] = [:],
        projects: [String: Project] = [:]
    ) {
        self.version = version
        self.instances = instances
        self.projects = projects
    }

    private enum CodingKeys: String, CodingKey {
        case version, instances, projects
    }

    /// `projects` alanı olmayan (v0.1.0) config dosyaları da okunur.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        instances = try container.decode([String: Instance].self, forKey: .instances)
        projects = try container.decodeIfPresent([String: Project].self, forKey: .projects) ?? [:]
    }
}
