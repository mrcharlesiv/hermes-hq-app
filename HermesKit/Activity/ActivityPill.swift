// Presentation only: a plan is not evidence of live work. All categories stay available in the overview.
nonisolated enum ShelfPieceKind: Int, CaseIterable, Hashable, Sendable {
    case goal, tasks, subagents, background, teammates, previousTasks, browser, phone
}

nonisolated struct ActivityPill: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var kind: ShelfPieceKind
        var words: String
        var isRunning = false
        var needsAttention = false
        var accessibilityWords: String? = nil
        var isHistorical = false
    }

    var entries: [Entry]
    /// The parent reply is running: only the pill's spinner. Its current step belongs to the transcript's own
    /// "<Bot> is …" line; the pill never repeats it (owner, 1043: "We're showing the same thing twice").
    var parentIsRunning = false

    /// Attention first, then task progress and independently running work. Ties retain category order.
    var ordered: [Entry] {
        entries.sorted { lhs, rhs in
            func rank(_ entry: Entry) -> Int {
                if entry.needsAttention { return 0 }
                if entry.kind == .tasks || (entry.kind == .previousTasks && !entry.isHistorical) { return 1 }
                if entry.isRunning, entry.kind == .subagents || entry.kind == .background || entry.kind == .teammates { return 2 }
                if entry.isRunning { return 3 }
                return 4
            }
            let l = rank(lhs), r = rank(rhs)
            return l == r ? lhs.kind.rawValue < rhs.kind.rawValue : l < r
        }
    }

    var isRunning: Bool { parentIsRunning || entries.contains { $0.isRunning } }
    var needsAttention: Bool { entries.contains { $0.needsAttention } }
    var singleAttentionKind: ShelfPieceKind? {
        let urgent = entries.filter(\.needsAttention)
        return urgent.count == 1 ? urgent[0].kind : nil
    }
    var accessibilityLabel: String {
        let parts = ordered.map { $0.accessibilityWords ?? $0.words }
        return (parts.isEmpty ? "Activity" : parts.joined(separator: ", ")) + (isRunning ? ", running" : "")
    }

    /// Shown for current categories only. A running parent with nothing else is the transcript's job, not a pill;
    /// finished history is reachable alongside current work but never pins an otherwise empty surface.
    func shouldShow(keepingDetailsOpen: Bool = false) -> Bool {
        entries.contains { !$0.isHistorical || $0.isRunning || $0.needsAttention }
            || (keepingDetailsOpen && !entries.isEmpty)
    }

    /// Current work only: finished history stays in the overview and is never counted in the pill.
    var current: [Entry] { ordered.filter { !$0.isHistorical || $0.needsAttention || $0.isRunning } }

    /// The approved pill names each current category ("Tasks 2/5 · 1 background"). The view lowers `maxSegments`
    /// only when the words don't fit its width; "+N more" then counts the current categories left out, never history.
    /// Three or more urgent categories are counted rather than listed.
    func words(maxSegments: Int = .max) -> String {
        let current = current
        let limit = max(1, maxSegments)
        let urgent = current.filter(\.needsAttention)
        if urgent.count > min(limit, 2) {
            let other = current.count - urgent.count
            return "\(urgent.count) need attention" + (other > 0 ? " · +\(other) more" : "")
        }
        if current.isEmpty { return ordered.first?.words ?? "Activity" }
        let shown = Array(current.prefix(limit))
        let overflow = current.count - shown.count
        return (shown.map(\.words) + (overflow > 0 ? ["+\(overflow) more"] : [])).joined(separator: " · ")
    }
}
