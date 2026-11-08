import OrchestratorCore
import Foundation

/// `claude-orchestrator remove|delete|rm <ad> [--purge [--permanent]] [--force] [--yes]`
enum RemoveCommand {
    static func run(_ args: [String], command: String = "remove") throws {
        let parsed = try Arguments(args, allowed: ["purge", "force", "permanent", "yes"])
        let name = try parsed.requirePositional(0, name: "instance adı", command: command)
        let purge = parsed.has("purge")
        var force = parsed.has("force")
        let permanent = parsed.has("permanent")

        if permanent && !purge {
            throw OrchestratorError.usage("\(command): --permanent yalnızca --purge ile kullanılabilir")
        }

        let ctl = Orchestrator()
        let status = try ctl.status(name: name)
        let assumeYes = parsed.has("yes")

        // Onay: veriler silinecekse ya da çalışan instance durdurulacaksa.
        if (purge || (status.isRunning && !force)) && !assumeYes {
            var lines: [String] = []
            if status.isRunning {
                lines.append("'\(name)' şu an çalışıyor; durdurulacak.")
            }
            if purge {
                let what = permanent ? "KALICI olarak silinecek (geri alınamaz)" : "Çöp Kutusu'na taşınacak"
                lines.append("'\(name)' profilinin girişi, ayarları ve tüm oturumları \(what).")
            } else {
                lines.append("Veriler korunacak (silmek için: --purge).")
            }
            guard Confirm.ask(lines.joined(separator: "\n")) else {
                throw OrchestratorError.runtime("iptal edildi")
            }
            force = force || status.isRunning
        } else if status.isRunning && assumeYes {
            force = true
        }

        let trashed = try ctl.remove(name: name, purge: purge, force: force, permanent: permanent)
        if status.isRunning { Output.line("durduruldu: \(name)") }
        if !purge {
            Output.line("profil silindi (veriler korundu, aynı adla 'new' geri getirir): \(name)")
        } else if let trashed {
            Output.line("profil silindi; veriler Çöp Kutusu'nda: \(trashed.path)")
        } else {
            Output.line("profil silindi (veriler dahil): \(name)")
        }
    }
}
