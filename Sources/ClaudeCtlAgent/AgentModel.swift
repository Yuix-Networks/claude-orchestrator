import ClaudeCtlCore
import Foundation

/// Menü çubuğu ikonundaki bir eylem.
public enum AgentAction: Equatable {
    /// Durmuş instance'ı başlat.
    case start
    /// Instance'ı öne getir.
    case activate
    /// Instance'ı durdur.
    case stop
    /// Workdir'yi Finder'da aç.
    case openWorkdir
    /// Profil klasörünü Finder'da aç.
    case openProfile
    /// Logları göster.
    case showLogs
    /// Giriş rehberini göster.
    case signinHelp
}

/// Menü çubuğunda görünen bir madde.
public struct AgentMenuItem: Equatable {
    public var title: String
    public var action: AgentAction
    public var isEnabled: Bool

    public init(title: String, action: AgentAction, isEnabled: Bool) {
        self.title = title
        self.action = action
        self.isEnabled = isEnabled
    }
}

/// Menü çubuğu agent'ının UI'dan bağımsız mantığı.
public final class AgentModel {
    private let ctl: ClaudeCtl

    public init(ctl: ClaudeCtl) {
        self.ctl = ctl
    }

    /// Instance'ların güncel durumu.
    /// Hafif yenileme: yalnızca pid canlılığı (profil boyutu hesaplanmaz —
    /// agent 5 saniyede bir çalıştığı için pahalı bir işlemdir).
    public func refresh() -> [InstanceStatus] {
        (try? ctl.list(includeSizes: false)) ?? []
    }

    /// Bir instance için menü maddeleri.
    public func menuItems(for status: InstanceStatus) -> [AgentMenuItem] {
        [
            AgentMenuItem(title: "Başlat", action: .start, isEnabled: !status.isRunning),
            AgentMenuItem(title: "Öne Getir", action: .activate, isEnabled: status.isRunning),
            AgentMenuItem(title: "Durdur", action: .stop, isEnabled: status.isRunning),
            AgentMenuItem(title: "Workdir'yi Aç", action: .openWorkdir, isEnabled: status.workdir != nil),
            AgentMenuItem(title: "Profil Klasörünü Aç", action: .openProfile, isEnabled: true),
            AgentMenuItem(title: "Loglar", action: .showLogs, isEnabled: true),
            AgentMenuItem(title: "Sign-in Yardımı", action: .signinHelp, isEnabled: true)
        ]
    }

    /// Eylemi gerçekleştirir.
    public func perform(_ action: AgentAction, for status: InstanceStatus) {
        switch action {
        case .start:
            do {
                _ = try ctl.start(name: status.name, folder: nil)
            } catch {
                AppKitSupport.presentMessage(title: "Başlatılamadı — \(status.name)", message: "\(error)")
            }
        case .activate:
            guard let pid = status.pid else { return }
            AppKitSupport.activateProcess(pid: pid)
        case .stop:
            _ = try? ctl.stop(name: status.name)
        case .openWorkdir:
            _ = try? ctl.open(name: status.name, target: .workdir)
        case .openProfile:
            _ = try? ctl.open(name: status.name, target: .profile)
        case .showLogs:
            showLogs(for: status)
        case .signinHelp:
            showSigninHelp(for: status)
        }
    }

    private func showLogs(for status: InstanceStatus) {
        let logFile = LogReader.defaultLogDirectory.appendingPathComponent("main.log")
        guard FileManager.default.fileExists(atPath: logFile.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", logFile.path]
        try? process.run()
    }

    private func showSigninHelp(for status: InstanceStatus) {
        guard let plan = try? ctl.signin(name: status.name) else { return }
        let message = plan.instructions.joined(separator: "\n")
        AppKitSupport.presentMessage(title: "Sign-in — \(plan.instance)", message: message)
    }
}
