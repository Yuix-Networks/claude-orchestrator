import ClaudeCtlCore
import Foundation

/// `claude-ctl new <ad> --workdir <yol>`
enum NewCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["workdir"])
        let name = try parsed.requirePositional(0, name: "instance adı", command: "new")
        let workdir = try parsed.requireFlag("workdir", command: "new")

        let ctl = ClaudeCtl()
        let instance = try ctl.new(name: name, workdir: workdir)

        if !FileManager.default.fileExists(atPath: workdir) {
            Output.line("uyarı: workdir bulunamadı: \(workdir)")
        }
        Output.line("instance oluşturuldu: \(instance.name)")
        Output.line("  workdir: \(instance.workdir ?? "-")")
        Output.line("  profil:  \(ctl.paths.profileDir(instance.name).path)")
        Output.line("  başlat:  claude-ctl start \(instance.name)")
    }
}
