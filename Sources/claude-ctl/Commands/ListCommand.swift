import ClaudeCtlCore
import Foundation

/// `claude-ctl list [--json]`
enum ListCommand {
    static func run(_ args: [String]) throws {
        let parsed = Arguments(args)
        let statuses = try ClaudeCtl().list()

        if parsed.has("json") {
            Output.json([
                "instances": statuses.map { status in
                    [
                        "name": status.name,
                        "workdir": status.workdir ?? NSNull(),
                        "isRunning": status.isRunning,
                        "pid": status.pid.map { Int($0) } ?? NSNull(),
                        "startedAt": status.startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                        "profileSizeBytes": String(status.profileSizeBytes),
                        "accountSignedIn": status.accountSignedIn
                    ] as [String: Any]
                }
            ])
            return
        }

        if statuses.isEmpty {
            Output.line("henüz instance yok — oluşturmak için: claude-ctl new <ad> --workdir <yol>")
            return
        }

        Output.line(pad("AD", 16) + pad("DURUM", 10) + pad("PID", 8) + "WORKDIR")
        for status in statuses {
            Output.line(
                pad(status.name, 16)
                + pad(status.isRunning ? "çalışıyor" : "durdu", 10)
                + pad(status.pid.map(String.init) ?? "-", 8)
                + (status.workdir ?? "-")
            )
        }
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }
}
