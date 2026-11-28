import Foundation
import Testing
@testable import HermesHQNative

/// [sidebar-usage] Owner 2026-11-28: "make it so that usage bars can show up on the bottom" of the Mac's sidebar. What
/// the foot lists (`SidebarUsage`): one clean entry per provider (rolling up pooled logins), crisp short provider names,
/// normalized labels, clear ring text, and event-driven refresh gating.
@Suite struct SidebarUsageTests {
    private func gauge(_ title: String, _ left: Double, reset: String? = nil, resetsAt: Date? = nil) -> UsageGauge {
        UsageGauge(id: title, title: title, left: left, reset: reset, resetsAt: resetsAt)
    }

    private func block(_ id: String, provider: String? = nil, title: String? = nil, account: String? = nil, gauges: [UsageGauge] = [], notes: [String] = []) -> UsageBlock {
        UsageBlock(id: id, provider: provider ?? id, title: title ?? id.capitalized, account: account, current: false, gauges: gauges, notes: notes)
    }

    @Test func aPlanWithBarsComesBeforeOneWithOnlyANote() {
        let listed = SidebarUsage.rows([
            block("gamma", notes: ["Rate limited · back in 2h"]),
            block("alpha", gauges: [gauge("Session", 0.6)]),
            block("beta", gauges: [gauge("Weekly", 0.3)]),
        ])
        #expect(listed.rows.map(\.id) == ["alpha", "beta", "gamma"])
        #expect(listed.more == 0)
        #expect(listed.rows[2].note == "Rate limited · back in 2h")
        #expect(listed.rows[2].gauges.isEmpty)
        #expect(listed.rows[2].ringText == "!")
    }

    @Test func aPlanWithNothingToSayIsLeftOut() {
        let listed = SidebarUsage.rows([block("alpha"), block("beta", gauges: [gauge("Session", 0.5)])])
        #expect(listed.rows.map(\.id) == ["beta"])
    }

    @Test func aLoginWithNoNewsIsLeftOut() {
        let listed = SidebarUsage.rows([
            block("alpha", notes: [UsageLimitsModel.notReported]),
            block("beta", notes: ["Signed out"]),
            block("gamma", notes: [UsageLimitsModel.refilledNote]),
            block("delta", notes: [UsageLimitsModel.notReported, "Used up · resets in 2h"]),
        ])
        #expect(listed.rows.map(\.id) == ["delta"])
        #expect(listed.rows.first?.note == "Used up · resets in 2h")
    }

    @Test func noMoreThanThreePlansAndTheRestAreCounted() {
        let blocks = (1...5).map { block("plan\($0)", gauges: [gauge("Session", 0.5)]) }
        let listed = SidebarUsage.rows(blocks)
        #expect(listed.rows.map(\.id) == ["plan1", "plan2", "plan3"])
        #expect(listed.more == 2)
    }

    @Test func nothingReportedIsNothingListed() {
        let listed = SidebarUsage.rows([])
        #expect(listed.rows.isEmpty)
        #expect(listed.more == 0)
    }

    @Test func verboseGatewayProviderNamesBecomeCrispShortNames() {
        #expect(SidebarUsage.providerName(slug: "openai-codex", fallback: "ChatGPT or Codex Subscription") == "Codex")
        #expect(SidebarUsage.providerName(slug: "anthropic", fallback: "Anthropic Account") == "Claude")
        #expect(SidebarUsage.providerName(slug: "claude-code", fallback: "Anthropic OAuth: Required Extra Usage Credits") == "Claude")
        #expect(SidebarUsage.providerName(slug: "nous", fallback: "Nous Portal") == "Nous")
        #expect(SidebarUsage.providerName(slug: "openrouter", fallback: "OpenRouter") == "OpenRouter")
        #expect(SidebarUsage.providerName(slug: "custom-acme", fallback: "Acme Subscription") == "Acme")
    }

    @Test func pooledAccountsRollUpIntoOneCleanProviderRow() throws {
        let listed = SidebarUsage.rows([
            block("openai-codex.1", provider: "openai-codex", title: "ChatGPT or Codex Subscription", account: "alice@acme.com",
                  gauges: [gauge("Session", 0.0), gauge("Weekly", 0.30)]),
            block("openai-codex.2", provider: "openai-codex", title: "ChatGPT or Codex Subscription", account: "Personal",
                  gauges: [gauge("Session", 1.0), gauge("Weekly", 0.90)]),
            block("anthropic", provider: "anthropic", title: "Anthropic Account", account: nil,
                  gauges: [gauge("Current session", 1.0), gauge("Current week", 0.80)]),
        ])
        #expect(listed.rows.count == 2)
        #expect(listed.rows.map(\.title) == ["Codex", "Claude"])
        let codex = try #require(listed.rows.first)
        #expect(codex.accountCount == 2)
        #expect(codex.gauges.map(SidebarUsage.shortTitle) == ["Session", "Weekly"])
        #expect(codex.gauges.map(SidebarUsage.figure) == ["50%", "60%"])
        #expect(codex.ringText == "50%")
        #expect(!SidebarUsage.tip(codex).contains("alice@acme.com"))
        #expect(SidebarUsage.tip(codex).contains("Codex (2 accounts)"))
    }

    @Test func pooledAccountExhaustedWithoutWindowsCountsAsZero() throws {
        let listed = SidebarUsage.rows([
            block("openai-codex.1", provider: "openai-codex", title: "ChatGPT or Codex Subscription", account: "Account 1",
                  gauges: [], notes: ["Used up · resets in 2h"]),
            block("openai-codex.2", provider: "openai-codex", title: "ChatGPT or Codex Subscription", account: "Account 2",
                  gauges: [gauge("Session", 1.0)]),
        ])
        let codex = try #require(listed.rows.first)
        #expect(codex.accountCount == 2)
        #expect(codex.ringText == "50%")
    }

    @Test func theTightestTwoAllowancesKeepThePlansOrder() {
        let all = [gauge("Session", 0.9), gauge("Weekly", 0.2), gauge("Opus week", 0.5)]
        #expect(SidebarUsage.tightest(all).map(\.title) == ["Weekly", "Opus week"])
        // Two or fewer: as they are.
        #expect(SidebarUsage.tightest(Array(all.prefix(2))).map(\.title) == ["Session", "Weekly"])
        // A tie keeps the earlier one.
        let tied = [gauge("A", 0.5), gauge("B", 0.5), gauge("C", 0.5)]
        #expect(SidebarUsage.tightest(tied).map(\.title) == ["A", "B"])
    }

    @Test func theRowKeepsEveryAllowanceForThePointersNote() {
        let all = [gauge("Current session", 0.9), gauge("Current week", 0.2, reset: "resets in 3d"), gauge("Opus week", 0.5)]
        let row = SidebarUsage.rows([block("claude", provider: "anthropic", title: "Anthropic Account", gauges: all)]).rows[0]
        #expect(row.gauges.count == 2)
        #expect(row.all.count == 3)
        #expect(row.tightest?.title == "Current week")
        #expect(row.ringText == "20%")
        #expect(SidebarUsage.tip(row) == "Claude\nSession: 90% left\nWeekly: 20% left · resets in 3d\nOpus week: 50% left")
        #expect(SidebarUsage.spoken(row) == "Claude. Session, 90% left. Weekly, 20% left, resets in 3d. Opus week, 50% left")
    }

    @Test func providerWindowNamesMatchAcrossClaudeCodexAndNous() {
        #expect(SidebarUsage.shortTitle(gauge("Current session", 1)) == "Session")
        #expect(SidebarUsage.shortTitle(gauge("Session", 1)) == "Session")
        #expect(SidebarUsage.shortTitle(gauge("5-hour", 1)) == "Session")
        #expect(SidebarUsage.shortTitle(gauge("Current week", 1)) == "Weekly")
        #expect(SidebarUsage.shortTitle(gauge("This Week", 1)) == "Weekly")
        #expect(SidebarUsage.shortTitle(gauge("Week", 1)) == "Weekly")
        #expect(SidebarUsage.shortTitle(gauge("Weekly", 1)) == "Weekly")
        #expect(SidebarUsage.shortTitle(gauge("This Month", 1)) == "Monthly")
        #expect(SidebarUsage.shortTitle(gauge("Monthly", 1)) == "Monthly")
        #expect(SidebarUsage.shortTitle(gauge("Today", 1)) == "Today")
        #expect(SidebarUsage.shortTitle(gauge(" opus week ", 1)) == "Opus week")
    }

    @Test func theBarWarnsAsThePageDoes() {
        #expect(SidebarUsage.level(gauge("a", 0.62)) == .fine)
        #expect(SidebarUsage.level(gauge("a", 0.25)) == .fine)
        #expect(SidebarUsage.level(gauge("a", 0.24)) == .warning)
        #expect(SidebarUsage.level(gauge("a", 0.1)) == .warning)
        #expect(SidebarUsage.level(gauge("a", 0.09)) == .low)
        #expect(SidebarUsage.figure(gauge("a", 0.624)) == "62%")
        #expect(SidebarUsage.figure(gauge("a", 1.0)) == "100%")
        #expect(SidebarUsage.figure(gauge("a", 0.0)) == "0%")
    }

    @Test func eventDrivenIntervalsGateRedundantReads() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SidebarUsage.due(last: nil, now: now, every: SidebarUsage.foregroundStaleAfter))
        #expect(!SidebarUsage.due(last: now.addingTimeInterval(-299), now: now, every: SidebarUsage.foregroundStaleAfter))
        #expect(SidebarUsage.due(last: now.addingTimeInterval(-300), now: now, every: SidebarUsage.foregroundStaleAfter))
        #expect(!SidebarUsage.due(last: now.addingTimeInterval(-119), now: now, every: SidebarUsage.afterTurnMinimum))
        #expect(SidebarUsage.due(last: now.addingTimeInterval(-120), now: now, every: SidebarUsage.afterTurnMinimum))
        #expect(!SidebarUsage.due(last: now.addingTimeInterval(-59), now: now, every: SidebarUsage.clickMinimum))
        #expect(SidebarUsage.due(last: now.addingTimeInterval(-60), now: now, every: SidebarUsage.clickMinimum))
    }

    @Test func nextResetFindsSoonestFutureWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let past = now.addingTimeInterval(-60)
        let soon = now.addingTimeInterval(3600)
        let later = now.addingTimeInterval(86_400)
        let blocks = [
            block("a", gauges: [gauge("Session", 0.5, resetsAt: past), gauge("Weekly", 0.4, resetsAt: later)]),
            block("b", gauges: [gauge("Session", 0.8, resetsAt: soon)]),
        ]
        #expect(SidebarUsage.nextReset(in: blocks, now: now) == soon)
        #expect(SidebarUsage.nextReset(in: [block("c", gauges: [gauge("Session", 0.5, resetsAt: past)])], now: now) == nil)
    }

    /// The gateway's catalog as the sidebar reads it (`GET /api/model/options`): real gateway names map to crisp titles.
    @Test func theCatalogsUsageRowsBecomeTheFootsPlans() throws {
        let reset = "2030-01-01T00:00:00+00:00"
        let json: JSONValue = [
            "providers": [
                ["slug": "openai-codex", "name": "ChatGPT or Codex Subscription", "authenticated": true, "models": [],
                 "usage": ["windows": [["label": "Session", "used_percent": 0, "resets_at": .string(reset)],
                                       ["label": "Weekly", "used_percent": 100, "resets_at": .string(reset)]]]],
                ["slug": "anthropic", "name": "Anthropic Account", "authenticated": true, "models": [],
                 "usage": ["windows": [["label": "Current session", "used_percent": 38, "resets_at": .string(reset)],
                                       ["label": "Current week", "used_percent": 59, "resets_at": .string(reset)]]]],
                ["slug": "plain", "name": "Plain", "authenticated": true, "models": []],
            ],
        ]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let listed = SidebarUsage.rows(UsageLimitsModel.blocks(ModelOptions(json: json), currentProvider: "", now: now))
        #expect(listed.rows.count == 2)
        #expect(listed.rows.map(\.title) == ["Codex", "Claude"])
        let claude = try #require(listed.rows.last)
        #expect(claude.gauges.map(SidebarUsage.shortTitle) == ["Session", "Weekly"])
        #expect(claude.gauges.map(SidebarUsage.figure) == ["62%", "41%"])
        #expect(claude.ringText == "41%")
    }
}
