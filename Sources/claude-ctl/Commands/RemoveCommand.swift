import ClaudeCtlCore
import Foundation

/// `claude-ctl remove <ad> [--purge [--permanent]] [--force] [--yes]`
enum RemoveCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["purge", "force", "permanent", "yes"])
        let name = try parsed.requirePositional(0, name: "instance adı", command: "remove")
        let purge = parsed.has("purge")
        let force = parsed.has("force")
        let permanent = parsed.has("permanent")

        if permanent && !purge {
            throw ClaudeCtlError.usage("remove: --permanent yalnızca --purge ile kullanılabilir")
        }

        let ctl = ClaudeCtl()
        if purge && !parsed.has("yes") {
            _ = try ctl.store.instance(named: name)
            let what = permanent ? "KALICI olarak silinecek (geri alınamaz)" : "Çöp Kutusu'na taşınacak"
            let prompt = "'\(name)' instance'ının profili, girişi ve tüm oturumları \(what)."
            guard Confirm.ask(prompt) else {
                throw ClaudeCtlError.runtime("iptal edildi")
            }
        }

        let trashed = try ctl.remove(name: name, purge: purge, force: force, permanent: permanent)
        if !purge {
            Output.line("instance silindi (veriler korundu): \(name)")
        } else if let trashed {
            Output.line("instance silindi; veriler Çöp Kutusu'nda: \(trashed.path)")
        } else {
            Output.line("instance silindi (veriler dahil): \(name)")
        }
    }
}
