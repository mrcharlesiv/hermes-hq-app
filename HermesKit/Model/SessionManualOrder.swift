// [manual-order] Hand-picked orders on the Sessions list (tester and the owner, Nous Discord 2026-10-29: "reorder
// the project", "favorite projects to keep some always at the top", "a manual sort option", "sort by profile"):
// Sort By Manual keeps the chats in the order they were dragged into; Group By Project and Group By Bot keep their
// groups in the order put there (hold a header › Move Up / Move Down, or Reorder…), favorite projects first. Pure.
//
// The desktop's rule (`V/app/chat/sidebar/order.ts` `orderByIds`): items the saved order does not know fold in by
// position. Ahead of the first known one (a chat started since, now the newest) they stay on top; behind it (an older
// page that just loaded) they sink below the hand-picked ones.

import Foundation

nonisolated enum SessionManualOrder {
    /// `items` (in their default order) laid out by `order`; unknown ids fold in by position, duplicates drawn once.
    static func ordered<T>(_ items: [T], id: (T) -> String, by order: [String]) -> [T] {
        guard !order.isEmpty, !items.isEmpty else { return items }
        var byId: [String: T] = [:]
        for item in items where byId[id(item)] == nil { byId[id(item)] = item }
        var seen = Set<String>()
        var known: [T] = []
        for key in order {
            guard let item = byId[key], seen.insert(key).inserted else { continue }
            known.append(item)
        }
        guard !known.isEmpty else { return items }
        let firstKnown = items.firstIndex { seen.contains(id($0)) } ?? 0
        var newer: [T] = [], older: [T] = []
        for (index, item) in items.enumerated() {
            let key = id(item)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            if index < firstKnown { newer.append(item) } else { older.append(item) }
        }
        return newer + known + older
    }

    /// The saved order after a run of `moved` (the ids as they now stand, a section's or a page's) was rearranged: the
    /// ids keep the places the moved ones held in `saved`, so ids not on screen (another group's, a page not loaded) stay
    /// where they were. Ids new to `saved` go where the first of the run stood (or first).
    static func merged(_ saved: [String], with moved: [String]) -> [String] {
        let run = Set(moved)
        var out: [String] = []
        var placed = false
        for key in saved {
            guard run.contains(key) else { out.append(key); continue }
            if !placed { out.append(contentsOf: moved); placed = true }
        }
        if !placed { out = moved + out }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// `ids` with the one at `from` moved to `to` (clamped).
    static func moved(_ ids: [String], from: Int, to: Int) -> [String] {
        guard ids.indices.contains(from) else { return ids }
        var ids = ids
        let id = ids.remove(at: from)
        ids.insert(id, at: max(0, min(to, ids.count)))
        return ids
    }

    /// Groups (project or bot groups, already in their default order) in the user's order, favorite projects first
    /// (in that same order). `key`: the group's project key or profile.
    static func groups(_ groups: [SessionGroup], key: (SessionGroup) -> String, order: [String], favorites: Set<String> = []) -> [SessionGroup] {
        let ordered = ordered(groups, id: key, by: order)
        guard !favorites.isEmpty else { return ordered }
        return ordered.filter { favorites.contains(key($0)) } + ordered.filter { !favorites.contains(key($0)) }
    }
}
