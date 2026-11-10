import Foundation

/// Result of a health check.
public enum CheckStatus: String, Equatable {
    case ok
    case warn
    case fail
}

/// A single health check.
public struct DoctorCheck: Equatable {
    public var name: String
    public var status: CheckStatus
    public var detail: String

    public init(name: String, status: CheckStatus, detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
    }
}

/// Instance- and app-level health checks.
public struct Doctor {
    public static let defaultDiskWarningBytes: Int64 = 5 * 1024 * 1024 * 1024

    public let paths: Paths
    public let appPath: String
    public let diskWarningBytes: Int64
    public let fileManager: FileManager
    /// Returns the installed Claude version (can be injected in tests).
    public let versionProvider: () -> String?

    public init(
        paths: Paths,
        appPath: String = ClaudeApp.defaultPath,
        diskWarningBytes: Int64 = Doctor.defaultDiskWarningBytes,
        fileManager: FileManager = .default,
        versionProvider: (() -> String?)? = nil
    ) {
        self.paths = paths
        self.appPath = appPath
        self.diskWarningBytes = diskWarningBytes
        self.fileManager = fileManager
        self.versionProvider = versionProvider ?? { ClaudeApp.version(appPath: appPath) }
    }

    /// App-level checks (is Claude installed?).
    public func appChecks(appPath: String? = nil) -> [DoctorCheck] {
        let path = appPath ?? self.appPath
        guard ClaudeApp.isInstalled(appPath: path) else {
            return [DoctorCheck(name: "claude-app", status: .fail, detail: "Claude.app not found: \(path)")]
        }
        let version = ClaudeApp.version(appPath: path) ?? "unknown version"
        return [DoctorCheck(name: "claude-app", status: .ok, detail: "\(path) (\(version))")]
    }

    /// Checks for a single instance.
    public func checks(for instance: Instance, state: InstanceState?) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []

        // Version change: the instance may have been started with an older version.
        if let recorded = state?.claudeVersion {
            if let current = versionProvider(), current != recorded {
                checks.append(DoctorCheck(
                    name: "claude-version",
                    status: .warn,
                    detail: "version changed: \(recorded) → \(current) (restart the instance)"
                ))
            } else {
                checks.append(DoctorCheck(
                    name: "claude-version",
                    status: .ok,
                    detail: "version: \(recorded)"
                ))
            }
        } else {
            checks.append(DoctorCheck(
                name: "claude-version",
                status: .ok,
                detail: "instance hasn't been started yet"
            ))
        }

        let profile = paths.profileDir(instance.name)

        if fileManager.fileExists(atPath: profile.path) {
            checks.append(DoctorCheck(name: "profile-dir", status: .ok, detail: profile.path))
        } else {
            checks.append(DoctorCheck(
                name: "profile-dir",
                status: .fail,
                detail: "profile directory missing: \(profile.path)"
            ))
        }

        // SingletonLock is normal for a running instance; only warn when the
        // lock exists while the instance is stopped.
        let lock = profile.appendingPathComponent("SingletonLock")
        let isRunning = state?.pid != nil && ProcessSignal.isAlive(state!.pid)
        if fileManager.fileExists(atPath: lock.path) {
            if isRunning {
                checks.append(DoctorCheck(
                    name: "profile-lock",
                    status: .ok,
                    detail: "locked (instance is running — normal)"
                ))
            } else {
                checks.append(DoctorCheck(
                    name: "profile-lock",
                    status: .warn,
                    detail: "stale lock — instance is stopped but the profile is locked"
                ))
            }
        } else {
            checks.append(DoctorCheck(name: "profile-lock", status: .ok, detail: "not locked"))
        }

        let size = directorySize(profile)
        checks.append(DoctorCheck(
            name: "disk",
            status: size > diskWarningBytes ? .warn : .ok,
            detail: "\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
        ))

        if let workdir = instance.workdir {
            let exists = fileManager.fileExists(atPath: workdir)
            checks.append(DoctorCheck(
                name: "workdir",
                status: exists ? .ok : .warn,
                detail: exists ? workdir : "workdir not found: \(workdir)"
            ))
        } else {
            checks.append(DoctorCheck(name: "workdir", status: .ok, detail: "not set"))
        }

        let cookies = profile.appendingPathComponent("Cookies")
        let signedIn = fileManager.fileExists(atPath: cookies.path)
        checks.append(DoctorCheck(
            name: "signin",
            status: signedIn ? .ok : .warn,
            detail: signedIn ? "signed-in profile found" : "may not be signed in"
        ))

        return checks
    }

    /// Total size of the directory (sum of logical file sizes).
    public func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}
