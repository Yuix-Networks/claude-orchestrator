import Foundation

/// `claude-ctl` dosya sistemi düzeni.
///
/// Tüm yollar tek bir kökten (`root`) türetilir; testler geçici bir kök verir,
/// üretimde kök `~/Library/Application Support/claude-ctl` olur.
public struct Paths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Üretim kökü: `~/Library/Application Support/claude-ctl`.
    public static var `default`: Paths {
        Paths(root: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/claude-ctl"))
    }

    /// Instance tanımlarının tutulduğu `config.json`.
    public var configFile: URL { root.appendingPathComponent("config.json") }

    /// Instance dizinlerinin kökü.
    public var instancesRoot: URL { root.appendingPathComponent("instances") }

    /// Agent singleton pid dosyasının tutulduğu dizin.
    public var stateDirectory: URL { root.appendingPathComponent("state") }

    public func instanceDir(_ name: String) -> URL {
        instancesRoot.appendingPathComponent(name)
    }

    /// Electron profili (`--user-data-dir`).
    public func profileDir(_ name: String) -> URL {
        instanceDir(name).appendingPathComponent("profile")
    }

    /// Claude Code yapılandırma dizini (`CLAUDE_CONFIG_DIR`).
    public func codeDir(_ name: String) -> URL {
        instanceDir(name).appendingPathComponent("claude-code")
    }

    /// Çalışma durumu (pid, başlangıç zamanı, sürüm).
    public func stateFile(_ name: String) -> URL {
        instanceDir(name).appendingPathComponent("state.json")
    }
}
