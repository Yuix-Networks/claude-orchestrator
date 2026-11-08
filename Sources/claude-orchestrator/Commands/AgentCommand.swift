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
            Output.line("menü çubuğu ikonu kaldırıldı")
            return
        }

        if parsed.has("install") {
            var executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "/usr/local/bin/claude-orchestrator")
                .standardizedFileURL
            // Eski adla (`claude-ctl` bağı) çağrıldıysa login item yeni ada bağlansın.
            let renamed = executable.deletingLastPathComponent().appendingPathComponent("claude-orchestrator")
            if executable.lastPathComponent == LegacyName.command,
               FileManager.default.isExecutableFile(atPath: renamed.path) {
                executable = renamed
            }
            let executablePath = executable.path
            let url = try LaunchAgentInstaller().install(executablePath: executablePath)
            Output.line("menü çubuğu ikonu kuruldu: \(url.path)")
            Output.line("  oturum açılışında otomatik başlar; şimdi başlatmak için: claude-orchestrator agent")
            return
        }

        // Agent modu: menü çubuğu ikonları.
        let controller = StatusItemController(model: AgentModel(ctl: Orchestrator()))
        NSApplication.shared.setActivationPolicy(.accessory)
        guard controller.start() else {
            // 0 ile çıkılır: launchd (`KeepAlive.SuccessfulExit = false`) ikinci
            // örneği yeniden başlatmaya çalışmasın.
            FileHandle.standardError.write(Data("agent zaten çalışıyor\n".utf8))
            exit(ExitCode.success)
        }
        NSApplication.shared.run()
    }
}
