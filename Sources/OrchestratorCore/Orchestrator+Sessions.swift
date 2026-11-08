import Foundation

/// Oturumların bulunduğu yer: bir instance veya varsayılan Claude kurulumu.
public struct SessionEndpoint: Equatable {
    /// Varsayılan (claude-orchestrator dışı) Claude Desktop kurulumunu temsil eden ad.
    ///
    /// Aynı adda bir instance tanımlıysa instance önceliklidir; yeni instance'a
    /// bu ad verilemez.
    public static let defaultName = "default"

    public var name: String
    /// `CLAUDE_CONFIG_DIR`.
    public var codeDir: URL
    /// Electron profili.
    public var profileDir: URL
    public var isRunning: Bool
    public var isDefault: Bool
    /// Transcript özet önbelleği.
    public var cacheFile: URL?

    public var store: SessionStore { SessionStore(codeDir: codeDir, profileDir: profileDir, cacheFile: cacheFile) }

    /// Profilde indirilmiş en yeni Claude Code CLI sürümü (`<profil>/claude-code/<sürüm>`).
    public var cliVersion: String? {
        let dir = profileDir.appendingPathComponent("claude-code")
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.first?.isNumber == true }
        return versions.max { SessionTransfer.compareVersions($0, $1) == .orderedAscending }
    }
}

/// Bir oturum ve bulunduğu yer.
public struct LocatedSession: Equatable {
    public var endpoint: SessionEndpoint
    public var session: SessionSummary
}

/// `clone` komutunun sonucu.
public struct CloneResult: Equatable {
    public var instance: Instance
    public var sessionCount: Int
}

extension Orchestrator {
    // MARK: - Uç noktalar

    /// Varsayılan Claude kurulumunun dizinleri.
    public static var defaultCodeDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    public static var defaultProfileDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Claude")
    }

    /// Ada göre uç nokta (`default` → varsayılan Claude kurulumu).
    public func endpoint(_ name: String) throws -> SessionEndpoint {
        let config = try store.load()
        if config.instances[name] == nil, name == SessionEndpoint.defaultName {
            return SessionEndpoint(
                name: name,
                codeDir: defaultCodeDir,
                profileDir: defaultProfileDir,
                isRunning: launcher.runningDefaultPid() != nil,
                isDefault: true,
                cacheFile: paths.sessionCacheFile
            )
        }
        guard config.instances[name] != nil else {
            throw OrchestratorError.notFound("instance '\(name)' bulunamadı")
        }
        return SessionEndpoint(
            name: name,
            codeDir: paths.codeDir(name),
            profileDir: paths.profileDir(name),
            isRunning: launcher.runningPid(profileDir: paths.profileDir(name)) != nil,
            isDefault: false,
            cacheFile: paths.sessionCacheFile
        )
    }

    /// Tüm instance'ların uç noktaları (ada göre sıralı).
    public func instanceEndpoints() throws -> [SessionEndpoint] {
        try store.load().instances.keys.sorted().map { try endpoint($0) }
    }

    // MARK: - Listeleme

    /// Oturumlar (en son etkinlik önce).
    ///
    /// - Parameters:
    ///   - instance: Yalnızca bu instance (`default` dahil). `nil` → tüm instance'lar.
    ///   - project: Yalnızca bu çalışma dizinindeki oturumlar.
    ///   - runningOnly: Yalnızca çalışan instance'lar.
    public func sessions(instance: String? = nil, project: String? = nil, runningOnly: Bool = false) throws -> [LocatedSession] {
        let endpoints = try instance.map { [try endpoint($0)] } ?? instanceEndpoints()
        let projectPath = project.map { URL(fileURLWithPath: $0).standardizedFileURL.path }

        return endpoints
            .filter { !runningOnly || $0.isRunning }
            .flatMap { endpoint in
                endpoint.store.sessions().map { LocatedSession(endpoint: endpoint, session: $0) }
            }
            .filter { located in
                guard let projectPath else { return true }
                if let cwd = located.session.cwd { return cwd == projectPath }
                return located.session.projectSlug == SessionStore.slug(for: projectPath)
            }
            .sorted { $0.session.lastActivity > $1.session.lastActivity }
    }

    /// Kimliğe (veya benzersiz öneke) göre oturum.
    ///
    /// `instance` verilmezse tüm instance'larda aranır; birden çok instance'ta
    /// eşleşme varsa belirsizlik hatası verilir.
    public func findSession(_ id: String, instance: String? = nil) throws -> LocatedSession {
        let endpoints = try instance.map { [try endpoint($0)] } ?? instanceEndpoints()
        var matches: [LocatedSession] = []
        for endpoint in endpoints {
            if let session = try endpoint.store.find(id) {
                matches.append(LocatedSession(endpoint: endpoint, session: session))
            }
        }
        guard let first = matches.first else {
            throw OrchestratorError.notFound("oturum bulunamadı: \(id)")
        }
        guard matches.count == 1 else {
            let names = matches.map(\.endpoint.name).joined(separator: ", ")
            throw OrchestratorError.usage("oturum birden çok instance'ta var (\(names)) — --instance ile belirt")
        }
        return first
    }

    /// Instance'ın en son etkin oturumu.
    public func lastSession(instance: String) throws -> LocatedSession {
        guard let last = try sessions(instance: instance).first else {
            throw OrchestratorError.notFound("'\(instance)' instance'ında oturum yok")
        }
        return last
    }

    // MARK: - Transfer

    /// Oturumu başka bir instance'a kopyalar veya taşır.
    ///
    /// Çalışan bir instance'ın config dizinine yazmak (veya `move` ile çalışan
    /// kaynaktan silmek) Claude Code'un açık dosyalarıyla yarışabilir; bu
    /// durumda `force` gerekir.
    public func transferSession(
        _ id: String,
        from: String? = nil,
        to: String,
        move: Bool,
        force: Bool = false
    ) throws -> TransferResult {
        let located = try findSession(id, instance: from)
        return try transfer(located, to: to, move: move, force: force)
    }

    /// Bulunmuş bir oturumu aktarır.
    public func transfer(_ located: LocatedSession, to: String, move: Bool, force: Bool = false) throws -> TransferResult {
        let target = try endpoint(to)
        if !force, target.isRunning {
            throw OrchestratorError.runtime(
                "hedef instance çalışıyor: \(target.name) — önce durdur ya da --force ile devam et"
            )
        }
        if move, !force, located.endpoint.isRunning {
            throw OrchestratorError.runtime(
                "kaynak instance çalışıyor: \(located.endpoint.name) — taşıma için önce durdur "
                + "(ya da 'copy' kullan / --force ile devam et)"
            )
        }
        let transfer = SessionTransfer(
            source: located.endpoint.store,
            target: target.store,
            backupsDir: paths.backupsDir,
            targetCLIVersion: target.cliVersion
        )
        return try transfer.transfer(located.session, move: move, force: force)
    }

    // MARK: - Klonlama

    /// Instance'ı profil + Claude Code config + oturumlarıyla birlikte klonlar.
    ///
    /// Kaynak çalışırken klonlanamaz: canlı bir Chromium profilinin (LevelDB,
    /// SQLite) kopyası tutarsız olur. APFS'te kopya `clonefile` ile yapılır
    /// (ek disk alanı neredeyse sıfır).
    public func clone(_ sourceName: String, as newName: String, workdir: String? = nil) throws -> CloneResult {
        try validateNewName(newName)
        let source = try store.instance(named: sourceName)
        let config = try store.load()
        guard config.instances[newName] == nil else {
            throw OrchestratorError.runtime("instance '\(newName)' zaten var")
        }
        if launcher.runningPid(profileDir: paths.profileDir(sourceName)) != nil {
            throw OrchestratorError.runtime(
                "kaynak instance çalışıyor: \(sourceName) — klonlamadan önce durdur"
            )
        }

        let fm = FileManager.default
        let destination = paths.instanceDir(newName)
        if fm.fileExists(atPath: destination.path) {
            throw OrchestratorError.runtime(
                "hedef dizin zaten var: \(destination.path) — eski verileri kaldır (remove --purge) veya başka ad seç"
            )
        }
        try fm.createDirectory(at: paths.instancesRoot, withIntermediateDirectories: true)

        let temporary = paths.instancesRoot.appendingPathComponent(".\(newName).clone-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: paths.instanceDir(sourceName), to: temporary)
            // Çalışma durumu ve Chromium tekil kilitleri kaynağa aittir.
            for leftover in ["state.json", "profile/SingletonLock", "profile/SingletonCookie", "profile/SingletonSocket"] {
                let url = temporary.appendingPathComponent(leftover)
                if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil || fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                }
            }
            try fm.moveItem(at: temporary, to: destination)
        } catch {
            try? fm.removeItem(at: temporary)
            throw OrchestratorError.runtime("klonlanamadı: \(error.localizedDescription)")
        }

        let instance = Instance(name: newName, workdir: workdir ?? source.workdir, iconBadge: source.iconBadge)
        try store.upsert(instance)
        if let workdir = instance.workdir, fm.fileExists(atPath: workdir), workdir != source.workdir {
            _ = try? seeder.seed(profileDir: paths.profileDir(newName), workdir: workdir)
        }

        let count = SessionStore(codeDir: paths.codeDir(newName)).sessions().count
        return CloneResult(instance: instance, sessionCount: count)
    }

    /// Bir instance'ın tüm oturumlarını diğerine kopyalar (`new --sessions-from`).
    ///
    /// - Returns: Kopyalanan oturumlar ve atlananlar (sebebiyle).
    public func copyAllSessions(from source: String, to target: String) throws -> (copied: [TransferResult], skipped: [(String, String)]) {
        var copied: [TransferResult] = []
        var skipped: [(String, String)] = []
        for located in try sessions(instance: source) {
            do {
                copied.append(try transfer(located, to: target, move: false))
            } catch {
                skipped.append((located.session.id, "\(error)"))
            }
        }
        return (copied, skipped)
    }

    /// Yeni instance adı: biçim kuralları + ayrılmış adlar.
    func validateNewName(_ name: String) throws {
        try NameValidator.validate(name)
        if name == SessionEndpoint.defaultName {
            throw OrchestratorError.invalidName(
                "'\(name)' ayrılmış bir ad (varsayılan Claude kurulumunu gösterir) — başka bir ad seç"
            )
        }
    }
}
