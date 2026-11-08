import Foundation

/// Claude'un paylaşılan log dosyasını okur.
///
/// Loglar tüm instance'lar arasında paylaşılır (`~/Library/Logs/Claude/main.log`),
/// bu yüzden filtreleme instance'ın başlangıç zamanı ve pid'i ile yapılır.
public struct LogReader {
    public static let defaultLogDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Claude")

    /// Sondan okumada bir seferde okunan blok boyutu.
    static let chunkSize: UInt64 = 64 * 1024

    public let logDirectory: URL

    public init(logDirectory: URL = LogReader.defaultLogDirectory) {
        self.logDirectory = logDirectory
    }

    public var logFile: URL { logDirectory.appendingPathComponent("main.log") }

    /// Log satırlarını filtreler.
    ///
    /// Dosya sondan geriye doğru bloklar halinde okunur; `limit` kadar eşleşme
    /// bulunduğunda veya `since`'ten eski bir satıra ulaşıldığında okuma durur.
    /// Böylece büyük bir `main.log` tamamen belleğe alınmaz.
    ///
    /// - Parameters:
    ///   - since: Bu tarihten eski satırlar elenir (zaman damgası olmayan satırlar elenmez).
    ///   - pid: Verilirse yalnızca bu sürece ait satırlar (`electron_main:<pid>`) döner.
    ///   - limit: En fazla bu kadar satır (en yeniler). `0` veya negatifse sınırsız.
    public func lines(since: Date, pid: Int32? = nil, limit: Int = 50) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: logFile) else { return [] }
        defer { try? handle.close() }

        let formatter = Self.makeFormatter()
        let fileSize = (try? handle.seekToEnd()) ?? 0

        var collected: [String] = []   // en yeniden eskiye
        var offset = fileSize
        var carry = Data()             // bir önceki bloğun başındaki yarım satır
        var reachedOlder = false

        while offset > 0, !reachedOlder, limit <= 0 || collected.count < limit {
            let readSize = min(Self.chunkSize, offset)
            offset -= readSize
            try? handle.seek(toOffset: offset)
            var block = (try? handle.read(upToCount: Int(readSize))) ?? Data()
            block.append(carry)

            var parts = block.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            // Dosyanın başına gelinmediyse ilk parça yarım satırdır; sonraki tura kalır.
            carry = offset > 0 ? Data(parts.removeFirst()) : Data()

            for part in parts.reversed() {
                guard let line = String(data: Data(part), encoding: .utf8), !line.isEmpty else { continue }
                if let timestamp = formatter.date(from: String(line.prefix(19))), timestamp < since {
                    reachedOlder = true
                    break
                }
                if let pid, !line.contains("electron_main:\(pid)") { continue }
                collected.append(line)
                if limit > 0, collected.count >= limit { break }
            }
        }

        return collected.reversed()
    }

    static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }
}

/// `logs -f` için log dosyası takipçisi.
///
/// Dosya döndürmeyi (rotation) algılar: dosyanın inode'u değişirse veya boyutu
/// son okunan konumun altına düşerse dosya baştan okunur. Böylece takip
/// sessizce durmaz.
public final class LogFollower {
    public let url: URL
    private var position: UInt64
    private var inode: UInt64?

    /// - Parameter fromEnd: `true` ise yalnızca bundan sonra yazılan satırlar döner.
    public init(url: URL, fromEnd: Bool = true) {
        self.url = url
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        position = fromEnd ? ((attributes?[.size] as? NSNumber)?.uint64Value ?? 0) : 0
    }

    /// Son çağrıdan beri eklenen tam satırlar.
    public func poll() -> [String] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            // Dosya döndürme sırasında geçici olarak yok olabilir.
            return []
        }
        let currentInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0

        if currentInode != inode || size < position {
            inode = currentInode
            position = 0
        }
        guard size > position, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        try? handle.seek(toOffset: position)
        let data = (try? handle.read(upToCount: Int(size - position))) ?? Data()
        // Yalnızca tamamlanmış satırlar tüketilir; yarım satır sonraki tura kalır.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let complete = data[data.startIndex...lastNewline]
        position += UInt64(complete.count)

        return String(decoding: complete, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }
}
