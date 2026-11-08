import Foundation

/// Bir sağlık kontrolünün sonucu.
public enum CheckStatus: String, Equatable {
    case ok
    case warn
    case fail
}

/// Tek bir sağlık kontrolü.
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

/// Instance ve uygulama düzeyinde sağlık kontrolleri.
public struct Doctor {
    public static let defaultDiskWarningBytes: Int64 = 5 * 1024 * 1024 * 1024

    public let paths: Paths
    public let appPath: String
    public let diskWarningBytes: Int64
    public let fileManager: FileManager

    public init(
        paths: Paths,
        appPath: String = ClaudeApp.defaultPath,
        diskWarningBytes: Int64 = Doctor.defaultDiskWarningBytes,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.appPath = appPath
        self.diskWarningBytes = diskWarningBytes
        self.fileManager = fileManager
    }

    /// Uygulama düzeyi kontroller (Claude kurulu mu?).
    public func appChecks(appPath: String? = nil) -> [DoctorCheck] {
        let path = appPath ?? self.appPath
        guard ClaudeApp.isInstalled(appPath: path) else {
            return [DoctorCheck(name: "claude-app", status: .fail, detail: "Claude.app bulunamadı: \(path)")]
        }
        let version = ClaudeApp.version(appPath: path) ?? "sürüm bilinmiyor"
        return [DoctorCheck(name: "claude-app", status: .ok, detail: "\(path) (\(version))")]
    }

    /// Tek bir instance'ın kontrolleri.
    public func checks(for instance: Instance, state: InstanceState?) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []

        // Sürüm değişikliği: instance eski sürümle başlatılmış olabilir.
        if let recorded = state?.claudeVersion {
            if let current = ClaudeApp.version(appPath: appPath), current != recorded {
                checks.append(DoctorCheck(
                    name: "claude-version",
                    status: .warn,
                    detail: "sürüm değişti: \(recorded) → \(current) (instance'ı yeniden başlat)"
                ))
            } else {
                checks.append(DoctorCheck(
                    name: "claude-version",
                    status: .ok,
                    detail: "sürüm: \(recorded)"
                ))
            }
        } else {
            checks.append(DoctorCheck(
                name: "claude-version",
                status: .ok,
                detail: "instance henüz başlatılmamış"
            ))
        }

        let profile = paths.profileDir(instance.name)

        if fileManager.fileExists(atPath: profile.path) {
            checks.append(DoctorCheck(name: "profile-dir", status: .ok, detail: profile.path))
        } else {
            checks.append(DoctorCheck(
                name: "profile-dir",
                status: .fail,
                detail: "profil dizini yok: \(profile.path)"
            ))
        }

        let lock = profile.appendingPathComponent("SingletonLock")
        if fileManager.fileExists(atPath: lock.path) {
            checks.append(DoctorCheck(
                name: "profile-lock",
                status: .warn,
                detail: "profil kilitli — başka bir instance kullanıyor olabilir"
            ))
        } else {
            checks.append(DoctorCheck(name: "profile-lock", status: .ok, detail: "kilit yok"))
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
                detail: exists ? workdir : "workdir bulunamadı: \(workdir)"
            ))
        } else {
            checks.append(DoctorCheck(name: "workdir", status: .ok, detail: "atanmadı"))
        }

        let cookies = profile.appendingPathComponent("Cookies")
        let signedIn = fileManager.fileExists(atPath: cookies.path)
        checks.append(DoctorCheck(
            name: "signin",
            status: signedIn ? .ok : .warn,
            detail: signedIn ? "oturum profili mevcut" : "giriş yapılmamış olabilir"
        ))

        return checks
    }

    /// Dizinin toplam boyutu (mantıksal dosya boyutları toplamı).
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
