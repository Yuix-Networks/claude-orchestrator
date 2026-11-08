import Foundation

/// Claude'un paylaşılan log dosyasını okur.
///
/// Loglar tüm instance'lar arasında paylaşılır (`~/Library/Logs/Claude/main.log`),
/// bu yüzden filtreleme instance'ın başlangıç zamanı ve pid'i ile yapılır.
public struct LogReader {
    public static let defaultLogDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Claude")

    public let logDirectory: URL

    public init(logDirectory: URL = LogReader.defaultLogDirectory) {
        self.logDirectory = logDirectory
    }

    /// Log satırlarını filtreler.
    ///
    /// - Parameters:
    ///   - since: Bu tarihten eski satırlar elenir (zaman damgası olmayan satırlar elenmez).
    ///   - pid: Verilirse yalnızca bu sürece ait satırlar (`electron_main:<pid>`) döner.
    ///   - limit: En fazla bu kadar satır (en yeniler).
    public func lines(since: Date, pid: Int32? = nil, limit: Int = 50) -> [String] {
        let url = logDirectory.appendingPathComponent("main.log")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var result: [String] = []
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty { continue }

            if let timestamp = formatter.date(from: String(line.prefix(19))), timestamp < since {
                continue
            }
            if let pid, !line.contains("electron_main:\(pid)") {
                continue
            }
            result.append(line)
        }

        guard limit > 0 else { return result }
        return Array(result.suffix(limit))
    }
}
