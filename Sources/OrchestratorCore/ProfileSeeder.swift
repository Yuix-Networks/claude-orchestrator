import Foundation

/// Result of a seed operation.
public struct SeedResult: Equatable {
    /// `true` if the workdir was added to the trusted folders.
    public var trustedFolderAdded: Bool
    /// `true` if a session preset was created for the workdir.
    public var presetAdded: Bool
    /// UUID of the account the preset belongs to (`nil` if the account is unknown).
    public var accountUUID: String?

    public init(trustedFolderAdded: Bool, presetAdded: Bool, accountUUID: String?) {
        self.trustedFolderAdded = trustedFolderAdded
        self.presetAdded = presetAdded
        self.accountUUID = accountUUID
    }
}

/// A Code tab environment (session preset) to write into a profile.
public struct PresetSpec: Equatable {
    public var name: String
    /// Main working folder (`target.cwd`).
    public var cwd: String
    /// Additional folders (`target.additionalFolders`).
    public var additionalFolders: [String]
    /// Default permission mode for sessions opened in this folder (`nil` → left alone).
    public var permissionMode: String?

    public init(name: String, cwd: String, additionalFolders: [String] = [], permissionMode: String? = nil) {
        self.name = name
        self.cwd = cwd
        self.additionalFolders = additionalFolders
        self.permissionMode = permissionMode
    }
}

/// Result of applying environments to a profile.
public struct PresetApplyResult: Equatable {
    /// Paths added to the trusted folders.
    public var trustedFoldersAdded: [String]
    /// Account UUID → `cwd`s of the environments added to that account.
    public var presetsAdded: [String: [String]]
    /// Accounts the environments were written to (empty means the account isn't known yet: not signed in).
    public var accounts: [String]
    /// Number of folder permission modes written (across all accounts).
    public var permissionModesSet: Int = 0
    /// Accounts where bypass was requested but the organization policy disallows it
    /// (`bypassPermissionsGateByAccount == false`); the mode won't work there.
    public var bypassBlockedAccounts: [String] = []

    public var addedCount: Int { presetsAdded.values.reduce(0) { $0 + $1.count } }
}

/// Result of removing environments from a profile.
public struct PresetRemoveResult: Equatable {
    public var trustedFoldersRemoved: [String]
    /// Number of environments removed (across all accounts).
    public var presetsRemoved: Int
}

/// An environment saved in a profile (for import and status display).
public struct ExistingPreset: Equatable {
    public var account: String
    public var name: String
    public var cwd: String
    public var additionalFolders: [String]
    public var lastUsedAt: Int64
}

/// Seeds the workdir and environments into a Claude Desktop profile.
///
/// Claude Desktop stores the Code tab environments inside the profile, per
/// account; this type writes them into instance profiles.
///
/// Files touched (in the instance profile):
/// - `claude_desktop_config.json` → `preferences.localAgentModeTrustedFolders`
/// - `ccd-session-presets.json` → `byAccount[account].presets[]`
///
/// Global rule: only files inside the instance profile are written.
/// An existing environment (same `cwd`) keeps its name and settings.
public struct ProfileSeeder {
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    /// Seeds the workdir into the instance profile (active account only).
    ///
    /// - Parameters:
    ///   - profileDir: The instance's Electron profile directory.
    ///   - workdir: Project folder to seed (must exist on disk).
    public func seed(profileDir: URL, workdir: String) throws -> SeedResult {
        guard FileManager.default.fileExists(atPath: workdir) else {
            throw OrchestratorError.runtime("workdir not found: \(workdir)")
        }
        let spec = PresetSpec(name: URL(fileURLWithPath: workdir).lastPathComponent, cwd: workdir)
        let result = try apply([spec], to: profileDir, allAccounts: false)
        return SeedResult(
            trustedFolderAdded: !result.trustedFoldersAdded.isEmpty,
            presetAdded: result.addedCount > 0,
            accountUUID: result.accounts.first
        )
    }

    /// Adds environments to the profile (idempotent).
    ///
    /// - Parameter allAccounts: If `true`, writes to **every** account known in the
    ///   profile (accounts in the presets file + the active account); if `false`,
    ///   only to the active account. If no account is known, environments are not
    ///   written and only the trusted folders are added (the first `start` after
    ///   sign-in finishes the job).
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
        var catalogChanged = false
        for account in accounts {
            var entry = try dictionary(byAccount[account], in: url) ?? [:]
            var list = try presetList(entry["presets"], in: url)
            // Claude Desktop treats an account catalog without `seededFromDraft` as
            // "not set up yet": on launch it builds an empty catalog, overwrites the
            // file, and the environments we added are lost. So mark it the same way
            // Desktop marks the catalogs it creates itself.
            if entry["seededFromDraft"] as? Bool != true {
                entry["seededFromDraft"] = true
                catalogChanged = true
            }
            if entry["builtIns"] == nil {
                entry["builtIns"] = [String: Any]()
                catalogChanged = true
            }
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

        if !added.isEmpty || catalogChanged {
            presets["byAccount"] = byAccount
            try writeObject(presets, to: url)
        }

        var result = PresetApplyResult(trustedFoldersAdded: trusted.added, presetsAdded: added, accounts: accounts)
        let moded = specs.filter { $0.permissionMode != nil }
        if !moded.isEmpty, !accounts.isEmpty {
            (result.permissionModesSet, result.bypassBlockedAccounts) =
                try applyPermissionModes(moded, accounts: accounts, profileDir: profileDir)
        }
        return result
    }

    // MARK: - Permission modes

    /// Permission modes Desktop accepts.
    public static let permissionModes: Set<String> = ["default", "acceptEdits", "plan", "auto", "bypassPermissions"]

    static func folderModeKey(_ account: String) -> String { "epitaxy-folder-permission-mode-v2.\(account)" }
    static func modeAckKey(_ account: String) -> String { "epitaxy-perm-mode-acks-v2.\(account)" }

    /// Writes the per-folder permission mode (`preferences.epitaxyPrefs`).
    ///
    /// For bypass, the app-level switch (`bypassPermissionsModeEnabled`), the
    /// account opt-in (`bypassPermissionsOptInByAccount`) and the folder's warning
    /// acknowledgement are written too. The organization policy
    /// (`bypassPermissionsGateByAccount`) is never changed; accounts where it is
    /// off are reported.
    private func applyPermissionModes(
        _ specs: [PresetSpec],
        accounts: [String],
        profileDir: URL
    ) throws -> (Int, [String]) {
        var count = 0
        var blocked: [String] = []
        try updateDesktopPreferences(profileDir: profileDir) { preferences, url in
            var epitaxy = try dictionary(preferences["epitaxyPrefs"], in: url) ?? [:]
            let gate = preferences["bypassPermissionsGateByAccount"] as? [String: Any] ?? [:]
            var optIn = try dictionary(preferences["bypassPermissionsOptInByAccount"], in: url) ?? [:]
            var changed = false
            let wantsBypass = specs.contains { $0.permissionMode == "bypassPermissions" }

            for account in accounts {
                var modes = try dictionary(epitaxy[Self.folderModeKey(account)], in: url) ?? [:]
                var acks = epitaxy[Self.modeAckKey(account)] as? [String] ?? []
                for spec in specs {
                    guard let mode = spec.permissionMode else { continue }
                    if modes[spec.cwd] as? String != mode {
                        modes[spec.cwd] = mode
                        changed = true
                    }
                    count += 1
                    let ack = "\(spec.cwd):\(mode)"
                    if mode == "bypassPermissions", !acks.contains(ack) {
                        acks.append(ack)
                        changed = true
                    }
                }
                epitaxy[Self.folderModeKey(account)] = modes
                epitaxy[Self.modeAckKey(account)] = acks
                if wantsBypass {
                    if gate[account] as? Bool == false { blocked.append(account) }
                    if optIn[account] as? Bool != true {
                        optIn[account] = true
                        changed = true
                    }
                }
            }
            if wantsBypass {
                if preferences["bypassPermissionsModeEnabled"] as? Bool != true {
                    preferences["bypassPermissionsModeEnabled"] = true
                    changed = true
                }
                preferences["bypassPermissionsOptInByAccount"] = optIn
            }
            preferences["epitaxyPrefs"] = epitaxy
            return changed
        }
        return (count, blocked)
    }

    /// Removes the folders' permission mode entries from every account.
    public func removePermissionModes(cwds: [String], profileDir: URL) throws {
        let url = profileDir.appendingPathComponent("claude_desktop_config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try updateDesktopPreferences(profileDir: profileDir) { preferences, url in
            guard var epitaxy = try dictionary(preferences["epitaxyPrefs"], in: url) else { return false }
            var changed = false
            for key in epitaxy.keys {
                if key.hasPrefix("epitaxy-folder-permission-mode-v2."), var modes = epitaxy[key] as? [String: Any] {
                    let before = modes.count
                    for cwd in cwds { modes.removeValue(forKey: cwd) }
                    if modes.count != before { epitaxy[key] = modes; changed = true }
                } else if key.hasPrefix("epitaxy-perm-mode-acks-v2."), let acks = epitaxy[key] as? [String] {
                    let kept = acks.filter { ack in !cwds.contains { ack.hasPrefix($0 + ":") } }
                    if kept.count != acks.count { epitaxy[key] = kept; changed = true }
                }
            }
            preferences["epitaxyPrefs"] = epitaxy
            return changed
        }
    }

    /// Folder → permission mode in the profile (for the active account, or the first account if unknown).
    public func permissionModes(profileDir: URL) -> [String: String] {
        let url = profileDir.appendingPathComponent("claude_desktop_config.json")
        guard let config = Self.readJSONObject(url),
              let epitaxy = (config["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any]
        else { return [:] }
        let account = Self.activeAccountUUID(profileDir: profileDir)
        let keys = epitaxy.keys.filter { $0.hasPrefix("epitaxy-folder-permission-mode-v2.") }.sorted()
        let key = account.map(Self.folderModeKey).flatMap { keys.contains($0) ? $0 : nil } ?? keys.first
        return key.flatMap { epitaxy[$0] as? [String: String] } ?? [:]
    }

    /// Removes environments whose `cwd` is one of the given paths from every
    /// account, and removes those paths from the trusted folders.
    @discardableResult
    public func remove(cwds: [String], trustedFolders: [String], from profileDir: URL) throws -> PresetRemoveResult {
        let trusted = try updateTrustedFolders(profileDir: profileDir) { current in
            current.filter { !trustedFolders.contains($0) }
        }
        try removePermissionModes(cwds: cwds, profileDir: profileDir)

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

    /// Local environments in the profile (all accounts).
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

    // MARK: - Desktop preferences

    /// Modifies `claude_desktop_config.json` → `preferences`.
    ///
    /// `transform` returns `true` if it changed something; only then is the file written.
    private func updateDesktopPreferences(
        profileDir: URL,
        _ transform: (inout [String: Any], URL) throws -> Bool
    ) throws {
        let url = profileDir.appendingPathComponent("claude_desktop_config.json")
        var config: [String: Any]
        switch try readObject(at: url) {
        case .missing: config = ["mcpServers": [String: Any](), "preferences": [String: Any]()]
        case let .object(value): config = value
        case .unexpectedType: throw unexpected(url)
        }
        var preferences = try dictionary(config["preferences"], in: url) ?? [:]
        guard try transform(&preferences, url) else { return }
        config["preferences"] = preferences
        try writeObject(config, to: url)
    }

    // MARK: - Trusted folders

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
            // Unexpected file structure: overwriting it would lose data.
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

    // MARK: - Active account

    /// UUID of the **active** account in the profile.
    ///
    /// In order of priority:
    /// 1. `config.json` → `lastKnownAccountUuid` (the account that last signed in to Claude)
    /// 2. `config.json` → `bootSideSessions.accountUuid`
    /// 3. The `bridge-state.json` key (`<workspaceId>:<accountUuid>`), if there is only one account
    /// 4. The only account in the presets file, if there is just one
    ///
    /// Returns `nil` if there are several candidates and none marks the active
    /// account: we don't guess, so presets never land in the wrong account.
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

    // MARK: - JSON helpers

    /// Result of reading a JSON object: missing file / object / unexpected structure.
    private enum ObjectRead {
        case missing
        case object([String: Any])
        case unexpectedType
    }

    private func unexpected(_ url: URL) -> OrchestratorError {
        .runtime("profile file has an unexpected structure, left untouched: \(url.path)")
    }

    private func readPresetsFile(_ url: URL) throws -> [String: Any] {
        switch try readObject(at: url) {
        case .missing: return ["byAccount": [String: Any]()]
        case let .object(value): return value
        case .unexpectedType: throw unexpected(url)
        }
    }

    /// `nil` if there is no value; throws if it isn't a dictionary, to avoid losing data.
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
        // Take a backup before the first rewrite (protects against data loss).
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
            throw OrchestratorError.runtime("couldn't write \(url.path) — \(error.localizedDescription)")
        }
    }
}
