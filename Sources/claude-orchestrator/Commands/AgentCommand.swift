import AppKit
import OrchestratorAgent
import OrchestratorCore
import Foundation

/// `claude-orchestrator agent [--install|--uninstall]`
enum AgentCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["install", "uninstall"])

        if parsed.has("uninstall") {
            try LaunchAgentInstaller().uninstall()
            Output.line("menu bar icon removed")
            return
        }

        if parsed.has("install") {
            let executablePath = URL(fileURLWithPath: CommandLine.arguments.first ?? "/usr/local/bin/claude-orchestrator")
                .standardizedFileURL.path
            let url = try LaunchAgentInstaller().install(executablePath: executablePath)
            Output.line("menu bar icon installed: \(url.path)")
            Output.line("  it starts automatically at login; to start it now: claude-orchestrator agent")
            return
        }

        // Agent mode: menu bar icons.
        let controller = StatusItemController(model: AgentModel(ctl: Orchestrator()))
        NSApplication.shared.setActivationPolicy(.accessory)
        guard controller.start() else {
            // Exit with 0 so that launchd (`KeepAlive.SuccessfulExit = false`)
            // does not keep relaunching the second copy.
            FileHandle.standardError.write(Data("agent is already running\n".utf8))
            exit(ExitCode.success)
        }
        NSApplication.shared.run()
    }
}
