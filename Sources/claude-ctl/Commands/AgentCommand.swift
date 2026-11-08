import AppKit
import ClaudeCtlAgent
import ClaudeCtlCore
import Foundation

/// `claude-ctl agent [--install|--uninstall]`
enum AgentCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["install", "uninstall"])

        if parsed.has("uninstall") {
            try LaunchAgentInstaller().uninstall()
            Output.line("menü çubuğu ikonu kaldırıldı")
            return
        }

        if parsed.has("install") {
            let executablePath = URL(fileURLWithPath: CommandLine.arguments.first ?? "/usr/local/bin/claude-ctl")
                .standardizedFileURL.path
            let url = try LaunchAgentInstaller().install(executablePath: executablePath)
            Output.line("menü çubuğu ikonu kuruldu: \(url.path)")
            Output.line("  oturum açılışında otomatik başlar; şimdi başlatmak için: claude-ctl agent")
            return
        }

        // Agent modu: menü çubuğu ikonları.
        let controller = StatusItemController(model: AgentModel(ctl: ClaudeCtl()))
        NSApplication.shared.setActivationPolicy(.accessory)
        guard controller.start() else {
            Output.error("agent zaten çalışıyor", code: ExitCode.runtime)
        }
        NSApplication.shared.run()
    }
}
