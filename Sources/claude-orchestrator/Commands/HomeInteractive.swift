import OrchestratorCore
import Foundation

/// `claude-orchestrator` with no arguments: profile list → profile actions,
/// with "New profile" below the list.
enum HomeInteractive {
    static func run() throws {
        let ctl = Orchestrator()
        var message: Message?
        var focus: String?
        var openProjects = false

        while true {
            guard let ui = TerminalUI() else {
                throw OrchestratorError.usage("a command is required (help: claude-orchestrator help)")
            }
            // Screens return with an action that has to leave raw terminal mode
            // (sign-in, session move); it runs on the normal screen.
            let next: Exit
            if openProjects, let exit = ProjectsInteractive.run(ctl: ctl, ui: ui) {
                next = exit
            } else {
                next = home(ctl: ctl, ui: ui, message: &message, focus: &focus)
            }
            openProjects = false
            ui.restore()

            switch next {
            case .quit:
                return
            case let .signIn(name):
                runOutside { try SigninCommand.run([name, "--exclusive"]) }
                focus = name
            case let .transfer(located, target, move):
                runOutside {
                    let outcome = try ctl.transferSessionRestarting(located, to: target, move: move) { Output.line($0) }
                    SessionMoveInteractive.report(outcome, located: located, target: target, move: move)
                }
                focus = located.endpoint.name
            case let .outside(action, reopenProjects):
                runOutside(action)
                openProjects = reopenProjects
            }
            message = nil
        }
    }

    enum Exit {
        case quit
        /// An action to run in normal terminal mode; return to the Projects screen afterwards?
        case outside(() throws -> Void, reopenProjects: Bool)
        case signIn(String)
        /// Session, target, and whether it is a move (otherwise a copy).
        case transfer(LocatedSession, String, Bool)
    }

    struct Message {
        var text: String
        var isError: Bool
    }

    /// Runs an action in normal terminal mode, then waits for Enter.
    static func runOutside(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
        }
        FileHandle.standardError.write(Data("\nPress Enter to return to the menu… ".utf8))
        _ = readLine()
    }

    // MARK: - Home screen

    private static func home(ctl: Orchestrator, ui: TerminalUI, message: inout Message?, focus: inout String?) -> Exit {
        while true {
            let profiles = (try? ctl.list(includeSizes: false)) ?? []
            let newRow = profiles.count
            let projectsRow = newRow + 1
            var picker = PickerModel(items: profiles.map(\.name) + ["New profile", "Projects"], searchable: false)
            if let focus, let row = profiles.firstIndex(where: { $0.name == focus }) {
                for _ in 0..<row { _ = picker.handle(.down) }
            }

            var chosen: Int?
            while chosen == nil {
                ui.draw(homeLines(profiles, picker: picker, message: message, newRow: newRow, columns: ui.size.columns))
                let key = ui.readKey()
                if key == .character("q") || key == .character("Q") { return .quit }
                switch picker.handle(key) {
                case let .select(index): chosen = index
                case .back, .cancel: return .quit
                case .none: continue
                }
                message = nil
            }
            guard let index = chosen else { continue }

            if index == projectsRow {
                if let exit = ProjectsInteractive.run(ctl: ctl, ui: ui) { return exit }
                continue
            }

            if index == newRow {
                if let created = newProfile(ctl: ctl, ui: ui) {
                    focus = created
                    message = Message(text: "Created profile \(display(created)).", isError: false)
                    // A new profile opens straight in its action screen (start / log in).
                    if let exit = profileMenu(created, ctl: ctl, ui: ui, message: &message) { return exit }
                }
                continue
            }

            focus = profiles[index].name
            if let exit = profileMenu(profiles[index].name, ctl: ctl, ui: ui, message: &message) { return exit }
        }
    }

    private static func homeLines(
        _ profiles: [InstanceStatus],
        picker: PickerModel,
        message: Message?,
        newRow: Int,
        columns: Int
    ) -> [String] {
        let rule = Style.dim + String(repeating: "─", count: max(0, min(columns, 72) - 1)) + Style.reset
        var lines = [
            Style.bold + "Claude Orchestrator" + Style.reset
                + Style.dim + "  — ↑/↓ to choose, Enter to open, q to quit" + Style.reset,
            rule
        ]
        if profiles.isEmpty {
            lines.append(Style.dim + "  No profiles yet." + Style.reset)
        }
        let nameWidth = max(12, (profiles.map { $0.name.count }.max() ?? 0) + 2)
        for (row, profile) in profiles.enumerated() {
            let selected = picker.selection == row
            let state = profile.isRunning
                ? Style.accent + "● running" + Style.reset
                : Style.dim + "○ stopped" + Style.reset
            let account = profile.accountSignedIn ? "" : Style.warning + "   not logged in" + Style.reset
            lines.append(
                (selected ? Style.inverse + "❯ " : "  ") + display(profile.name).fitted(nameWidth) + Style.reset
                    + state + account
            )
        }
        lines.append(rule)
        let newSelected = picker.selection == newRow
        lines.append((newSelected ? Style.inverse + "❯ " : "  ") + "+ New profile" + Style.reset)
        lines.append((picker.selection == newRow + 1 ? Style.inverse + "❯ " : "  ") + "Projects…" + Style.reset)
        if let message {
            lines.append("")
            lines.append((message.isError ? Style.warning : Style.dim) + message.text + Style.reset)
        }
        return lines
    }

    // MARK: - Profile actions

    private enum Action: String {
        case start = "Start"
        case stop = "Stop"
        case restart = "Restart"
        case logIn = "Log in"
        /// On a logged-in profile: when the session has expired or the account should change.
        case logInAgain = "Log in again…"
        case sessions = "Sessions…"
        case back = "Back"
    }

    /// `nil` → back to the home screen; otherwise an action to run in normal terminal mode.
    private static func profileMenu(_ name: String, ctl: Orchestrator, ui: TerminalUI, message: inout Message?) -> Exit? {
        while true {
            guard let status = try? ctl.status(name: name) else { return nil }
            // On a profile that isn't logged in, logging in is the only useful action
            // (the login flow also starts it); the other actions appear after login.
            let actions: [Action] = status.accountSignedIn
                ? (status.isRunning ? [.stop, .restart] : [.start]) + [.sessions, .logInAgain, .back]
                : [.logIn]
            var picker = PickerModel(items: actions.map(\.rawValue), searchable: false)

            var chosen: Action?
            while chosen == nil {
                ui.draw(menuLines(status, actions: actions, picker: picker, message: message))
                let key = ui.readKey()
                switch picker.handle(key) {
                case let .select(index): chosen = actions[index]
                case .back, .cancel: return nil
                case .none: continue
                }
                message = nil
            }

            switch chosen! {
            case .back:
                return nil
            case .start:
                message = perform("Starting \(display(name))…", ui: ui) {
                    let result = try ctl.start(name: name, folder: nil)
                    return "Started \(display(name)) (pid \(result.pid))."
                        + (result.warning.map { "\nwarning: \($0)" } ?? "")
                }
            case .stop, .restart:
                if let blocker = hostBlocker(ctl: ctl, stopping: [name]) {
                    message = Message(text: blocker, isError: true)
                    continue
                }
                let restart = chosen == .restart
                message = perform("\(restart ? "Restarting" : "Stopping") \(display(name))…", ui: ui) {
                    let stopped = try ctl.stop(name: name)
                    guard restart else {
                        return "Stopped \(display(name))." + (stopped.forced ? " (it had to be force-quit)" : "")
                    }
                    let started = try ctl.start(name: name, folder: nil)
                    return "Restarted \(display(name)) (pid \(started.pid))."
                }
            case .logIn, .logInAgain:
                // The other running instances are closed during login.
                let others = ((try? ctl.list(includeSizes: false)) ?? [])
                    .filter { $0.name != name && $0.isRunning }.map(\.name)
                if let blocker = hostBlocker(ctl: ctl, stopping: others + [name]) {
                    message = Message(text: blocker, isError: true)
                    continue
                }
                switch confirmLogIn(name, others: others, ui: ui) {
                case true: return .signIn(name)
                case false: continue
                }
            case .sessions:
                if let exit = sessionsScreen(name, ctl: ctl, ui: ui, message: &message) { return exit }
            }
        }
    }

    // MARK: - Sessions

    /// The profile's sessions: search → pick → copy / move.
    private static func sessionsScreen(_ name: String, ctl: Orchestrator, ui: TerminalUI, message: inout Message?) -> Exit? {
        let sessions = (try? ctl.sessions(instance: name)) ?? []
        guard !sessions.isEmpty else {
            message = Message(text: "\(display(name)) has no sessions yet.", isError: false)
            return nil
        }
        var picker = PickerModel(items: sessions.map(SessionMoveInteractive.searchText))
        while true {
            let render: (PickerModel) -> (lines: [String], cursor: (Int, Int)?) = {
                SessionMoveInteractive.sessionScreen(
                    $0, sessions, ui, heading: "\(display(name)) · sessions", escapeHint: "Esc to go back"
                )
            }
            guard let index = SessionMoveInteractive.pick(&picker, ui: ui, render: render) else { return nil }
            if let exit = sessionMenu(sessions[index], ctl: ctl, ui: ui) { return exit }
        }
    }

    private enum SessionAction: String {
        case copy = "Copy to…"
        case move = "Move to…"
        case back = "Back"
    }

    /// Session details + actions. `nil` → back to the session list.
    private static func sessionMenu(_ located: LocatedSession, ctl: Orchestrator, ui: TerminalUI) -> Exit? {
        let actions: [SessionAction] = [.copy, .move, .back]
        var picker = PickerModel(items: actions.map(\.rawValue), searchable: false)
        var notice: Message?
        while true {
            ui.draw(sessionLines(located, actions: actions, picker: picker, notice: notice))
            let index: Int
            switch picker.handle(ui.readKey()) {
            case let .select(selected): index = selected
            case .back, .cancel: return nil
            case .none: continue
            }
            notice = nil
            let action = actions[index]
            if action == .back { return nil }
            let move = action == .move

            let instances = (try? ctl.instanceEndpoints()) ?? []
            let candidates = instances.filter { $0.name != located.endpoint.name }
            guard !candidates.isEmpty else {
                notice = Message(text: "There is no other account to \(move ? "move" : "copy") this session to.", isError: true)
                continue
            }
            var target: String?
            if candidates.count == 1 {
                target = candidates[0].name
            } else {
                var targets = PickerModel(items: candidates.map(\.name), searchable: false)
                if case let .select(row) = SessionMoveInteractive.pickTarget(
                    &targets, located: located, candidates: candidates, move: move, ui: ui
                ) {
                    target = candidates[row].name
                }
            }
            guard let target else { continue }
            if let blocker = SessionMoveInteractive.selfStopBlocker(
                located: located, target: target, move: move, instances: instances
            ) {
                notice = Message(text: blocker, isError: true)
                continue
            }
            if SessionMoveInteractive.confirm(located: located, target: target, move: move, instances: instances, ui: ui) == true {
                return .transfer(located, target, move)
            }
        }
    }

    private static func sessionLines(
        _ located: LocatedSession,
        actions: [SessionAction],
        picker: PickerModel,
        notice: Message?
    ) -> [String] {
        let session = located.session
        func row(_ label: String, _ value: String) -> String {
            Style.dim + label.fitted(14) + Style.reset + value
        }
        var lines = [
            Style.bold + SessionMoveInteractive.title(session) + Style.reset,
            Style.dim + "↑/↓ to choose, Enter to run, Esc to go back" + Style.reset,
            "",
            row("Account", display(located.endpoint.name) + (located.endpoint.isRunning ? "  ● running" : "")),
            row("Project", session.cwd.map { SessionCommand.shortPath($0, width: 60) } ?? session.projectSlug),
            row("Started", session.startedAt.map(SessionMoveInteractive.relativeDate) ?? "-"),
            row("Last active", SessionMoveInteractive.relativeDate(session.lastActivity)),
            row("Messages", "\(session.messageCount)"),
            row("Size", ByteCountFormatter.string(fromByteCount: session.sizeBytes, countStyle: .file)),
            row("Id", session.id),
            ""
        ]
        for (index, action) in actions.enumerated() {
            lines.append((picker.selection == index ? Style.inverse + "❯ " : "  ") + action.rawValue + Style.reset)
        }
        if let notice {
            lines.append("")
            lines.append((notice.isError ? Style.warning : Style.dim) + notice.text + Style.reset)
        }
        return lines
    }

    private static func menuLines(_ status: InstanceStatus, actions: [Action], picker: PickerModel, message: Message?) -> [String] {
        var details = status.isRunning ? Style.accent + "● running" + Style.reset : Style.dim + "○ stopped" + Style.reset
        if let pid = status.pid, status.isRunning { details += Style.dim + " · pid \(pid)" + Style.reset }
        details += status.accountSignedIn
            ? Style.dim + " · logged in" + Style.reset
            : Style.warning + " · not logged in" + Style.reset
        if let workdir = status.workdir {
            details += Style.dim + " · " + SessionCommand.shortPath(workdir, width: 40) + Style.reset
        }
        var lines = [
            Style.bold + display(status.name) + Style.reset + "  " + details,
            Style.dim + "↑/↓ to choose, Enter to run, Esc to go back" + Style.reset,
            ""
        ]
        for (row, action) in actions.enumerated() {
            lines.append((picker.selection == row ? Style.inverse + "❯ " : "  ") + action.rawValue + Style.reset)
        }
        if let message {
            lines.append("")
            lines.append((message.isError ? Style.warning : Style.dim) + message.text + Style.reset)
        }
        return lines
    }

    /// Short actions run on screen; the result becomes a message on the home/action screen.
    private static func perform(_ progress: String, ui: TerminalUI, _ body: () throws -> String) -> Message {
        ui.draw([Style.dim + progress + Style.reset])
        do {
            return Message(text: try body(), isError: false)
        } catch {
            return Message(text: "\(error)", isError: true)
        }
    }

    private static func confirmLogIn(_ name: String, others: [String], ui: TerminalUI) -> Bool {
        var body = "A browser window will open for you to log in to Claude. "
            + "Once you approve it there, you are sent back to the \(display(name)) window."
        if !others.isEmpty {
            let list = others.map(display).joined(separator: ", ")
            body += "\n\nSo that the login returns to the right window, the other running instances (\(list)) "
                + "will be shut down while you log in and reopened afterwards."
        }
        let width = min(ui.size.columns - 2, 78)
        let lines = [Style.bold + "Log in to \(display(name))" + Style.reset, ""]
            + body.wrapped(width)
            + ["", Style.bold + "Continue? [Y/n]" + Style.reset]
        while true {
            ui.draw(lines)
            switch ui.readKey() {
            case .character("y"), .character("Y"), .enter: return true
            case .character("n"), .character("N"), .escape, .interrupt: return false
            default: continue
            }
        }
    }

    // MARK: - New profile

    /// The name of the created profile; `nil` if cancelled.
    private static func newProfile(ctl: Orchestrator, ui: TerminalUI) -> String? {
        textInput(
            ui: ui,
            title: "New profile",
            hint: "Lowercase letters, digits and hyphens. Enter to create, Esc to cancel.",
            label: "Name: "
        ) { name in
            guard !name.isEmpty else { return "Enter a name." }
            do {
                _ = try ctl.new(name: name, workdir: nil)
                return nil
            } catch {
                return "\(error)"
            }
        }
    }

    /// Single-line text input. If `submit` returns an error text, the screen
    /// stays; if it returns `nil`, the entered value is returned. Esc → `nil`.
    static func textInput(
        ui: TerminalUI,
        title: String,
        hint: String,
        label: String,
        initial: String = "",
        context: [String] = [],
        submit: (String) -> String?
    ) -> String? {
        var text = initial
        var problem: String?
        while true {
            var lines = [Style.bold + title + Style.reset, Style.dim + hint + Style.reset, ""] + context
            if !context.isEmpty { lines.append("") }
            let inputRow = lines.count
            lines.append(label + text)
            if let problem {
                lines.append("")
                lines.append(Style.warning + problem + Style.reset)
            }
            ui.draw(lines, cursor: (row: inputRow, column: label.count + text.count))

            switch ui.readKey() {
            case let .character(character):
                text.append(character)
                problem = nil
            case .backspace:
                if !text.isEmpty { text.removeLast() }
                problem = nil
            case .clearQuery:
                text = ""
            case .enter:
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if let error = submit(trimmed) {
                    problem = error
                } else {
                    return trimmed
                }
            case .escape, .interrupt:
                return nil
            default:
                continue
            }
        }
    }

    // MARK: - Helpers

    /// Is this terminal running inside one of the instances about to be closed
    /// (a Code tab terminal, a Claude Code tool)? If so, closing it would kill
    /// this command too.
    static func hostBlocker(ctl: Orchestrator, stopping names: [String]) -> String? {
        guard let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] else { return nil }
        let current = URL(fileURLWithPath: configDir).standardizedFileURL.path
        for name in names {
            guard let endpoint = try? ctl.endpoint(name), endpoint.isRunning,
                  endpoint.codeDir.standardizedFileURL.path == current else { continue }
            return "This terminal is running inside \(display(name)), which would have to be shut down. "
                + "Use a regular terminal (Terminal, iTerm) for this."
        }
        return nil
    }

    static func display(_ name: String) -> String { SessionMoveInteractive.display(name) }
}
