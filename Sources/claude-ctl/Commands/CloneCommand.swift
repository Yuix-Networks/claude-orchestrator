import ClaudeCtlCore
import Foundation

/// `claude-ctl clone <kaynak> --as <yeni-ad> [--workdir <yol>]`
enum CloneCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["as", "workdir"])
        let source = try parsed.requirePositional(0, name: "kaynak instance", command: "clone")
        let name = try parsed.requireFlag("as", command: "clone")

        let result = try ClaudeCtl().clone(source, as: name, workdir: parsed.optionalFlag("workdir"))
        Output.line("instance klonlandı: \(source) → \(result.instance.name)")
        Output.line("  oturum:  \(result.sessionCount)")
        Output.line("  workdir: \(result.instance.workdir ?? "-")")
        Output.line("  not:     profil (giriş dahil) kopyalandı; farklı hesap için instance'ta çıkış yapıp yeniden gir")
        Output.line("  başlat:  claude-ctl start \(result.instance.name)")
    }
}
