import ClaudeCtlCore
import Foundation

/// `claude-ctl signin <ad> [--restart]`
enum SigninCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["restart"])
        let name = try parsed.requirePositional(0, name: "instance adı", command: "signin")

        let plan = try ClaudeCtl().signin(name: name, restart: parsed.has("restart"))
        for instruction in plan.instructions {
            Output.line(instruction)
        }
    }
}
