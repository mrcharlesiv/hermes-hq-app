// [groups] Where rooms go in the Bots list (docs/spec/3x-groups.md §7.1, §7.9, §7.11): pinned rooms as tiles after
// the bots' tiles, then the Group Chats block — rooms in no section first, then one sub-block per user section that
// holds rooms (an empty one only while a room is being dragged). Also the Show › filter. Pure.

import Foundation

/// Filter › Show (`S/ui-bots/roster-filters.ts:12-18`), for this session.
nonisolated enum BotKindFilter: String, CaseIterable, Sendable {
    case all, bots, groups

    var title: String {
        switch self {
        case .all: "All"
        case .bots: "Bots"
        case .groups: "Group Chats"
        }
    }
}

extension BotActivityFilter {
    /// A room under Activity (`HB/row-helpers.ts`): Active Now = a round is running; Recently Active = a message in the
    /// last 7 days; Older = none.
    nonisolated func matches(_ room: GroupRowModel, now: Date = Date()) -> Bool {
        switch self {
        case .all: return true
        case .active: return room.running
        case .recent, .older:
            let recent = room.lastAt > 0 && now.timeIntervalSince1970 - room.lastAt / 1000 <= BotsBar.recentWindow
            return self == .recent ? recent : !recent
        }
    }
}

extension BotsBar {
    // [filters-only] Filter is always on the bar (owner 2026-11-03), so a room or Show › no longer has to keep it there.

    /// The token under the bar: the active filters joined in the web's order ("Group Chats · Active Now").
    nonisolated static func token(kind: BotKindFilter, activity: BotActivityFilter) -> String? {
        let parts = [kind == .all ? nil : kind.title, token(activity: activity)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    nonisolated static func filtersActive(kind: BotKindFilter, activity: BotActivityFilter) -> Bool { kind != .all || activity != .all }
}

nonisolated enum GroupList {
    struct Filed: Equatable, Sendable {
        var id: String
        var name: String
        var rooms: [GroupRowModel]
        /// An empty section shown as a drop target while a room is dragged.
        var hint: Bool
    }

    struct Plan: Equatable, Sendable {
        var tiles: [GroupRowModel] = []
        /// Directly under the Group Chats header: pins the grid could not take first, then rooms in no section.
        var loose: [GroupRowModel] = []
        /// The pins the grid could not take (also first in `loose`). With user sections they join the Pinned section,
        /// as a bot's pin past the six does, instead of landing in Unassigned (audit 05-6).
        var overflow: [GroupRowModel] = []
        var filed: [Filed] = []
        /// Hidden rooms (UX study #254): under Hidden, after the hidden bots.
        var hidden: [GroupRowModel] = []
        /// The header's count: every room of the block.
        var count: Int { loose.count + filed.reduce(0) { $0 + $1.rooms.count } }
        var isEmpty: Bool { tiles.isEmpty && loose.isEmpty && filed.isEmpty }
    }

    /// By the user's order when set, else newest message first; names break ties.
    static func sorted(_ rooms: [GroupRowModel]) -> [GroupRowModel] {
        rooms.sorted { a, b in
            switch (a.order, b.order) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            if a.lastAt != b.lastAt { return a.lastAt > b.lastAt }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// `freeTiles`: slots the bots' tiles left in the grid. `sections`: the device's user sections, in order.
    static func plan(_ rooms: [GroupRowModel], freeTiles: Int, sections: [(id: String, name: String)], draggingRoom: Bool) -> Plan {
        var plan = Plan()
        plan.hidden = sorted(rooms.filter(\.hidden))
        let rooms = rooms.filter { !$0.hidden }
        let pinned = rooms.filter(\.pinned).sorted { ($0.pinnedAt ?? 0, $0.name) < ($1.pinnedAt ?? 0, $1.name) }
        plan.tiles = Array(pinned.prefix(max(0, freeTiles)))
        let overflow = Array(pinned.dropFirst(max(0, freeTiles)))
        plan.overflow = overflow
        let rest = sorted(rooms.filter { !$0.pinned })
        let known = Set(sections.map(\.id))
        // A room whose section was deleted shows in "no section" again.
        plan.loose = overflow + rest.filter { $0.sectionId.map { !known.contains($0) } ?? true }
        for section in sections {
            let members = rest.filter { $0.sectionId == section.id }
            if !members.isEmpty || draggingRoom {
                plan.filed.append(Filed(id: section.id, name: section.name, rooms: members, hint: members.isEmpty))
            }
        }
        return plan
    }

    /// Search (the room's name and its members' names) and Activity, in list order.
    static func results(_ rooms: [GroupRowModel], query: String, activity: BotActivityFilter, now: Date = Date()) -> [GroupRowModel] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return sorted(rooms).filter { room in
            activity.matches(room, now: now) && words.allSatisfy { room.search.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Where a dragged room may drop (§7.11): the Group Chats header clears its section; a room sub-block files it.
    /// [bots-groupby] A user section files it and Unassigned clears it (rooms and bots share sections now); the tiles,
    /// Pinned and Hidden refuse it. nil = not a target.
    enum Drop: Equatable, Sendable { case section(String?) }

    static func drop(room: Bool, over section: BotListSectionID?) -> Drop? {
        guard room else { return nil }
        switch section {
        case .groups?: return .section(nil)
        case .groupSection(let id)?: return .section(id)
        // [bots-groupby] With sections, rooms are filed among the bots: a section files it, Unassigned unfiles it.
        case .user(let id)?: return .section(id)
        case .unassigned?: return .section(nil)
        default: return nil
        }
    }

    static let dropHint = "Drop a group chat here."
}
