import ClaudeCtlCore
import Foundation

/// `claude-ctl open <ad> [--target workdir|profile]`
enum OpenCommand {
    static func run(_ args: [String]) throws {
        let parsed = Arguments(args)
        let name = try parsed.requirePositional(0, name: "instance adı", command: "open")
        let target = OpenTarget(rawValue: parsed.optionalFlag("target") ?? "workdir") ?? .workdir

        try ClaudeCtl().open(name: name, target: target)
        Output.line("açıldı (\(target.rawValue)): \(name)")
    }
}
