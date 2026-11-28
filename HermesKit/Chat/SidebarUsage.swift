// [sidebar-usage] Owner 2026-11-28: "make it so that usage bars can show up on the bottom" of the Mac's sidebar. What
// is left on each signed-in plan, cut down to what fits at the sidebar's foot: a few plans, two bars each, in the
// words ⋯ › Usage & Limits uses (`UsageLimitsModel.blocks`). Pure, so tested alone; the views are the app's
// (`MacSidebarUsage`).

import Foundation

/// One plan (or one login of a pool) at the sidebar's foot.
nonisolated struct SidebarUsageRow: Hashable, Sendable, Identifiable {
    var id: String
    /// Screenshot-safe label for the always-visible sidebar: "Claude", or "Claude · 1" for one login of a pool.
    var title: String
    /// Concise caption under the folded rail's ring ("Claude", "Codex", or "Claude 1" when pooled).
    var shortName: String
    /// Full label including any pool account name ("Claude · Work"), reserved for the click-to-open popover.
    var fullTitle: String
    /// The bars drawn: the plan's tightest allowances, in the plan's own order.
    var gauges: [UsageGauge]
    /// What a bar can't say ("Rate limited · back in 2h"), shown when there are no bars.
    var note: String?
    /// Every allowance of the plan, for the pointer's note.
    var all: [UsageGauge]

    /// The allowance with the least left: the folded rail's ring.
    var tightest: UsageGauge? { all.min { $0.left < $1.left } }

    /// What stands inside the folded rail's ring: the tightest percentage left ("62%"), or "!" when rate-limited.
    var ringText: String {
        if let tightest { return SidebarUsage.figure(tightest) }
        return "!"
    }
}

nonisolated enum SidebarUsage {
    /// The most plans listed: the foot is a glance, the page has the rest.
    static let maxRows = 3
    static let gaugesPerRow = 2

    /// How a bar is coloured, as on the page: under a tenth left warns in red, under a quarter in orange.
    nonisolated enum Level: Sendable { case fine, warning, low }

    static func level(_ gauge: UsageGauge) -> Level { gauge.low ? .low : gauge.warning ? .warning : .fine }

    /// The plans to draw, and how many more there are than fit. A plan with bars comes before one with only a note;
    /// a plan with neither is left out.
    /// Multi-login pools are numbered ("Claude · 1", "Claude · 2") in the always-visible sidebar so personal or work
    /// account labels aren't leaked in casual screenshots; `fullTitle` keeps the account name for the popover.
    static func rows(_ blocks: [UsageBlock]) -> (rows: [SidebarUsageRow], more: Int) {
        let kept = blocks.compactMap { block -> (block: UsageBlock, note: String?)? in
            let note = block.notes.first { !quietNotes.contains($0) }
            guard !block.gauges.isEmpty || note != nil else { return nil }
            return (block, note)
        }
        var providerCounts: [String: Int] = [:]
        for item in kept { providerCounts[item.block.provider, default: 0] += 1 }
        var seen: [String: Int] = [:]
        let all = kept.map { item -> SidebarUsageRow in
            let block = item.block
            let account = block.account?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fullTitle = account.isEmpty ? block.title : "\(block.title) · \(account)"
            let pooled = (providerCounts[block.provider] ?? 1) > 1
            let title: String
            let shortName: String
            if pooled {
                let n = (seen[block.provider] ?? 0) + 1
                seen[block.provider] = n
                title = "\(block.title) · \(n)"
                shortName = "\(block.title) \(n)"
            } else {
                title = block.title
                shortName = block.title
            }
            return SidebarUsageRow(id: block.id, title: title, shortName: shortName, fullTitle: fullTitle,
                                   gauges: tightest(block.gauges), note: item.note, all: block.gauges)
        }
        let ordered = all.filter { !$0.gauges.isEmpty } + all.filter { $0.gauges.isEmpty }
        return (Array(ordered.prefix(maxRows)), max(0, ordered.count - maxRows))
    }

    /// Notes that are no news at a glance: the page says them, the foot leaves the plan out.
    static let quietNotes: Set<String> = [UsageLimitsModel.notReported, UsageLimitsModel.refilledNote, "Signed out"]

    /// The `gaugesPerRow` allowances with the least left, kept in the plan's order (the session before the week).
    static func tightest(_ gauges: [UsageGauge]) -> [UsageGauge] {
        guard gauges.count > gaugesPerRow else { return gauges }
        let kept = Set(gauges.enumerated().sorted { ($0.element.left, $0.offset) < ($1.element.left, $1.offset) }
            .prefix(gaugesPerRow).map(\.offset))
        return gauges.enumerated().filter { kept.contains($0.offset) }.map(\.element)
    }

    /// Normalized allowance name so every provider matches cleanly ("Current session" / "Session" → "Session",
    /// "Current week" / "This Week" / "Week" / "Weekly" → "Weekly", "This Month" / "Month" / "Monthly" → "Monthly").
    static func shortTitle(_ gauge: UsageGauge) -> String {
        shortTitle(gauge.title)
    }

    static func shortTitle(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in ["Current ", "This "] where name.lowercased().hasPrefix(lead.lowercased()) {
            name = String(name.dropFirst(lead.count))
        }
        switch name.lowercased() {
        case "session", "5-hour", "5 hour", "5h": return "Session"
        case "week", "weekly": return "Weekly"
        case "month", "monthly": return "Monthly"
        case "day", "today": return "Today"
        case "daily": return "Daily"
        default: return name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    /// "62%": what is left, as the bar's own figure.
    static func figure(_ gauge: UsageGauge) -> String { UsageLimitsModel.percent(gauge.left) }

    /// Under the pointer: the plan and every allowance in full ("Session: 62% left · resets in 2h 14m").
    static func tip(_ row: SidebarUsageRow) -> String {
        var lines = [row.title]
        lines += row.all.map { "\(shortTitle($0)): \($0.detail)" }
        if let note = row.note { lines.append(note) }
        return lines.joined(separator: "\n")
    }

    /// What VoiceOver reads for a plan: "Claude. Session, 62% left, resets in 2h 14m. Weekly, 24% left."
    static func spoken(_ row: SidebarUsageRow) -> String {
        var parts = [row.title]
        parts += row.all.map { [shortTitle($0), $0.leftText, $0.reset].compactMap { $0 }.joined(separator: ", ") }
        if let note = row.note { parts.append(note) }
        return parts.joined(separator: ". ")
    }

    /// Event-driven freshness intervals (zero blind periodic polling):
    /// - `foregroundStaleAfter`: returning to the app catches CLI/mobile usage without firing on quick Alt-Tabs.
    /// - `afterTurnMinimum`: matches Hermes gateway's own 120s usage cache TTL after a chat turn completes.
    /// - `afterTurnDelay`: brief settle pause after `message.complete` so the gateway's post-turn fetch lands first.
    /// - `clickMinimum`: clicking the block refreshes if at least a minute old (popover Refresh always asks).
    static let foregroundStaleAfter: TimeInterval = 300
    static let afterTurnMinimum: TimeInterval = 120
    static let afterTurnDelay: TimeInterval = 3
    static let clickMinimum: TimeInterval = 60

    static func due(last: Date?, now: Date, every: TimeInterval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= every
    }

    /// Soonest upcoming reset date across all active gauges, so the store can schedule a single exact wake instead
    /// of a repeating timer.
    static func nextReset(in blocks: [UsageBlock], now: Date) -> Date? {
        blocks.flatMap(\.gauges).compactMap(\.resetsAt).filter { $0 > now }.min()
    }
}
