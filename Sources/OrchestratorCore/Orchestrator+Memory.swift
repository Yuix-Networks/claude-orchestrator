import Foundation

/// Bir instance'taki ortak CLAUDE.md bağının durumu.
public enum MemoryLinkState: String, Equatable {
    /// Bağ bu işlemde kuruldu.
    case linked
    /// Bağ zaten ortak dosyayı gösteriyor.
    case alreadyLinked
    /// Instance'ın kendine ait bir CLAUDE.md'si var; dokunulmadı (`force` ile yedeklenip bağlanır).
    case ownFile
    /// Bağ yok (durum sorgusu).
    case missing
    /// Bağ kaldırıldı.
    case unlinked
}

/// Ortak CLAUDE.md işleminin instance başına sonucu.
public struct MemoryLinkResult: Equatable {
    public var instance: String
    public var state: MemoryLinkState
    /// `force` ile kenara alınan eski dosya.
    public var backup: URL?
}

/// Ortak CLAUDE.md.
///
/// Her instance'ın kendi `CLAUDE_CONFIG_DIR`'i olduğu için Claude Code, varsayılan
/// kurulumun `~/.claude/CLAUDE.md` dosyasını instance'larda okumaz. Bu uzantı her
/// instance'ın config dizinine o dosyaya işaret eden bir sembolik bağ koyar:
/// kurallar tek yerden düzenlenir, tüm instance'larda aynıdır.
extension Orchestrator {
    /// Ortak dosya: varsayılan kurulumun CLAUDE.md'si.
    public var sharedMemoryFile: URL { defaultCodeDir.appendingPathComponent("CLAUDE.md") }

    func memoryFile(_ instance: String) -> URL {
        paths.codeDir(instance).appendingPathComponent("CLAUDE.md")
    }

    /// Instance'lara ortak CLAUDE.md bağını kurar.
    ///
    /// - Parameters:
    ///   - instance: Yalnızca bu instance (`nil` → hepsi).
    ///   - force: Instance'ın kendi CLAUDE.md'si varsa `CLAUDE.md.bak-<zaman>` olarak
    ///     kenara alıp bağla.
    @discardableResult
    public func linkSharedMemory(instance: String? = nil, force: Bool = false) throws -> [MemoryLinkResult] {
        guard FileManager.default.fileExists(atPath: sharedMemoryFile.path) else {
            throw OrchestratorError.runtime("ortak dosya yok: \(sharedMemoryFile.path) — önce oluştur")
        }
        return try memoryTargets(instance).map { name in
            let fm = FileManager.default
            let target = memoryFile(name)
            switch memoryState(name) {
            case .alreadyLinked:
                return MemoryLinkResult(instance: name, state: .alreadyLinked, backup: nil)
            case .ownFile where !force:
                return MemoryLinkResult(instance: name, state: .ownFile, backup: nil)
            case .ownFile:
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
                let backup = target.deletingLastPathComponent().appendingPathComponent("CLAUDE.md.bak-\(stamp)")
                try fm.moveItem(at: target, to: backup)
                try fm.createSymbolicLink(at: target, withDestinationURL: sharedMemoryFile)
                return MemoryLinkResult(instance: name, state: .linked, backup: backup)
            default:
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Başka bir yeri gösteren ya da kırık bağ değiştirilir.
                if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
                    try fm.removeItem(at: target)
                }
                try fm.createSymbolicLink(at: target, withDestinationURL: sharedMemoryFile)
                return MemoryLinkResult(instance: name, state: .linked, backup: nil)
            }
        }
    }

    /// Ortak CLAUDE.md bağlarını kaldırır (instance'ın kendi dosyalarına dokunmaz).
    @discardableResult
    public func unlinkSharedMemory(instance: String? = nil) throws -> [MemoryLinkResult] {
        try memoryTargets(instance).map { name in
            guard memoryState(name) == .alreadyLinked else {
                return MemoryLinkResult(instance: name, state: memoryState(name), backup: nil)
            }
            try FileManager.default.removeItem(at: memoryFile(name))
            return MemoryLinkResult(instance: name, state: .unlinked, backup: nil)
        }
    }

    /// Her instance'ın bağ durumu.
    public func sharedMemoryStatus() throws -> [MemoryLinkResult] {
        try memoryTargets(nil).map { MemoryLinkResult(instance: $0, state: memoryState($0), backup: nil) }
    }

    func memoryState(_ instance: String) -> MemoryLinkState {
        let target = memoryFile(instance)
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) {
            let resolved = URL(fileURLWithPath: destination, relativeTo: target.deletingLastPathComponent())
                .standardizedFileURL.path
            return resolved == sharedMemoryFile.standardizedFileURL.path ? .alreadyLinked : .missing
        }
        return FileManager.default.fileExists(atPath: target.path) ? .ownFile : .missing
    }

    private func memoryTargets(_ instance: String?) throws -> [String] {
        if let instance {
            _ = try store.instance(named: instance)
            return [instance]
        }
        return try store.load().instances.keys.sorted()
    }

    /// `new`/`start` için: bağ yoksa ve ortak dosya varsa kur; asla üzerine yazma.
    func ensureSharedMemory(_ instance: String) {
        guard FileManager.default.fileExists(atPath: sharedMemoryFile.path),
              memoryState(instance) == .missing
        else { return }
        _ = try? linkSharedMemory(instance: instance)
    }
}
