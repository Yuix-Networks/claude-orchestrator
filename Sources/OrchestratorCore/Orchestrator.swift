import Foundation

/// Result of the `start` command.
public struct StartResult: Equatable {
    public var instance: Instance
    /// pid of the main Claude process.
    public var pid: Int32
    /// `true` if the instance was already running (it was not restarted).
    public var alreadyRunning: Bool
    /// Profile seeding that was done (`nil` when there is no workdir).
    public var seed: SeedResult?
    /// Warning to show the user (e.g. workdir not found).
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

/// Result of the `stop` command.
public struct StopResult: Equatable {
    /// Was there a running process to shut down?
    public var wasRunning: Bool
    /// Was SIGKILL needed because SIGTERM was not enough?
    public var forced: Bool

    public init(wasRunning: Bool, forced: Bool) {
        self.wasRunning = wasRunning
        self.forced = forced
    }
}

/// Current status of an instance.
public struct InstanceStatus: Equatable {
    public var name: String
    public var workdir: String?
    public var isRunning: Bool
    public var pid: Int32?
    public var startedAt: Date?
    public var profileSizeBytes: Int64
    /// Does the profile have a sign-in (cookie) file?
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

/// Folder targeted by the `open` command.
public enum OpenTarget: String, Equatable {
    case workdir
    case profile
}

/// Guide for the `signin` command.
public struct SigninPlan: Equatable {
    public var instance: String
    /// Which instance the `claude://` handler goes to (`nil` if it cannot be determined).
    public var handlerInstance: String?
    /// Other running instances (risk of a handler conflict).
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

/// Entry point for the `claude-orchestrator` logic.
public final class Orchestrator {
    public let paths: Paths
    public let store: InstanceStore
    public let launcher: Launching
    public let seeder: ProfileSeeder
    public let logReader: LogReader
    public let appPath: String
    /// Config directory of the default (non-instance) Claude install (`~/.claude`).
    public let defaultCodeDir: URL
    /// Electron profile of the default Claude install.
    public let defaultProfileDir: URL

    public init(
        paths: Paths = .default,
        appPath: String = ClaudeApp.defaultPath,
        processListing: ProcessListing = PsProcessListing(),
        launcher: Launching? = nil,
        logReader: LogReader = LogReader(),
        defaultCodeDir: URL = Orchestrator.defaultCodeDir,
        defaultProfileDir: URL = Orchestrator.defaultProfileDir
    ) {
        self.defaultCodeDir = defaultCodeDir
        self.defaultProfileDir = defaultProfileDir
        self.paths = paths
        self.store = InstanceStore(paths: paths)
        self.launcher = launcher ?? Launcher(appPath: appPath, processListing: processListing)
        self.seeder = ProfileSeeder(paths: paths)
        self.logReader = logReader
        self.appPath = appPath
    }

    // MARK: - new

    /// Creates a new instance (config + profile directories).
    public func new(name: String, workdir: String?) throws -> Instance {
        try validateNewName(name)

        let config = try store.load()
        guard config.instances[name] == nil else {
            throw OrchestratorError.runtime("instance '\(name)' already exists")
        }

        let instance = Instance(name: name, workdir: workdir)
        try store.upsert(instance)

        try FileManager.default.createDirectory(at: paths.profileDir(name), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.codeDir(name), withIntermediateDirectories: true)

        // Seed the profile (trusted folders). The session preset can't be written
        // until the account is known; `start` tries again then.
        if let workdir, FileManager.default.fileExists(atPath: workdir) {
            _ = try? seeder.seed(profileDir: paths.profileDir(name), workdir: workdir)
        }
        // Registered projects: trusted folders now, environments after the first sign-in.
        _ = try? syncProjects(instance: name)
        ensureSharedMemory(name)

        return instance
    }

    // MARK: - start

    /// Starts the instance.
    public func start(name: String, folder: String?) throws -> StartResult {
        let instance = try store.instance(named: name)
        let profileDir = paths.profileDir(name)
        let codeDir = paths.codeDir(name)

        if let pid = launcher.runningPid(profileDir: profileDir) {
            // The state file may be gone; write it again.
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
            // The lock may be left over from a crashed instance: if the pid holding
            // it is no longer alive, the lock is stale, so remove it and carry on.
            let holder = launcher.lockHolderPid(profileDir: profileDir)
            if let holder, ProcessSignal.isAlive(holder) {
                throw OrchestratorError.runtime(
                    "profile is locked: \(profileDir.path) (SingletonLock) — pid \(holder) is using it"
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
                    // The instance should open even if seeding fails.
                    warning = "seeding failed: \(error.localizedDescription)"
                }
            } else {
                warning = "workdir not found: \(workdir) — skipped seeding"
            }
        }

        // Registered projects are applied on every start: once the account is known
        // after sign-in, environments get written, and changes Claude overwrote come back.
        if let failure = (try? syncProjects(instance: name))?.first?.error {
            warning = [warning, "project sync failed: \(failure)"].compactMap { $0 }.joined(separator: "; ")
        }

        ensureSharedMemory(name)

        let request = LaunchRequest(
            appPath: appPath,
            profileDir: profileDir.path,
            codeDir: codeDir.path,
            extraArgs: folder.map { [$0] } ?? []
        )
        try launcher.launch(request)

        guard let pid = waitForPid(profileDir: profileDir, timeout: 10) else {
            throw OrchestratorError.runtime(
                "couldn't start instance: process not found (\(profileDir.path))"
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

    /// Stops the instance.
    public func stop(name: String) throws -> StopResult {
        try NameValidator.validate(name)
        let stateFile = paths.stateFile(name)

        // Only a process verified by its profile flag is terminated.
        // The pid in state.json may belong to another process because of pid
        // reuse, so it isn't a reliable source on its own.
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

    /// Removes the instance.
    ///
    /// - Parameters:
    ///   - purge: If `true`, the instance directory (profile + Claude Code config +
    ///     sessions) is removed too. If `false`, the data is kept (it comes back
    ///     when the instance is created again).
    ///   - force: If the instance is running, stop it first (it isn't removed if it won't stop).
    ///   - permanent: With `purge`, `true` deletes the data permanently;
    ///     `false` (the default) moves it to the Trash so it can be restored.
    /// - Returns: The new location of the data if it was moved to the Trash.
    @discardableResult
    public func remove(name: String, purge: Bool, force: Bool = false, permanent: Bool = false) throws -> URL? {
        _ = try store.instance(named: name)

        if launcher.runningPid(profileDir: paths.profileDir(name)) != nil {
            guard force else {
                throw OrchestratorError.runtime(
                    "instance is running: \(name) — run 'claude-orchestrator stop \(name)' first (or use --force to stop and remove it)"
                )
            }
            // Stop it first so the data isn't pulled out from under a running Claude.
            _ = try stop(name: name)
            if launcher.runningPid(profileDir: paths.profileDir(name)) != nil {
                throw OrchestratorError.runtime("couldn't stop instance: \(name) — not removed")
            }
        }

        var trashedTo: URL?
        if purge {
            let instanceDir = paths.instanceDir(name)
            if FileManager.default.fileExists(atPath: instanceDir.path) {
                if permanent {
                    try FileManager.default.removeItem(at: instanceDir)
                } else {
                    var resulting: NSURL?
                    do {
                        try FileManager.default.trashItem(at: instanceDir, resultingItemURL: &resulting)
                    } catch {
                        throw OrchestratorError.runtime(
                            "couldn't move to Trash: \(instanceDir.path) — \(error.localizedDescription) (use --permanent to delete it permanently)"
                        )
                    }
                    trashedTo = resulting as URL?
                }
            }
        }

        try store.remove(named: name)
        try? FileManager.default.removeItem(at: paths.stateFile(name))
        return trashedTo
    }

    // MARK: - list / status

    /// Status of every instance (sorted by name).
    public func list(includeSizes: Bool = true) throws -> [InstanceStatus] {
        let config = try store.load()
        return config.instances.values
            .sorted { $0.name < $1.name }
            .map { status(for: $0, includeSize: includeSizes) }
    }

    /// Status of a single instance.
    public func status(name: String) throws -> InstanceStatus {
        let instance = try store.instance(named: name)
        return status(for: instance)
    }

    private func status(for instance: Instance, includeSize: Bool = true) -> InstanceStatus {
        let profile = paths.profileDir(instance.name)
        let pid = launcher.runningPid(profileDir: profile)
        let stateFile = paths.stateFile(instance.name)
        let state = try? JSONFile.read(InstanceState.self, from: stateFile)

        // Clean up the stale state file of a dead instance.
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

    /// Log lines for the instance (filtered from the shared log file).
    ///
    /// The log file is shared by all instances, so lines can only be told apart
    /// by the instance's start time (an exact split isn't possible).
    public func logs(name: String, lines: Int) throws -> [String] {
        _ = try store.instance(named: name)
        let state = try JSONFile.read(InstanceState.self, from: paths.stateFile(name))
        let since = state?.startedAt ?? Date.distantPast
        return logReader.lines(since: since, pid: nil, limit: lines)
    }

    // MARK: - open

    /// Opens the instance's workdir or profile folder in Finder.
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
            throw OrchestratorError.runtime("folder not found: \(path.path)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [path.path]
        do {
            try process.run()
        } catch {
            throw OrchestratorError.runtime("couldn't open: \(path.path) — \(error.localizedDescription)")
        }
    }

    // MARK: - signin

    /// Sign-in guide: reports the risk of a `claude://` handler conflict.
    ///
    /// With `restart`, the target instance is restarted so it becomes the last
    /// one to register the `claude://` handler.
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
            "1) Target instance: \(name)",
            "2) A 'claude://' link only reaches one instance, so quit the other instances.",
            "3) Start 'Sign in' in this instance; the browser should hand you back to this instance."
        ]
        if !others.isEmpty {
            instructions.insert(
                "0) Warning: these instances are running and may take over the handler: \(others.joined(separator: ", "))",
                at: 0
            )
        }
        if restart {
            instructions.insert("0) Instance restarted (it now owns the handler).", at: 0)
        }

        return SigninPlan(
            instance: instance.name,
            handlerInstance: nil,
            otherInstancesRunning: others,
            instructions: instructions
        )
    }

    // MARK: - doctor

    /// Health checks (all instances or a single one).
    public func doctor(name: String?) throws -> [DoctorCheck] {
        let doctor = Doctor(paths: paths, appPath: appPath)
        var checks = doctor.appChecks()

        let config = try store.load()
        let instances: [Instance]
        if let name {
            guard let instance = config.instances[name] else {
                throw OrchestratorError.notFound("instance '\(name)' not found")
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
