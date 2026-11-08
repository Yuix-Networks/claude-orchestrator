import ClaudeCtlCore
import Foundation

/// `claude-ctl remove <ad> [--purge]`
enum RemoveCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["purge", "force"])
        let name = try parsed.requirePositional(0, name: "instance adı", command: "remove")
        let purge = parsed.has("purge")
        let force = parsed.has("force")

        try ClaudeCtl().remove(name: name, purge: purge, force: force)
        Output.line(purge ? "instance silindi (veriler dahil): \(name)" : "instance silindi (veriler korundu): \(name)")
    }
}
