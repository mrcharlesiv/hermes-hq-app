// What the Bots list says when it has no rows (docs/spec/3x-morepages.md §6). The rule is pure so every stream's
// empty states live in one table; the page draws them.

import Foundation

nonisolated enum BotListEmpty: Equatable, Sendable {
    case none
    case noBots
    case offline(String)
    case search
    case filtered
    /// Every bot is hidden and the Hidden section is folded (`S/ui-bots/roster-empty.tsx:18-19`).
    case allHidden

    static let allHiddenSymbol = "eye.slash"
    static let allHiddenTitle = "All Bots Are Hidden"
    static let allHiddenText = "Hidden bots keep working; they just aren’t listed."
    static let allHiddenButton = "Show Hidden Bots"
}

nonisolated extension BotList {
    /// `rows` = bots and group chats listed; `hidden` of the bots; `matches` = rows a search or filter found.
    /// `offline` = why the roster can't load, when it can't and there is nothing saved.
    static func emptyState(bots: Int, hidden: Int, rooms: Int = 0, query: String, filtered: Bool, hiddenShown: Bool,
                           matches: Int = 0, offline: String? = nil) -> BotListEmpty {
        if !query.isEmpty { return matches == 0 ? .search : .none }
        if filtered { return matches == 0 ? .filtered : .none }
        if bots == 0, rooms == 0 { return offline.map { .offline($0) } ?? .noBots }
        if bots > 0, hidden == bots, rooms == 0, !hiddenShown { return .allHidden }
        return .none
    }
}
