import Foundation

/// Elle düzenlenen proje dosyası (`projects.json`) ile kayıt arasındaki fark.
///
/// Dosya biçimi:
///
/// ```json
/// {
///   "projects": [
///     { "name": "vpn", "path": "~/workspace/vpn/vpn-api-backend",
///       "folders": ["~/workspace/vpn/unblock-master-vpn"] },
///     { "path": "~/workspace/tto" }
///   ]
/// }
/// ```
///
/// - `name` isteğe bağlı (yoksa klasör adı), `folders` isteğe bağlı.
/// - `permissionMode` isteğe bağlı: `bypassPermissions`, `acceptEdits`, `auto`,
///   `plan`, `default` — bu projede açılan oturumların varsayılan izin modu.
/// - `defaults` (isteğe bağlı) tüm projelere uygulanır: `folders` her projenin ek
///   klasörlerine eklenir (projenin kendi klasörü hariç), `permissionMode`
///   projede yazılmadıysa kullanılır.
/// - Yollar `~` ile veya dosyanın bulunduğu klasöre göre göreli yazılabilir.
/// - `//` ile başlayan anahtarlar not olarak yok sayılır; okurken `//` yorumları
///   ve sondaki virgüller de kabul edilir (JSON5).
public struct ProjectPlan: Equatable {
    /// Kayıtta olmayan, eklenecek projeler.
    public var toAdd: [Project]
    /// Klasörü veya ek klasörleri değişen projeler (eski, yeni).
    public var toUpdate: [ProjectChange]
    /// Adı değişen projeler (aynı ana klasör, yeni ad).
    public var toRename: [ProjectChange]
    /// `prune` ile silinecek, dosyada olmayan projeler.
    public var toRemove: [Project]
    /// Dosyada olmayan ama `prune` verilmediği için kalan projeler.
    public var untracked: [Project]
    public var unchanged: [Project]

    public var hasChanges: Bool {
        !(toAdd.isEmpty && toUpdate.isEmpty && toRename.isEmpty && toRemove.isEmpty)
    }
}

/// Bir projenin eski ve yeni hali.
public struct ProjectChange: Equatable {
    public var old: Project
    public var new: Project
}

/// `project apply` sonucu.
public struct ProjectApplyResult: Equatable {
    public var plan: ProjectPlan
    /// Eklenen/değişen projelerin instance'lara yazılması.
    public var synced: [ProjectSyncResult]
    /// Değişen/silinen projelerin eski ortamlarının kaldırılması.
    public var withdrawn: [ProjectRemoveResult]
}

extension Orchestrator {
    /// `project apply` / `project export` için varsayılan dosya.
    public static var defaultManifestURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/claude-orchestrator/projects.json")
    }

    // MARK: - Okuma

    /// Proje dosyasını okur ve doğrular.
    ///
    /// Tüm sorunlar toplanıp tek hatada raporlanır (ilk hatada durulmaz), böylece
    /// elle düzenlenen dosyadaki her yazım hatası bir seferde görülür.
    public static func loadManifest(_ url: URL) throws -> [Project] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw OrchestratorError.runtime("proje dosyası okunamadı: \(url.path) — \(error.localizedDescription)")
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            throw OrchestratorError.runtime("proje dosyası geçerli JSON değil: \(url.path) — \(detail)")
        }

        guard let object = root as? [String: Any] else {
            throw OrchestratorError.runtime("proje dosyası bir JSON nesnesi olmalı: { \"projects\": [ … ] }")
        }
        var problems: [String] = []
        for key in object.keys where !["projects", "version", "defaults"].contains(key) && !key.hasPrefix("//") {
            problems.append("bilinmeyen alan: \"\(key)\" (beklenen: \"projects\", \"defaults\")")
        }
        if let version = object["version"], (version as? Int) != 1 {
            problems.append("desteklenmeyen sürüm: \(version) (yalnızca 1)")
        }
        guard let entries = object["projects"] as? [Any] else {
            problems.append("\"projects\" bir dizi olmalı")
            throw OrchestratorError.runtime(Self.manifestError(url, problems))
        }

        let base = url.deletingLastPathComponent()

        // Ortak ayarlar.
        var defaultFolders: [String] = []
        var defaultMode: String?
        if let rawDefaults = object["defaults"] {
            if let defaults = rawDefaults as? [String: Any] {
                for key in defaults.keys where !["folders", "permissionMode"].contains(key) && !key.hasPrefix("//") {
                    problems.append("defaults: bilinmeyen alan \"\(key)\" (beklenen: folders, permissionMode)")
                }
                if let rawFolders = defaults["folders"] {
                    if let list = rawFolders as? [String] {
                        for raw in list {
                            do {
                                let folder = try resolveDirectory(raw, relativeTo: base)
                                if !defaultFolders.contains(folder) { defaultFolders.append(folder) }
                            } catch {
                                problems.append("defaults: ek klasör — \(error)")
                            }
                        }
                    } else {
                        problems.append("defaults: \"folders\" metin dizisi olmalı")
                    }
                }
                if let rawMode = defaults["permissionMode"] {
                    if let mode = validatePermissionMode(rawMode) { defaultMode = mode } else {
                        problems.append("defaults: \(permissionModeProblem(rawMode))")
                    }
                }
            } else {
                problems.append("\"defaults\" bir nesne olmalı")
            }
        }

        var projects: [Project] = []
        var names: [String: Int] = [:]
        var paths: [String: Int] = [:]

        for (index, entry) in entries.enumerated() {
            let label = "projects[\(index)]"
            guard let item = entry as? [String: Any] else {
                problems.append("\(label): bir nesne olmalı")
                continue
            }
            for key in item.keys where !["name", "path", "folders", "permissionMode"].contains(key) && !key.hasPrefix("//") {
                problems.append("\(label): bilinmeyen alan \"\(key)\" (beklenen: name, path, folders, permissionMode)")
            }
            guard let rawPath = item["path"] as? String else {
                problems.append("\(label): \"path\" zorunlu ve metin olmalı")
                continue
            }
            let path: String
            do {
                path = try resolveDirectory(rawPath, relativeTo: base)
            } catch {
                problems.append("\(label): \(error)")
                continue
            }

            let rawName = item["name"] ?? URL(fileURLWithPath: path).lastPathComponent
            guard let nameText = rawName as? String, let name = try? validateProjectName(nameText) else {
                problems.append("\(label): \"name\" geçersiz (1-80 karakter metin)")
                continue
            }
            let tag = "\(label) \"\(name)\""

            var folders: [String] = []
            if let rawFolders = item["folders"] {
                guard let list = rawFolders as? [String] else {
                    problems.append("\(tag): \"folders\" metin dizisi olmalı")
                    continue
                }
                for raw in list {
                    do {
                        let folder = try resolveDirectory(raw, relativeTo: base)
                        if folder != path && !folders.contains(folder) { folders.append(folder) }
                    } catch {
                        problems.append("\(tag): ek klasör — \(error)")
                    }
                }
            }

            var mode = defaultMode
            if let rawMode = item["permissionMode"] {
                if let valid = validatePermissionMode(rawMode) { mode = valid } else {
                    problems.append("\(tag): \(permissionModeProblem(rawMode))")
                }
            }
            for folder in defaultFolders where folder != path && !folders.contains(folder) {
                folders.append(folder)
            }

            if let first = names[name] {
                problems.append("\(tag): ad projects[\(first)] ile aynı")
                continue
            }
            if let first = paths[path] {
                problems.append("\(tag): klasör projects[\(first)] ile aynı (\(path))")
                continue
            }
            names[name] = index
            paths[path] = index
            projects.append(Project(name: name, path: path, additionalFolders: folders, permissionMode: mode))
        }

        guard problems.isEmpty else {
            throw OrchestratorError.runtime(Self.manifestError(url, problems))
        }
        return projects
    }

    private static func validatePermissionMode(_ raw: Any) -> String? {
        guard let mode = raw as? String, ProfileSeeder.permissionModes.contains(mode) else { return nil }
        return mode
    }

    private static func permissionModeProblem(_ raw: Any) -> String {
        let allowed = ProfileSeeder.permissionModes.sorted().joined(separator: ", ")
        return "\"permissionMode\" geçersiz: \(raw) (geçerli: \(allowed))"
    }

    private static func manifestError(_ url: URL, _ problems: [String]) -> String {
        "proje dosyasında \(problems.count) sorun var (\(url.path)) — hiçbir şey değiştirilmedi:\n"
            + problems.map { "  - \($0)" }.joined(separator: "\n")
    }

    // MARK: - Plan ve uygulama

    /// Dosya ile kayıt arasındaki farkı hesaplar (hiçbir şey yazmaz).
    public func planApply(_ desired: [Project], prune: Bool) throws -> ProjectPlan {
        let current = try store.load().projects
        let desiredNames = Set(desired.map(\.name))
        // Dosyada adı geçmeyen kayıtlı projeler, ana klasörlerine göre.
        var absentByPath: [String: Project] = [:]
        for project in current.values where !desiredNames.contains(project.name) {
            absentByPath[project.path] = project
        }

        var plan = ProjectPlan(toAdd: [], toUpdate: [], toRename: [], toRemove: [], untracked: [], unchanged: [])
        for wanted in desired {
            if let existing = current[wanted.name] {
                var updated = wanted
                updated.createdAt = existing.createdAt
                if existing.sameDefinition(as: wanted) {
                    plan.unchanged.append(existing)
                } else {
                    plan.toUpdate.append(ProjectChange(old: existing, new: updated))
                }
            } else if let renamed = absentByPath.removeValue(forKey: wanted.path) {
                // Aynı klasör yeni adla: kayıt aynı klasörü iki adla tutamaz, yeniden adlandırmadır.
                var updated = wanted
                updated.createdAt = renamed.createdAt
                plan.toRename.append(ProjectChange(old: renamed, new: updated))
            } else {
                // Klasör kayıtta başka bir projedeyse, o proje dosyada başka bir yola
                // taşınmıştır (dosyada klasörler benzersiz); güncelleme önce uygulanır.
                plan.toAdd.append(wanted)
            }
        }

        let leftovers = absentByPath.values.sorted { $0.name < $1.name }
        if prune { plan.toRemove = leftovers } else { plan.untracked = leftovers }
        return plan
    }

    /// Planı uygular: kaydı günceller, eski ortamları kaldırır, yenilerini
    /// tüm instance'lara yazar.
    ///
    /// Klasörü, ek klasörleri veya adı değişen bir projenin instance'lardaki ortamı
    /// silinip yeniden yazılır (o ortamdaki model gibi Desktop ayarları sıfırlanır).
    /// Yalnızca izin modu değiştiyse ortama dokunulmaz, mod yerinde güncellenir.
    public func apply(_ plan: ProjectPlan) throws -> ProjectApplyResult {
        guard plan.hasChanges else {
            return ProjectApplyResult(plan: plan, synced: [], withdrawn: [])
        }
        var config = try store.load()
        let replaced = plan.toUpdate.map(\.old) + plan.toRename.map(\.old)
        for project in plan.toRemove + replaced {
            config.projects.removeValue(forKey: project.name)
        }
        let written = plan.toAdd + plan.toUpdate.map(\.new) + plan.toRename.map(\.new)
        for project in written {
            config.projects[project.name] = project
        }
        try store.save(config)

        // Ortamı yeniden yazılması gerekenler: tanımı (mod dışında) değişenler.
        let rewritten = plan.toUpdate
            .filter { $0.old.path != $0.new.path || $0.old.additionalFolders != $0.new.additionalFolders }
            .map(\.old) + plan.toRename.map(\.old)
        let withdrawn = withdraw(plan.toRemove + rewritten, remaining: config)

        // Dosyadan kaldırılan izin modları Desktop'tan da silinir.
        let clearedModes = plan.toUpdate
            .filter { $0.old.permissionMode != nil && $0.new.permissionMode == nil }
            .map(\.new.path)
        if !clearedModes.isEmpty {
            for endpoint in try instanceEndpoints() {
                try? seeder.removePermissionModes(cwds: clearedModes, profileDir: endpoint.profileDir)
            }
        }

        let synced = try syncProjects(only: written)
        return ProjectApplyResult(plan: plan, synced: synced, withdrawn: withdrawn)
    }

    // MARK: - Dışa aktarma

    /// Kayıtlı projeleri proje dosyası biçiminde döner (ev dizini `~` olarak).
    ///
    /// Alan sırası elle okunabilirlik için sabittir: name, path, folders.
    public func exportManifest() throws -> String {
        try Self.renderManifest(projects())
    }

    public static func renderManifest(_ projects: [Project]) -> String {
        func quoted(_ text: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])
            let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            return String(array.dropFirst().dropLast())
        }
        func tilde(_ path: String) -> String {
            let home = NSHomeDirectory()
            return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
        let items = projects.map { project -> String in
            var fields = ["\"name\": \(quoted(project.name))", "\"path\": \(quoted(tilde(project.path)))"]
            if !project.additionalFolders.isEmpty {
                let folders = project.additionalFolders.map { quoted(tilde($0)) }.joined(separator: ", ")
                fields.append("\"folders\": [\(folders)]")
            }
            if let mode = project.permissionMode {
                fields.append("\"permissionMode\": \(quoted(mode))")
            }
            return "    { " + fields.joined(separator: ", ") + " }"
        }
        return "{\n  \"projects\": [\n" + items.joined(separator: ",\n") + "\n  ]\n}\n"
    }
}
