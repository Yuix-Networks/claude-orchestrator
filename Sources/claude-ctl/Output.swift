import Foundation

/// Çıkış kodları.
public enum ExitCode {
    public static let success: Int32 = 0
    public static let runtime: Int32 = 1
    public static let usage: Int32 = 2
}

/// Konsol çıktısı ve hata yönetimi.
enum Output {
    static func error(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("hata: \(message)\n".utf8))
        exit(code)
    }

    static func line(_ text: String) {
        print(text)
    }

    static func json(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }
}
