import OrchestratorCore
import Foundation

/// Argümansız `claude-orchestrator`: profil listesi → profil eylemleri,
/// listenin altında "New profile".
enum HomeInteractive {
    static func run() throws {
        let ctl = Orchestrator()
        var message: Message?
        var focus: String?

        while true {
            guard let ui = TerminalUI() else {
                throw OrchestratorError.usage("komut gerekli (yardım: claude-orchestrator help)")
            }
            // Ekranlar terminal kipini bırakması gereken bir eylemle döner
            // (giriş, oturum taşıma); o eylem ana ekranda çalışır.
            let next = home(ctl: ctl, ui: ui, message: &message, focus: &focus)
            ui.restore()

            switch next {
            case .quit:
                return
            case let .signIn(name):
                runOutside { try SigninCommand.run([name, "--exclusive"]) }
                focus = name
            case let .moveSession(name):
                runOutside {
                    try SessionMoveInteractive.run(id: nil, from: name, to: nil, assumeYes: false)
                }
                focus = name
            }
            message = nil
        }
    }

    private enum Exit {
        case quit
        case signIn(String)
        case moveSession(String)
    }

    private struct Message {
        var text: String
        var isError: Bool
    }

    /// Terminal kipinde çalışan bir eylem; bitince Enter beklenir.
    private static func runOutside(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
        }
        FileHandle.standardError.write(Data("\nPress Enter to return to the menu… ".utf8))
        _ = readLine()
    }

    // MARK: - Ana ekran

    private static func home(ctl: Orchestrator, ui: TerminalUI, message: inout Message?, focus: inout String?) -> Exit {
        while true {
            let profiles = (try? ctl.list(includeSizes: false)) ?? []
            let newRow = profiles.count
            var picker = PickerModel(items: profiles.map(\.name) + ["New profile"], searchable: false)
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

            if index == newRow {
                if let created = newProfile(ctl: ctl, ui: ui) {
                    focus = created
                    message = Message(text: "Created profile \(display(created)).", isError: false)
                    // Yeni profil hemen eylem ekranında açılır (başlat / giriş).
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
        if let message {
            lines.append("")
            lines.append((message.isError ? Style.warning : Style.dim) + message.text + Style.reset)
        }
        return lines
    }

    // MARK: - Profil eylemleri

    private enum Action: String {
        case start = "Start"
        case stop = "Stop"
        case restart = "Restart"
        case logIn = "Log in"
        case moveSession = "Move a session…"
        case back = "Back"
    }

    /// `nil` → ana ekrana dön; aksi halde terminal kipinde çalışacak eylem.
    private static func profileMenu(_ name: String, ctl: Orchestrator, ui: TerminalUI, message: inout Message?) -> Exit? {
        while true {
            guard let status = try? ctl.status(name: name) else { return nil }
            // Giriş yapılmamış profilde yapılabilecek tek anlamlı şey giriş
            // (başlatmayı da giriş akışı yapar); diğer eylemler girişten sonra çıkar.
            let actions: [Action] = status.accountSignedIn
                ? (status.isRunning ? [.stop, .restart] : [.start]) + [.logIn, .moveSession, .back]
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
            case .logIn:
                // Giriş sırasında diğer çalışan instance'lar kapatılır.
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
            case .moveSession:
                return .moveSession(name)
            }
        }
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

    /// Kısa eylemler ekranda çalışır; sonuç ana/eylem ekranında mesaj olur.
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

    // MARK: - Yeni profil

    /// Oluşturulan profilin adı; vazgeçilirse `nil`.
    private static func newProfile(ctl: Orchestrator, ui: TerminalUI) -> String? {
        var name = ""
        var problem: String?
        let prompt = "Name: "
        while true {
            var lines = [
                Style.bold + "New profile" + Style.reset,
                Style.dim + "Lowercase letters, digits and hyphens. Enter to create, Esc to cancel." + Style.reset,
                "",
                prompt + name
            ]
            if let problem {
                lines.append("")
                lines.append(Style.warning + problem + Style.reset)
            }
            ui.draw(lines, cursor: (row: 3, column: prompt.count + name.count))

            switch ui.readKey() {
            case let .character(character):
                name.append(character)
                problem = nil
            case .backspace:
                if !name.isEmpty { name.removeLast() }
                problem = nil
            case .clearQuery:
                name = ""
            case .enter:
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else {
                    problem = "Enter a name."
                    continue
                }
                do {
                    _ = try ctl.new(name: trimmed, workdir: nil)
                    return trimmed
                } catch {
                    problem = "\(error)"
                    continue
                }
            case .escape, .interrupt:
                return nil
            default:
                continue
            }
        }
    }

    // MARK: - Yardımcılar

    /// Bu terminal, kapatılacak instance'lardan birinin içinde mi çalışıyor?
    /// (Code sekmesi terminali, Claude Code aracı.) Öyleyse kapanış bu komutu
    /// da sonlandırır.
    private static func hostBlocker(ctl: Orchestrator, stopping names: [String]) -> String? {
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

    private static func display(_ name: String) -> String { SessionMoveInteractive.display(name) }
}
