import OrchestratorCore
import Foundation

/// An action in the menu bar icon's menu.
public enum AgentAction: Equatable {
    /// Start a stopped instance.
    case start
    /// Bring the instance to the front.
    case activate
    /// Stop the instance.
    case stop
    /// Open the workdir in Finder.
    case openWorkdir
    /// Open the profile folder in Finder.
    case openProfile
    /// Show the logs.
    case showLogs
    /// Show the sign-in guide.
    case signinHelp
}

/// An item shown in the menu bar menu.
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

/// UI-independent logic of the menu bar agent.
public final class AgentModel {
    private let ctl: Orchestrator

    public init(ctl: Orchestrator) {
        self.ctl = ctl
    }

    /// Current status of the instances.
    /// Lightweight refresh: only checks pid liveness. Profile sizes are not
    /// computed, since the agent refreshes every 5 seconds and that is expensive.
    public func refresh() -> [InstanceStatus] {
        (try? ctl.list(includeSizes: false)) ?? []
    }

    /// Menu items for an instance.
    public func menuItems(for status: InstanceStatus) -> [AgentMenuItem] {
        [
            AgentMenuItem(title: "Start", action: .start, isEnabled: !status.isRunning),
            AgentMenuItem(title: "Bring to Front", action: .activate, isEnabled: status.isRunning),
            AgentMenuItem(title: "Stop", action: .stop, isEnabled: status.isRunning),
            AgentMenuItem(title: "Open Workdir", action: .openWorkdir, isEnabled: status.workdir != nil),
            AgentMenuItem(title: "Open Profile Folder", action: .openProfile, isEnabled: true),
            AgentMenuItem(title: "Logs", action: .showLogs, isEnabled: true),
            AgentMenuItem(title: "Sign-in Help", action: .signinHelp, isEnabled: true)
        ]
    }

    /// Performs the action.
    public func perform(_ action: AgentAction, for status: InstanceStatus) {
        switch action {
        case .start:
            do {
                _ = try ctl.start(name: status.name, folder: nil)
            } catch {
                AppKitSupport.presentMessage(title: "Couldn't start \(status.name)", message: "\(error)")
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
