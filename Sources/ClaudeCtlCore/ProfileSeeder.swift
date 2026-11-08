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

    // MARK: - Güvenli klasörler

    private func addTrustedFolder(profileDir: URL, workdir: String) throws -> Bool {
        let url = profileDir.appendingPathComponent("claude_desktop_config.json")
        var config: [String: Any]
        switch try readObject(at: url) {
        case .missing:
            config = ["mcpServers": [String: Any](), "preferences": [String: Any]()]
        case let .object(value):
            config = value
        case .unexpectedType:
            // Dosya beklenmeyen yapıda: ezmek veri kaybı yaratır.
            throw ClaudeCtlError.runtime(
                "profil dosyası beklenmeyen yapıda, dokunulmadı: \(url.path)"
            )
        }

        var preferences: [String: Any]
        if let existing = config["preferences"] {
            guard let value = existing as? [String: Any] else {
                throw ClaudeCtlError.runtime(
                    "profil dosyası beklenmeyen yapıda, dokunulmadı: \(url.path)"
                )
            }
            preferences = value
        } else {
            preferences = [:]
        }

        var folders: [String]
        if let existing = preferences["localAgentModeTrustedFolders"] {
            guard let value = existing as? [String] else {
                throw ClaudeCtlError.runtime(
                    "profil dosyası beklenmeyen yapıda, dokunulmadı: \(url.path)"
                )
            }
            folders = value
        } else {
            folders = []
        }

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
        var presets: [String: Any]
        switch try readObject(at: url) {
        case .missing:
            presets = ["byAccount": [String: Any]()]
        case let .object(value):
            presets = value
        case .unexpectedType:
            throw ClaudeCtlError.runtime(
                "profil dosyası beklenmeyen yapıda, dokunulmadı: \(url.path)"
            )
        }

        var byAccount: [String: Any]
        if let existing = presets["byAccount"] {
            guard let value = existing as? [String: Any] else {
                throw ClaudeCtlError.runtime(
                    "profil dosyası beklenmeyen yapıda, dokunulmadı: \(url.path)"
                )
            }
            byAccount = value
        } else {
            byAccount = [:]
        }

        guard let accountUUID = Self.activeAccountUUID(profileDir: profileDir, knownAccounts: Array(byAccount.keys)) else {
            // Hesap henüz bilinmiyor (ilk giriş yapılmamış): preset yazılmaz.
            return (nil, false)
        }

        var account: [String: Any]
        if let existing = byAccount[accountUUID] {
            guard let value = existing as? [String: Any] else {
                throw ClaudeCtlError.runtime(
                    "profil dosyası beklenmeyen yapıda, dokunulmadı: \(url.path)"
                )
            }
            account = value
        } else {
            account = [:]
        }

        var presetList: [[String: Any]]
        if let existing = account["presets"] {
            guard let value = existing as? [[String: Any]] else {
                throw ClaudeCtlError.runtime(
                    "profil dosyası beklenmeyen yapıda, dokunulmadı: \(url.path)"
                )
            }
            presetList = value
        } else {
            presetList = []
        }

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

    /// Profilde **etkin** hesabın UUID'si.
    ///
    /// Öncelik sırası:
    /// 1. `config.json` → `lastKnownAccountUuid` (Claude'un son giriş yapan hesabı)
    /// 2. `config.json` → `bootSideSessions.accountUuid`
    /// 3. `bridge-state.json` anahtarı (`<workspaceId>:<accountUuid>`) — tek anahtar varsa
    /// 4. Preset dosyasında tek hesap varsa o hesap
    ///
    /// Birden çok aday olup hiçbiri etkin hesabı göstermiyorsa `nil` döner:
    /// preset yanlış hesaba yazılmasın diye tahmin yapılmaz.
    public static func activeAccountUUID(profileDir: URL, knownAccounts: [String] = []) -> String? {
        if let config = readJSONObject(profileDir.appendingPathComponent("config.json")) {
            if let uuid = config["lastKnownAccountUuid"] as? String, !uuid.isEmpty {
                return uuid
            }
            if let boot = config["bootSideSessions"] as? [String: Any],
               let uuid = boot["accountUuid"] as? String, !uuid.isEmpty {
                return uuid
            }
        }
        if let bridge = readJSONObject(profileDir.appendingPathComponent("bridge-state.json")) {
            let accounts = Set(bridge.keys.compactMap { $0.split(separator: ":").last.map(String.init) })
            if accounts.count == 1 { return accounts.first }
        }
        if knownAccounts.count == 1 { return knownAccounts.first }
        return nil
    }

    private static func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - JSON yardımcıları

    /// JSON nesnesi okuma sonucu: dosya yok / nesne / beklenmeyen yapı.
    private enum ObjectRead {
        case missing
        case object([String: Any])
        case unexpectedType
    }

    private func readObject(at url: URL) throws -> ObjectRead {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unexpectedType
            }
            return .object(object)
        } catch {
            throw ClaudeCtlError.corruptConfig(url)
        }
    }

    private func writeObject(_ object: [String: Any], to url: URL) throws {
        // İlk yeniden yazmadan önce yedek al (veri kaybı koruması).
        let backup = url.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: url.path),
           !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: url, to: backup)
        }
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
