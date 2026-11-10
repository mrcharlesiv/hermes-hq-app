import Foundation

/// The chat's display rows, newest first, and how many of them the table shows. Pure bookkeeping with no UIKit, so
/// it can be tested on scripted sequences: `allRows` always equals what `ChatRowBuilder.build` makes for
/// `messages[builtFrom...]`, reversed.
///
/// - The table holds `allRows.prefix(shownCount)`: the newest rows. The rest (`hiddenOlder`) wait at the old end;
///   the screen reveals them as the reader nears them and hides them again once the reader is back at the newest end,
///   so table updates cost O(shown), not O(chat).
/// - Messages older than `builtFrom` have no rows yet; they are built off the main thread in chunks.
struct ChatRowModel {
    /// Every built row, newest first.
    private(set) var allRows: [ChatRow] = []
    /// Rows at the old end of `allRows` that are not in the table.
    private(set) var hiddenOlder = 0
    /// Hidden rows, counted from the shown boundary, that the background fill has measured (a lower bound).
    private(set) var measuredHidden = 0
    /// Rows exist for `messages[builtFrom...]`.
    private(set) var builtFrom = 0
    /// The rows were built from a longer message list than `count` (messages went away without a reset): only a full
    /// rebuild is consistent again.
    func isStale(forMessageCount count: Int) -> Bool { builtFrom > count }
    /// Bumped whenever rows built off the main thread from an older snapshot would be stale.
    private(set) var generation = 0

    var shownCount: Int { allRows.count - hiddenOlder }
    var shown: ArraySlice<ChatRow> { allRows.prefix(shownCount) }

    // MARK: Building

    /// Builds the newest `syncMessages` messages' rows. With `oldestShown` (a message id), the build reaches down to
    /// that message and everything down to it stays shown, so a reader deep in history stays put; without it every
    /// row starts hidden (the caller reveals the first screen).
    mutating func rebuildAll(_ input: ChatRowBuilder.Input, syncMessages: Int, oldestShown: String?) {
        let messages = input.messages
        var lo = max(0, messages.count - syncMessages)
        if let oldestShown, let index = messages.firstIndex(where: { $0.id == oldestShown }) { lo = min(lo, index) }
        allRows = ChatRowBuilder.build(input, range: lo..<messages.count).reversed()
        builtFrom = lo
        generation += 1
        measuredHidden = 0
        if let oldestShown {
            if let last = allRows.lastIndex(where: { $0.messageId == oldestShown }) {
                hiddenOlder = allRows.count - (last + 1)
            } else {
                hiddenOlder = max(0, allRows.count - 40)
            }
        } else {
            hiddenOlder = allRows.count
        }
    }

    /// Rebuilds the rows of the messages touched by `ids` and everything newer (from the message before the oldest
    /// touched one, whose tail and corners depend on it).
    mutating func rebuildNewest(_ input: ChatRowBuilder.Input, touching ids: [String]) {
        let messages = input.messages
        var remaining = Set(ids)
        var lowest: Int?
        var i = messages.count - 1
        while i >= 0 && !remaining.isEmpty {
            if remaining.remove(messages[i].id) != nil { lowest = i }
            i -= 1
        }
        guard let lowest else { return }
        if lowest < builtFrom { generation += 1 }   // a chunk in flight read the old text
        rebuildNewest(input, fromMessage: max(0, lowest - 1))
    }

    /// Rebuilds `messages[lo...]` (and the waiting capsule).
    mutating func rebuildNewest(_ input: ChatRowBuilder.Input, fromMessage lo: Int) {
        let messages = input.messages
        // Never past the end: when the messages shrank without a reset, `builtFrom` (counted in the old array) can lie
        // beyond it (the screen resets the model then; this keeps a late caller from trapping on the range).
        var lo = min(messages.count, max(builtFrom, min(lo, messages.count)))
        // [updates] From the start of an update group the region reaches into: its line counts what follows.
        if lo < messages.count { lo = max(builtFrom, UpdateGroups.widen(lo...lo, input: input).lowerBound) }
        let fresh = ChatRowBuilder.build(input, range: lo..<messages.count)
        var ids = Set(messages[lo...].map(\.id))
        ids.insert("waiting")
        ids.insert(PromptRows.tailMessageId)   // [questions] the approval card / question note after the newest message
        var prefix = 0
        while prefix < allRows.count && ids.contains(allRows[prefix].messageId) { prefix += 1 }
        let shownBefore = shownCount
        allRows.replaceSubrange(0..<prefix, with: fresh.reversed())
        if prefix > shownBefore {
            // The rebuilt region reached rows not shown yet: show the region, hide what lies beyond it.
            hiddenOlder = max(0, allRows.count - fresh.count)
            measuredHidden = max(0, measuredHidden - (prefix - shownBefore))
        }
        measuredHidden = min(measuredHidden, hiddenOlder)
    }

    /// Message indices grouped into runs of adjacent ones, oldest first ([3, 1, 4, 9] → 1...1, 3...4, 9...9).
    static func runs(of indices: [Int]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        for i in Set(indices).sorted() {
            if let last = runs.last, last.upperBound + 1 == i { runs[runs.count - 1] = last.lowerBound...i } else { runs.append(i...i) }
        }
        return runs
    }

    /// Rebuilds the rows of `messages[range]` in place (a tool row opened deep in history), without touching the
    /// messages around them.
    mutating func rebuildMessages(_ input: ChatRowBuilder.Input, _ range: ClosedRange<Int>) {
        let messages = input.messages
        var lo = max(builtFrom, range.lowerBound), hi = min(messages.count - 1, range.upperBound)
        guard lo <= hi else { return }
        // [updates] The whole of any update group the range touches (opening a group's line redraws its members).
        let wide = UpdateGroups.widen(lo...hi, input: input)
        lo = max(builtFrom, wide.lowerBound)
        hi = min(messages.count - 1, wide.upperBound)
        if hi == messages.count - 1 { rebuildNewest(input, fromMessage: lo); return }
        let fresh = Array(ChatRowBuilder.build(input, range: lo..<(hi + 1)).reversed())
        let ids = Set(messages[lo...hi].map(\.id))
        guard let start = allRows.firstIndex(where: { ids.contains($0.messageId) }) else { return }
        var end = start
        while end < allRows.count && ids.contains(allRows[end].messageId) { end += 1 }
        let shownBefore = shownCount
        allRows.replaceSubrange(start..<end, with: fresh)
        let delta = fresh.count - (end - start)
        if start >= shownBefore {
            // Entirely hidden.
            hiddenOlder += delta
            measuredHidden = min(measuredHidden, start - shownBefore)
        } else if end > shownBefore {
            // Straddles the boundary: show the whole region.
            hiddenOlder = allRows.count - (start + fresh.count)
            measuredHidden = max(0, measuredHidden - (end - shownBefore))
        }
        measuredHidden = min(measuredHidden, hiddenOlder)
    }

    /// `count` older messages arrived at the oldest end (`messages` already holds them): they join the unbuilt range,
    /// and the old first message is rebuilt when it was built (its day separator and run may change).
    mutating func rebuildOldest(_ input: ChatRowBuilder.Input, added count: Int) {
        let messages = input.messages
        guard count > 0, !messages.isEmpty else { return }
        generation += 1
        if builtFrom > 0 {
            builtFrom += count
            return
        }
        let boundary = min(count, messages.count - 1)
        builtFrom = boundary
        // [updates] With every message of an update group it is in: an opened card's rows carry their own messages' ids
        // but are drawn by the line's message, so rebuilt alone the later ones' rows would show twice.
        // The old first message drawing nothing (a bot's silent note), the first one that draws is the one whose gap
        // changes.
        let rows = UpdateGroups.Rows(input)
        var first = boundary
        while first < messages.count - 1, first - boundary < UpdateGroups.reach, rows.at(first).isEmpty { first += 1 }
        let hi = min(messages.count - 1, max(first, UpdateGroups.widen(first...first, input: input).upperBound))
        let fresh = ChatRowBuilder.build(input, range: boundary..<(hi + 1))
        let ids = Set(messages[boundary...hi].map(\.id))
        var suffix = 0
        while suffix < allRows.count && ids.contains(allRows[allRows.count - 1 - suffix].messageId) { suffix += 1 }
        let boundaryWasShown = suffix > hiddenOlder
        allRows.replaceSubrange((allRows.count - suffix)..., with: fresh.reversed())
        if boundaryWasShown {
            hiddenOlder = 0
            measuredHidden = 0
        } else {
            hiddenOlder += fresh.count - suffix
            measuredHidden = min(measuredHidden, max(0, hiddenOlder - fresh.count))
        }
    }

    /// The next chunk of unbuilt messages to build off the main thread: `lo..<builtFrom`.
    func nextChunk(size: Int) -> Range<Int>? {
        guard builtFrom > 0 else { return nil }
        return max(0, builtFrom - size)..<builtFrom
    }

    /// Takes a chunk built off the main thread (oldest first) for `messages[range]`; false when it went stale.
    @discardableResult
    mutating func appendBuilt(_ rows: [ChatRow], range: Range<Int>, generation: Int, measured: Bool) -> Bool {
        guard generation == self.generation, builtFrom == range.upperBound else { return false }
        let allMeasured = measuredHidden == hiddenOlder
        allRows.append(contentsOf: rows.reversed())
        hiddenOlder += rows.count
        if measured && allMeasured { measuredHidden += rows.count }
        builtFrom = range.lowerBound
        return true
    }

    // MARK: Showing

    /// Shows `count` more rows at the old end.
    mutating func reveal(_ count: Int) {
        let k = max(0, min(count, hiddenOlder))
        hiddenOlder -= k
        measuredHidden = max(0, measuredHidden - k)
    }

    /// Hides old rows so that `shown` remain (their layouts stay measured).
    mutating func hide(keeping shown: Int) {
        let k = shownCount - max(0, shown)
        guard k > 0 else { return }
        hiddenOlder += k
        measuredHidden += k
    }

    /// The next hidden rows the background fill should measure, and the id that must still sit first when it's done.
    func nextToMeasure(max count: Int) -> ArraySlice<ChatRow>? {
        let start = shownCount + measuredHidden
        guard start < allRows.count else { return nil }
        return allRows[start..<min(allRows.count, start + count)]
    }

    /// The fill measured `count` hidden rows starting with `firstId`; counted only if they still start the unmeasured
    /// part (otherwise the fill walks them again, finding them in the cache).
    mutating func markMeasured(_ count: Int, firstId: String) {
        let start = shownCount + measuredHidden
        guard start < allRows.count, allRows[start].id == firstId else { return }
        measuredHidden = min(hiddenOlder, measuredHidden + count)
    }
}

/// What turns the table's rows into the model's: deletes by old index, inserts by new index (UITableView's batch
/// semantics), and the rows kept in place whose content or presentation changed.
nonisolated struct ChatRowDiff {
    var deletes: [Int] = []          // old indices
    var inserts: [Int] = []          // new indices
    var changed: [Int] = []          // new indices of rows kept whose layout changed
    var front = 0
    var back = 0

    var isEmpty: Bool { deletes.isEmpty && inserts.isEmpty && changed.isEmpty }

    static func same(_ a: ChatRow, _ b: ChatRow) -> Bool {
        a.fingerprint == b.fingerprint && a.variant == b.variant && a.gapAbove == b.gapAbove
    }

    static func make(old: [ChatRow], new: ArraySlice<ChatRow>) -> ChatRowDiff {
        var d = ChatRowDiff()
        let newRows = new.startIndex == 0 ? new : ArraySlice(Array(new))
        let oldCount = old.count, newCount = newRows.count
        var f = 0
        while f < oldCount && f < newCount && old[f].id == newRows[f].id {
            if !same(old[f], newRows[f]) { d.changed.append(f) }
            f += 1
        }
        var b = 0
        while b < oldCount - f && b < newCount - f && old[oldCount - 1 - b].id == newRows[newCount - 1 - b].id {
            if !same(old[oldCount - 1 - b], newRows[newCount - 1 - b]) { d.changed.append(newCount - 1 - b) }
            b += 1
        }
        d.front = f
        d.back = b
        if f < oldCount - b || f < newCount - b {
            var oldIds: [String: Int] = [:]
            for i in f..<(oldCount - b) { oldIds[old[i].id] = i }
            var newIds = Set<String>()
            for i in f..<(newCount - b) {
                newIds.insert(newRows[i].id)
                if let oi = oldIds[newRows[i].id] {
                    if !same(old[oi], newRows[i]) { d.changed.append(i) }
                } else {
                    d.inserts.append(i)
                }
            }
            for i in f..<(oldCount - b) where !newIds.contains(old[i].id) { d.deletes.append(i) }
            // [activity] Rows that kept their ids but changed order (a turn-end read folds a reply's parts in stored order,
            // which can differ from the live order): the table has no move here, so a kept row would be reconfigured in a
            // cell of another kind. They go out and come back in instead.
            let keptOld = (f..<(oldCount - b)).filter { newIds.contains(old[$0].id) }
            let keptNew = (f..<(newCount - b)).filter { oldIds[newRows[$0].id] != nil }
            if keptOld.map({ old[$0].id }) != keptNew.map({ newRows[$0].id }) {
                let moved = Set(keptNew)
                d.changed.removeAll { moved.contains($0) }
                d.deletes = (d.deletes + keptOld).sorted()
                d.inserts = (d.inserts + keptNew).sorted()
            }
        }
        return d
    }
}
