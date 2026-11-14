import Foundation

public enum ExitCause: String, Codable, Equatable {
    /// claude-orchestrator closed it (stop, restart, sign-in, session move).
    case orchestratorStop
    /// Claude ran its normal quit cleanup: the menu's Quit, or a SIGTERM from outside.
    case gracefulQuit
    /// A crash report was written.
    case crash
    /// Gone without quit cleanup and without a crash report: SIGKILL, force quit, power loss.
    case abrupt
}

public struct ExitDiagnosis: Equatable {
    public var cause: ExitCause
    public var detail: String
}

/// Works out *why* an instance's main process disappeared, from the evidence on disk.
public struct ExitDiagnoser {
    private let paths: Paths
    private let logReader: LogReader
    private let actions: ActionJournal
    private let diagnosticReports: URL

    public init(
        paths: Paths,
        logReader: LogReader = LogReader(),
        diagnosticReports: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DiagnosticReports")
    ) {
        self.paths = paths
        self.logReader = logReader
        self.actions = ActionJournal(paths: paths)
        self.diagnosticReports = diagnosticReports
    }

    /// - Parameters:
    ///   - lastSeen: the last sample in which the process was still there.
    ///   - now: the first sample in which it was gone.
    ///   - crowded: other instances exited in the same sample, so the shared log is ambiguous.
    public func diagnose(instance: String, lastSeen: Date, now: Date, crowded: Bool = false) -> ExitDiagnosis {
        let from = lastSeen.addingTimeInterval(-3)
        let until = now.addingTimeInterval(3)

        if let action = actions.records(since: from)
            .last(where: { $0.instance == instance && $0.time <= until && ["stop", "restart"].contains($0.action) }) {
            return ExitDiagnosis(cause: .orchestratorStop, detail: "claude-orchestrator \(action.action): \(action.via)")
        }

        if let report = crashEvidence(instance: instance, since: from) {
            return ExitDiagnosis(cause: .crash, detail: "crash report \(report)")
        }

        let quitLines = logReader.lines(since: from, limit: 0).filter {
            $0.contains("beforeQuit: handler fired") || $0.contains("Running onQuitCleanup")
        }
        if !quitLines.isEmpty {
            let note = crowded ? " (log is shared and several instances exited together, so it may be another one's)" : ""
            return ExitDiagnosis(
                cause: .gracefulQuit,
                detail: "Claude ran its quit cleanup: someone chose Quit or sent SIGTERM; it was not a crash\(note)"
            )
        }

        return ExitDiagnosis(
            cause: .abrupt,
            detail: "no quit cleanup in the log and no crash report: killed (SIGKILL / force quit) or the machine lost power"
        )
    }

    private func crashEvidence(instance: String, since: Date) -> String? {
        let fileManager = FileManager.default
        let profile = paths.profileDir(instance)
        let directories = [
            profile.appendingPathComponent("Crashpad/completed"),
            profile.appendingPathComponent("Crashpad/pending"),
            diagnosticReports
        ]
        for directory in directories {
            let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names {
                if directory == diagnosticReports, !name.hasPrefix("Claude") { continue }
                let url = directory.appendingPathComponent(name)
                if let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                   modified >= since {
                    return url.path
                }
            }
        }
        return nil
    }
}
