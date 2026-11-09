import Foundation

/// Terminal seçicisine gelen tuşlar (terminalden bağımsız).
public enum PickerKey: Equatable {
    case character(Character)
    case backspace
    /// Ctrl-U: sorguyu temizle.
    case clearQuery
    case up
    case down
    case pageUp
    case pageDown
    case enter
    /// Esc: bir önceki ekrana dön.
    case escape
    /// Ctrl-C / Ctrl-D: iptal.
    case interrupt
}

/// Seçicinin bir tuştan sonra istediği eylem.
public enum PickerAction: Equatable {
    case none
    /// Seçilen öğenin `items` içindeki indeksi.
    case select(Int)
    case back
    case cancel
}

/// Aranabilir, klavyeyle gezilen liste: durum + tuş işleme.
///
/// Çizimden bağımsızdır; terminal katmanı yalnızca `visible` / `selection`
/// değerlerini çizer.
public struct PickerModel {
    /// Arama metinleri (öğe başına bir tane).
    public let items: [String]
    /// `true` ise sorgu kutusu yok (kısa listeler: hedef hesap seçimi).
    public let searchable: Bool
    public private(set) var query = ""
    /// Filtrelenmiş öğeler (puana göre sıralı): `items` indeksi + eşleşen konumlar.
    public private(set) var visible: [(index: Int, positions: [Int])] = []
    /// `visible` içindeki seçili satır.
    public private(set) var selection = 0
    /// Sayfa kaydırması için görünen satır sayısı.
    public var pageSize = 10

    public init(items: [String], searchable: Bool = true) {
        self.items = items
        self.searchable = searchable
        refilter()
    }

    public var selectedIndex: Int? {
        visible.indices.contains(selection) ? visible[selection].index : nil
    }

    public mutating func handle(_ key: PickerKey) -> PickerAction {
        switch key {
        case let .character(character):
            guard searchable else { return .none }
            query.append(character)
            refilter()
        case .backspace:
            guard searchable, !query.isEmpty else { return .none }
            query.removeLast()
            refilter()
        case .clearQuery:
            guard searchable, !query.isEmpty else { return .none }
            query = ""
            refilter()
        case .up:
            move(by: -1)
        case .down:
            move(by: 1)
        case .pageUp:
            move(by: -max(1, pageSize))
        case .pageDown:
            move(by: max(1, pageSize))
        case .enter:
            return selectedIndex.map(PickerAction.select) ?? .none
        case .escape:
            // Önce sorguyu temizle; boşsa geri dön.
            if searchable, !query.isEmpty {
                query = ""
                refilter()
                return .none
            }
            return .back
        case .interrupt:
            return .cancel
        }
        return .none
    }

    private mutating func move(by delta: Int) {
        guard !visible.isEmpty else { return }
        selection = min(max(selection + delta, 0), visible.count - 1)
    }

    private mutating func refilter() {
        visible = FuzzyMatch.filter(Array(items.indices), query: query) { items[$0] }
            .map { (index: $0.item, positions: $0.result.positions) }
        selection = 0
    }
}
