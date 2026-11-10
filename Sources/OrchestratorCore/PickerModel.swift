import Foundation

/// Keys sent to the terminal picker (terminal-independent).
public enum PickerKey: Equatable {
    case character(Character)
    case backspace
    /// Ctrl-U: clear the query.
    case clearQuery
    case up
    case down
    case pageUp
    case pageDown
    case enter
    /// Esc: go back to the previous screen.
    case escape
    /// Ctrl-C / Ctrl-D: cancel.
    case interrupt
}

/// What the picker wants done after a key press.
public enum PickerAction: Equatable {
    case none
    /// Index of the selected item in `items`.
    case select(Int)
    case back
    case cancel
}

/// A searchable, keyboard-driven list: state plus key handling.
///
/// Independent of drawing; the terminal layer just renders `visible` and
/// `selection`.
public struct PickerModel {
    /// Search texts (one per item).
    public let items: [String]
    /// If `false`, there is no query box (short lists, such as picking the target account).
    public let searchable: Bool
    public private(set) var query = ""
    /// Filtered items, sorted by score: `items` index plus matched positions.
    public private(set) var visible: [(index: Int, positions: [Int])] = []
    /// Selected row within `visible`.
    public private(set) var selection = 0
    /// Number of visible rows, used for paging.
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
            // Clear the query first; if it's already empty, go back.
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
