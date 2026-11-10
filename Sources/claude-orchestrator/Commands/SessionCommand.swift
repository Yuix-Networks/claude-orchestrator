import OrchestratorCore
import Foundation

/// `claude-orchestrator session <list|show|copy|move|last> …`
enum SessionCommand {
    static let usage = """
    session list [--instance <name>] [--project <path>] [--running] [--json]
    session show <session-id> [--instance <name>] [--json]
    session copy <session-id> --to <instance> [--instance <source>] [--force] [--json]
    session move <session-id> --to <instance> [--instance <source>] [--force] [--json]
    session move [<session-id>] [--to <instance>] [--instance <source>] [--yes]
                 (interactive without an id or --to: search, pick, confirm)
    session last --from <instance> --to <instance> [--copy] [--force] [--json]
    """

    static func run(_ args: [String]) throws {
        guard let sub = args.first else {
            throw OrchestratorError.usage("session: a subcommand is required\n\(usage)")
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "list": try list(rest)
        case "show": try show(rest)
        case "copy": try transfer(rest, move: false, command: "session copy")
        case "move": try transfer(rest, move: true, command: "session move")
        case "last": try last(rest)
        default:
            throw OrchestratorError.usage("session: unknown subcommand: \(sub)\n\(usage)")
        }
    }

    // MARK: - list

    static func list(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["instance", "project", "running", "json"])
        let sessions = try Orchestrator().sessions(
            instance: parsed.optionalFlag("instance"),
            project: parsed.optionalFlag("project"),
            runningOnly: parsed.has("running")
        )

        if parsed.has("json") {
            Output.json(["schemaVersion": Output.schemaVersion, "sessions": sessions.map(dictionary)])
            return
        }
        if sessions.isEmpty {
            Output.line("no sessions")
            return
        }
        Output.line(
            ListCommand.pad("INSTANCE", 12) + ListCommand.pad("SESSION", 10) + ListCommand.pad("LAST ACTIVE", 18)
            + ListCommand.pad("MSGS", 7) + ListCommand.pad("PROJECT", 28) + "TITLE / FIRST PROMPT"
        )
        for located in sessions {
            let session = located.session
            Output.line(
                ListCommand.pad(located.endpoint.name, 12)
                + ListCommand.pad(String(session.id.prefix(8)), 10)
                + ListCommand.pad(session.endedAt.map(shortDate) ?? "-", 18)
                + ListCommand.pad(String(session.messageCount), 7)
                + ListCommand.pad(shortPath(session.cwd ?? session.projectSlug, width: 27), 28)
                + truncate(session.title ?? session.firstPrompt ?? "-", 60)
            )
        }
    }

    // MARK: - show

    static func show(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["instance", "json"])
        let id = try parsed.requirePositional(0, name: "session id", command: "session show")
        let located = try Orchestrator().findSession(id, instance: parsed.optionalFlag("instance"))

        if parsed.has("json") {
            var object = dictionary(located)
            object["schemaVersion"] = Output.schemaVersion
            Output.json(object)
            return
        }
        let session = located.session
        Output.line("session:      \(session.id)")
        Output.line("instance:     \(located.endpoint.name)")
        if let title = session.title { Output.line("title:        \(title)") }
        Output.line("directory:    \(session.cwd ?? "-")")
        Output.line("started:      \(session.startedAt.map(shortDate) ?? "-")")
        Output.line("last active:  \(session.endedAt.map(shortDate) ?? "-")")
        if let start = session.startedAt, let end = session.endedAt {
            Output.line("duration:     \(duration(end.timeIntervalSince(start)))")
        }
        Output.line("messages:     \(session.messageCount)")
        Output.line("CLI version:  \(session.cliVersion ?? "-")")
        Output.line("size:         \(ByteCountFormatter.string(fromByteCount: session.sizeBytes, countStyle: .file))")
        Output.line("transcript:   \(session.transcript.path)")
        if let first = session.firstPrompt { Output.line("first prompt: \(first)") }
        if let last = session.lastPrompt, last != session.firstPrompt { Output.line("last prompt:  \(last)") }
        Output.line("resume:       CLAUDE_CONFIG_DIR=\"\(located.endpoint.codeDir.path)\" claude --resume \(session.id)")
    }

    // MARK: - copy / move

    static func transfer(_ args: [String], move: Bool, command: String) throws {
        let parsed = try Arguments(args, allowed: Set(["instance", "to", "force", "json"] + (move ? ["yes"] : [])))
        // Interactive move: if the session or target is missing, pick them on screen.
        if move, parsed.positionals.isEmpty || parsed.optionalFlag("to") == nil,
           !parsed.has("json"), !parsed.has("force") {
            try SessionMoveInteractive.run(
                id: parsed.positionals.first,
                from: parsed.optionalFlag("instance"),
                to: parsed.optionalFlag("to"),
                assumeYes: parsed.has("yes")
            )
            return
        }
        let id = try parsed.requirePositional(0, name: "session id", command: command)
        let to = try parsed.requireFlag("to", command: command)

        let result = try Orchestrator().transferSession(
            id, from: parsed.optionalFlag("instance"), to: to, move: move, force: parsed.has("force")
        )
        report(result, to: to, move: move, json: parsed.has("json"))
    }

    // MARK: - last

    static func last(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["from", "to", "copy", "force", "json"])
        let from = try parsed.requireFlag("from", command: "session last")
        let to = try parsed.requireFlag("to", command: "session last")
        let move = !parsed.has("copy")

        let ctl = Orchestrator()
        let located = try ctl.lastSession(instance: from)
        let result = try ctl.transfer(located, to: to, move: move, force: parsed.has("force"))
        report(result, to: to, move: move, json: parsed.has("json"))
    }

    // MARK: - Output

    static func report(_ result: TransferResult, to: String, move: Bool, json: Bool) {
        if json {
            Output.json([
                "schemaVersion": Output.schemaVersion,
                "sessionId": result.session.id,
                "to": to,
                "moved": move,
                "copiedFiles": result.copiedFiles.map(\.path),
                "desktopMetadata": result.desktopMetadata?.path ?? NSNull(),
                "backup": result.backup?.path ?? NSNull(),
                "warnings": result.warnings
            ])
            return
        }
        for warning in result.warnings {
            Output.line("warning: \(warning)")
        }
        Output.line("\(move ? "moved" : "copied"): \(result.session.id) → \(to)")
        if let backup = result.backup {
            Output.line("  source backup: \(backup.path)")
        }
        if result.desktopMetadata != nil {
            Output.line("  added to the Claude Desktop sidebar (shows after the instance restarts)")
        }
    }

    static func dictionary(_ located: LocatedSession) -> [String: Any] {
        let session = located.session
        let iso = ISO8601DateFormatter()
        return [
            "instance": located.endpoint.name,
            "id": session.id,
            "projectSlug": session.projectSlug,
            "cwd": session.cwd ?? NSNull(),
            "title": session.title ?? NSNull(),
            "startedAt": session.startedAt.map { iso.string(from: $0) } ?? NSNull(),
            "endedAt": session.endedAt.map { iso.string(from: $0) } ?? NSNull(),
            "messageCount": session.messageCount,
            "firstPrompt": session.firstPrompt ?? NSNull(),
            "lastPrompt": session.lastPrompt ?? NSNull(),
            "cliVersion": session.cliVersion ?? NSNull(),
            "sizeBytes": session.sizeBytes,
            "transcript": session.transcript.path
        ]
    }

    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600, minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
    }

    static func shortPath(_ path: String, width: Int) -> String {
        let home = NSHomeDirectory()
        let display = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        return display.count > width ? "…" + display.suffix(width - 1) : display
    }

    static func truncate(_ text: String, _ width: Int) -> String {
        text.count > width ? String(text.prefix(width - 1)) + "…" : text
    }
}
