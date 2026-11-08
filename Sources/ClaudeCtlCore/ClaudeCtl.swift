import Foundation

/// `start` komutunun sonucu.
public struct StartResult: Equatable {
    public var instance: Instance
    /// Claude ana sürecinin pid'i.
    public var pid: Int32
    /// Instance zaten çalışıyorsa `true` (yeniden başlatılmadı).
    public var alreadyRunning: Bool
    /// Yapılan profil tohumlaması (workdir yoksa `nil`).
    public var seed: SeedResult?
    /// Kullanıcıya gösterilmesi gereken uyarı (örn. workdir bulunamadı).
    public var warning: String?

    public init(
        instance: Instance,
        pid: Int32,
        alreadyRunning: Bool,
        seed: SeedResult?,
        warning: String?
    ) {
        self.instance = instance
        self.pid = pid
        self.alreadyRunning = alreadyRunning
        self.seed = seed
        self.warning = warning
    }
}

/// `stop` komutunun sonucu.
public struct StopResult: Equatable {
    /// Kapatılan çalışan bir süreç var mıydı?
    public var wasRunning: Bool
    /// SIGTERM yetmediyse SIGKILL kullanıldı mı?
    public var forced: Bool

    public init(wasRunning: Bool, forced: Bool) {
        self.wasRunning = wasRunning
        self.forced = forced
    }
}

/// `claude-ctl` iş mantığının giriş noktası.
public final class ClaudeCtl {
    public let paths: Paths
    public let store: InstanceStore
    public let launcher: Launching
    public let seeder: ProfileSeeder
    public let appPath: String

    public init(
        paths: Paths = .default,
        appPath: String = ClaudeApp.defaultPath,
        processListing: ProcessListing = PsProcessListing(),
        launcher: Launching? = nil
    ) {
        self.paths = paths
        self.store = InstanceStore(paths: paths)
        self.launcher = launcher ?? Launcher(appPath: appPath, processListing: processListing)
        self.seeder = ProfileSeeder(paths: paths)
        self.appPath = appPath
    }

    // MARK: - new

    /// Yeni instance oluşturur (config + profil dizinleri).
    public func new(name: String, workdir: String?) throws -> Instance {
        try NameValidator.validate(name)

        let config = try store.load()
        guard config.instances[name] == nil else {
            throw ClaudeCtlError.runtime("instance '\(name)' zaten var")
        }

        let instance = Instance(name: name, workdir: workdir)
        try store.upsert(instance)

        try FileManager.default.createDirectory(at: paths.profileDir(name), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.codeDir(name), withIntermediateDirectories: true)

        return instance
    }

    // MARK: - start

    /// Instance'ı başlatır.
    public func start(name: String, folder: String?) throws -> StartResult {
        let instance = try store.instance(named: name)
        let profileDir = paths.profileDir(name)
        let codeDir = paths.codeDir(name)

        if let pid = launcher.runningPid(profileDir: profileDir) {
            return StartResult(
                instance: instance,
                pid: pid,
                alreadyRunning: true,
                seed: nil,
                warning: nil
            )
        }

        if launcher.isProfileLocked(profileDir: profileDir) {
            throw ClaudeCtlError.runtime(
                "profil kilitli: \(profileDir.path) (SingletonLock) — başka bir Claude instance'ı bu profili kullanıyor"
            )
        }

        var warning: String?
        var seed: SeedResult?
        if let workdir = instance.workdir {
            if FileManager.default.fileExists(atPath: workdir) {
                seed = try seeder.seed(profileDir: profileDir, workdir: workdir)
            } else {
                warning = "workdir bulunamadı: \(workdir) — tohumlama atlandı"
            }
        }

        let request = LaunchRequest(
            appPath: appPath,
            profileDir: profileDir.path,
            codeDir: codeDir.path,
            extraArgs: folder.map { [$0] } ?? []
        )
        try launcher.launch(request)

        guard let pid = waitForPid(profileDir: profileDir, timeout: 10) else {
            throw ClaudeCtlError.runtime(
                "instance başlatılamadı: süreç bulunamadı (\(profileDir.path))"
            )
        }

        try JSONFile.write(
            InstanceState(pid: pid, startedAt: Date(), claudeVersion: ClaudeApp.version(appPath: appPath)),
            to: paths.stateFile(name)
        )

        return StartResult(
            instance: instance,
            pid: pid,
            alreadyRunning: false,
            seed: seed,
            warning: warning
        )
    }

    private func waitForPid(profileDir: URL, timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = launcher.runningPid(profileDir: profileDir) {
                return pid
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return launcher.runningPid(profileDir: profileDir)
    }

    // MARK: - stop

    /// Instance'ı durdurur.
    public func stop(name: String) throws -> StopResult {
        let stateFile = paths.stateFile(name)
        guard let state = try JSONFile.read(InstanceState.self, from: stateFile) else {
            return StopResult(wasRunning: false, forced: false)
        }

        guard ProcessSignal.isAlive(state.pid) else {
            try? FileManager.default.removeItem(at: stateFile)
            return StopResult(wasRunning: false, forced: false)
        }

        ProcessSignal.terminate(state.pid)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !ProcessSignal.isAlive(state.pid) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }

        var forced = false
        if ProcessSignal.isAlive(state.pid) {
            ProcessSignal.forceKill(state.pid)
            forced = true
        }

        try? FileManager.default.removeItem(at: stateFile)
        return StopResult(wasRunning: true, forced: forced)
    }
}
