import Foundation

/// Bir seed işleminin sonucu.
public struct SeedResult: Equatable {
    /// Workdir güvenli klasörler listesine eklendiyse `true`.
    public var trustedFolderAdded: Bool
    /// Workdir için session preset oluşturulduysa `true`.
    public var presetAdded: Bool
    /// Preset'in bağlandığı hesap UUID'si (hesap bilinmiyorsa `nil`).
    public var accountUUID: String?

    public init(trustedFolderAdded: Bool, presetAdded: Bool, accountUUID: String?) {
        self.trustedFolderAdded = trustedFolderAdded
        self.presetAdded = presetAdded
        self.accountUUID = accountUUID
    }
}

/// Claude Desktop profiline workdir tohumlar.
///
/// Claude Desktop Code sekmesinin seçili klasörü profilin içinde saklar; bu
/// tohumlama instance başına varsayılan proje klasörünü sabitler.
///
/// Etkilenen dosyalar (instance profilinde):
/// - `claude_desktop_config.json` → `preferences.localAgentModeTrustedFolders`
/// - `ccd-session-presets.json` → `byAccount[hesap].presets[]`
///
/// Global kural: yalnızca instance profilinin içindeki dosyalara yazılır.
public struct ProfileSeeder {
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    /// Instance profiline workdir'i tohumlar.
    ///
    /// - Parameters:
    ///   - profileDir: Instance'ın Electron profil dizini.
    ///   - workdir: Tohumlanacak proje klasörü (diskte var olmalı).
    public func seed(profileDir: URL, workdir: String) throws -> SeedResult {
        guard FileManager.default.fileExists(atPath: workdir) else {
            throw ClaudeCtlError.runtime("workdir bulunamadı: \(workdir)")
        }

        let trustedFolderAdded = try addTrustedFolder(profileDir: profileDir, workdir: workdir)
        let (accountUUID, presetAdded) = try addSessionPreset(profileDir: profileDir, workdir: workdir)

        return SeedResult(
            trustedFolderAdded: trustedFolderAdded,
            presetAdded: presetAdded,
            accountUUID: accountUUID
        )
    }

    /// Instance adından profil dizini türeterek tohumlar.
    public func seed(instanceName: String, workdir: String) throws -> SeedResult {
        try seed(profileDir: paths.profileDir(instanceName), workdir: workdir)
    }

    // MARK: - Güvenli klasörler

    private func addTrustedFolder(profileDir: URL, workdir: String) throws -> Bool {
        let url = profileDir.appendingPathComponent("claude_desktop_config.json")
        var config = try readObject(at: url) ?? ["mcpServers": [String: Any](), "preferences": [String: Any]()]
        var preferences = config["preferences"] as? [String: Any] ?? [:]
        var folders = preferences["localAgentModeTrustedFolders"] as? [String] ?? []

        let added = !folders.contains(workdir)
        if added { folders.append(workdir) }

        preferences["localAgentModeTrustedFolders"] = folders
        config["preferences"] = preferences
        try writeObject(config, to: url)
        return added
    }

    // MARK: - Session preset

    private func addSessionPreset(profileDir: URL, workdir: String) throws -> (String?, Bool) {
        let url = profileDir.appendingPathComponent("ccd-session-presets.json")
        var presets = try readObject(at: url) ?? ["byAccount": [String: Any]()]
        var byAccount = presets["byAccount"] as? [String: Any] ?? [:]

        guard let accountUUID = byAccount.keys.sorted().first ?? accountUUIDFromBridgeState(profileDir: profileDir) else {
            // Hesap henüz bilinmiyor (ilk giriş yapılmamış): preset yazılmaz.
            return (nil, false)
        }

        var account = byAccount[accountUUID] as? [String: Any] ?? [:]
        var presetList = account["presets"] as? [[String: Any]] ?? []

        let alreadyExists = presetList.contains { preset in
            (preset["target"] as? [String: Any])?["cwd"] as? String == workdir
        }
        if !alreadyExists {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            presetList.append([
                "id": UUID().uuidString,
                "name": URL(fileURLWithPath: workdir).lastPathComponent,
                "createdAt": now,
                "lastUsedAt": now,
                "target": ["kind": "local", "cwd": workdir]
            ])
        }

        account["presets"] = presetList
        byAccount[accountUUID] = account
        presets["byAccount"] = byAccount
        try writeObject(presets, to: url)

        return (accountUUID, !alreadyExists)
    }

    /// `bridge-state.json` anahtarları `<workspaceId>:<accountUuid>` biçimindedir.
    private func accountUUIDFromBridgeState(profileDir: URL) -> String? {
        let url = profileDir.appendingPathComponent("bridge-state.json")
        guard let object = try? readObject(at: url), let key = object.keys.sorted().first else { return nil }
        guard let last = key.split(separator: ":").last else { return nil }
        return String(last)
    }

    // MARK: - JSON yardımcıları

    private func readObject(at url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            throw ClaudeCtlError.corruptConfig(url)
        }
    }

    private func writeObject(_ object: [String: Any], to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw ClaudeCtlError.runtime("yazılamadı: \(url.path) — \(error.localizedDescription)")
        }
    }
}
