import Foundation

/// `claude-orchestrator` error types.
///
/// `usage` → exit code 2, everything else → exit code 1.
public enum OrchestratorError: Error, Equatable {
    /// Usage error: wrong command, missing argument, invalid name.
    case usage(String)
    /// Runtime error: missing file, process failed to start, locked profile, etc.
    case runtime(String)
    /// The requested instance is not defined.
    case notFound(String)
    /// The instance name doesn't follow the naming rules.
    case invalidName(String)
    /// `config.json` couldn't be read or is corrupt.
    case corruptConfig(URL)
}

extension OrchestratorError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .usage(message),
             let .runtime(message),
             let .notFound(message),
             let .invalidName(message):
            return message
        case let .corruptConfig(url):
            return "corrupt config: \(url.path)"
        }
    }
}
