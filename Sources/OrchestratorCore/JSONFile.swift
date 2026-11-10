import Foundation

/// Atomic JSON read/write helpers.
///
/// Dates are stored as ISO-8601 (`2026-11-08T10:00:00Z`) so that `config.json`
/// stays easy to read and edit by hand.
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

    /// Reads the file. Returns `nil` if it doesn't exist; throws `corruptConfig` if it is unreadable or corrupt.
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try makeDecoder().decode(type, from: data)
        } catch {
            throw OrchestratorError.corruptConfig(url)
        }
    }

    /// Writes the file atomically, creating parent directories as needed.
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
            throw OrchestratorError.runtime("couldn't write \(url.path) — \(error.localizedDescription)")
        }
    }
}
