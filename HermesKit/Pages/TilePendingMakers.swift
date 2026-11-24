// [tiles-v2] Pure helpers for Tiles v2:
//   - `TilePendingStore`: persists in-flight TileMaker runs per account so app suspension/relaunch never orphans a
//     hidden tile chat (it reattaches and auto-pins/redraws when the turn finishes).
//   - `TileIdeaMatcher`: ranks/badges New Tile ideas based on the selected bot's role, name, or available tools.
//   - `TileActivitySummary`: summarizes active tile jobs and estimated daily model runs for Settings › Tile Model.

import Foundation

/// An in-flight tile creation or change, persisted across app launches so its hidden chat is never orphaned.
nonisolated struct PendingTileMaker: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var accountId: String
    var sessionId: String
    var botId: String
    /// Set for Change… or live button turns; nil for New Tile or Duplicate….
    var pinId: String?
    var pinName: String?
    var path: String
    var what: String
    var dashboardPage: String
    var desiredSize: PinTileSize?
    var acting: Bool
    /// Seconds since 1970.
    var askedAt: Double
}

/// Persists pending tile makers per account in `UserDefaults` (injectable for tests).
nonisolated enum TilePendingStore {
    static let prefix = "hq.tilePendingMakers."
    /// Pending entries older than 30 minutes are pruned automatically on load.
    static let maxAge: TimeInterval = 30 * 60

    static func key(accountId: String) -> String { prefix + accountId }

    static func load(accountId: String, defaults: UserDefaults = .standard, now: Date = Date()) -> [PendingTileMaker] {
        guard let data = defaults.data(forKey: key(accountId: accountId)),
              let list = try? JSONDecoder().decode([PendingTileMaker].self, from: data) else { return [] }
        let cutoff = now.timeIntervalSince1970 - maxAge
        let fresh = list.filter { $0.askedAt >= cutoff && !$0.sessionId.isEmpty }
        if fresh.count != list.count { save(fresh, accountId: accountId, defaults: defaults) }
        return fresh
    }

    static func upsert(_ item: PendingTileMaker, defaults: UserDefaults = .standard, now: Date = Date()) {
        guard !item.sessionId.isEmpty else { return }
        var list = load(accountId: item.accountId, defaults: defaults, now: now)
        list.removeAll { $0.id == item.id || $0.sessionId == item.sessionId }
        list.append(item)
        save(list, accountId: item.accountId, defaults: defaults)
    }

    static func remove(id: String, accountId: String, defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: key(accountId: accountId)),
              var list = try? JSONDecoder().decode([PendingTileMaker].self, from: data) else { return }
        let before = list.count
        list.removeAll { $0.id == id }
        if list.count != before { save(list, accountId: accountId, defaults: defaults) }
    }

    static func clear(accountId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(accountId: accountId))
    }

    private static func save(_ list: [PendingTileMaker], accountId: String, defaults: UserDefaults) {
        if list.isEmpty {
            defaults.removeObject(forKey: key(accountId: accountId))
        } else if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: key(accountId: accountId))
        }
    }
}

/// [tiles-v2] Ranks New Tile ideas for a chosen bot based on keywords in its role, name, or connected tools.
nonisolated enum TileIdeaMatcher {
    struct Idea: Equatable, Sendable, Hashable {
        var words: String
        var symbol: String
        var keywords: [String]
    }

    struct Ranked: Equatable, Sendable, Hashable {
        var words: String
        var symbol: String
        var matched: Bool
    }

    static let catalog: [Idea] = [
        Idea(words: "Revenue this week, with a chart by day", symbol: "chart.bar.fill",
             keywords: ["revenue", "sales", "stripe", "finance", "billing", "business", "money", "metrics"]),
        Idea(words: "Today’s calendar and the next meeting", symbol: "calendar",
             keywords: ["calendar", "schedule", "meeting", "assistant", "agenda", "google", "outlook"]),
        Idea(words: "Unread emails that need a reply", symbol: "envelope.badge",
             keywords: ["mail", "email", "gmail", "inbox", "outlook", "assistant"]),
        Idea(words: "Weather here for the next 12 hours", symbol: "cloud.sun.fill",
             keywords: ["weather", "home", "daily", "assistant", "morning"]),
        Idea(words: "My open tasks, due soonest first", symbol: "checklist",
             keywords: ["task", "todo", "kanban", "project", "linear", "jira", "assistant"]),
        Idea(words: "Jobs that ran today, and any that failed", symbol: "clock.badge.checkmark",
             keywords: ["ops", "devops", "job", "cron", "monitor", "infra", "hermes"]),
        Idea(words: "Deals closing this month and their total", symbol: "target",
             keywords: ["sales", "crm", "hubspot", "deal", "revenue", "finance"]),
        Idea(words: "Spending this month against last month", symbol: "dollarsign.circle",
             keywords: ["finance", "budget", "spend", "expense", "money", "bank"]),
        Idea(words: "My stocks and crypto, today’s change", symbol: "chart.line.uptrend.xyaxis",
             keywords: ["finance", "stock", "crypto", "market", "portfolio", "trading"]),
        Idea(words: "Messages that mention me in Slack", symbol: "bubble.left.and.exclamationmark.bubble.right",
             keywords: ["slack", "discord", "chat", "comms", "team"]),
        Idea(words: "GitHub pull requests waiting on me", symbol: "arrow.triangle.pull",
             keywords: ["github", "git", "code", "dev", "engineer", "pr", "repo", "coding"]),
        Idea(words: "Website and server status", symbol: "server.rack",
             keywords: ["ops", "devops", "server", "infra", "uptime", "site", "cloud", "monitor"]),
        Idea(words: "My next trip: flights, hotel and times", symbol: "airplane",
             keywords: ["travel", "flight", "trip", "calendar", "mail", "assistant"]),
        Idea(words: "Birthdays and follow-ups due this week", symbol: "person.2",
             keywords: ["crm", "contact", "people", "calendar", "assistant", "social"]),
        Idea(words: "Steps, sleep and workouts this week", symbol: "figure.run",
             keywords: ["health", "fitness", "workout", "sleep", "meal", "nutrition", "whoop", "oura"]),
        Idea(words: "Top headlines in my industry today", symbol: "newspaper",
             keywords: ["news", "research", "brief", "digest", "media", "web"]),
        Idea(words: "A countdown to a date that matters", symbol: "hourglass",
             keywords: ["launch", "event", "calendar", "goal", "milestone"]),
        Idea(words: "Quote or word of the day", symbol: "quote.bubble",
             keywords: ["daily", "quote", "journal", "morning"]),
    ]

    /// Ranks `catalog` so ideas matching `signals` (lowercased bot name, role, tool/connector names) appear first,
    /// preserving relative catalog order within each group.
    static func ranked(for signals: [String]) -> [Ranked] {
        let haystack = signals.joined(separator: " ").lowercased()
        let tokens = Set(haystack.split { !($0.isLetter || $0.isNumber) }.map(String.init))
        guard !tokens.isEmpty else {
            return catalog.map { Ranked(words: $0.words, symbol: $0.symbol, matched: false) }
        }
        var matched: [Ranked] = []
        var rest: [Ranked] = []
        for idea in catalog {
            let hit = idea.keywords.contains { kw in tokens.contains(kw) || haystack.contains(kw) }
            let item = Ranked(words: idea.words, symbol: idea.symbol, matched: hit)
            if hit { matched.append(item) } else { rest.append(item) }
        }
        return matched + rest
    }
}

/// [tiles-v2] Aggregated tile update activity for Settings › Tile Model.
nonisolated struct TileActivitySummary: Equatable, Sendable {
    var totalJobs: Int
    var activeJobs: Int
    var pausedJobs: Int
    var failingJobs: Int
    var scriptJobs: Int
    var estimatedModelRunsPerDay: Int

    static func summarize(_ jobs: [CronJob], now: Date = Date()) -> TileActivitySummary {
        var active = 0, paused = 0, failing = 0, scripts = 0
        var modelRuns = 0.0
        for job in jobs {
            let isScript = TileModels.isScriptOnly(job)
            if isScript { scripts += 1 }
            if TileJobs.isPaused(job) {
                paused += 1
                continue
            }
            active += 1
            if case .failed = TileJobs.health(job, now: now) { failing += 1 }
            if !isScript, let runs = TileJobs.estimatedRunsPerDay(job) { modelRuns += runs }
        }
        return TileActivitySummary(totalJobs: jobs.count, activeJobs: active, pausedJobs: paused,
                                   failingJobs: failing, scriptJobs: scripts,
                                   estimatedModelRunsPerDay: Int(modelRuns.rounded()))
    }

    /// Concise primary summary line ("4 active tiles · ~64 model runs/day").
    var headline: String {
        guard totalJobs > 0 else { return "No scheduled tiles yet" }
        let activeWord = activeJobs == 1 ? "1 active tile" : "\(activeJobs) active tiles"
        if activeJobs == 0 {
            return pausedJobs == 1 ? "1 tile paused" : "\(pausedJobs) tiles paused"
        }
        if estimatedModelRunsPerDay > 0 {
            return "\(activeWord) · ~\(estimatedModelRunsPerDay) model runs/day"
        }
        return scriptJobs == activeJobs ? "\(activeWord) (scripts only)" : activeWord
    }

    /// Optional secondary detail line for paused/failing/script breakdown.
    var detail: String? {
        var parts: [String] = []
        if failingJobs > 0 { parts.append(failingJobs == 1 ? "1 failing" : "\(failingJobs) failing") }
        if pausedJobs > 0 && activeJobs > 0 { parts.append("\(pausedJobs) paused") }
        if scriptJobs > 0 && scriptJobs < activeJobs { parts.append("\(scriptJobs) script-only") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
