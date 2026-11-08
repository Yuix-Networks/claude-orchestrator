import Darwin
import Foundation

/// Süreç sinyalleri ve canlılık kontrolü.
public enum ProcessSignal {
    /// Süreç hâlâ var mı? (ölü süreç için `false`)
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    /// Nazik kapatma (SIGTERM).
    public static func terminate(_ pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
    }

    /// Zorla kapatma (SIGKILL).
    public static func forceKill(_ pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
    }
}
