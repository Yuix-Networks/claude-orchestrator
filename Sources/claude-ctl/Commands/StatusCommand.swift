import ClaudeCtlCore
import Foundation

/// `claude-ctl status <ad> [--json]`
enum StatusCommand {
    static func run(_ args: [String]) throws {
        let parsed = Arguments(args)
        let name = try parsed.requirePositional(0, name: "instance adı", command: "status")
        let ctl = ClaudeCtl()
        let status = try ctl.status(name: name)

        if parsed.has("json") {
            Output.json([
                "name": status.name,
                "workdir": status.workdir ?? NSNull(),
                "isRunning": status.isRunning,
                "pid": status.pid.map { Int($0) } ?? NSNull(),
                "startedAt": status.startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                "profileSizeBytes": String(status.profileSizeBytes),
                "accountSignedIn": status.accountSignedIn,
                "profileDir": ctl.paths.profileDir(name).path
            ])
            return
        }

        Output.line("instance:    \(status.name)")
        Output.line("durum:      \(status.isRunning ? "çalışıyor" : "durdu")\(status.pid.map { " (pid \($0))" } ?? "")")
        if let startedAt = status.startedAt {
            Output.line("başlangıç:  \(ISO8601DateFormatter().string(from: startedAt))")
        }
        Output.line("workdir:    \(status.workdir ?? "-")")
        Output.line("profil:     \(ctl.paths.profileDir(name).path)")
        Output.line("boyut:      \(ByteCountFormatter.string(fromByteCount: status.profileSizeBytes, countStyle: .file))")
        Output.line("oturum:     \(status.accountSignedIn ? "var" : "yok (giriş yapılmamış olabilir)")")
    }
}
