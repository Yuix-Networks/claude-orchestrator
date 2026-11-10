import Foundation

/// Definition of a single Claude instance.
public struct Instance: Codable, Equatable, Sendable {
    public var name: String
    /// Project folder the instance works in. `nil` means no workdir is set.
    public var workdir: String?
    public var createdAt: Date
    /// Start automatically at login?
    public var autoStart: Bool
    /// Short label shown on the menu bar icon.
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

/// A project that should exist in every instance (an "environment" in Claude Desktop).
///
/// Kept centrally in `config.json` and synced to the Code tab environments
/// (`ccd-session-presets.json`) of every instance profile.
public struct Project: Codable, Equatable, Sendable {
    /// The environment's name as shown in Claude Desktop (the registry key).
    public var name: String
    /// Main working folder (absolute path).
    public var path: String
    /// Additional folders (absolute paths).
    public var additionalFolders: [String]
    /// Default permission mode for sessions opened in this project
    /// (`bypassPermissions`, `acceptEdits`, …). `nil` → the Desktop setting is left alone.
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

    /// Is the definition the same? (ignores the creation time)
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

/// Contents of `config.json`.
public struct Config: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var instances: [String: Instance]
    /// Projects synced to every instance (keyed by name).
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

    /// Also reads config files without a `projects` field (v0.1.0).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        instances = try container.decode([String: Instance].self, forKey: .instances)
        projects = try container.decodeIfPresent([String: Project].self, forKey: .projects) ?? [:]
    }
}
