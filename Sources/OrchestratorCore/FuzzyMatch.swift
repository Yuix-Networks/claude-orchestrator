import Foundation

/// fzf benzeri bulanık eşleştirme.
///
/// Sorgu boşluklarla parçalara ayrılır; her parça adayda sırayla (ardışık
/// olması gerekmeden) geçmelidir. Ardışık eşleşmeler, kelime başları ve
/// metnin başı ödüllendirilir; aradaki boşluklar cezalandırılır. Büyük/küçük
/// harf ve aksanlar yok sayılır (`ı`/`İ` dahil: "anahtar" → "ANAHTARLARI").
public enum FuzzyMatch {
    public struct Result: Equatable {
        public var score: Int
        /// Adayda eşleşen karakterlerin konumları (`Character` dizisindeki sıra).
        public var positions: [Int]
    }

    /// `nil` → eşleşme yok. Boş sorgu her adayla 0 puanla eşleşir.
    public static func match(_ query: String, in candidate: String) -> Result? {
        let tokens = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        guard !tokens.isEmpty else { return Result(score: 0, positions: []) }

        let text = candidate.map { fold(String($0)) }
        var total = 0
        var positions = Set<Int>()
        for token in tokens {
            guard let result = bestMatch(Array(token), in: text) else { return nil }
            total += result.score
            positions.formUnion(result.positions)
        }
        return Result(score: total, positions: positions.sorted())
    }

    /// Adayları puana göre sıralar (eşit puanda özgün sıra korunur).
    public static func filter<T>(_ items: [T], query: String, text: (T) -> String) -> [(item: T, result: Result)] {
        items.enumerated()
            .compactMap { offset, item in match(query, in: text(item)).map { (offset, item, $0) } }
            .sorted { $0.2.score != $1.2.score ? $0.2.score > $1.2.score : $0.0 < $1.0 }
            .map { ($0.1, $0.2) }
    }

    // MARK: - İç ayrıntılar

    /// Karşılaştırma için normalleştirir. Her karakter tek karakter kalır
    /// (konumlar özgün metinle hizalı olsun diye).
    static func fold(_ text: String) -> String {
        let mapped = text.replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "i")
        let folded = mapped.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded.count == text.count ? folded : text.lowercased()
    }

    private static let bonusConsecutive = 15
    private static let bonusWordStart = 10
    private static let bonusFirstChar = 8
    private static let scoreMatch = 16
    private static let penaltyGap = 1

    /// Tek parça için en iyi eşleşme (dinamik programlama; adaylar kısa).
    private static func bestMatch(_ token: [Character], in text: [String]) -> Result? {
        let n = token.count, m = text.count
        guard n > 0, n <= m else { return nil }
        let chars = text.map { $0.first ?? " " }

        // best[i][j]: token[0...i] eşleşmiş ve token[i] text[j]'de → en yüksek puan.
        var best = Array(repeating: Array(repeating: Int.min, count: m), count: n)
        var from = Array(repeating: Array(repeating: -1, count: m), count: n)

        func bonus(_ j: Int) -> Int {
            if j == 0 { return bonusFirstChar + bonusWordStart }
            let previous = chars[j - 1]
            return (previous.isLetter || previous.isNumber) ? 0 : bonusWordStart
        }

        for j in 0..<m where chars[j] == token[0] {
            best[0][j] = scoreMatch + bonus(j)
        }
        guard n > 1 else { return finish(best: best, from: from, n: n, m: m) }

        for i in 1..<n {
            // Önceki satırın j'ye kadarki en iyi değerini (boşluk cezasıyla) taşı.
            var runningBest = Int.min
            var runningIndex = -1
            for j in 0..<m {
                if j > 0, best[i - 1][j - 1] != Int.min {
                    // Ardışık: doğrudan bir önceki karakter.
                    if chars[j] == token[i] {
                        let consecutive = best[i - 1][j - 1] + scoreMatch + bonusConsecutive + bonus(j)
                        if consecutive > best[i][j] { best[i][j] = consecutive; from[i][j] = j - 1 }
                    }
                }
                if chars[j] == token[i], runningIndex >= 0 {
                    let gap = j - runningIndex - 1
                    let gapped = runningBest + scoreMatch + bonus(j) - gap * penaltyGap
                    if gapped > best[i][j] { best[i][j] = gapped; from[i][j] = runningIndex }
                }
                if best[i - 1][j] != Int.min,
                   runningIndex < 0 || best[i - 1][j] >= runningBest - (j - runningIndex) * penaltyGap {
                    runningBest = best[i - 1][j]
                    runningIndex = j
                }
            }
        }
        return finish(best: best, from: from, n: n, m: m)
    }

    private static func finish(best: [[Int]], from: [[Int]], n: Int, m: Int) -> Result? {
        var end = -1
        var score = Int.min
        for j in 0..<m where best[n - 1][j] > score {
            score = best[n - 1][j]
            end = j
        }
        guard end >= 0 else { return nil }
        var positions = [end]
        var j = end
        for i in stride(from: n - 1, to: 0, by: -1) {
            j = from[i][j]
            positions.append(j)
        }
        return Result(score: score, positions: positions.reversed())
    }
}
