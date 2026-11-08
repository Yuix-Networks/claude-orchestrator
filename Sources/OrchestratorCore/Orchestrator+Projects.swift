import Foundation

/// Bir projenin bir instance'taki durumu.
public enum ProjectPresence: String, Equatable {
    /// Ortam, profildeki tüm bilinen hesaplarda var.
    case synced
    /// Ortam en az bir hesapta eksik.
    case missing
    /// Profilde henüz hesap yok (giriş yapılmamış): ortam ilk girişten sonraki
    /// `start` ile yazılır; güvenli klasör şimdiden eklidir.
    case pendingSignIn
}

/// Bir instance'a proje senkronlamanın sonucu.
public struct ProjectSyncResult: Equatable {
    public var instance: String
    public var isRunning: Bool
    public var applied: PresetApplyResult?
    public var error: String?
}

/// Proje kaldırmanın instance başına sonucu.
public struct ProjectRemoveResult: Equatable {
    public var instance: String
    public var isRunning: Bool
    public var removed: PresetRemoveResult?
    public var error: String?
}

/// İçe aktarmanın sonucu.
public struct ProjectImportResult: Equatable {
    public var imported: [Project]
    /// Atlanan klasörler ve sebebi.
    public var skipped: [(path: String, reason: String)]

    public static func == (lhs: ProjectImportResult, rhs: ProjectImportResult) -> Bool {
        lhs.imported == rhs.imported && lhs.skipped.map(\.path) == rhs.skipped.map(\.path)
    }
}

extension Orchestrator {
    // MARK: - Kayıt

    /// Kayıtlı projeler (ada göre sıralı).
    public func projects() throws -> [Project] {
        try store.load().projects.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Projeyi kaydeder ve tüm instance'lara senkronlar.
    ///
    /// - Parameters:
    ///   - name: Claude Desktop'ta görünecek ortam adı. `nil` ise klasör adı.
    ///   - path: Ana klasör (`~` ve göreli yol kabul edilir; var olmalı).
    ///   - additionalFolders: Ek klasörler.
    ///   - replace: Aynı adda proje varsa üzerine yaz.
    public func addProject(
        name: String?,
        path: String,
        additionalFolders: [String] = [],
        replace: Bool = false
    ) throws -> (project: Project, sync: [ProjectSyncResult]) {
        let resolvedPath = try Self.resolveDirectory(path)
        var folders: [String] = []
        for folder in try additionalFolders.map({ try Self.resolveDirectory($0) })
        where folder != resolvedPath && !folders.contains(folder) {
            folders.append(folder)
        }
        let projectName = try Self.validateProjectName(name ?? URL(fileURLWithPath: resolvedPath).lastPathComponent)

        var config = try store.load()
        if let existing = config.projects[projectName], !replace {
            throw OrchestratorError.runtime(
                "'\(projectName)' adlı proje zaten var (\(existing.path)) — değiştirmek için --replace"
            )
        }
        if let other = config.projects.values.first(where: { $0.path == resolvedPath && $0.name != projectName }) {
            throw OrchestratorError.runtime("bu klasör zaten '\(other.name)' adıyla kayıtlı: \(resolvedPath)")
        }

        let project = Project(
            name: projectName,
            path: resolvedPath,
            additionalFolders: folders,
            createdAt: config.projects[projectName]?.createdAt ?? Date()
        )
        config.projects[projectName] = project
        try store.save(config)

        return (project, try syncProjects(only: [project]))
    }

    /// Projeyi kayıttan siler; `keepInInstances` değilse instance'lardaki
    /// ortamını ve güvenli klasörünü de kaldırır.
    ///
    /// Başka bir kayıtlı projenin veya instance workdir'inin kullandığı
    /// klasörler güvenli klasörlerden çıkarılmaz.
    public func removeProject(name: String, keepInInstances: Bool = false) throws -> [ProjectRemoveResult] {
        var config = try store.load()
        guard let project = config.projects.removeValue(forKey: name) else {
            throw OrchestratorError.notFound("proje '\(name)' bulunamadı")
        }
        try store.save(config)
        guard !keepInInstances else { return [] }

        let stillUsed = Set(config.projects.values.flatMap { [$0.path] + $0.additionalFolders })
        var results: [ProjectRemoveResult] = []
        for instance in config.instances.values.sorted(by: { $0.name < $1.name }) {
            let protected = stillUsed.union(instance.workdir.map { [$0] } ?? [])
            let folders = ([project.path] + project.additionalFolders).filter { !protected.contains($0) }
            let running = launcher.runningPid(profileDir: paths.profileDir(instance.name)) != nil
            do {
                let removed = try seeder.remove(
                    cwds: [project.path],
                    trustedFolders: folders,
                    from: paths.profileDir(instance.name)
                )
                results.append(ProjectRemoveResult(instance: instance.name, isRunning: running, removed: removed, error: nil))
            } catch {
                results.append(ProjectRemoveResult(instance: instance.name, isRunning: running, removed: nil, error: "\(error)"))
            }
        }
        return results
    }

    // MARK: - Senkronlama

    /// Kayıtlı projeleri instance profillerine yazar (idempotent).
    ///
    /// - Parameters:
    ///   - instance: Yalnızca bu instance (`default` = instance dışı Claude).
    ///     `nil` → tüm instance'lar (varsayılan kurulum dahil edilmez).
    ///   - only: Yalnızca bu projeler (`nil` → hepsi).
    public func syncProjects(instance: String? = nil, only: [Project]? = nil) throws -> [ProjectSyncResult] {
        let projects = try only ?? self.projects()
        let endpoints = try instance.map { [try endpoint($0)] } ?? instanceEndpoints()
        return endpoints.map { endpoint in
            do {
                let applied = try seeder.apply(projects.map(\.presetSpec), to: endpoint.profileDir, allAccounts: true)
                return ProjectSyncResult(instance: endpoint.name, isRunning: endpoint.isRunning, applied: applied, error: nil)
            } catch {
                return ProjectSyncResult(instance: endpoint.name, isRunning: endpoint.isRunning, applied: nil, error: "\(error)")
            }
        }
    }

    /// Projenin her instance'taki durumu.
    public func projectPresence(_ project: Project) throws -> [(instance: String, presence: ProjectPresence)] {
        try instanceEndpoints().map { endpoint in
            let presets = seeder.existingPresets(profileDir: endpoint.profileDir)
            let accounts = Set(presets.map(\.account))
                .union(ProfileSeeder.activeAccountUUID(profileDir: endpoint.profileDir).map { [$0] } ?? [])
            guard !accounts.isEmpty else { return (endpoint.name, .pendingSignIn) }
            let withProject = Set(presets.filter { $0.cwd == project.path }.map(\.account))
            return (endpoint.name, withProject.isSuperset(of: accounts) ? .synced : .missing)
        }
    }

    // MARK: - İçe aktarma

    /// Bir instance'ın (veya `default` kurulumun) mevcut ortamlarını kayda alır.
    ///
    /// Aynı klasör birden çok hesapta varsa en son kullanılan adı alınır.
    /// Zaten kayıtlı ya da diskte olmayan klasörler atlanır. Ad çakışırsa
    /// sonuna ` (2)` gibi bir ek konur.
    public func importProjects(from source: String) throws -> ProjectImportResult {
        let endpoint = try endpoint(source)
        var config = try store.load()
        let registeredPaths = Set(config.projects.values.map(\.path))

        var newest: [String: ExistingPreset] = [:]
        for preset in seeder.existingPresets(profileDir: endpoint.profileDir) {
            if let current = newest[preset.cwd], current.lastUsedAt >= preset.lastUsedAt { continue }
            newest[preset.cwd] = preset
        }

        var imported: [Project] = []
        var skipped: [(path: String, reason: String)] = []
        for preset in newest.values.sorted(by: { $0.cwd < $1.cwd }) {
            if registeredPaths.contains(preset.cwd) {
                skipped.append((preset.cwd, "zaten kayıtlı"))
                continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: preset.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                skipped.append((preset.cwd, "klasör bulunamadı"))
                continue
            }
            let baseName = (try? Self.validateProjectName(preset.name)) ?? URL(fileURLWithPath: preset.cwd).lastPathComponent
            var name = baseName
            var counter = 2
            while config.projects[name] != nil {
                name = "\(baseName) (\(counter))"
                counter += 1
            }
            let folders = preset.additionalFolders.filter { FileManager.default.fileExists(atPath: $0) }
            let project = Project(name: name, path: preset.cwd, additionalFolders: folders)
            config.projects[name] = project
            imported.append(project)
        }
        try store.save(config)
        return ProjectImportResult(imported: imported, skipped: skipped)
    }

    // MARK: - Doğrulama

    /// Proje adı: boş olmayan, en fazla 80 karakter, kontrol karakteri içermeyen.
    static func validateProjectName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw OrchestratorError.usage("proje adı geçersiz: '\(raw)' (1-80 karakter, satır sonu olmadan)")
        }
        return name
    }

    /// `~` ve göreli yolu mutlak, standart yola çevirir; klasör olmalı.
    static func resolveDirectory(_ path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded)
        let resolved = url.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OrchestratorError.runtime("klasör bulunamadı: \(resolved)")
        }
        return resolved
    }
}
