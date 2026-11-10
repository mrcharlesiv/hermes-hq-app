// The Bots bar's filter state (`S/ui-bots/filter-token.ts`, `roster-filters.ts`; `HB/roster-pane-derivation.ts`):
// the Activity choices, what a filter keeps, and the token under the bar. Pure. Show › (Bots / Group Chats) waits for
// group chats on the phone. [filters-only] Filter is always on the bar and holds filters only (owner 2026-11-03): the
// gateway in use is switched from the title (this list shows one gateway at a time).

import Foundation

nonisolated enum BotActivityFilter: String, CaseIterable, Sendable {
    case all, active, recent, older

    var title: String {
        switch self {
        case .all: "Any Time"
        case .active: "Active Now"
        case .recent: "Recently Active"
        case .older: "Older"
        }
    }

    /// `HB/row-helpers.ts` `rosterActivityMatches`: Active Now is a bot working now; Recently Active, a message in the
    /// last 7 days; Older, none.
    func matches(_ bot: Bot, now: Date = Date()) -> Bool {
        switch self {
        case .all: return true
        case .active: return bot.isWorking
        case .recent, .older:
            let recent = bot.lastActive.map { now.timeIntervalSince($0) <= BotsBar.recentWindow } ?? false
            return self == .recent ? recent : !recent
        }
    }
}

/// [manualorder] Filter › Sort By: Recent Activity (the default: pinned, then the newest activity first) or Manual (the
/// owner's order, `BotRowOrder`; a row dragged to a new place picks it, as on the desktop).
nonisolated enum BotSortOrder: String, CaseIterable, Sendable {
    case recent, manual

    var title: String { self == .recent ? "Recent Activity" : "Manual" }
}

/// [bots-groupby] Filter › Group By (tester 2026-11-05: "if I want to quickly sort all bots by activity I can just turn
/// off section groupings"): Sections (the user's sections, then Unassigned) or None (one list, newest activity first).
/// Kept on this device.
nonisolated enum BotGroupBy: String, CaseIterable, Sendable {
    case sections, none

    var title: String { self == .sections ? "Sections" : "None" }

    static let key = "hq.bots.groupBy"
    static var saved: BotGroupBy {
        get { UserDefaults.standard.string(forKey: key).flatMap(BotGroupBy.init(rawValue:)) ?? .sections }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// [pinned-rows] Filter › Pinned Bots (owner 2026-11-08): Faces (up to six faces with their names over the list, the
/// rest under a Pinned header) or Rows (every pin a row like the others at the top of the list, no header, dragged
/// into its own order). Both keep one order of pins (`PinOrder`). Kept on this device.
nonisolated enum BotPinnedLook: String, CaseIterable, Sendable {
    case faces, rows

    var title: String { self == .faces ? "Faces" : "Rows" }
    var subtitle: String { self == .faces ? "Faces and names at the top" : "Rows at the top, like the others" }

    static let key = "hq.bots.pinnedLook"
    static var saved: BotPinnedLook {
        get { UserDefaults.standard.string(forKey: key).flatMap(BotPinnedLook.init(rawValue:)) ?? .faces }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

nonisolated enum BotsBar {
    // [filters-only] No `filterShown` any more: the web's BOT_ROSTER_SEARCH_THRESHOLD (8 bots, a second gateway or a
    // hidden bot) hid Filter, and with it Sort By › Manual, from a short list. Filter is always on the bar now.
    static let recentWindow: TimeInterval = 7 * 24 * 60 * 60

    /// What the token under the bar names; nil when nothing filters.
    static func token(activity: BotActivityFilter) -> String? {
        activity == .all ? nil : activity.title
    }

    /// The rows a search or a filter shows, in list order. A search finds hidden bots too (as before); a filter alone
    /// shows them only while Show Hidden Bots is on.
    static func results(_ bots: [Bot], query: String, activity: BotActivityFilter, showHidden: Bool, now: Date = Date()) -> [Bot] {
        let base = query.isEmpty ? BotList.sorted(bots) : BotList.search(bots, query: query)
        return base.filter { (showHidden || !query.isEmpty || !$0.hidden) && activity.matches($0, now: now) }
    }
}
