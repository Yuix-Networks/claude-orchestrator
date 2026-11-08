import OrchestratorCore
import Foundation

/// `claude-orchestrator new <ad> [--workdir <yol>] [--sessions-from <instance>]`
enum NewCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["workdir", "sessions-from"])
        let name = try parsed.requirePositional(0, name: "instance adı", command: "new")
        let workdir = parsed.optionalFlag("workdir")
        if parsed.has("workdir"), workdir == nil {
            throw OrchestratorError.usage("new: --workdir bir yol gerektirir")
        }
        let sessionsFrom = parsed.optionalFlag("sessions-from")

        let ctl = Orchestrator()
        if let sessionsFrom {
            // Kaynak, instance oluşturulmadan önce doğrulanır (yarım kurulum kalmasın).
            _ = try ctl.endpoint(sessionsFrom)
        }
        let instance = try ctl.new(name: name, workdir: workdir)

        if let workdir, !FileManager.default.fileExists(atPath: workdir) {
            Output.line("uyarı: workdir bulunamadı: \(workdir)")
        }
        Output.line("instance oluşturuldu: \(instance.name)")
        Output.line("  workdir: \(instance.workdir ?? "-")")
        Output.line("  profil:  \(ctl.paths.profileDir(instance.name).path)")

        if let sessionsFrom {
            let (copied, skipped) = try ctl.copyAllSessions(from: sessionsFrom, to: instance.name)
            Output.line("  oturum:  \(copied.count) oturum '\(sessionsFrom)' kaynağından kopyalandı")
            for (id, reason) in skipped {
                Output.line("  uyarı:   atlandı \(id): \(reason)")
            }
        }
        Output.line("  başlat:  claude-orchestrator start \(instance.name)")
    }
}
