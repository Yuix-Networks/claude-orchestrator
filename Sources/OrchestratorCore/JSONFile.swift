import Foundation

/// Atomik JSON okuma/yazma yardımcıları.
///
/// Tarihler ISO-8601 (`2026-11-08T10:00:00Z`) olarak saklanır; `config.json`
/// kullanıcı tarafından elle de okunup düzenlenebilir kalsın diye.
public enum JSONFile {
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Dosyayı okur. Dosya yoksa `nil`; okunamaz/bozuksa `corruptConfig` hatası.
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try makeDecoder().decode(type, from: data)
        } catch {
            throw OrchestratorError.corruptConfig(url)
        }
    }

    /// Dosyayı yazar (üst dizinler gerekirse oluşturulur, yazma atomiktir).
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            let data = try makeEncoder().encode(value)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch let error as OrchestratorError {
            throw error
        } catch {
            throw OrchestratorError.runtime("yazılamadı: \(url.path) — \(error.localizedDescription)")
        }
    }
}
