import ClaudeCtlCore
import Foundation

/// `claude-ctl logs <ad> [-n N] [-f]`
enum LogsCommand {
    static func run(_ args: [String]) throws {
        let parsed = try Arguments(args, allowed: ["lines", "follow"])
        let name = try parsed.requirePositional(0, name: "instance adı", command: "logs")
        let limit = Int(parsed.optionalFlag("lines") ?? "50") ?? 50
        let ctl = ClaudeCtl()

        for line in try ctl.logs(name: name, lines: limit) {
            Output.line(line)
        }

        guard parsed.has("follow") else { return }

        // Canlı takip: yeni satırları yazdır.
        let logFile = LogReader.defaultLogDirectory.appendingPathComponent("main.log")
        var position = (try? FileManager.default.attributesOfItem(atPath: logFile.path)[.size] as? Int64) ?? 0
        while true {
            Thread.sleep(forTimeInterval: 1)
            guard let size = try? FileManager.default.attributesOfItem(atPath: logFile.path)[.size] as? Int64, size > position else {
                continue
            }
            if let handle = try? FileHandle(forReadingFrom: logFile) {
                handle.seek(toFileOffset: UInt64(position))
                let data = handle.readDataToEndOfFile()
                position = size
                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    Output.line(text.trimmingCharacters(in: .newlines))
                }
                try? handle.close()
            }
        }
    }
}
