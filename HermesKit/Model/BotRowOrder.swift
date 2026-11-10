// [manualorder] The Bots rows in the owner's own order (tester, 2026-10-29: "a 'manual sort' option"):
// Filter › Sort By › Manual, a row dragged to a new place, or a row's Move Up / Move Down. Kept on this device per
// account (`BotDeviceState.rowOrder`, profile names, top row first; nil is Sort By › Recent Activity), as the desktop
// keeps its sidebar's (`D/app/chat/sidebar/order.ts` orderByIds, `D/store/layout.ts` setSidebarOrdering). Every block
// (Pinned, each section, the unassigned rows, Hidden) draws its rows in the order's sequence; the tiles keep their own
// (`PinOrder`). Pure.

import Foundation

nonisolated enum BotRowOrder {
    /// `rows` (one block, in activity order) in the sequence `ids` names. A row the order doesn't name folds in by
    /// position (`orderByIds`): ahead of the block's first named row in activity order (newer or busier than it) it
    /// goes on top, else below the named ones. Duplicates draw once.
    static func ordered<T>(_ rows: [T], by ids: [String], id: (T) -> String) -> [T] {
        guard !ids.isEmpty, !rows.isEmpty else { return rows }
        var byId: [String: T] = [:]
        for row in rows where byId[id(row)] == nil { byId[id(row)] = row }
        var seen = Set<String>()
        var named: [T] = []
        for key in ids {
            guard let row = byId[key], seen.insert(key).inserted else { continue }
            named.append(row)
        }
        let firstNamed = rows.firstIndex { seen.contains(id($0)) }
        var newer: [T] = [], older: [T] = []
        for (index, row) in rows.enumerated() {
            guard seen.insert(id(row)).inserted else { continue }
            if let firstNamed, index < firstNamed { newer.append(row) } else { older.append(row) }
        }
        return newer + named + older
    }

    static func ordered(_ bots: [Bot], by ids: [String]) -> [Bot] { ordered(bots, by: ids, id: \.id) }

    /// The saved order once a block's rows read `rows` (top first, after a drop or a Move Up): they fill the places
    /// they held in it, so every other block keeps its own sequence; a name the order lacked (a bot dropped in from
    /// another block it never had a place in) is added at the end first. Duplicates in `saved` are dropped.
    static func placed(_ rows: [String], in saved: [String]) -> [String] {
        var seen = Set<String>()
        var next = saved.filter { seen.insert($0).inserted }
        for key in rows where seen.insert(key).inserted { next.append(key) }
        var unique = Set<String>()
        var queue = rows.filter { unique.insert($0).inserted }[...]   // one place each
        return next.map { key in unique.contains(key) ? (queue.popFirst() ?? key) : key }
    }

    /// The order kept for the next launch: names of bots that no longer exist dropped, and a row on show it didn't name
    /// (`blocks`: each block's rows top first, as `ordered` drew them) added where it landed, after the row above it in
    /// its block, else before the one below. Rows it names keep their places (a bot drawn in its old block for a moment,
    /// while the write that files it elsewhere is out, keeps the place its drop gave it). A pinned tile keeps its place
    /// for when it comes back as a row.
    static func reconciled(_ saved: [String], blocks: [[String]], existing: Set<String>) -> [String] {
        var seen = Set<String>()
        var next = saved.filter { existing.contains($0) && seen.insert($0).inserted }
        for rows in blocks {
            for (index, key) in rows.enumerated() where !seen.contains(key) {
                if let above = rows[..<index].last(where: { seen.contains($0) }), let at = next.firstIndex(of: above) {
                    next.insert(key, at: at + 1)
                } else if let below = rows[(index + 1)...].first(where: { seen.contains($0) }), let at = next.firstIndex(of: below) {
                    next.insert(key, at: at)
                } else {
                    next.append(key)
                }
                seen.insert(key)
            }
        }
        return next
    }

    /// Move Up (-1) and Move Down (+1) for a row at `index` of a block's `count`, each only with a neighbour there.
    static func moves(index: Int?, count: Int) -> [Int] {
        guard let index, (0..<count).contains(index) else { return [] }
        return [-1, 1].filter { (0..<count).contains(index + $0) }
    }

    static func moveTitle(_ delta: Int) -> String { delta < 0 ? "Move Up" : "Move Down" }
}
