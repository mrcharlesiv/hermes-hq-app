// ⋯ › Usage & Limits: what is left on each signed-in plan, read from the gateway's model catalog (`model.options`
// rows' `usage`, `plan_usage` and `limit`; H:tui_gateway/contracts/config_free_tier_control.py ProviderUsage), the
// chat's own tokens, cost and credits (`session.usage`), and the pay-as-you-go logins' balances where Hermes gives one
// (/usage, billing.state; tester batch 3). The wire values and the page's rows; pure, so tested alone.

import Foundation

/// One subscription window (`ProviderUsageWindow`): the 5-hour session, the week, a model family's week.
nonisolated struct UsageWindow: Hashable, Sendable {
    var label: String
    var usedPercent: Double
    var resetsAt: Date?
    /// The window caps one model family only (`scope: "model"`), never the whole login.
    var modelScoped = false

    init(label: String, usedPercent: Double, resetsAt: Date? = nil, modelScoped: Bool = false) {
        self.label = label; self.usedPercent = usedPercent; self.resetsAt = resetsAt; self.modelScoped = modelScoped
    }

    init?(json: JSONValue) {
        guard let label = json["label"]?.string, let used = json["used_percent"]?.double, used.isFinite else { return nil }
        self.init(label: label, usedPercent: used, resetsAt: UsageDates.parse(json["resets_at"]?.string),
                  modelScoped: json["scope"]?.string == "model")
    }
}

/// One login of a provider's credential pool (`ProviderUsageAccount`).
nonisolated struct UsageAccount: Hashable, Sendable {
    nonisolated enum State: String, Sendable { case ready, limited, unknown, unavailable }
    var id: String
    var label: String
    var windows: [UsageWindow]
    var state: State
    var resetsAt: Date?

    init?(json: JSONValue) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        label = json["label"]?.string ?? ""
        windows = (json["windows"]?.array ?? []).compactMap(UsageWindow.init(json:))
        state = State(rawValue: json["state"]?.string ?? "") ?? .unknown
        resetsAt = UsageDates.parse(json["resets_at"]?.string)
    }
}

/// `ProviderUsage`: one account's windows, or (a pool of several logins) one row per account.
nonisolated struct ProviderUsage: Hashable, Sendable {
    var windows: [UsageWindow]
    var accounts: [UsageAccount]?

    init?(json: JSONValue?) {
        guard let json, json.object != nil else { return nil }
        windows = (json["windows"]?.array ?? []).compactMap(UsageWindow.init(json:))
        accounts = json["accounts"]?.array.map { $0.compactMap(UsageAccount.init(json:)) }
    }
}

/// A usage-window plan's allowances (`PlanUsage`, the Nous Portal plans): what is left of each, not prices.
nonisolated struct PlanUsage: Hashable, Sendable {
    nonisolated struct Gauge: Hashable, Sendable {
        var label: String
        var title: String
        var leftFraction: Double
        var resetsAt: Date?
    }
    var plan: String?
    var gauges: [Gauge]
    var pausedReason: String?

    init?(json: JSONValue?) {
        guard let json, json.object != nil else { return nil }
        plan = json["plan"]?.string
        pausedReason = json["paused_reason"]?.string
        gauges = (json["gauges"]?.array ?? []).compactMap { g in
            guard let label = g["label"]?.string, let left = g["left_fraction"]?.double, left.isFinite else { return nil }
            let reset = g["resets_at_ms"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
            return Gauge(label: label, title: g["title"]?.string ?? "", leftFraction: left, resetsAt: reset)
        }
    }
}

/// `ProviderLimit`: the whole login is rate-limited until a time, or only some of its models are.
nonisolated struct ProviderLimit: Hashable, Sendable {
    var account: Bool
    var resetsAt: Date?
    var models: [String]

    init?(json: JSONValue?) {
        guard let json, let scope = json["scope"]?.string else { return nil }
        account = scope == "account"
        resetsAt = UsageDates.parse(json["resets_at"]?.string)
        models = (json["models"]?.object ?? [:]).keys.sorted()
    }
}

nonisolated enum UsageDates {
    /// Python's `isoformat()`: "2026-10-30T17:46:00+00:00", with or without fractional seconds.
    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// "in 6d 3h", "in 2h 14m", "in 5m", "soon" (under a minute or past).
    static func until(_ date: Date, now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        guard minutes > 0 else { return "soon" }
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d" }
        if hours > 0 { return mins > 0 ? "in \(hours)h \(mins)m" : "in \(hours)h" }
        return "in \(mins)m"
    }
}

// MARK: - The page

/// One allowance as a bar: how much is left, and when it fills again.
nonisolated struct UsageGauge: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    /// 0…1 of the allowance still left.
    var left: Double
    /// "resets in 6d 3h"
    var reset: String?
    /// "86% left"
    var leftText: String { "\(UsageLimitsModel.percent(left)) left" }
    /// "86% left · resets in 6d 3h"
    var detail: String { [leftText, reset].compactMap { $0 }.joined(separator: " · ") }
    /// Under a tenth left: the bar warns.
    var low: Bool { left < 0.1 }
    /// Under a quarter left: the bar turns orange before it turns red.
    var warning: Bool { left < 0.25 }
    /// When it fills again, if the gateway said (a reminder is set for it).
    var resetsAt: Date?
    /// 0…1 of the window gone by, when its length is known from its name ("Session" 5 h, "Weekly" 7 d): where an even
    /// pace would have the bar.
    var elapsed: Double?
    /// How the allowance is going at the rate it has been used.
    var pace: UsagePace?

    init(id: String, title: String, left: Double, reset: String? = nil, resetsAt: Date? = nil,
         elapsed: Double? = nil, pace: UsagePace? = nil) {
        self.id = id; self.title = title; self.left = left; self.reset = reset
        self.resetsAt = resetsAt; self.elapsed = elapsed; self.pace = pace
    }
}

/// Whether an allowance lasts until it fills again, at the rate it has been used this window.
nonisolated enum UsagePace: Hashable, Sendable {
    /// It lasts (or too little of the window has gone by to say otherwise).
    case steady
    /// At this rate it runs out before it resets: "in 1d 2h".
    case runsOut(String)
    /// Nothing left.
    case usedUp

    var text: String {
        switch self {
        case .steady: "On pace to last until it resets"
        case .runsOut(let when): "Runs out \(when) at this pace"
        case .usedUp: "Used up"
        }
    }
}

/// One provider (or one login of a pool) on the page.
nonisolated struct UsageBlock: Hashable, Sendable, Identifiable {
    var id: String
    /// The provider's slug.
    var provider: String
    var title: String
    /// A pool's login ("Account 2" when the gateway gives no label).
    var account: String?
    /// The chat's own provider (listed first).
    var current: Bool
    var gauges: [UsageGauge]
    /// What a bar can't say: "Rate limited · back in 2h", "Not reported yet", "Signed out".
    var notes: [String]
}

nonisolated enum UsageLimitsModel {
    static let notReported = "Not reported yet"
    static let refilledNote = "Refilled"

    private static func passed(_ date: Date?, _ now: Date) -> Bool { date.map { $0 <= now } ?? false }

    /// Every signed-in provider that reports a plan, a window or a limit; the chat's provider first.
    static func blocks(_ options: ModelOptions, currentProvider: String, now: Date = Date()) -> [UsageBlock] {
        var out: [UsageBlock] = []
        for row in options.providers where row.authenticated != false {
            let title = providerTitle(row)
            let current = row.matches(currentProvider)
            var limitNotes: [String] = []
            if let limit = row.limit, !passed(limit.resetsAt, now) {
                let when = limit.resetsAt.map { " · back \(UsageDates.until($0, now: now))" } ?? ""
                limitNotes.append(limit.account ? "Rate limited\(when)"
                                  : "\(limit.models.count == 1 ? "1 model" : "\(limit.models.count) models") rate limited\(when)")
            }
            if let plan = row.plan {
                var notes = limitNotes
                if let paused = plan.pausedReason, !paused.isEmpty { notes.append(paused) }
                let gauges = plan.gauges.enumerated().map { i, g in
                    gauge(id: "\(row.slug).plan.\(i)", title: planWord(g), left: g.leftFraction, resetsAt: g.resetsAt, now: now)
                }
                out.append(UsageBlock(id: "\(row.slug).plan", provider: row.slug, title: title, account: plan.plan, current: current, gauges: gauges, notes: notes))
            } else if let accounts = row.usage?.accounts, !accounts.isEmpty {
                for (i, account) in accounts.enumerated() {
                    var notes = i == 0 ? limitNotes : []
                    switch account.state {
                    case .unavailable: notes.append("Signed out")
                    case .unknown where account.windows.isEmpty: notes.append(notReported)
                    case .limited where account.windows.isEmpty && passed(account.resetsAt, now): notes.append(refilledNote)
                    case .limited where account.windows.isEmpty:
                        notes.append("Used up" + (account.resetsAt.map { " · resets \(UsageDates.until($0, now: now))" } ?? ""))
                    default: break
                    }
                    let label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    out.append(UsageBlock(id: "\(row.slug).\(account.id)", provider: row.slug, title: title, account: label.isEmpty ? "Account \(i + 1)" : label,
                                          current: current, gauges: windowGauges(account.windows, id: "\(row.slug).\(account.id)", now: now),
                                          notes: notes))
                }
            } else if let windows = row.usage?.windows, !windows.isEmpty {
                out.append(UsageBlock(id: row.slug, provider: row.slug, title: title, account: nil, current: current,
                                      gauges: windowGauges(windows, id: row.slug, now: now), notes: limitNotes))
            } else if !limitNotes.isEmpty {
                out.append(UsageBlock(id: row.slug, provider: row.slug, title: title, account: nil, current: current, gauges: [], notes: limitNotes))
            }
        }
        // Stable: the chat's provider first, the rest in the gateway's order.
        return out.filter(\.current) + out.filter { !$0.current }
    }

    /// Whether asking again in a moment can fill something in: the gateway refreshes usage in the background after
    /// each catalog read, so an account it hasn't heard from yet is often known a few seconds later. A single login
    /// comes with no usage at all while its last answer is over 15 minutes old (H:hermes_cli/inventory.py
    /// `_apply_usage`): a Claude subscription read the first time the page opens in a while showed as a pay-as-you-go
    /// login with no balance (owner, 2026-10-30).
    static func worthAskingAgain(_ options: ModelOptions) -> Bool {
        options.providers.contains { row in
            guard row.authenticated != false, !row.models.isEmpty else { return false }
            if let accounts = row.usage?.accounts { return accounts.contains { $0.state == .unknown && $0.windows.isEmpty } }
            return row.usage == nil && row.plan == nil
        }
    }

    /// The ⋯ row's subtitle: the chat's provider's tightest allowance ("Weekly · 86% left"), or its rate limit.
    static func menuSubtitle(_ options: ModelOptions?, provider: String, now: Date = Date()) -> String? {
        guard let options, let row = options.row(matching: provider) else { return nil }
        if let limit = row.limit, limit.account, !passed(limit.resetsAt, now) { return "Rate limited" + (limit.resetsAt.map { " · back \(UsageDates.until($0, now: now))" } ?? "") }
        let gauges = blocks(ModelOptions(providers: [row]), currentProvider: provider, now: now).flatMap(\.gauges)
        guard let tightest = gauges.min(by: { $0.left < $1.left }) else { return nil }
        return "\(tightest.title) · \(tightest.leftText)"
    }

    private static func windowGauges(_ windows: [UsageWindow], id: String, now: Date) -> [UsageGauge] {
        windows.enumerated().map { i, w in
            gauge(id: "\(id).\(i)", title: w.label, left: 1 - w.usedPercent / 100, resetsAt: w.resetsAt, now: now)
        }
    }

    private static func gauge(id: String, title: String, left: Double, resetsAt: Date?, now: Date) -> UsageGauge {
        // The catalog can be hours old: a window whose reset time has passed has filled again, whatever it said then
        // (the page's next read confirms it).
        if passed(resetsAt, now) { return UsageGauge(id: id, title: title.isEmpty ? "Allowance" : title, left: 1, reset: refilledNote.lowercased()) }
        let clamped = max(0, min(1, left.isFinite ? left : 0))
        let (elapsed, pace) = pace(left: clamped, resetsAt: resetsAt, length: windowLength(title), now: now)
        return UsageGauge(id: id, title: title.isEmpty ? "Allowance" : title, left: clamped,
                          reset: resetsAt.map { "resets \(UsageDates.until($0, now: now))" },
                          resetsAt: resetsAt, elapsed: elapsed, pace: pace)
    }

    /// A window's length from its name, as Hermes words them (H:agent/account_usage.py: "Current session", "Session",
    /// "Current week", "Weekly", "Opus week"; the plan gauges "Today", "This Week", "This Month"). Any other name
    /// ("API key quota", "Subscription", "Large Models") has no known length, and no pace.
    static func windowLength(_ title: String) -> TimeInterval? {
        let name = title.lowercased()
        if name.contains("session") || name.contains("5-hour") || name.contains("5 hour") || name.contains("5h") { return 5 * 3600 }
        if name.contains("week") { return 7 * 86400 }
        if name.contains("month") { return 30 * 86400 }
        if name.contains("today") || name.contains("daily") || name == "day" { return 86400 }
        return nil
    }

    /// How far into its window an allowance is, and whether it lasts at the rate used so far. A window under a tenth
    /// (or ten minutes) old says nothing yet, and only a clear miss warns: early use is lumpy, and a week that "runs out
    /// in 5d 9h" of 6d 3h after its first evening only alarms.
    static func pace(left: Double, resetsAt: Date?, length: TimeInterval?, now: Date) -> (elapsed: Double?, pace: UsagePace?) {
        var elapsed: Double?
        var gone: TimeInterval = 0
        var untilReset: TimeInterval = 0
        if let resetsAt, let length {
            untilReset = resetsAt.timeIntervalSince(now)
            // A reset further off than the window is long: the name misled, so no pace.
            if untilReset > 0, untilReset <= length * 1.05 {
                gone = max(0, length - untilReset)
                elapsed = min(1, gone / length)
            }
        }
        if left <= 0.005 { return (elapsed, .usedUp) }
        guard let elapsed, let length else { return (nil, nil) }
        let used = 1 - left
        guard gone >= max(length * 0.1, 600), used > 0.02 else { return (elapsed, .steady) }
        let emptyIn = left * gone / used
        guard emptyIn < untilReset * 0.8 else { return (elapsed, .steady) }
        return (elapsed, .runsOut(UsageDates.until(now.addingTimeInterval(emptyIn), now: now)))
    }

    /// The allowance the page leads with: the chat's provider's tightest, or nil when it has none to show.
    static func headline(_ blocks: [UsageBlock]) -> (block: UsageBlock, gauge: UsageGauge)? {
        let pairs = blocks.filter(\.current).flatMap { block in block.gauges.map { (block: block, gauge: $0) } }
        return pairs.min { $0.gauge.left < $1.gauge.left }
    }

    /// Under the page's title: how old its numbers are ("Updated just now", "Updated 4 min ago", "Updated at 9:12 AM"),
    /// "Offline · " first while there is no connection. Nothing before the first read.
    static func freshness(_ updated: Date?, now: Date, offline: Bool, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let updated else { return offline ? "Offline" : nil }
        let minutes = Int(now.timeIntervalSince(updated) / 60)
        let age = minutes < 1 ? "Updated just now"
            : minutes < 60 ? "Updated \(minutes) min ago"
            : "Updated \(clock(updated, now: now, calendar: calendar, locale: locale))"
        return offline ? "Offline · " + age.replacingOccurrences(of: "Updated", with: "updated") : age
    }

    /// "4:10 PM" today, "Tue 1:00 PM" within seven days, "Nov 5" further off: when a window fills again on the clock.
    static func clock(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let format = DateFormatter()
        format.locale = locale
        format.timeZone = calendar.timeZone
        format.calendar = calendar
        let template = calendar.isDate(date, inSameDayAs: now) ? "jmm"
            : date.timeIntervalSince(now) < 7 * 86400 ? "EEEjmm" : "MMMd"
        format.setLocalizedDateFormatFromTemplate(template)
        // iOS puts a narrow no-break space before "PM": a plain one, so the line wraps and reads like the rest.
        return format.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    static func percent(_ fraction: Double) -> String { "\(Int((max(0, min(1, fraction)) * 100).rounded()))%" }

    /// The gateway's allowance ids in words (`PlanUsageGauge.label`); any other id shows its title.
    private static func planWord(_ g: PlanUsage.Gauge) -> String {
        switch g.label {
        case "day": "Today"
        case "week": "This Week"
        case "month": "This Month"
        case "top_tier": "Large Models"
        default: g.title.isEmpty ? g.label.capitalized : g.title
        }
    }

    static func providerTitle(_ row: ModelProviderRow) -> String {
        let name = ModelNames.plainProviderName(row.name)
        if !name.isEmpty { return name }
        let display = ModelNames.providerDisplayName(row.slug)
        return display.isEmpty ? row.slug : display
    }

    // MARK: This chat

    /// The chat's own numbers (`session.usage`): Context, Tokens, Cache, Speed and Cost, as Session Info shows them.
    static func chatRows(_ usage: SessionUsage?, price: String? = nil) -> [SessionInfoRow] {
        guard let usage else { return [] }
        return SessionInfoRows.usageRows(usage, price: price)
    }

    /// Nous credits as the gateway words them (`session.usage` `credits_lines`), blank and decoration-only lines out.
    static func creditLines(_ answer: JSONValue?) -> [String] {
        let lines = (answer?["credits_lines"]?.array ?? answer?["usage"]?["credits_lines"]?.array ?? []).compactMap(\.string)
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            line.contains(where: { $0.isLetter || $0.isNumber })
        }
    }

    // MARK: Pay as you go (tester batch 3)

    static let balanceChecking = "Checking…"
    static let balanceUnlimited = "Unlimited"
    static let balanceUnavailable = "Balance not available"
    static let balanceOffline = "Offline"
    static let balanceFailed = "Couldn’t check"
    /// Hermes words OpenRouter's and Codex's balance only in /usage, for the chat's own provider
    /// (H:agent/account_usage.py, "Credits balance: $…"); Nous's comes with every chat's /usage and from billing.state.
    static let balanceInItsOwnChat: Set<String> = ["openrouter", "openai-codex"]
    static let nous = "nous"

    /// The balances in Hermes' /usage (`slash.exec usage`, H:tui_gateway/methods_slash.py `_usage_account_blocks`, read
    /// in the chat's own profile): the chat provider's block says "Credits balance: $12.34" or "Credits balance:
    /// unlimited" under its "Provider: openrouter" line (Codex: "Provider: openai-codex (Plus)"); the Nous block says
    /// "Total usable: $7.50" under "Provider: nous". Nothing else counts, whatever numbers it holds.
    static func reportedBalances(_ text: String) -> [String: UsageBalance] {
        var out: [String: UsageBalance] = [:]
        var provider: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            // A blank line or a block's title ("📈 Account limits", "📈 Nous credits") starts again.
            if line.isEmpty || line.hasPrefix("📈") { provider = nil; continue }
            if line.hasPrefix("Provider: ") {
                provider = line.dropFirst("Provider: ".count).split(separator: " ").first.map { $0.lowercased() }
                continue
            }
            guard let provider, out[provider] == nil else { continue }
            let label = provider == nous ? "Total usable:" : "Credits balance:"
            guard line.hasPrefix(label) else { continue }
            let value = line.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
            if provider != nous, value == "unlimited" { out[provider] = .unlimited }
            else if let amount = dollars(value) { out[provider] = .amount(amount) }
        }
        return out
    }

    /// Nous's balance from `billing.state` (H:tui_gateway/billing_view.py `_serialize_billing_state`): the credits it can
    /// spend, `usage.total_spendable_display` (the portal's total usable credits, the figure /usage words "Total usable",
    /// so both reads give the row one figure); the account balance `balance_display` only when Hermes has no total (its
    /// usage model is fail-open). It never fails as a call: a portal failure is an answer carrying `error`. The free
    /// tier and a signed-out login have no balance.
    static func nousBalance(_ state: JSONValue) -> UsageBalance {
        if state["free_tier_account"]?.bool == true { return .unavailable }
        if state["logged_in"]?.bool == true {
            let usage = state["usage"]
            let total = usage?["available"]?.bool == true ? usage?["total_spendable_display"]?.string.flatMap(dollars) : nil
            if let amount = total ?? state["balance_display"]?.string.flatMap(dollars)
                ?? state["balance_usd"]?.string.flatMap({ dollars("$" + $0) }) {
                return .amount(amount)
            }
        }
        if let error = state["error"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty { return .failed(error) }
        return .unavailable
    }

    /// "$12.34", "$1,234.50", "$7"; a debt as Python words it ("$-1.23") turned round ("-$1.23"). Anything else
    /// ("—", "$nan") is no amount.
    static func dollars(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.range(of: #"^(-\$|\$-?)[0-9][0-9,]*(\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        let digits = text.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "$", with: "")
        return (text.contains("-") ? "-$" : "$") + digits
    }

    static let balanceElsewhereNote = "Shows in a chat that uses it"
    static let balanceNotStartedNote = "Shows once this chat has started"
    static let balanceFooter = "Balances as Hermes reports them. A provider paid by API key may not report one."

    /// A /usage answer's figures (`reportedBalances`) joined to those the page has. Hermes leaves a provider out of
    /// /usage when its check fails (H:tui_gateway/methods_slash.py `_usage_account_blocks` is fail-open), so an answer
    /// without a figure keeps the one before; a newer answer's figures replace an older's, and an older answer that
    /// lands late only fills what is missing.
    static func joined(_ report: UsageRead<[String: UsageBalance]>, _ figures: [String: UsageBalance],
                       newer: Bool) -> UsageRead<[String: UsageBalance]> {
        let had: [String: UsageBalance] = if case .done(let old) = report { old } else { [:] }
        return .done(newer ? had.merging(figures) { _, new in new } : had.merging(figures) { old, _ in old })
    }

    /// One row per signed-in provider with no plan, window or limit to show (the page's pay-as-you-go logins; a name
    /// once), the chat's first, each with the best any read gave. `report` is this chat's /usage, its figures by
    /// provider (not asked offline, nor before the chat has started); `billing` is billing.state, asked only in the
    /// main bot's chats (it reads the gateway's own Nous login, whichever bot asks). A figure counts for any provider;
    /// a read still out or failed speaks only for a provider it can fill: the chat's own when /usage gives its balance
    /// (OpenRouter, Codex), and Nous.
    static func balanceRows(_ options: ModelOptions, blocks: [UsageBlock], currentProvider: String,
                            report: UsageRead<[String: UsageBalance]>, billing: UsageRead<JSONValue>,
                            offline: Bool) -> [UsageBalanceRow] {
        let shown = Set(blocks.map(\.provider))
        var seen: Set<String> = []
        let reported: [String: UsageBalance] = if case .done(let figures) = report { figures } else { [:] }
        let billed: UsageBalance? = if case .done(let state) = billing { nousBalance(state) } else { nil }
        let notStarted = report == .notAsked && !offline
        let ordered = options.providers.filter { $0.matches(currentProvider) } + options.providers.filter { !$0.matches(currentProvider) }
        return ordered.compactMap { row -> UsageBalanceRow? in
            let title = providerTitle(row)
            guard row.authenticated != false, !shown.contains(row.slug), !row.models.isEmpty, seen.insert(title).inserted else { return nil }
            let current = row.matches(currentProvider)
            // The reads that can say: this chat's /usage, for its own provider and for Nous; billing.state, for Nous.
            var reads: [UsageBalance] = []
            if let figure = reported[row.slug] {
                reads.append(figure)
            } else if (current && balanceInItsOwnChat.contains(row.slug)) || row.slug == nous {
                reads.append(waiting(report, offline: offline))
            }
            if row.slug == nous, billing != .notAsked { reads.append(billed ?? waiting(billing, offline: offline)) }
            let balance = reads.max { rank($0) < rank($1) } ?? .unavailable
            var note: String?
            switch balance {
            case .failed(let why): note = why
            case .unavailable where !current && balanceInItsOwnChat.contains(row.slug): note = balanceElsewhereNote
            case .unavailable where notStarted && ((current && balanceInItsOwnChat.contains(row.slug)) || (row.slug == nous && billed == nil)):
                note = balanceNotStartedNote
            default: break
            }
            return UsageBalanceRow(provider: row.slug, title: title, current: current, balance: balance, note: note)
        }
    }

    static let blockBalanceTitle = "Credits balance"

    /// The chat's own provider when it shows as a plan instead of a pay-as-you-go row (an OpenRouter key with a spending
    /// limit has a window; a Codex login has its plan's): the balance its /usage gives, a row under the bars once there
    /// is one, nothing before. Not a pool's login: /usage doesn't say which of them it read.
    static func blockBalance(_ block: UsageBlock, report: UsageRead<[String: UsageBalance]>) -> UsageBalance? {
        guard block.current, block.account == nil, balanceInItsOwnChat.contains(block.provider),
              case .done(let figures) = report else { return nil }
        return figures[block.provider]
    }

    /// What a read with no figure for a provider says of it.
    private static func waiting<Value>(_ read: UsageRead<Value>, offline: Bool) -> UsageBalance {
        switch read {
        case .notAsked: offline ? .offline : .unavailable
        case .pending: offline ? .offline : .checking
        case .done: .unavailable
        case .failed(let why): offline ? .offline : .failed(why)
        }
    }

    /// A figure beats a read still out, which beats a failure, which beats offline, which beats none.
    private static func rank(_ balance: UsageBalance) -> Int {
        switch balance {
        case .amount, .unlimited: 5
        case .checking: 4
        case .failed: 3
        case .offline: 2
        case .unavailable: 1
        }
    }
}

/// A pay-as-you-go login's credits as Hermes gives them. Never a number Hermes didn't give.
nonisolated enum UsageBalance: Hashable, Sendable {
    /// A read that can say is still out.
    case checking
    /// "$12.34", as Hermes words it (a debt "-$1.23").
    case amount(String)
    case unlimited
    /// Hermes has none for this login (a provider paid by key, the free tier, signed out, another chat's provider).
    case unavailable
    /// No connection, and nothing read before it went.
    case offline
    /// The read failed: why, in the gateway's words.
    case failed(String)
}

/// One read the page makes: still out, its answer, why it failed, or not made.
nonisolated enum UsageRead<Value: Hashable & Sendable>: Hashable, Sendable {
    case notAsked
    case pending
    case done(Value)
    case failed(String)
}

/// One pay-as-you-go login on the page: whose, and its balance.
nonisolated struct UsageBalanceRow: Hashable, Sendable, Identifiable {
    var provider: String
    var title: String
    /// The chat's own provider (listed first).
    var current: Bool
    var balance: UsageBalance
    /// Under the name: why a check failed, or where a balance Hermes can give shows instead.
    var note: String?
    var id: String { provider }

    /// "OpenRouter · This Chat"
    var label: String { current ? "\(title) · This Chat" : title }

    /// No balance and nothing coming: folded under one row so a page of logins paid by key doesn't bury the figures
    /// (owner, 2026-10-30). A chat that hasn't started keeps its row: its balance comes once it does.
    var quiet: Bool { balance == .unavailable && note != UsageLimitsModel.balanceNotStartedNote }

    /// The value column; `money` formats an amount the way the app shows money.
    func value(money: (String) -> String = { $0 }) -> String {
        switch balance {
        case .checking: UsageLimitsModel.balanceChecking
        case .amount(let amount): money(amount)
        case .unlimited: UsageLimitsModel.balanceUnlimited
        case .unavailable: UsageLimitsModel.balanceUnavailable
        case .offline: UsageLimitsModel.balanceOffline
        case .failed: UsageLimitsModel.balanceFailed
        }
    }
}
