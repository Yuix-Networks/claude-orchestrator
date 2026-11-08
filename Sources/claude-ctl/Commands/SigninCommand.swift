import ClaudeCtlCore
import Foundation

/// `claude-ctl signin <ad> [--restart] [--exclusive]`
enum SigninCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["restart", "exclusive"])
        let name = try parsed.requirePositional(0, name: "instance adı", command: "signin")
        let ctl = ClaudeCtl()

        guard parsed.has("exclusive") else {
            let plan = try ctl.signin(name: name, restart: parsed.has("restart"))
            for instruction in plan.instructions {
                Output.line(instruction)
            }
            return
        }

        // Özel mod: `claude://` dönüşü yanlış instance'a gitmesin diye diğer
        // instance'lar giriş süresince kapatılır, sonra yeniden açılır.
        guard isatty(STDIN_FILENO) != 0 else {
            throw ClaudeCtlError.usage("signin --exclusive etkileşimli terminal gerektirir")
        }
        _ = try ctl.store.instance(named: name)
        let others = try ctl.list(includeSizes: false).filter { $0.name != name && $0.isRunning }.map(\.name)
        for other in others {
            _ = try ctl.stop(name: other)
            Output.line("durduruldu (giriş süresince): \(other)")
        }
        // Yeniden başlatma, hedefi `claude://` için kayıtlı son örnek yapar.
        _ = try ctl.stop(name: name)
        _ = try ctl.start(name: name, folder: nil)
        Output.line("başlatıldı: \(name)")

        if ctl.launcher.runningDefaultPid() != nil {
            Output.line("uyarı: varsayılan Claude (instance dışı) açık — derin bağlantıyı o yakalayabilir; giriş sırasında kapatman önerilir")
        }
        Output.line("")
        Output.line("'\(name)' penceresinde giriş yap (tarayıcıdaki onaydan sonra uygulamaya dönülür).")
        FileHandle.standardError.write(Data("Giriş tamamlanınca Enter'a bas… ".utf8))
        _ = readLine()

        for other in others {
            do {
                _ = try ctl.start(name: other, folder: nil)
                Output.line("yeniden başlatıldı: \(other)")
            } catch {
                Output.line("uyarı: \(other) başlatılamadı: \(error)")
            }
        }
        let signedIn = try ctl.status(name: name).accountSignedIn
        Output.line(signedIn ? "giriş algılandı: \(name)" : "uyarı: '\(name)' profilinde oturum çerezi bulunamadı")
    }
}
