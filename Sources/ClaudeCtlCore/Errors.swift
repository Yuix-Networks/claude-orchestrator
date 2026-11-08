import Foundation

/// `claude-ctl` hata tipleri.
///
/// `usage` → exit code 2, diğerleri → exit code 1.
public enum ClaudeCtlError: Error, Equatable {
    /// Kullanım hatası: yanlış komut, eksik argüman, geçersiz ad.
    case usage(String)
    /// Çalışma hatası: dosya yok, süreç başlatılamadı, kilitli profil vb.
    case runtime(String)
    /// Aranan instance tanımı yok.
    case notFound(String)
    /// Instance adı biçim kurallarına uymuyor.
    case invalidName(String)
    /// `config.json` okunamadı veya bozuk.
    case corruptConfig(URL)
}

extension ClaudeCtlError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .usage(message),
             let .runtime(message),
             let .notFound(message),
             let .invalidName(message):
            return message
        case let .corruptConfig(url):
            return "config bozuk: \(url.path)"
        }
    }
}
