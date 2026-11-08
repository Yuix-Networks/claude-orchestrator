import OrchestratorAgent
import OrchestratorCore
import Foundation

let rawArguments = Array(CommandLine.arguments.dropFirst())

let usage = """
claude-orchestrator — Claude Desktop instance'larını ve oturumlarını yönetir

KULLANIM
  claude-orchestrator <komut> [argümanlar]

KOMUTLAR
  version                        Sürümü yazdırır
  new <ad> [--workdir <yol>] [--sessions-from <instance>]
                                 Instance oluşturur (isteğe bağlı: workdir, oturumlar)
  start <ad> [--folder <yol>]     Instance'ı başlatır (ayrı profil + config)
  stop <ad>                      Instance'ı durdurur
  list [--json]                  Instance'ların durumu
  status <ad> [--json]           Tek instance'ın ayrıntısı
  logs <ad> [-n N] [-f]          Log satırları (-f: takip et)
  open <ad> [--target workdir|profile]
  signin <ad> [--restart] [--exclusive]
                                 Giriş rehberi; --exclusive diğerlerini giriş süresince kapatır
  doctor [<ad>] [--json]         Sağlık kontrolleri
  remove <ad> [--purge [--permanent]] [--force] [--yes]
                                 Instance'ı siler (--purge: veriler Çöp Kutusu'na)
  clone <ad> --as <yeni-ad> [--workdir <yol>]
                                 Instance'ı profil + oturumlarıyla klonlar
  project add <yol> [--name <ad>] [--folder <ek-yol>]... [--replace]
  project list | remove <ad> [--keep] | sync [--instance <ad>]
  project import --from <instance|default>
  project apply [<dosya>] [--prune] [--dry-run]
                                 projects.json'u uygular (varsayılan
                                 ~/.config/claude-orchestrator/projects.json)
  project export [<dosya>] [--force]
                                 Kayıtlı projeleri projects.json biçiminde yazar
                                 Tüm instance'larda aynı projeler (Desktop'ta "environment");
                                 takma ad: env
  memory status | link [--instance <ad>] [--force] | unlink
                                 ~/.claude/CLAUDE.md'yi tüm instance'larla paylaşır
  session list [--instance <ad>] [--project <yol>] [--running] [--json]
  session show <id> [--instance <ad>] [--json]
  session copy|move <id> --to <instance> [--instance <kaynak>] [--force]
  session last --from <instance> --to <instance> [--copy] [--force]
                                 Claude Code oturumlarını instance'lar arasında aktarır
                                 ('default' = instance dışı Claude kurulumu)
  agent [--install|--uninstall]  Menü çubuğu ikonları

VERİ KONUMU
  ~/Library/Application Support/claude-ctl/

Detaylı bilgi: https://github.com/Yuix-Networks/claude-orchestrator
"""

do {
    guard let command = rawArguments.first else {
        Output.error("komut gerekli (yardım: claude-orchestrator help)", code: ExitCode.usage)
    }

    if command == "version" || command == "--version" || command == "-v" {
        print("claude-orchestrator \(AppVersion.current)")
        exit(ExitCode.success)
    }

    if command == "help" || command == "--help" || command == "-h" {
        print(usage)
        exit(ExitCode.success)
    }

    let rest = Array(rawArguments.dropFirst())

    switch command {
    case "new":
        try NewCommand.run(rest)
    case "start":
        try StartCommand.run(rest)
    case "stop":
        try StopCommand.run(rest)
    case "list":
        try ListCommand.run(rest)
    case "status":
        try StatusCommand.run(rest)
    case "logs":
        try LogsCommand.run(rest)
    case "open":
        try OpenCommand.run(rest)
    case "signin":
        try SigninCommand.run(rest)
    case "doctor":
        try DoctorCommand.run(rest)
    case "remove":
        try RemoveCommand.run(rest)
    case "agent":
        try AgentCommand.run(rest)
    case "clone":
        try CloneCommand.run(rest)
    case "session":
        try SessionCommand.run(rest)
    case "project", "env", "environment":
        try ProjectCommand.run(rest)
    case "memory":
        try MemoryCommand.run(rest)
    default:
        Output.error("bilinmeyen komut: \(command)", code: ExitCode.usage)
    }
} catch let error as OrchestratorError {
    switch error {
    case let .usage(message), let .invalidName(message), let .notFound(message):
        // Kullanıcı hatalı argüman verdi — kullanım hatası (exit 2).
        Output.error(message, code: ExitCode.usage)
    default:
        Output.error(error.description, code: ExitCode.runtime)
    }
} catch {
    Output.error(error.localizedDescription, code: ExitCode.runtime)
}
