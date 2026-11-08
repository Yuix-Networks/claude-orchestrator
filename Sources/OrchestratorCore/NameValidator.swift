import Foundation

/// Instance adı doğrulama.
///
/// Ad, dosya sisteminde güvenle kullanılabilmeli: yol ayırıcı, `..` veya
/// boşluk içeremez; büyük harf ve Unicode kabul edilmez.
public enum NameValidator {
    /// `[a-z0-9][a-z0-9-]{0,31}` — 1-32 karakter, küçük harf/rakam/tire.
    public static let pattern = "^[a-z0-9][a-z0-9-]{0,31}\\z"

    /// Ad geçerli değilse `OrchestratorError.invalidName` fırlatır.
    public static func validate(_ name: String) throws {
        guard name.range(of: pattern, options: .regularExpression) != nil else {
            throw OrchestratorError.invalidName(
                "instance adı '\(name)' geçersiz: sadece küçük harf, rakam ve tire, 1-32 karakter"
            )
        }
    }

    /// Ad geçerli mi?
    public static func isValid(_ name: String) -> Bool {
        name.range(of: pattern, options: .regularExpression) != nil
    }
}
