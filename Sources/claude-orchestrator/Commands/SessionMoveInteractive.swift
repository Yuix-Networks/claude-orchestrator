import OrchestratorCore
import Foundation

/// Interactive `session move`: find/pick a session → pick the target account → confirm.
///
/// Screen 1 opens when no session id is given, screen 2 when `--to` is missing
/// (screen 2 is skipped if only one account can be the target). After
/// confirmation the source and target instances are closed in turn, the session
/// is moved, and the closed instances are reopened.
enum SessionMoveInteractive {
    static func run(id: String?, from: String?, to: String?, assumeYes: Bool) throws {
        let ctl = Orchestrator()

        var preselected: LocatedSession?
        if let id { preselected = try ctl.findSession(id, instance: from) }
        let sessions = preselected == nil ? try ctl.sessions(instance: from) : []
        if preselected == nil, sessions.isEmpty {
            throw OrchestratorError.notFound(from.map { "no sessions in instance '\($0)'" } ?? "no sessions")
        }
        let instances = try ctl.instanceEndpoints()
        if let to { _ = try ctl.endpoint(to) }

        guard let ui = TerminalUI() else {
            throw OrchestratorError.usage(
                "session move: interactive selection needs a terminal; "
                + "in scripts use: session move <session-id> --to <instance>"
            )
        }

        var screen: Screen = preselected == nil ? .sessions : .target
        var chosen = preselected
        var target = to
        var sessionPicker = PickerModel(items: sessions.map(searchText))

        flow: while true {
            switch screen {
            case .sessions:
                guard let index = pick(&sessionPicker, ui: ui, render: { sessionScreen($0, sessions, ui, heading: "Move a session") }) else {
                    ui.restore()
                    throw OrchestratorError.runtime("cancelled — nothing was changed")
                }
                chosen = sessions[index]
                target = to
                screen = .target

            case .target:
                guard let located = chosen else { screen = .sessions; continue }
                let candidates = instances.filter { $0.name != located.endpoint.name }
                if candidates.isEmpty {
                    ui.restore()
                    throw OrchestratorError.runtime("there is no other account to move this session to")
                }
                if let given = target {
                    guard given != located.endpoint.name else {
                        ui.restore()
                        throw OrchestratorError.usage("the session already belongs to \(display(given))")
                    }
                    screen = .confirm
                } else if candidates.count == 1 {
                    // With only one option there is nothing to ask.
                    target = candidates[0].name
                    screen = .confirm
                } else {
                    var picker = PickerModel(items: candidates.map(\.name), searchable: false)
                    switch pickTarget(&picker, located: located, candidates: candidates, move: true, ui: ui) {
                    case let .select(index):
                        target = candidates[index].name
                        screen = .confirm
                    case .back where preselected == nil:
                        screen = .sessions
                    default:
                        ui.restore()
                        throw OrchestratorError.runtime("cancelled — nothing was changed")
                    }
                }

            case .confirm:
                guard let located = chosen, let targetName = target else { screen = .sessions; continue }
                if let blocker = selfStopBlocker(located: located, target: targetName, move: true, instances: instances) {
                    ui.restore()
                    throw OrchestratorError.runtime(blocker)
                }
                if assumeYes { break flow }
                // No `switch` on `Bool?`: older Swift versions don't treat true/false/nil
                // as exhaustive (this broke the first v0.2.8 release build).
                let answer = confirm(located: located, target: targetName, move: true, instances: instances, ui: ui)
                if answer == true { break flow }
                if answer == false {
                    ui.restore()
                    throw OrchestratorError.runtime("cancelled — nothing was changed")
                }
                do {
                    // Back: to the target screen if it was shown, otherwise to the session list.
                    let candidates = instances.filter { $0.name != located.endpoint.name }
                    if to == nil, candidates.count > 1 {
                        target = nil
                        screen = .target
                    } else if preselected == nil {
                        screen = .sessions
                    } else {
                        ui.restore()
                        throw OrchestratorError.runtime("cancelled — nothing was changed")
                    }
                }
            }
        }
        ui.restore()

        guard let located = chosen, let targetName = target else { return }
        let outcome = try ctl.moveSessionRestarting(located, to: targetName) { Output.line($0) }
        report(outcome, located: located, target: targetName, move: true)
    }

    static func report(_ outcome: SessionMovePlan.Outcome, located: LocatedSession, target: String, move: Bool) {
        for warning in outcome.result.warnings { Output.line("warning: \(warning)") }
        Output.line("\(move ? "Moved" : "Copied") \"\(title(located.session))\" from \(display(located.endpoint.name)) to \(display(target)).")
        if let backup = outcome.result.backup {
            Output.line("  Backup of the original: \(backup.path)")
        }
        if outcome.result.desktopMetadata != nil {
            Output.line("  It now appears in \(display(target))'s Code tab.")
        }
        for failure in outcome.restartFailures {
            Output.line("warning: could not restart \(failure.name): \(failure.error)")
        }
    }

    private enum Screen { case sessions, target, confirm }

    // MARK: - Screen 1: sessions

    static func searchText(_ located: LocatedSession) -> String {
        let session = located.session
        let project = session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        return "\(title(session)) \(located.endpoint.name) \(project)"
    }

    /// The selected index; `nil` when cancelled.
    static func pick(
        _ picker: inout PickerModel,
        ui: TerminalUI,
        render: (PickerModel) -> (lines: [String], cursor: (Int, Int)?)
    ) -> Int? {
        while true {
            picker.pageSize = max(1, ui.size.rows - 6)
            let frame = render(picker)
            ui.draw(frame.lines, cursor: frame.cursor.map { (row: $0.0, column: $0.1) })
            switch picker.handle(ui.readKey()) {
            case let .select(index): return index
            case .back, .cancel: return nil
            case .none: continue
            }
        }
    }

    static func sessionScreen(
        _ picker: PickerModel,
        _ sessions: [LocatedSession],
        _ ui: TerminalUI,
        heading: String,
        escapeHint: String = "Esc to quit"
    ) -> (lines: [String], cursor: (Int, Int)?) {
        let (rows, columns) = ui.size
        let prompt = "Search: "
        var lines = [
            Style.bold + heading + Style.reset + Style.dim
                + "  — type to filter, ↑/↓ to choose, Enter to select, \(escapeHint)" + Style.reset,
            prompt + picker.query,
            Style.dim + String(repeating: "─", count: max(0, columns - 1)) + Style.reset
        ]

        let metaWidth = 12 + 2 + 16 + 2 + 9
        let titleWidth = max(20, columns - metaWidth - 4)
        let listRows = max(1, rows - lines.count - 2)
        let window = scrollWindow(selection: picker.selection, count: picker.visible.count, height: listRows)

        if picker.visible.isEmpty {
            lines.append(Style.dim + "  No sessions match \"\(picker.query)\"" + Style.reset)
        }
        for row in window {
            let entry = picker.visible[row]
            let located = sessions[entry.index]
            let selected = row == picker.selection
            let base = selected ? Style.inverse : ""
            let marker = selected ? "❯ " : "  "
            // Search text is "<title> <instance> <project>": matches in the title are highlighted.
            let name = title(located.session)
            let titlePositions = entry.positions.filter { $0 < name.count }
            let running = located.endpoint.isRunning ? "●" : " "
            let meta = " " + "\(running) \(located.endpoint.name)".fitted(12) + "  "
                + relativeDate(located.session.lastActivity).fitted(16) + "  "
                + "\(located.session.messageCount) msgs".fitted(9)
            lines.append(
                base + marker + name.highlighted(titlePositions, width: titleWidth, base: base)
                    + base + Style.dim + meta + Style.reset
            )
        }
        let footer = "\(picker.visible.count)/\(sessions.count) sessions · ● running"
        lines.append(Style.dim + footer + Style.reset)
        return (lines, (1, prompt.count + picker.query.count))
    }

    // MARK: - Screen 2: target account

    static func pickTarget(
        _ picker: inout PickerModel,
        located: LocatedSession,
        candidates: [SessionEndpoint],
        move: Bool,
        ui: TerminalUI
    ) -> PickerAction {
        while true {
            var lines = [
                Style.bold + "\(move ? "Move" : "Copy") \"\(title(located.session))\"" + Style.reset,
                Style.dim + "From \(display(located.endpoint.name)) to which account?"
                    + "  ↑/↓ to choose, Enter to select, Esc to go back" + Style.reset,
                ""
            ]
            for (row, entry) in picker.visible.enumerated() {
                let endpoint = candidates[entry.index]
                let selected = row == picker.selection
                let state = endpoint.isRunning ? Style.dim + "  running" + Style.reset : ""
                lines.append(
                    (selected ? Style.inverse + "❯ " : "  ") + display(endpoint.name) + Style.reset + state
                )
            }
            ui.draw(lines)
            let action = picker.handle(ui.readKey())
            if action != .none { return action }
        }
    }

    // MARK: - Screen 3: confirmation

    /// `true` confirm, `false` cancel, `nil` back.
    static func confirm(
        located: LocatedSession,
        target: String,
        move: Bool,
        instances: [SessionEndpoint],
        ui: TerminalUI
    ) -> Bool? {
        let source = located.endpoint.name
        let affected = move ? [source, target] : [target]
        let running = affected.filter { name in instances.first { $0.name == name }?.isRunning == true }
        let width = min(ui.size.columns - 2, 78)

        var body = "Session: \"\(title(located.session))\"\n"
        body += "From \(display(source)) to \(display(target))"
        if let cwd = located.session.cwd { body += " · \(SessionCommand.shortPath(cwd, width: 40))" }
        body += "\n\n"
        if running.isEmpty {
            body += move
                ? "Neither instance is running, so the session will be moved right away."
                : "\(display(target)) is not running, so the session will be copied right away."
        } else {
            let names = running.map { display($0) }
            let subject = running.count == 1
                ? "the Claude instance signed in to the \(names[0]) account will be shut down"
                : "the Claude instances signed in to the \(names[0]) and \(names[1]) accounts will be shut down one after the other"
            let verb = move ? "move" : "copy"
            body += "To \(verb) the session safely, \(subject), and the session will then be \(verb == "move" ? "moved" : "copied"). "
                + (running.count == 1 ? "It will be reopened" : "Both will be reopened")
                + " once the move is complete."
            body += "\n\nAny unsent messages or work in progress in those windows may be lost."
        }
        body += move
            ? "\n\nThe original copy is kept as a backup and can be restored."
            : "\n\n\(display(source)) keeps its copy of the session."

        let lines = [Style.bold + "Confirm session \(move ? "move" : "copy")" + Style.reset, ""]
            + body.wrapped(width)
            + ["", Style.bold + "Do you want to proceed? [y/N]" + Style.reset
                + Style.dim + "  (Esc to go back)" + Style.reset]
        while true {
            ui.draw(lines)
            switch ui.readKey() {
            case .character("y"), .character("Y"): return true
            case .character("n"), .character("N"), .enter, .interrupt: return false
            case .escape: return nil
            default: continue
            }
        }
    }

    /// If this command runs inside an instance that is about to be closed (a Code
    /// tab terminal, a Claude Code tool), closing it kills the command too: the
    /// move stops halfway and the instances are not reopened.
    static func selfStopBlocker(located: LocatedSession, target: String, move: Bool, instances: [SessionEndpoint]) -> String? {
        guard let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] else { return nil }
        let current = URL(fileURLWithPath: configDir).standardizedFileURL.path
        let names = move ? [located.endpoint.name, target] : [target]
        let affected = instances.filter { names.contains($0.name) && $0.isRunning }
        guard let owner = affected.first(where: { $0.codeDir.standardizedFileURL.path == current }) else { return nil }
        return "this terminal is running inside the \(display(owner.name)) Claude instance, which has to be shut down "
            + "for the \(move ? "move" : "copy") — run the command from a regular terminal (Terminal, iTerm) instead"
    }

    // MARK: - Formatting

    static func title(_ session: SessionSummary) -> String {
        let raw = session.title ?? session.firstPrompt ?? session.id
        return raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Account names are shown capitalized (`work` → `Work`).
    static func display(_ name: String) -> String {
        name.prefix(1).uppercased() + name.dropFirst()
    }

    static func relativeDate(_ date: Date) -> String {
        guard date != .distantPast else { return "-" }
        let calendar = Calendar.current
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        if calendar.isDateInToday(date) { return "today \(time.string(from: date))" }
        if calendar.isDateInYesterday(date) { return "yesterday \(time.string(from: date))" }
        time.dateFormat = "yyyy-MM-dd HH:mm"
        return time.string(from: date)
    }

    /// The row range that keeps the selected row visible.
    private static func scrollWindow(selection: Int, count: Int, height: Int) -> Range<Int> {
        guard count > height else { return 0..<count }
        let start = min(max(0, selection - height / 2), count - height)
        return start..<(start + height)
    }
}
