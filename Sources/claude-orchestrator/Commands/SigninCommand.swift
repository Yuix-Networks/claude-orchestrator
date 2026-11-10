import OrchestratorCore
import Foundation

/// `claude-orchestrator signin <name> [--restart] [--exclusive]`
enum SigninCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["restart", "exclusive"])
        let name = try parsed.requirePositional(0, name: "instance name", command: "signin")
        let ctl = Orchestrator()

        guard parsed.has("exclusive") else {
            let plan = try ctl.signin(name: name, restart: parsed.has("restart"))
            for instruction in plan.instructions {
                Output.line(instruction)
            }
            return
        }

        // Exclusive mode: the other instances are closed during sign-in so the
        // `claude://` callback can't land in the wrong one, then reopened.
        guard isatty(STDIN_FILENO) != 0 else {
            throw OrchestratorError.usage("signin --exclusive needs an interactive terminal")
        }
        _ = try ctl.store.instance(named: name)
        let others = try ctl.list(includeSizes: false).filter { $0.name != name && $0.isRunning }.map(\.name)
        for other in others {
            _ = try ctl.stop(name: other)
            Output.line("stopped (during sign-in): \(other)")
        }
        // Restarting makes the target the last-registered handler for `claude://`.
        _ = try ctl.stop(name: name)
        _ = try ctl.start(name: name, folder: nil)
        Output.line("started: \(name)")

        if ctl.launcher.runningDefaultPid() != nil {
            Output.line("warning: the default Claude (outside any instance) is open and may catch the sign-in link; close it while you sign in")
        }
        Output.line("")
        Output.line("Sign in in the '\(name)' window (after you approve in the browser, you return to the app).")
        FileHandle.standardError.write(Data("Press Enter when sign-in is done… ".utf8))
        _ = readLine()

        for other in others {
            do {
                _ = try ctl.start(name: other, folder: nil)
                Output.line("restarted: \(other)")
            } catch {
                Output.line("warning: could not start \(other): \(error)")
            }
        }
        let signedIn = try ctl.status(name: name).accountSignedIn
        Output.line(signedIn ? "sign-in detected: \(name)" : "warning: no session cookie found in the '\(name)' profile")
    }
}
