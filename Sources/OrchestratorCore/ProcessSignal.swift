import Darwin
import Foundation

/// Process signals and liveness checks.
public enum ProcessSignal {
    /// Is the process still alive? (`false` for a dead process)
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    /// Graceful shutdown (SIGTERM).
    public static func terminate(_ pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
    }

    /// Forced shutdown (SIGKILL).
    public static func forceKill(_ pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
    }
}
