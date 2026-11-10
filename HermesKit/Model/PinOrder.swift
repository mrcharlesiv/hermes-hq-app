// The pinned tiles' order as the owner drags them (`S/ui-bots/pinned-model.ts`, `pinned-order.ts`). Kept on this device
// per account (`BotDeviceState.pinOrder`, profile names, first tile first): the gateway stores who is pinned, never
// where. A pin never dragged keeps its roster place after the placed ones (`RosterBuilder.build`). Pure.

import Foundation

nonisolated enum PinOrder {
    /// The most names kept: past it, the oldest names not on screen (unpinned or deleted bots) go first.
    static let limit = 64

    /// `keys` with the one at `from` moved to `to`.
    static func moved<T>(_ keys: [T], from: Int, to: Int) -> [T] {
        guard keys.indices.contains(from) else { return keys }
        var next = keys
        let key = next.remove(at: from)
        next.insert(key, at: min(max(0, to), next.count))
        return next
    }

    /// The saved order after a drop: the tiles' new order (`after`) fills the places the tiles (`before`) held in it, so a
    /// pin out of view keeps its own; tiles that were never placed follow. Past `limit` names, the oldest names not on
    /// screen go first.
    static func next(saved: [String], before: [String], after: [String], limit: Int = PinOrder.limit) -> [String] {
        let shown = Set(before)
        var queue = after[...]
        var placed = saved.map { key -> String in
            guard shown.contains(key) else { return key }
            return queue.popFirst() ?? key
        }
        placed.append(contentsOf: queue)
        var extra = placed.count - limit
        guard extra > 0 else { return placed }
        return placed.filter { key in
            if shown.contains(key) { return true }
            if extra > 0 { extra -= 1; return false }
            return true
        }
    }
}
