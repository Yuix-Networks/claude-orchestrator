import OrchestratorCore
import Foundation

/// "Projects…" on the home screen: the registered projects (shown as
/// environments in every profile) and interactive versions of the `project`
/// subcommands.
///
/// Actions that write (add, remove, apply, sync, import) run through the
/// existing `ProjectCommand` functions in normal terminal mode; the screens only
/// collect input and confirmation, so behaviour and reports match the CLI.
enum ProjectsInteractive {
    typealias Exit = HomeInteractive.Exit
    typealias Message = HomeInteractive.Message

    private enum Entry: Equatable {
        case project(Int)
        case add, apply, export, sync, importFrom
    }

    /// `nil` → back to the home screen.
    static func run(ctl: Orchestrator, ui: TerminalUI) -> Exit? {
        var message: Message?
        var selection = 0
        while true {
            let projects = (try? ctl.projects()) ?? []
            // Computing the state reads the process list (~0.3 s): do it once per load, not on every key.
            let presence = projects.map { project in
                ((try? ctl.projectPresence(project)) ?? []).map { (instance: $0.instance, presence: $0.presence) }
            }
            let entries = projects.indices.map(Entry.project) + [.add, .apply, .export, .sync, .importFrom]
            var picker = PickerModel(items: entries.map { _ in "" }, searchable: false)
            for _ in 0..<min(selection, entries.count - 1) { _ = picker.handle(.down) }

            var chosen: Entry?
            while chosen == nil {
                ui.draw(listLines(projects, presence: presence, entries: entries, picker: picker, message: message, columns: ui.size.columns))
                switch picker.handle(ui.readKey()) {
                case let .select(index): chosen = entries[index]
                case .back, .cancel: return nil
                case .none: continue
                }
                message = nil
            }
            selection = picker.selection

            switch chosen! {
            case let .project(index):
                if let exit = projectMenu(projects[index], ctl: ctl, ui: ui) { return exit }
            case .add:
                if let exit = addProject(ui: ui) { return exit }
            case .apply:
                switch applyManifest(ctl: ctl, ui: ui) {
                case let .exit(exit): return exit
                case let .message(text): message = text
                case .none: break
                }
            case .export:
                message = exportManifest(ctl: ctl, ui: ui)
            case .sync:
                return .outside({ try ProjectCommand.sync([]) }, reopenProjects: true)
            case .importFrom:
                if let exit = importFrom(ctl: ctl, ui: ui) { return exit }
            }
        }
    }

    // MARK: - List

    private static func listLines(
        _ projects: [Project],
        presence: [[(instance: String, presence: ProjectPresence)]],
        entries: [Entry],
        picker: PickerModel,
        message: Message?,
        columns: Int
    ) -> [String] {
        let rule = Style.dim + String(repeating: "─", count: max(0, min(columns, 100) - 1)) + Style.reset
        var lines = [
            Style.bold + "Projects" + Style.reset
                + Style.dim + "  — shown as environments in every profile · ↑/↓, Enter, Esc to go back" + Style.reset,
            rule
        ]
        if projects.isEmpty {
            lines.append(Style.dim + "  No projects yet. Add one, apply a projects.json or import them from a profile." + Style.reset)
        }
        let nameWidth = min(28, max(12, (projects.map { $0.name.count }.max() ?? 0) + 2))
        for (row, entry) in entries.enumerated() {
            let marker = picker.selection == row ? Style.inverse + "❯ " : "  "
            switch entry {
            case let .project(index):
                let project = projects[index]
                let states = presence[index]
                    .map { "\($0.instance) \(ProjectCommand.symbol($0.presence))" }
                    .joined(separator: "  ")
                lines.append(
                    marker + project.name.fitted(nameWidth) + Style.reset
                        + SessionCommand.shortPath(project.path, width: 36).fitted(38)
                        + Style.dim + states + Style.reset
                )
            case .add:
                lines.append(rule)
                lines.append(marker + "+ Add project" + Style.reset)
            case .apply:
                lines.append(marker + "Apply a projects.json…" + Style.reset)
            case .export:
                lines.append(marker + "Export to a projects.json…" + Style.reset)
            case .sync:
                lines.append(marker + "Sync all profiles" + Style.reset)
            case .importFrom:
                lines.append(marker + "Import from a profile…" + Style.reset)
            }
        }
        if !projects.isEmpty {
            lines.append("")
            lines.append(Style.dim + "✓ in sync   ✗ missing (Sync all profiles)   … waiting for the first login" + Style.reset)
        }
        if let message {
            lines.append("")
            lines.append((message.isError ? Style.warning : Style.dim) + message.text + Style.reset)
        }
        return lines
    }

    // MARK: - Project details

    private static func projectMenu(_ project: Project, ctl: Orchestrator, ui: TerminalUI) -> Exit? {
        let actions = ["Remove…", "Back"]
        var picker = PickerModel(items: actions, searchable: false)
        let presence = (try? ctl.projectPresence(project)) ?? []
        while true {
            var lines = [
                Style.bold + project.name + Style.reset,
                Style.dim + "↑/↓ to choose, Enter to run, Esc to go back" + Style.reset,
                "",
                Style.dim + "Folder".fitted(16) + Style.reset + SessionCommand.shortPath(project.path, width: 70)
            ]
            for folder in project.additionalFolders {
                lines.append(Style.dim + "Extra folder".fitted(16) + Style.reset + SessionCommand.shortPath(folder, width: 70))
            }
            if let mode = project.permissionMode {
                lines.append(Style.dim + "Permission mode".fitted(16) + Style.reset + mode)
            }
            for entry in presence {
                let state: String
                switch entry.presence {
                case .synced: state = "✓ in sync"
                case .missing: state = "✗ missing"
                case .pendingSignIn: state = "… waiting for the first login"
                }
                lines.append(Style.dim + HomeInteractive.display(entry.instance).fitted(16) + Style.reset + state)
            }
            lines.append("")
            for (row, action) in actions.enumerated() {
                lines.append((picker.selection == row ? Style.inverse + "❯ " : "  ") + action + Style.reset)
            }
            ui.draw(lines)

            switch picker.handle(ui.readKey()) {
            case .select(0):
                let body = "\"\(project.name)\" is removed from the list and from the Code tab of every profile. "
                    + "The folder itself is not touched. A running profile shows the change after a restart."
                if confirm(ui: ui, title: "Remove \(project.name)?", body: body) {
                    return .outside({ try ProjectCommand.remove([project.name]) }, reopenProjects: true)
                }
            case .select, .back, .cancel:
                return nil
            case .none:
                continue
            }
        }
    }

    // MARK: - Add

    private static func addProject(ui: TerminalUI) -> Exit? {
        guard let rawPath = HomeInteractive.textInput(
            ui: ui,
            title: "Add project",
            hint: "The project folder (~ is fine). Enter to continue, Esc to cancel.",
            label: "Folder: ",
            submit: { text in
                guard !text.isEmpty else { return "Enter a folder." }
                var isDirectory: ObjCBool = false
                let path = expand(text)
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return "No such folder: \(path)"
                }
                return nil
            }
        ) else { return nil }
        let path = expand(rawPath)

        guard let name = HomeInteractive.textInput(
            ui: ui,
            title: "Add project",
            hint: "The name shown in Claude's Code tab. Enter to add, Esc to cancel.",
            label: "Name: ",
            initial: URL(fileURLWithPath: path).lastPathComponent,
            context: [Style.dim + "Folder  " + Style.reset + SessionCommand.shortPath(path, width: 70)],
            submit: { $0.isEmpty ? "Enter a name." : nil }
        ) else { return nil }

        return .outside({ try ProjectCommand.add([path, "--name", name]) }, reopenProjects: true)
    }

    // MARK: - projects.json

    private enum ApplyResult {
        case exit(Exit)
        case message(Message)
    }

    private static func applyManifest(ctl: Orchestrator, ui: TerminalUI) -> ApplyResult? {
        var plan: ProjectPlan?
        guard let rawPath = HomeInteractive.textInput(
            ui: ui,
            title: "Apply a projects.json",
            hint: "Adds, updates and renames projects to match the file. Enter to preview, Esc to cancel.",
            label: "File: ",
            initial: SessionCommand.shortPath(Orchestrator.defaultManifestURL.path, width: 200),
            submit: { text in
                do {
                    plan = try ctl.planApply(try Orchestrator.loadManifest(URL(fileURLWithPath: expand(text))), prune: true)
                    return nil
                } catch {
                    return "\(error)"
                }
            }
        ), let plan else { return nil }
        let path = expand(rawPath)

        // Removals (--prune) are a separate option: registered projects not in the file.
        let changes = plan.toAdd.count + plan.toUpdate.count + plan.toRename.count
        let removable = plan.toRemove
        if changes == 0, removable.isEmpty {
            return .message(Message(text: "Nothing to change — all \(plan.unchanged.count) projects match the file.", isError: false))
        }

        var preview: [String] = []
        for project in plan.toAdd { preview.append(Style.accent + "  + " + Style.reset + project.name + Style.dim + "  " + SessionCommand.shortPath(project.path, width: 50) + Style.reset) }
        for change in plan.toRename { preview.append(Style.warning + "  ~ " + Style.reset + "\(change.old.name) → \(change.new.name)") }
        for change in plan.toUpdate { preview.append(Style.warning + "  ~ " + Style.reset + change.new.name + Style.dim + "  " + ProjectCommand.describe(change) + Style.reset) }
        for project in removable { preview.append(Style.dim + "  - \(project.name)  (not in the file)" + Style.reset) }

        var options: [(label: String, prune: Bool)] = []
        if changes > 0 { options.append(("Apply changes", false)) }
        if !removable.isEmpty {
            options.append((changes > 0 ? "Apply and remove the \(removable.count) not in the file" : "Remove the \(removable.count) not in the file", true))
        }
        var picker = PickerModel(items: options.map(\.label) + ["Cancel"], searchable: false)
        while true {
            var lines = [
                Style.bold + "Apply \(SessionCommand.shortPath(path, width: 60))" + Style.reset,
                Style.dim + "↑/↓ to choose, Enter to run, Esc to cancel" + Style.reset,
                ""
            ] + preview + [""]
            for (row, label) in (options.map(\.label) + ["Cancel"]).enumerated() {
                lines.append((picker.selection == row ? Style.inverse + "❯ " : "  ") + label + Style.reset)
            }
            ui.draw(lines)
            switch picker.handle(ui.readKey()) {
            case let .select(index) where index < options.count:
                let arguments = [path] + (options[index].prune ? ["--prune"] : [])
                return .exit(.outside({ try ProjectCommand.applyManifest(arguments) }, reopenProjects: true))
            case .select, .back, .cancel:
                return nil
            case .none:
                continue
            }
        }
    }

    private static func exportManifest(ctl: Orchestrator, ui: TerminalUI) -> Message? {
        guard let rawPath = HomeInteractive.textInput(
            ui: ui,
            title: "Export to a projects.json",
            hint: "Writes the registered projects to a file you can edit and apply later. Enter to write, Esc to cancel.",
            label: "File: ",
            initial: SessionCommand.shortPath(Orchestrator.defaultManifestURL.path, width: 200),
            submit: { $0.isEmpty ? "Enter a file path." : nil }
        ) else { return nil }
        let url = URL(fileURLWithPath: expand(rawPath))

        if FileManager.default.fileExists(atPath: url.path),
           !confirm(ui: ui, title: "Overwrite \(SessionCommand.shortPath(url.path, width: 60))?",
                    body: "The file already exists and will be replaced.") {
            return nil
        }
        do {
            let text = try ctl.exportManifest()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            return Message(text: "Wrote \(SessionCommand.shortPath(url.path, width: 80)).", isError: false)
        } catch {
            return Message(text: "\(error)", isError: true)
        }
    }

    // MARK: - Import

    private static func importFrom(ctl: Orchestrator, ui: TerminalUI) -> Exit? {
        let sources = ((try? ctl.instanceEndpoints()) ?? []).map(\.name) + [SessionEndpoint.defaultName]
        var picker = PickerModel(items: sources, searchable: false)
        while true {
            var lines = [
                Style.bold + "Import projects" + Style.reset,
                Style.dim + "Registers the environments a profile already has. ↑/↓ to choose, Enter to import, Esc to go back" + Style.reset,
                ""
            ]
            for (row, source) in sources.enumerated() {
                let label = source == SessionEndpoint.defaultName
                    ? "Default Claude install" + Style.dim + "  (outside claude-orchestrator)" + Style.reset
                    : HomeInteractive.display(source)
                lines.append((picker.selection == row ? Style.inverse + "❯ " : "  ") + label + Style.reset)
            }
            ui.draw(lines)
            switch picker.handle(ui.readKey()) {
            case let .select(index):
                return .outside({ try ProjectCommand.importFrom(["--from", sources[index]]) }, reopenProjects: true)
            case .back, .cancel:
                return nil
            case .none:
                continue
            }
        }
    }

    // MARK: - Helpers

    /// `[y/N]` confirmation.
    private static func confirm(ui: TerminalUI, title: String, body: String) -> Bool {
        let lines = [Style.bold + title + Style.reset, ""]
            + body.wrapped(min(ui.size.columns - 2, 78))
            + ["", Style.bold + "Do you want to proceed? [y/N]" + Style.reset]
        while true {
            ui.draw(lines)
            switch ui.readKey() {
            case .character("y"), .character("Y"): return true
            case .character("n"), .character("N"), .enter, .escape, .interrupt: return false
            default: continue
            }
        }
    }

    private static func expand(_ path: String) -> String {
        ProjectCommand.manifestURL(path).standardizedFileURL.path
    }
}
