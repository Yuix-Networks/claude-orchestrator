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

/// Profile yazılacak bir Code sekmesi ortamı ("environment" / session preset).
public struct PresetSpec: Equatable {
    public var name: String
    /// Ana çalışma klasörü (`target.cwd`).
    public var cwd: String
    /// Ek klasörler (`target.additionalFolders`).
    public var additionalFolders: [String]

    public init(name: String, cwd: String, additionalFolders: [String] = []) {
        self.name = name
        self.cwd = cwd
        self.additionalFolders = additionalFolders
    }
}

/// Bir profile ortam uygulamasının sonucu.
public struct PresetApplyResult: Equatable {
    /// Güvenli klasörlere eklenen yollar.
    public var trustedFoldersAdded: [String]
    /// Hesap UUID'si → o hesaba eklenen ortamların `cwd`'leri.
    public var presetsAdded: [String: [String]]
    /// Ortamların yazıldığı hesaplar (boşsa hesap henüz bilinmiyor: giriş yapılmamış).
    public var accounts: [String]

    public var addedCount: Int { presetsAdded.values.reduce(0) { $0 + $1.count } }
}

/// Bir profilden ortam kaldırmanın sonucu.
public struct PresetRemoveResult: Equatable {
    public var trustedFoldersRemoved: [String]
    /// Silinen ortam sayısı (tüm hesaplar).
    public var presetsRemoved: Int
}

/// Profilde kayıtlı bir ortam (içe aktarma ve durum gösterimi için).
public struct ExistingPreset: Equatable {
    public var account: String
    public var name: String
    public var cwd: String
    public var additionalFolders: [String]
    public var lastUsedAt: Int64
}

/// Claude Desktop profiline workdir ve ortamlar tohumlar.
///
/// Claude Desktop Code sekmesinin ortamlarını ("environment") profilin içinde
/// hesap başına saklar; bu tip onları instance profillerine yazar.
///
/// Etkilenen dosyalar (instance profilinde):
/// - `claude_desktop_config.json` → `preferences.localAgentModeTrustedFolders`
/// - `ccd-session-presets.json` → `byAccount[hesap].presets[]`
///
/// Global kural: yalnızca instance profilinin içindeki dosyalara yazılır.
/// Var olan bir ortamın (aynı `cwd`) adı ve ayarları değiştirilmez.
public struct ProfileSeeder {
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    /// Instance profiline workdir'i tohumlar (yalnızca etkin hesaba).
    ///
    /// - Parameters:
    ///   - profileDir: Instance'ın Electron profil dizini.
    ///   - workdir: Tohumlanacak proje klasörü (diskte var olmalı).
    public func seed(profileDir: URL, workdir: String) throws -> SeedResult {
        guard FileManager.default.fileExists(atPath: workdir) else {
            throw OrchestratorError.runtime("workdir bulunamadı: \(workdir)")
        }
        let spec = PresetSpec(name: URL(fileURLWithPath: workdir).lastPathComponent, cwd: workdir)
        let result = try apply([spec], to: profileDir, allAccounts: false)
        return SeedResult(
            trustedFolderAdded: !result.trustedFoldersAdded.isEmpty,
            presetAdded: result.addedCount > 0,
            accountUUID: result.accounts.first
        )
    }

    /// Ortamları profile ekler (idempotent).
    ///
    /// - Parameter allAccounts: `true` ise profilde bilinen **tüm** hesaplara
    ///   (preset dosyasındaki hesaplar + etkin hesap) yazılır; `false` ise
    ///   yalnızca etkin hesaba. Hesap bilinmiyorsa ortamlar yazılmaz, yalnızca
    ///   güvenli klasörler eklenir (ilk girişten sonraki `start` tamamlar).
    @discardableResult
    public func apply(_ specs: [PresetSpec], to profileDir: URL, allAccounts: Bool) throws -> PresetApplyResult {
        let folders = specs.flatMap { [$0.cwd] + $0.additionalFolders }
        let trusted = try updateTrustedFolders(profileDir: profileDir) { current in
            var updated = current
            for folder in folders where !updated.contains(folder) { updated.append(folder) }
            return updated
        }

        let url = profileDir.appendingPathComponent("ccd-session-presets.json")
        var presets = try readPresetsFile(url)
        var byAccount = try dictionary(presets["byAccount"], in: url) ?? [:]

        var accounts: [String] = []
        let active = Self.activeAccountUUID(profileDir: profileDir, knownAccounts: Array(byAccount.keys))
        if allAccounts {
            accounts = byAccount.keys.sorted()
            if let active, !accounts.contains(active) { accounts.append(active) }
        } else if let active {
            accounts = [active]
        }

        var added: [String: [String]] = [:]
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for account in accounts {
            var entry = try dictionary(byAccount[account], in: url) ?? [:]
            var list = try presetList(entry["presets"], in: url)
            for spec in specs where !list.contains(where: { Self.cwd(of: $0) == spec.cwd }) {
                var target: [String: Any] = ["kind": "local", "cwd": spec.cwd]
                if !spec.additionalFolders.isEmpty { target["additionalFolders"] = spec.additionalFolders }
                list.append([
                    "id": UUID().uuidString.lowercased(),
                    "name": spec.name,
                    "createdAt": now,
                    "lastUsedAt": now,
                    "target": target
                ])
                added[account, default: []].append(spec.cwd)
            }
            entry["presets"] = list
            byAccount[account] = entry
        }

        if !added.isEmpty {
            presets["byAccount"] = byAccount
            try writeObject(presets, to: url)
        }

        return PresetApplyResult(trustedFoldersAdded: trusted.added, presetsAdded: added, accounts: accounts)
    }

    /// `cwd`'si verilen yollardan biri olan ortamları tüm hesaplardan kaldırır;
    /// bu yolları güvenli klasörlerden de çıkarır.
    @discardableResult
    public func remove(cwds: [String], trustedFolders: [String], from profileDir: URL) throws -> PresetRemoveResult {
        let trusted = try updateTrustedFolders(profileDir: profileDir) { current in
            current.filter { !trustedFolders.contains($0) }
        }

        let url = profileDir.appendingPathComponent("ccd-session-presets.json")
        var presets = try readPresetsFile(url)
        var byAccount = try dictionary(presets["byAccount"], in: url) ?? [:]
        var removed = 0
        for account in byAccount.keys {
            var entry = try dictionary(byAccount[account], in: url) ?? [:]
            let list = try presetList(entry["presets"], in: url)
            let kept = list.filter { preset in !cwds.contains(Self.cwd(of: preset) ?? "") }
            guard kept.count != list.count else { continue }
            removed += list.count - kept.count
            entry["presets"] = kept
            byAccount[account] = entry
        }
        if removed > 0 {
            presets["byAccount"] = byAccount
            try writeObject(presets, to: url)
        }
        return PresetRemoveResult(trustedFoldersRemoved: trusted.removed, presetsRemoved: removed)
    }

    /// Profildeki yerel ortamlar (tüm hesaplar).
    public func existingPresets(profileDir: URL) -> [ExistingPreset] {
        let url = profileDir.appendingPathComponent("ccd-session-presets.json")
        guard let object = Self.readJSONObject(url),
              let byAccount = object["byAccount"] as? [String: Any]
        else { return [] }
        var result: [ExistingPreset] = []
        for (account, value) in byAccount {
            guard let list = (value as? [String: Any])?["presets"] as? [[String: Any]] else { continue }
            for preset in list {
                guard let target = preset["target"] as? [String: Any],
                      (target["kind"] as? String ?? "local") == "local",
                      let cwd = target["cwd"] as? String
                else { continue }
                result.append(ExistingPreset(
                    account: account,
                    name: preset["name"] as? String ?? URL(fileURLWithPath: cwd).lastPathComponent,
                    cwd: cwd,
                    additionalFolders: target["additionalFolders"] as? [String] ?? [],
                    lastUsedAt: (preset["lastUsedAt"] as? NSNumber)?.int64Value ?? 0
                ))
            }
        }
        return result
    }

    private static func cwd(of preset: [String: Any]) -> String? {
        (preset["target"] as? [String: Any])?["cwd"] as? String
    }

    // MARK: - Güvenli klasörler

    private func updateTrustedFolders(
        profileDir: URL,
        _ transform: ([String]) -> [String]
    ) throws -> (added: [String], removed: [String]) {
        let url = profileDir.appendingPathComponent("claude_desktop_config.json")
        var config: [String: Any]
        switch try readObject(at: url) {
        case .missing:
            config = ["mcpServers": [String: Any](), "preferences": [String: Any]()]
        case let .object(value):
            config = value
        case .unexpectedType:
            // Dosya beklenmeyen yapıda: ezmek veri kaybı yaratır.
            throw unexpected(url)
        }

        var preferences = try dictionary(config["preferences"], in: url) ?? [:]
        var folders: [String] = []
        if let existing = preferences["localAgentModeTrustedFolders"] {
            guard let value = existing as? [String] else { throw unexpected(url) }
            folders = value
        }

        let updated = transform(folders)
        let added = updated.filter { !folders.contains($0) }
        let removed = folders.filter { !updated.contains($0) }
        let fileMissing = !FileManager.default.fileExists(atPath: url.path)
        guard !added.isEmpty || !removed.isEmpty || fileMissing else { return ([], []) }

        preferences["localAgentModeTrustedFolders"] = updated
        config["preferences"] = preferences
        try writeObject(config, to: url)
        return (added, removed)
    }

    // MARK: - Etkin hesap

    /// Profilde **etkin** hesabın UUID'si.
    ///
    /// Öncelik sırası:
    /// 1. `config.json` → `lastKnownAccountUuid` (Claude'un son giriş yapan hesabı)
    /// 2. `config.json` → `bootSideSessions.accountUuid`
    /// 3. `bridge-state.json` anahtarı (`<workspaceId>:<accountUuid>`) — tek hesap varsa
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

    private func unexpected(_ url: URL) -> OrchestratorError {
        .runtime("profil dosyası beklenmeyen yapıda, dokunulmadı: \(url.path)")
    }

    private func readPresetsFile(_ url: URL) throws -> [String: Any] {
        switch try readObject(at: url) {
        case .missing: return ["byAccount": [String: Any]()]
        case let .object(value): return value
        case .unexpectedType: throw unexpected(url)
        }
    }

    /// Değer yoksa `nil`; sözlük değilse veri kaybını önlemek için hata.
    private func dictionary(_ value: Any?, in url: URL) throws -> [String: Any]? {
        guard let value else { return nil }
        guard let dictionary = value as? [String: Any] else { throw unexpected(url) }
        return dictionary
    }

    private func presetList(_ value: Any?, in url: URL) throws -> [[String: Any]] {
        guard let value else { return [] }
        guard let list = value as? [[String: Any]] else { throw unexpected(url) }
        return list
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
            throw OrchestratorError.corruptConfig(url)
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
            throw OrchestratorError.runtime("yazılamadı: \(url.path) — \(error.localizedDescription)")
        }
    }
}
