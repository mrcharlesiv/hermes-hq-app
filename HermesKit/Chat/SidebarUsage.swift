// [sidebar-usage] Owner 2026-11-28: "make it so that usage bars can show up on the bottom" of the Mac's sidebar. What
// is left on each signed-in plan, cut down to what fits at the sidebar's foot: one clean entry per provider (rolling
// up multi-account pools into a combined average so duplicate accounts never crowd the sidebar or leak account names),
// crisp short provider names, normalized Session/Weekly labels, and zero-polling event-driven refresh intervals.

import Foundation

/// One provider at the sidebar's foot (rolls up multi-account credential pools into one clear summary).
nonisolated struct SidebarUsageRow: Hashable, Sendable, Identifiable {
    var id: String
    /// Crisp short provider name that never truncates on the sidebar or folded rail ("Claude", "Codex", "Nous").
    var title: String
    /// Number of signed-in logins rolled into this row (1 for a single login, 2+ for a credential pool).
    var accountCount: Int
    /// The bars drawn: the provider's tightest allowances, in order.
    var gauges: [UsageGauge]
    /// What a bar can't say ("Rate limited · back in 2h"), shown when there are no bars.
    var note: String?
    /// Every allowance of the provider, for tooltips and VoiceOver.
    var all: [UsageGauge]

    /// The allowance with the least left: the folded rail's ring.
    var tightest: UsageGauge? { all.min { $0.left < $1.left } }

    /// What stands inside the folded rail's ring: the tightest percentage left ("100%", "62%", "0%"), or "!" when
    /// rate-limited with no numeric gauge.
    var ringText: String {
        if let tightest { return SidebarUsage.figure(tightest) }
        return "!"
    }
}

nonisolated enum SidebarUsage {
    /// The most providers listed: the foot is a glance, the popover has the rest.
    static let maxRows = 3
    static let gaugesPerRow = 2

    /// How a bar is coloured, as on the page: under a tenth left warns in red, under a quarter in orange.
    nonisolated enum Level: Sendable { case fine, warning, low }

    static func level(_ gauge: UsageGauge) -> Level { gauge.low ? .low : gauge.warning ? .warning : .fine }

    /// Crisp canonical short provider name for compact UI chrome (never "ChatGPT or Codex Subscription" or
    /// "Anthropic OAuth: Required Extra Usage Credits…").
    static func providerName(slug: String, fallback: String) -> String {
        switch slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "openai-codex", "codex": return "Codex"
        case "anthropic", "claude", "claude-code": return "Claude"
        case "nous", "nous-portal": return "Nous"
        case "openrouter": return "OpenRouter"
        case "openai", "openai-api": return "OpenAI"
        case "gemini", "google", "vertex": return "Gemini"
        case "copilot", "github-copilot", "copilot-acp": return "Copilot"
        case "xai", "xai-oauth": return "Grok"
        case "minimax", "minimax-oauth", "minimax-cn": return "MiniMax"
        case "qwen-oauth", "alibaba": return "Qwen"
        case "kimi-coding", "kimi-coding-cn": return "Kimi"
        case "deepseek": return "DeepSeek"
        case "fireworks": return "Fireworks"
        case "ollama", "ollama-cloud": return "Ollama"
        case "bedrock": return "Bedrock"
        case "cursor": return "Cursor"
        default:
            var name = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = slug.trimmingCharacters(in: .whitespacesAndNewlines) }
            // Strip verbose gateway suffixes so even unknown providers stay concise.
            for suffix in [" Subscription", " Account", " Portal", " OAuth", " Plan"] {
                if name.lowercased().hasSuffix(suffix.lowercased()), name.count > suffix.count {
                    name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return name
        }
    }

    /// Notes that are no news at a glance: the page says them, the foot leaves the plan out.
    static let quietNotes: Set<String> = [UsageLimitsModel.notReported, UsageLimitsModel.refilledNote, "Signed out"]

    /// The providers to draw, and how many more there are than fit.
    /// Multi-account credential pools for the same provider roll up into ONE clean entry showing combined remaining
    /// capacity across the pool, so duplicate accounts never crowd out other providers or leak account labels in
    /// screenshots. Clicking opens the popover with every individual login in full.
    static func rows(_ blocks: [UsageBlock]) -> (rows: [SidebarUsageRow], more: Int) {
        let kept = blocks.compactMap { block -> (block: UsageBlock, note: String?)? in
            let note = block.notes.first { !quietNotes.contains($0) }
            guard !block.gauges.isEmpty || note != nil else { return nil }
            return (block, note)
        }
        var order: [String] = []
        var grouped: [String: [(block: UsageBlock, note: String?)]] = [:]
        for item in kept {
            let key = item.block.provider.isEmpty ? item.block.id : item.block.provider
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(item)
        }
        let all = order.compactMap { key -> SidebarUsageRow? in
            guard let items = grouped[key], let first = items.first else { return nil }
            let name = providerName(slug: first.block.provider, fallback: first.block.title)
            if items.count == 1 {
                let b = first.block
                return SidebarUsageRow(id: b.provider.isEmpty ? b.id : b.provider, title: name, accountCount: 1,
                                       gauges: tightest(b.gauges), note: first.note, all: b.gauges)
            }
            return rolledUpPool(id: key, title: name, items: items)
        }
        let ordered = all.filter { !$0.gauges.isEmpty } + all.filter { $0.gauges.isEmpty }
        return (Array(ordered.prefix(maxRows)), max(0, ordered.count - maxRows))
    }

    /// Combines multiple pooled logins of one provider into a single clear summary:
    /// averages remaining % per normalized window across all logins (counting exhausted/rate-limited logins with no
    /// windows as 0% so the combined bar reflects true remaining pool capacity).
    private static func rolledUpPool(id: String, title: String, items: [(block: UsageBlock, note: String?)]) -> SidebarUsageRow {
        var windowOrder: [String] = []
        var sums: [String: Double] = [:]
        var counts: [String: Int] = [:]
        var resets: [String: Date] = [:]
        var resetText: [String: String] = [:]
        var exhaustedWithoutWindows = 0

        for item in items {
            if item.block.gauges.isEmpty {
                exhaustedWithoutWindows += 1
                continue
            }
            var seenInBlock: Set<String> = []
            for g in item.block.gauges {
                let label = shortTitle(g)
                guard seenInBlock.insert(label).inserted else { continue }
                if sums[label] == nil { windowOrder.append(label) }
                sums[label, default: 0] += max(0, min(1, g.left))
                counts[label, default: 0] += 1
                if let at = g.resetsAt {
                    if let current = resets[label] {
                        if at < current { resets[label] = at; resetText[label] = g.reset }
                    } else {
                        resets[label] = at; resetText[label] = g.reset
                    }
                }
            }
        }

        let gauges: [UsageGauge] = windowOrder.enumerated().map { idx, label in
            let totalAccounts = (counts[label] ?? 0) + exhaustedWithoutWindows
            let avg = totalAccounts > 0 ? (sums[label] ?? 0) / Double(totalAccounts) : 0
            return UsageGauge(id: "\(id).pool.\(idx)", title: label, left: avg,
                              reset: resetText[label], resetsAt: resets[label])
        }
        let note = gauges.isEmpty ? items.compactMap(\.note).first : nil
        return SidebarUsageRow(id: id, title: title, accountCount: items.count,
                               gauges: tightest(gauges), note: note, all: gauges)
    }

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

    /// Under the pointer: the provider and every allowance in full ("Session: 62% left · resets in 2h 14m").
    static func tip(_ row: SidebarUsageRow) -> String {
        let head = row.accountCount > 1 ? "\(row.title) (\(row.accountCount) accounts)" : row.title
        var lines = [head]
        lines += row.all.map { "\(shortTitle($0)): \($0.detail)" }
        if let note = row.note { lines.append(note) }
        if row.accountCount > 1 { lines.append("Click for per-account details") }
        return lines.joined(separator: "\n")
    }

    /// What VoiceOver reads for a plan: "Claude. Session, 62% left, resets in 2h 14m. Weekly, 24% left."
    static func spoken(_ row: SidebarUsageRow) -> String {
        let head = row.accountCount > 1 ? "\(row.title), \(row.accountCount) accounts" : row.title
        var parts = [head]
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
