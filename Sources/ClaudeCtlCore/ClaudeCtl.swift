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

/// Bir instance'ın anlık durumu.
public struct InstanceStatus: Equatable {
    public var name: String
    public var workdir: String?
    public var isRunning: Bool
    public var pid: Int32?
    public var startedAt: Date?
    public var profileSizeBytes: Int64
    /// Profilde oturum (cookie) dosyası var mı?
    public var accountSignedIn: Bool

    public init(
        name: String,
        workdir: String?,
        isRunning: Bool,
        pid: Int32?,
        startedAt: Date?,
        profileSizeBytes: Int64,
        accountSignedIn: Bool
    ) {
        self.name = name
        self.workdir = workdir
        self.isRunning = isRunning
        self.pid = pid
        self.startedAt = startedAt
        self.profileSizeBytes = profileSizeBytes
        self.accountSignedIn = accountSignedIn
    }
}

/// `open` komutunda hedeflenen klasör.
public enum OpenTarget: String, Equatable {
    case workdir
    case profile
}

/// `signin` komutunun rehberi.
public struct SigninPlan: Equatable {
    public var instance: String
    /// `claude://` handler'ın hangi instance'a gittiği (ölçülemiyorsa `nil`).
    public var handlerInstance: String?
    /// Çalışan diğer instance'lar (handler çakışması riski).
    public var otherInstancesRunning: [String]
    public var instructions: [String]

    public init(
        instance: String,
        handlerInstance: String?,
        otherInstancesRunning: [String],
        instructions: [String]
    ) {
        self.instance = instance
        self.handlerInstance = handlerInstance
        self.otherInstancesRunning = otherInstancesRunning
        self.instructions = instructions
    }
}

/// `claude-ctl` iş mantığının giriş noktası.
public final class ClaudeCtl {
    public let paths: Paths
    public let store: InstanceStore
    public let launcher: Launching
    public let seeder: ProfileSeeder
    public let logReader: LogReader
    public let appPath: String

    public init(
        paths: Paths = .default,
        appPath: String = ClaudeApp.defaultPath,
        processListing: ProcessListing = PsProcessListing(),
        launcher: Launching? = nil,
        logReader: LogReader = LogReader()
    ) {
        self.paths = paths
        self.store = InstanceStore(paths: paths)
        self.launcher = launcher ?? Launcher(appPath: appPath, processListing: processListing)
        self.seeder = ProfileSeeder(paths: paths)
        self.logReader = logReader
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

        // Profil tohumlanır (güvenli klasörler). Session preset hesap bilinmiyorsa
        // yazılamaz; o aşamada `start` yeniden dener.
        if let workdir, FileManager.default.fileExists(atPath: workdir) {
            _ = try? seeder.seed(profileDir: paths.profileDir(name), workdir: workdir)
        }

        return instance
    }

    // MARK: - start

    /// Instance'ı başlatır.
    public func start(name: String, folder: String?) throws -> StartResult {
        let instance = try store.instance(named: name)
        let profileDir = paths.profileDir(name)
        let codeDir = paths.codeDir(name)

        if let pid = launcher.runningPid(profileDir: profileDir) {
            // Durum dosyası kaybolmuş olabilir; yeniden yaz.
            try? JSONFile.write(
                InstanceState(pid: pid, startedAt: Date(), claudeVersion: ClaudeApp.version(appPath: appPath)),
                to: paths.stateFile(name)
            )
            return StartResult(
                instance: instance,
                pid: pid,
                alreadyRunning: true,
                seed: nil,
                warning: nil
            )
        }

        if launcher.isProfileLocked(profileDir: profileDir) {
            // Kilit, çökmüş bir instance'dan kalmış olabilir: kilidi tutan pid
            // artık yaşamıyorsa kilit bayattır, temizlenip devam edilir.
            let holder = launcher.lockHolderPid(profileDir: profileDir)
            if let holder, ProcessSignal.isAlive(holder) {
                throw ClaudeCtlError.runtime(
                    "profil kilitli: \(profileDir.path) (SingletonLock) — pid \(holder) bu profili kullanıyor"
                )
            }
            try? FileManager.default.removeItem(at: profileDir.appendingPathComponent("SingletonLock"))
        }

        var warning: String?
        var seed: SeedResult?
        if let workdir = instance.workdir {
            if FileManager.default.fileExists(atPath: workdir) {
                do {
                    seed = try seeder.seed(profileDir: profileDir, workdir: workdir)
                } catch {
                    // Tohumlama başarısız olsa da instance açılmalı.
                    warning = "tohumlama başarısız: \(error.localizedDescription)"
                }
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
        try NameValidator.validate(name)
        let stateFile = paths.stateFile(name)

        // Yalnızca profil işaretiyle doğrulanmış süreç sonlandırılır.
        // state.json'daki pid PID yeniden kullanımı nedeniyle başka bir sürece
        // ait olabilir; bu yüzden tek başına güvenilir bir kaynak değildir.
        guard let pid = launcher.runningPid(profileDir: paths.profileDir(name)) else {
            try? FileManager.default.removeItem(at: stateFile)
            return StopResult(wasRunning: false, forced: false)
        }

        ProcessSignal.terminate(pid)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !ProcessSignal.isAlive(pid) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }

        var forced = false
        if ProcessSignal.isAlive(pid) {
            ProcessSignal.forceKill(pid)
            forced = true
        }

        try? FileManager.default.removeItem(at: stateFile)
        return StopResult(wasRunning: true, forced: forced)
    }

    // MARK: - remove

    /// Instance'ı siler.
    ///
    /// - Parameter purge: `true` ise profil klasörü de diskinten silinir.
    ///   `false` ise veriler korunur (instance yeniden oluşturulduğunda geri gelir).
    public func remove(name: String, purge: Bool, force: Bool = false) throws {
        _ = try store.instance(named: name)

        if !force, launcher.runningPid(profileDir: paths.profileDir(name)) != nil {
            throw ClaudeCtlError.runtime(
                "instance çalışıyor: \(name) — önce 'claude-ctl stop \(name)' çalıştır (zorlamak için: --force)"
            )
        }

        if purge {
            let instanceDir = paths.instanceDir(name)
            if FileManager.default.fileExists(atPath: instanceDir.path) {
                try FileManager.default.removeItem(at: instanceDir)
            }
        }

        try store.remove(named: name)
        try? FileManager.default.removeItem(at: paths.stateFile(name))
    }

    // MARK: - list / status

    /// Tüm instance'ların durumu (ada göre sıralı).
    public func list(includeSizes: Bool = true) throws -> [InstanceStatus] {
        let config = try store.load()
        return config.instances.values
            .sorted { $0.name < $1.name }
            .map { status(for: $0, includeSize: includeSizes) }
    }

    /// Tek instance'ın durumu.
    public func status(name: String) throws -> InstanceStatus {
        let instance = try store.instance(named: name)
        return status(for: instance)
    }

    private func status(for instance: Instance, includeSize: Bool = true) -> InstanceStatus {
        let profile = paths.profileDir(instance.name)
        let pid = launcher.runningPid(profileDir: profile)
        let stateFile = paths.stateFile(instance.name)
        let state = try? JSONFile.read(InstanceState.self, from: stateFile)

        // Ölü instance'ın bayat durum dosyasını temizle.
        if state != nil && pid == nil {
            try? FileManager.default.removeItem(at: stateFile)
        }

        let cookies = profile.appendingPathComponent("Cookies")
        return InstanceStatus(
            name: instance.name,
            workdir: instance.workdir,
            isRunning: pid != nil,
            pid: pid,
            startedAt: pid == nil ? nil : state?.startedAt,
            profileSizeBytes: includeSize ? Doctor(paths: paths, appPath: appPath).directorySize(profile) : 0,
            accountSignedIn: FileManager.default.fileExists(atPath: cookies.path)
        )
    }

    // MARK: - logs

    /// Instance'ın log satırları (paylaşılan log dosyasından filtrelenir).
    ///
    /// Log dosyası tüm instance'lar arasında paylaşıldığı için ayrım yalnızca
    /// instance'ın başlangıç zamanıyla yapılabilir (kesin ayrım mümkün değil).
    public func logs(name: String, lines: Int) throws -> [String] {
        _ = try store.instance(named: name)
        let state = try JSONFile.read(InstanceState.self, from: paths.stateFile(name))
        let since = state?.startedAt ?? Date.distantPast
        return logReader.lines(since: since, pid: nil, limit: lines)
    }

    // MARK: - open

    /// Instance'ın workdir'ini veya profil klasörünü Finder'da açar.
    public func open(name: String, target: OpenTarget) throws {
        let instance = try store.instance(named: name)
        let path: URL
        switch target {
        case .workdir:
            path = URL(fileURLWithPath: instance.workdir ?? paths.instanceDir(name).path)
        case .profile:
            path = paths.profileDir(name)
        }
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ClaudeCtlError.runtime("klasör bulunamadı: \(path.path)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [path.path]
        do {
            try process.run()
        } catch {
            throw ClaudeCtlError.runtime("açılamadı: \(path.path) — \(error.localizedDescription)")
        }
    }

    // MARK: - signin

    /// Giriş rehberi: `claude://` handler çakışması riskini raporlar.
    ///
    /// `restart` verilirse hedef instance yeniden başlatılır; böylece `claude://`
    /// handler en son kaydeden instance olur.
    public func signin(name: String, restart: Bool = false) throws -> SigninPlan {
        let instance = try store.instance(named: name)
        let others = try list()
            .filter { $0.name != name && $0.isRunning }
            .map(\.name)

        if restart {
            _ = try stop(name: name)
            _ = try start(name: name, folder: nil)
        }

        var instructions = [
            "1) Hedef instance: \(name)",
            "2) 'claude://' derin bağlantısı yalnızca tek instance'a gider; diğer instance'ları kapat.",
            "3) Bu instance'ta 'Sign in' akışını başlat; tarayıcıdan dönüş bu instance'a düşmelidir."
        ]
        if !others.isEmpty {
            instructions.insert(
                "0) Uyarı: şu instance'lar çalışıyor ve handler'a müdahale edebilir: \(others.joined(separator: ", "))",
                at: 0
            )
        }
        if restart {
            instructions.insert("0) Instance yeniden başlatıldı (handler artık bu instance).", at: 0)
        }

        return SigninPlan(
            instance: instance.name,
            handlerInstance: nil,
            otherInstancesRunning: others,
            instructions: instructions
        )
    }

    // MARK: - doctor

    /// Sağlık kontrolleri (tüm instance'lar veya tek instance).
    public func doctor(name: String?) throws -> [DoctorCheck] {
        let doctor = Doctor(paths: paths, appPath: appPath)
        var checks = doctor.appChecks()

        let config = try store.load()
        let instances: [Instance]
        if let name {
            guard let instance = config.instances[name] else {
                throw ClaudeCtlError.notFound("instance '\(name)' bulunamadı")
            }
            instances = [instance]
        } else {
            instances = config.instances.values.sorted { $0.name < $1.name }
        }

        for instance in instances {
            let state = try? JSONFile.read(InstanceState.self, from: paths.stateFile(instance.name))
            checks.append(contentsOf: doctor.checks(for: instance, state: state))
        }
        return checks
    }
}
