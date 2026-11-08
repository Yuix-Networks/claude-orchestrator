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

    /// JSON çıktılarının şema sürümü. Alan silme/yeniden adlandırma gibi
    /// kırıcı değişikliklerde artırılır; yeni alan eklemek artırmayı gerektirmez.
    static let schemaVersion = 1

    /// Nesneyi JSON olarak yazar; `schemaVersion` alanı her çıktıya eklenir.
    static func json(_ value: [String: Any]) {
        var value = value
        if value["schemaVersion"] == nil { value["schemaVersion"] = schemaVersion }
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }
}

/// Etkileşimli onay.
enum Confirm {
    /// Terminalde evet/hayır sorar. Terminal yoksa (betik, boru) onay
    /// varsayılmaz: `--yes` zorunlu olduğu bildirilir.
    static func ask(_ prompt: String) -> Bool {
        guard isatty(STDIN_FILENO) != 0 else {
            Output.error("\(prompt)\nonay için terminal yok — devam etmek için --yes ekle", code: ExitCode.usage)
        }
        FileHandle.standardError.write(Data("\(prompt)\nDevam edilsin mi? [e/H] ".utf8))
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return ["e", "evet", "y", "yes"].contains(answer)
    }
}

/// v0.1.0'daki eski komut adı (geriye dönük uyumluluk bağı).
enum LegacyName {
    static let command = "claude-ctl"
}

/// Sürüm (release etiketiyle aynı tutulur: `v<current>`).
enum AppVersion {
    static let current = "0.2.1"
}
