// ⋯ › Prompts, Usage & Limits and Model Prices (TestFlight feedback 2026-10-24): the catalog's new fields, the pages'
// rows, the models.dev fallback and the prompt library. No network.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

private func json(_ text: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

/// A `model.options` answer shaped as Hermes sends it (H:hermes_cli/inventory.py `build_model_options_payload`).
private let catalog = json("""
{"model": "claude-opus-5-5[1m]", "provider": "anthropic", "providers": [
  {"slug": "anthropic", "name": "Anthropic", "authenticated": true, "models": ["claude-opus-5-5[1m]", "claude-haiku-4-5"],
   "usage": {"windows": [{"label": "Session", "used_percent": 40, "resets_at": "2026-10-24T14:00:00+00:00", "scope": "account"},
                         {"label": "Weekly", "used_percent": 95.4, "resets_at": "2026-10-30T12:00:00.250000+00:00"}]}},
  {"slug": "openai-codex", "name": "ChatGPT or Codex Subscription", "authenticated": true, "models": ["gpt-5.5"],
   "usage": {"windows": [], "accounts": [
     {"id": "codex:a", "label": "work", "windows": [{"label": "Weekly", "used_percent": 14, "resets_at": "2026-10-30T17:46:00+00:00"}], "state": "ready"},
     {"id": "codex:b", "label": "", "windows": [], "state": "unknown"}]}},
  {"slug": "openrouter", "name": "OpenRouter", "authenticated": true, "models": ["moonshotai/kimi-k3", "free/model:free"],
   "pricing": {"moonshotai/kimi-k3": {"input": "$2.00", "output": "$10.00", "cache": "$0.20", "free": false},
               "free/model:free": {"input": "free", "output": "free", "cache": null, "free": true}},
   "limit": {"scope": "account", "resets_at": "2026-10-24T13:30:00+00:00"}},
  {"slug": "nous", "name": "Nous Portal", "authenticated": true, "models": ["hermes-5"],
   "plan_usage": {"kind": "window", "plan": "Plus", "gauges": [{"label": "week", "left_fraction": 0.25, "style": "bar", "resets_at_ms": 1793000000000}]}},
  {"slug": "deepseek", "name": "DeepSeek", "authenticated": true, "models": ["deepseek-v4"]},
  {"slug": "gemini", "name": "Google AI Studio", "authenticated": false, "models": ["gemini-3-pro"]}
]}
""")

private let now = ISO8601DateFormatter().date(from: "2026-10-24T12:00:00Z")!

@Suite("Menu extras · catalog fields")
struct MenuExtrasCatalogTests {
    @Test func decodesPricesUsagePlanAndLimit() {
        let options = ModelOptions(json: catalog)
        let anthropic = options.row(matching: "anthropic")!
        #expect(anthropic.authenticated == true)
        #expect(anthropic.usage?.windows.count == 2)
        #expect(anthropic.usage?.windows[1].resetsAt != nil)   // fractional seconds parse
        let codex = options.row(matching: "openai-codex")!
        #expect(codex.usage?.accounts?.map(\.state) == [.ready, .unknown])
        let router = options.row(matching: "openrouter")!
        #expect(router.pricing["moonshotai/kimi-k3"] == ModelPrice(input: "$2.00", output: "$10.00", cache: "$0.20"))
        #expect(router.pricing["free/model:free"]?.free == true)
        #expect(router.limit?.account == true)
        #expect(options.row(matching: "nous")?.plan?.gauges.first?.leftFraction == 0.25)
        #expect(options.row(matching: "gemini")?.authenticated == false)
    }
}

@Suite("Menu extras · Usage & Limits")
struct UsageLimitsTests {
    @Test func blocksListLimitsCurrentProviderFirst() {
        let blocks = UsageLimitsModel.blocks(ModelOptions(json: catalog), currentProvider: "openai-codex", now: now)
        #expect(blocks.map(\.id) == ["openai-codex.codex:a", "openai-codex.codex:b", "anthropic", "openrouter", "nous.plan"])
        #expect(blocks[0].account == "work" && blocks[0].current)
        #expect(blocks[0].gauges.first?.detail == "86% left · resets in 6d 5h")
        #expect(blocks[1].account == "Account 2")
        #expect(blocks[1].notes == [UsageLimitsModel.notReported])
        let anthropic = blocks[2]
        #expect(anthropic.gauges.map(\.leftText) == ["60% left", "5% left"])
        #expect(anthropic.gauges[1].low)
        #expect(blocks[3].gauges.isEmpty && blocks[3].notes == ["Rate limited · back in 1h 30m"])
        #expect(blocks[4].gauges.first?.title == "This Week" && blocks[4].account == "Plus")
    }

    @Test func payAsYouGoRowsAndSubtitles() {
        let options = ModelOptions(json: catalog)
        let blocks = UsageLimitsModel.blocks(options, currentProvider: "anthropic", now: now)
        // Signed-in providers with nothing to report are the pay-as-you-go rows; a signed-out one is never named.
        let rows = UsageLimitsModel.balanceRows(options, blocks: blocks, currentProvider: "anthropic", report: .notAsked,
                                                billing: .notAsked, offline: false)
        #expect(rows.map(\.title) == ["DeepSeek"])
        #expect(rows[0].value() == UsageLimitsModel.balanceUnavailable && rows[0].note == nil)
        #expect(UsageLimitsModel.menuSubtitle(options, provider: "anthropic", now: now) == "Weekly · 5% left")
        #expect(UsageLimitsModel.menuSubtitle(options, provider: "openrouter", now: now) == "Rate limited · back in 1h 30m")
        #expect(UsageLimitsModel.menuSubtitle(options, provider: "deepseek", now: now) == nil)
        #expect(UsageLimitsModel.menuSubtitle(nil, provider: "anthropic", now: now) == nil)
        #expect(UsageLimitsModel.worthAskingAgain(options))
    }

    /// [owner 2026-10-30] A login whose usage Hermes hasn't fetched lately comes with none: the page asks again.
    @Test func asksAgainForALoginWithNoUsageYet() {
        let bare = ModelProviderRow(slug: "claude-subscription", name: "Claude Subscription", models: ["opus"], aliases: [], capabilities: [:])
        #expect(UsageLimitsModel.worthAskingAgain(ModelOptions(providers: [bare])))
        var read = bare
        read.usage = ProviderUsage(json: .object(["windows": .array([.object(["label": .string("Session"), "used_percent": .number(28)])])]))
        #expect(!UsageLimitsModel.worthAskingAgain(ModelOptions(providers: [read])))
        var out = bare
        out.authenticated = false
        #expect(!UsageLimitsModel.worthAskingAgain(ModelOptions(providers: [out])))
    }

    /// [owner 2026-10-30] Rows with no balance fold away; a chat yet to start keeps its row.
    @Test func noBalanceRowsAreQuiet() {
        #expect(UsageBalanceRow(provider: "deepseek", title: "DeepSeek", current: false, balance: .unavailable).quiet)
        #expect(UsageBalanceRow(provider: "openrouter", title: "OpenRouter", current: false, balance: .unavailable,
                                note: UsageLimitsModel.balanceElsewhereNote).quiet)
        #expect(!UsageBalanceRow(provider: "openrouter", title: "OpenRouter", current: true, balance: .unavailable,
                                 note: UsageLimitsModel.balanceNotStartedNote).quiet)
        #expect(!UsageBalanceRow(provider: "nous", title: "Nous Portal", current: false, balance: .amount("$7.50")).quiet)
        #expect(!UsageBalanceRow(provider: "nous", title: "Nous Portal", current: false, balance: .failed("x")).quiet)
    }

    @Test func passedResetsRefill() throws {
        // Three hours on, from the same cached catalog: Anthropic's Session (14:00) and OpenRouter's limit (13:30) are over.
        let later = now.addingTimeInterval(3 * 3600)
        let options = ModelOptions(json: catalog)
        let blocks = UsageLimitsModel.blocks(options, currentProvider: "anthropic", now: later)
        let anthropic = try #require(blocks.first { $0.provider == "anthropic" })
        #expect(anthropic.gauges[0].leftText == "100% left" && anthropic.gauges[0].reset == "refilled")
        #expect(anthropic.gauges[1].leftText == "5% left")
        #expect(!blocks.contains { $0.provider == "openrouter" })
        #expect(UsageLimitsModel.menuSubtitle(options, provider: "openrouter", now: later) == nil)
    }

    // Owner 2026-10-30 redesign: window lengths from Hermes's names, the pace, the lead card, clock times, freshness.
    @Test func windowLengthsFromNames() {
        #expect(UsageLimitsModel.windowLength("Current session") == TimeInterval(5 * 3600))
        #expect(UsageLimitsModel.windowLength("Session") == TimeInterval(5 * 3600))
        #expect(UsageLimitsModel.windowLength("Opus week") == TimeInterval(7 * 86400))
        #expect(UsageLimitsModel.windowLength("Weekly") == TimeInterval(7 * 86400))
        #expect(UsageLimitsModel.windowLength("This Month") == TimeInterval(30 * 86400))
        #expect(UsageLimitsModel.windowLength("Today") == 86400)
        #expect(UsageLimitsModel.windowLength("API key quota") == nil)
        #expect(UsageLimitsModel.windowLength("Large Models") == nil)
    }

    @Test func paceSaysWhenAnAllowanceRunsOutEarly() {
        let week = 7 * 86400.0
        // Two days into a week with half of it used: at that rate the rest goes in two days, five before the reset.
        let early = UsageLimitsModel.pace(left: 0.5, resetsAt: now.addingTimeInterval(5 * 86400), length: week, now: now)
        #expect(abs((early.elapsed ?? 0) - 2.0 / 7) < 0.001)
        #expect(early.pace == .runsOut("in 2d"))
        // Five days in with half used: it lasts.
        #expect(UsageLimitsModel.pace(left: 0.5, resetsAt: now.addingTimeInterval(2 * 86400), length: week, now: now).pace == .steady)
        // Too early in the window to judge: one question in the first minutes, a first evening of a week.
        #expect(UsageLimitsModel.pace(left: 0.86, resetsAt: now.addingTimeInterval(6 * 86400 + 3 * 3600), length: week, now: now).pace == .steady)
        #expect(UsageLimitsModel.pace(left: 0.9, resetsAt: now.addingTimeInterval(week - 300), length: week, now: now).pace == .steady)
        // Nothing left; no length known; a reset further off than the window.
        #expect(UsageLimitsModel.pace(left: 0, resetsAt: now.addingTimeInterval(3600), length: 5 * 3600, now: now).pace == .usedUp)
        #expect(UsageLimitsModel.pace(left: 0.2, resetsAt: now.addingTimeInterval(3600), length: nil, now: now).pace == nil)
        #expect(UsageLimitsModel.pace(left: 0.2, resetsAt: now.addingTimeInterval(9 * 86400), length: week, now: now).elapsed == nil)
    }

    @Test func headlineIsTheChatsTightestAllowance() throws {
        let options = ModelOptions(json: catalog)
        let lead = try #require(UsageLimitsModel.headline(UsageLimitsModel.blocks(options, currentProvider: "anthropic", now: now)))
        #expect(lead.block.provider == "anthropic" && lead.gauge.title == "Weekly" && lead.gauge.leftText == "5% left")
        // A pay-as-you-go chat has no plan to lead with.
        #expect(UsageLimitsModel.headline(UsageLimitsModel.blocks(options, currentProvider: "deepseek", now: now)) == nil)
        // The gauges carry their reset and pace.
        #expect(lead.gauge.resetsAt != nil && lead.gauge.warning)
    }

    @Test func clockAndFreshness() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        let at = now   // 2026-10-24 12:00 UTC, a Saturday
        #expect(UsageLimitsModel.clock(at.addingTimeInterval(3600), now: at, calendar: calendar, locale: locale) == "1:00 PM")
        #expect(UsageLimitsModel.clock(at.addingTimeInterval(2 * 86400), now: at, calendar: calendar, locale: locale) == "Mon 12:00 PM")
        #expect(UsageLimitsModel.clock(at.addingTimeInterval(12 * 86400), now: at, calendar: calendar, locale: locale) == "Nov 5")
        #expect(UsageLimitsModel.freshness(nil, now: at, offline: false) == nil)
        #expect(UsageLimitsModel.freshness(nil, now: at, offline: true) == "Offline")
        #expect(UsageLimitsModel.freshness(at.addingTimeInterval(-20), now: at, offline: false) == "Updated just now")
        #expect(UsageLimitsModel.freshness(at.addingTimeInterval(-240), now: at, offline: false) == "Updated 4 min ago")
        #expect(UsageLimitsModel.freshness(at.addingTimeInterval(-240), now: at, offline: true) == "Offline · updated 4 min ago")
        #expect(UsageLimitsModel.freshness(at.addingTimeInterval(-7200), now: at, offline: false, calendar: calendar, locale: locale)
                == "Updated 10:00 AM")
    }

    nonisolated static let spans: [(Double, String)] = [(30, "in 1m"), (3540, "in 59m"), (3600, "in 1h"), (266_400, "in 3d 2h"),
                                            (172_800, "in 2d"), (-5, "soon")]

    @Test(arguments: spans)
    func until(seconds: Double, text: String) {
        #expect(UsageDates.until(now.addingTimeInterval(seconds), now: now) == text)
    }

    @Test func chatRowsAndCredits() {
        let usage = SessionUsage(total: 52_114, input: 48_210, output: 3_904, contextUsed: 62_000, contextMax: 200_000,
                                 contextPercent: 31, contextEstimated: false, costUsd: 0.42)
        let rows = UsageLimitsModel.chatRows(usage)
        #expect(rows.map(\.label) == ["Context", "Tokens", "Cost"])
        #expect(rows[2].value == "$0.42")
        #expect(rows[0].value == "31%" && rows[0].bar == 0.31)
        #expect(UsageLimitsModel.chatRows(nil).isEmpty)
        let answer = json(#"{"input": 1, "credits_lines": ["💳 Credits", "", "Balance: $4.20", "────"]}"#)
        #expect(UsageLimitsModel.creditLines(answer) == ["💳 Credits", "Balance: $4.20"])
    }
}

/// Pay-as-you-go logins (tester batch 3): OpenRouter and Nous credits, a DeepSeek key, a second row Hermes names the same,
/// a signed-out one, beside a plan with windows.
private let payAsYouGo = json("""
{"model": "moonshotai/kimi-k3", "provider": "openrouter", "providers": [
  {"slug": "anthropic", "name": "Anthropic", "authenticated": true, "models": ["claude-sonnet-5"],
   "usage": {"windows": [{"label": "Weekly", "used_percent": 20, "resets_at": "2026-10-30T12:00:00+00:00"}]}},
  {"slug": "openrouter", "name": "OpenRouter", "authenticated": true, "models": ["moonshotai/kimi-k3"]},
  {"slug": "nous", "name": "Nous Portal", "authenticated": true, "models": ["hermes-5"]},
  {"slug": "deepseek", "name": "DeepSeek", "authenticated": true, "models": ["deepseek-v4"]},
  {"slug": "deepseek-alt", "name": "DeepSeek", "authenticated": true, "models": ["deepseek-v4"]},
  {"slug": "xai", "name": "xAI", "authenticated": false, "models": ["grok-5"]}
]}
""")

/// /usage as Hermes answers it in a chat on OpenRouter whose profile is signed in to Nous
/// (H:tui_gateway/methods_slash.py `_format_live_usage_output`; H:agent/account_usage.py renders both blocks).
private let usageText = """
Session Token Usage
────────────────────────────────────────
Model: moonshotai/kimi-k3
Input tokens:                 48,210
Total tokens:                 52,114

📈 Account limits
Provider: openrouter
API key quota: 75% remaining (25% used) • $15.00 of $20.00 remaining
Credits balance: $12.34
API key usage: $5.00 total • $1.25 today
📈 Nous credits
Provider: nous
Subscription credits: $0.00
Top-up credits: $7.50
Total usable: $7.50
Top up: https://portal.nousresearch.com/billing
(or run /topup)
"""

@Suite("Menu extras · pay-as-you-go balances")
struct UsageBalanceTests {
    @Test func reportGivesEachProvidersOwnLineOnly() {
        #expect(UsageLimitsModel.reportedBalances(usageText) == ["openrouter": .amount("$12.34"), "nous": .amount("$7.50")])
        // Codex says it the same way, plan in brackets; "unlimited" is a balance too; markdown (the messaging /usage) is bare.
        let codex = "📈 **Account limits**\nProvider: openai-codex (Plus)\nSession: 90% remaining (10% used)\nCredits balance: unlimited"
        #expect(UsageLimitsModel.reportedBalances(codex) == ["openai-codex": .unlimited])
        // Python's f"${x:.2f}" of a debt, and thousands.
        #expect(UsageLimitsModel.reportedBalances("Provider: openai-codex\nCredits balance: $-1.23") == ["openai-codex": .amount("-$1.23")])
        #expect(UsageLimitsModel.reportedBalances("Provider: nous (Pro)\nTotal usable: $1,234.56") == ["nous": .amount("$1,234.56")])
    }

    @Test func reportNeverGuesses() {
        // No provider line, a balance that isn't a number, another provider's wording, a window plan's top-up after
        // OpenRouter's block (no title or provider line of its own), a token count.
        #expect(UsageLimitsModel.reportedBalances("Credits balance: $5.00").isEmpty)
        #expect(UsageLimitsModel.reportedBalances("Provider: openrouter\nCredits balance: $nan").isEmpty)
        #expect(UsageLimitsModel.reportedBalances("Provider: openrouter\nTotal usable: $5.00").isEmpty)
        #expect(UsageLimitsModel.reportedBalances("Provider: nous\nCredits balance: $5.00").isEmpty)
        let window = "📈 Account limits\nProvider: openrouter\nAPI key usage: $5.00 total\nNous Plus\nToday  ██  40% used\nTop-up credits: $3.00"
        #expect(UsageLimitsModel.reportedBalances(window).isEmpty)
        #expect(UsageLimitsModel.reportedBalances("Provider: openrouter\n\nCredits balance: $5.00").isEmpty)
        #expect(UsageLimitsModel.reportedBalances("Usage: 12 calls · 48,210 in / 3,904 out\nContext: 31% of 200K tokens").isEmpty)
    }

    @Test(arguments: [("$7", "$7"), ("$12.34", "$12.34"), ("$1,234.5", "$1,234.5"), ("$-0.50", "-$0.50"), ("-$2.00", "-$2.00")])
    func dollars(text: String, shown: String) {
        #expect(UsageLimitsModel.dollars(text) == shown)
    }

    @Test(arguments: ["—", "", "12.34", "$", "$nan", "$inf", "$1e5", "€5.00", "-$-1.00", "$5 left"])
    func notDollars(text: String) {
        #expect(UsageLimitsModel.dollars(text) == nil)
    }

    @Test func nousFromBillingState() {
        // H:tui_gateway/billing_view.py `_serialize_billing_state`, and the handler's fail-open answer. The credits Nous
        // can spend (`usage.total_spendable_display`, /usage's "Total usable") come before the account balance.
        let both = #"{"ok": true, "logged_in": true, "balance_usd": "3.4", "balance_display": "$3.40", "usage": {"ok": true, "available": true, "total_spendable_display": "$1,007.50", "topup_remaining_display": "$7.50"}}"#
        #expect(UsageLimitsModel.nousBalance(json(both)) == .amount("$1,007.50"))
        // No total (Hermes' usage model is fail-open, and a window plan has none): the account balance.
        #expect(UsageLimitsModel.nousBalance(json(#"{"ok": true, "logged_in": true, "balance_display": "$3.40", "usage": {"ok": true, "available": false}}"#)) == .amount("$3.40"))
        #expect(UsageLimitsModel.nousBalance(json(#"{"ok": true, "logged_in": true, "balance_display": "$3.40", "usage": {"available": true, "total_spendable_display": null}}"#)) == .amount("$3.40"))
        #expect(UsageLimitsModel.nousBalance(json(#"{"ok": true, "logged_in": true, "balance_display": "$3.40", "usage": {"available": false, "total_spendable_display": "$9.00"}}"#)) == .amount("$3.40"),
                "a total the usage model says isn't available doesn't count")
        #expect(UsageLimitsModel.nousBalance(json(#"{"ok": true, "logged_in": false, "usage": {"available": true, "total_spendable_display": "$9.00"}}"#)) == .unavailable,
                "signed out: nothing")
        #expect(UsageLimitsModel.nousBalance(json(#"{"ok": true, "logged_in": true, "balance_usd": "7.5", "balance_display": "$7.50"}"#)) == .amount("$7.50"))
        #expect(UsageLimitsModel.nousBalance(json(#"{"ok": true, "logged_in": true, "balance_usd": "7.5", "balance_display": null}"#)) == .amount("$7.5"))
        #expect(UsageLimitsModel.nousBalance(json(#"{"ok": true, "logged_in": true, "balance_usd": null, "balance_display": "—"}"#)) == .unavailable)
        #expect(UsageLimitsModel.nousBalance(json(#"{"ok": true, "logged_in": false, "free_tier_account": true, "free_tier_model": "x"}"#)) == .unavailable)
        #expect(UsageLimitsModel.nousBalance(json(#"{"ok": true, "logged_in": false, "free_tier_account": false}"#)) == .unavailable)
        #expect(UsageLimitsModel.nousBalance(json(#"{"ok": true, "logged_in": false, "free_tier_account": false, "error": "could not load billing state"}"#))
                == .failed("could not load billing state"))
        // Signed in with a balance: a side error (the card, say) doesn't hide it.
        #expect(UsageLimitsModel.nousBalance(json(#"{"ok": true, "logged_in": true, "balance_display": "$3.00", "error": "card lookup failed"}"#)) == .amount("$3.00"))
    }

    /// A /usage answer as the page keeps it: its figures.
    private func done(_ text: String) -> UsageRead<[String: UsageBalance]> { .done(UsageLimitsModel.reportedBalances(text)) }

    private func rows(_ provider: String = "openrouter", report: UsageRead<[String: UsageBalance]>,
                      billing: UsageRead<JSONValue> = .notAsked, offline: Bool = false) -> [String: UsageBalanceRow] {
        let options = ModelOptions(json: payAsYouGo)
        let blocks = UsageLimitsModel.blocks(options, currentProvider: provider, now: now)
        let list = UsageLimitsModel.balanceRows(options, blocks: blocks, currentProvider: provider, report: report, billing: billing, offline: offline)
        return Dictionary(uniqueKeysWithValues: list.map { ($0.provider, $0) })
    }

    @Test func rowsAreTheQuietLoginsChatsFirstEachNameOnce() {
        let options = ModelOptions(json: payAsYouGo)
        let blocks = UsageLimitsModel.blocks(options, currentProvider: "deepseek-alt", now: now)
        let list = UsageLimitsModel.balanceRows(options, blocks: blocks, currentProvider: "deepseek-alt", report: .pending, billing: .notAsked, offline: false)
        // Anthropic has a plan (a block, not a row); xAI is signed out; the chat's DeepSeek row is the one kept.
        #expect(list.map(\.provider) == ["deepseek-alt", "openrouter", "nous"])
        #expect(list[0].label == "DeepSeek · This Chat" && list[1].label == "OpenRouter")
    }

    @Test func checkingThenWhatHermesSaid() {
        let asking = rows(report: .pending, billing: .pending)
        #expect(asking["openrouter"]?.balance == .checking && asking["openrouter"]?.value() == UsageLimitsModel.balanceChecking)
        #expect(asking["nous"]?.balance == .checking)
        #expect(asking["deepseek"]?.balance == .unavailable, "no read can fill a key's balance: never Checking")
        let answered = rows(report: done(usageText), billing: .pending)
        #expect(answered["openrouter"]?.value(money: { BillingText.money($0, locale: Locale(identifier: "en_US")) }) == "$12.34")
        #expect(answered["nous"]?.balance == .amount("$7.50"), "the chat's own /usage answers before billing.state")
        #expect(answered["deepseek"]?.value() == UsageLimitsModel.balanceUnavailable && answered["deepseek"]?.note == nil)
        // billing.state first: Nous's figure shows while /usage is still out.
        let billed = rows(report: .pending, billing: .done(json(#"{"logged_in": true, "balance_display": "$7.50"}"#)))
        #expect(billed["nous"]?.balance == .amount("$7.50") && billed["openrouter"]?.balance == .checking)
    }

    @Test func aKeysChatProviderNeverWaitsOnUsage() {
        // DeepSeek is paid by key: /usage gives it no balance, so a read still out or failed doesn't speak for it.
        #expect(rows("deepseek", report: .pending)["deepseek"]?.balance == .unavailable)
        #expect(rows("deepseek", report: .failed("usage report failed"))["deepseek"]?.balance == .unavailable)
        #expect(rows("deepseek", report: .failed("usage report failed"))["deepseek"]?.note == nil)
        // ...while OpenRouter, in its own chat, waits on it.
        #expect(rows("openrouter", report: .pending)["openrouter"]?.balance == .checking)
        // A figure in the report counts for whichever provider it names (a provider plugin's /usage can give one).
        #expect(rows("deepseek", report: done("📈 Account limits\nProvider: deepseek\nCredits balance: $4.20"))["deepseek"]?.balance == .amount("$4.20"))
    }

    @Test func answersJoinNewestFirstAndKeepWhatALaterOneLeftOut() {
        let first = UsageLimitsModel.joined(.pending, ["openrouter": .amount("$12.34"), "nous": .amount("$7.50")], newer: true)
        #expect(first == .done(["openrouter": .amount("$12.34"), "nous": .amount("$7.50")]))
        // A newer answer whose OpenRouter check failed (fail-open: no block) keeps $12.34; its Nous figure wins.
        let second = UsageLimitsModel.joined(first, ["nous": .amount("$7.00")], newer: true)
        #expect(second == .done(["openrouter": .amount("$12.34"), "nous": .amount("$7.00")]))
        // An older answer landing late fills only what is missing.
        let late = UsageLimitsModel.joined(.done(["nous": .amount("$7.00")]), ["openrouter": .amount("$9.99"), "nous": .amount("$7.50")], newer: false)
        #expect(late == .done(["openrouter": .amount("$9.99"), "nous": .amount("$7.00")]))
        // After a failure, an answer starts afresh.
        #expect(UsageLimitsModel.joined(.failed("usage report failed"), [:], newer: true) == .done([:]))
    }

    @Test func failuresSayWhyAndOfflineKeepsWhatWasRead() {
        let failed = rows(report: .failed("usage report failed"), billing: .done(json(#"{"logged_in": true, "balance_display": "$7.50"}"#)))
        #expect(failed["openrouter"]?.value() == UsageLimitsModel.balanceFailed && failed["openrouter"]?.note == "usage report failed")
        #expect(failed["nous"]?.balance == .amount("$7.50"), "billing.state still gives Nous")
        // Nous's portal failing shows only once /usage hasn't got it either.
        let portal = json(#"{"logged_in": false, "free_tier_account": false, "error": "could not load billing state"}"#)
        #expect(rows(report: .pending, billing: .done(portal))["nous"]?.balance == .checking)
        #expect(rows(report: done("Provider: openrouter\nCredits balance: $1.00"), billing: .done(portal))["nous"]?.note == "could not load billing state")
        // The free tier: nothing to show, nothing to explain.
        let free = rows(report: done(""), billing: .done(json(#"{"logged_in": false, "free_tier_account": true}"#)))["nous"]
        #expect(free?.balance == .unavailable && free?.note == nil)
        // Opened offline: what a read would fill says so; a key still has none.
        let away = rows(report: .notAsked, billing: .notAsked, offline: true)
        #expect(away["openrouter"]?.value() == UsageLimitsModel.balanceOffline && away["nous"]?.balance == .offline)
        #expect(away["deepseek"]?.balance == .unavailable)
        // Gone offline after the reads: the figures stay; a read cut off by it says Offline, not why it failed.
        let kept = rows(report: done(usageText), offline: true)
        #expect(kept["openrouter"]?.balance == .amount("$12.34") && kept["nous"]?.balance == .amount("$7.50"))
        #expect(rows(report: .failed("connection lost"), offline: true)["openrouter"]?.balance == .offline)
        // A read still out when the connection goes says Offline, not Checking…, until it is back.
        #expect(rows(report: .pending, offline: true)["openrouter"]?.balance == .offline)
    }

    @Test func notesSayWhereABalanceShows() {
        // In a chat on Anthropic, OpenRouter's balance isn't this chat's to read.
        let anthropic = rows("anthropic", report: done("📈 Account limits\nProvider: anthropic\nWeekly: 80% remaining (20% used)"))
        #expect(anthropic["openrouter"]?.balance == .unavailable && anthropic["openrouter"]?.note == UsageLimitsModel.balanceElsewhereNote)
        #expect(anthropic["nous"]?.note == nil, "Nous's comes with any chat's /usage: it isn't signed in here")
        // A chat that hasn't started has no /usage to ask.
        let fresh = rows(report: .notAsked)
        #expect(fresh["openrouter"]?.note == UsageLimitsModel.balanceNotStartedNote)
        #expect(fresh["nous"]?.note == UsageLimitsModel.balanceNotStartedNote)
        #expect(fresh["deepseek"]?.note == nil)
        // ...but the main bot's chat has billing.state for Nous.
        let main = rows(report: .notAsked, billing: .done(json(#"{"logged_in": true, "balance_display": "$7.50"}"#)))
        #expect(main["nous"]?.balance == .amount("$7.50") && main["nous"]?.note == nil)
        #expect(rows(report: done(usageText))["openrouter"]?.value(money: { _ in "formatted" }) == "formatted")
        #expect(rows(report: done("Provider: openrouter\nCredits balance: unlimited"))["openrouter"]?.value() == UsageLimitsModel.balanceUnlimited)
    }

    /// An OpenRouter key with a spending limit has a window (H:agent/account_usage.py "API key quota"), so OpenRouter
    /// shows as a plan, not a pay-as-you-go row; a single Codex login has its plan's windows.
    private let keyLimit = json("""
    {"model": "moonshotai/kimi-k3", "provider": "openrouter", "providers": [
      {"slug": "openrouter", "name": "OpenRouter", "authenticated": true, "models": ["moonshotai/kimi-k3"],
       "usage": {"windows": [{"label": "API key quota", "used_percent": 25, "resets_at": null, "scope": "account"}]}},
      {"slug": "openai-codex", "name": "ChatGPT or Codex Subscription", "authenticated": true, "models": ["gpt-5.5"],
       "usage": {"windows": [{"label": "Weekly", "used_percent": 14, "resets_at": "2026-10-30T17:46:00+00:00"}]}}
    ]}
    """)

    @Test func aPlansBlockShowsItsChatsBalanceUnderTheBars() throws {
        let options = ModelOptions(json: keyLimit)
        let blocks = UsageLimitsModel.blocks(options, currentProvider: "openrouter", now: now)
        let router = try #require(blocks.first { $0.provider == "openrouter" })
        #expect(UsageLimitsModel.balanceRows(options, blocks: blocks, currentProvider: "openrouter", report: done(usageText),
                                             billing: .notAsked, offline: false).isEmpty, "a block, so not a pay-as-you-go row")
        #expect(UsageLimitsModel.blockBalance(router, report: done(usageText)) == .amount("$12.34"))
        // Nothing until /usage answers, and nothing it didn't say.
        #expect(UsageLimitsModel.blockBalance(router, report: .pending) == nil)
        #expect(UsageLimitsModel.blockBalance(router, report: .failed("usage report failed")) == nil)
        #expect(UsageLimitsModel.blockBalance(router, report: .notAsked) == nil)
        #expect(UsageLimitsModel.blockBalance(router, report: done("Provider: openrouter\nAPI key usage: $5.00 total")) == nil)
        // A single Codex login's credits, in a chat on Codex; in a chat on OpenRouter, Codex's block has none.
        let codexText = "📈 Account limits\nProvider: openai-codex (Plus)\nCredits balance: unlimited"
        let codex = try #require(UsageLimitsModel.blocks(options, currentProvider: "openai-codex", now: now).first { $0.provider == "openai-codex" })
        #expect(UsageLimitsModel.blockBalance(codex, report: done(codexText)) == .unlimited)
        let codexElsewhere = try #require(blocks.first { $0.provider == "openai-codex" })
        #expect(UsageLimitsModel.blockBalance(codexElsewhere, report: done(codexText)) == nil)
        // A pool's logins: /usage doesn't say which one it read. A rate-limited OpenRouter (a block of notes) keeps it.
        let pooled = UsageLimitsModel.blocks(ModelOptions(json: catalog), currentProvider: "openai-codex", now: now)
        #expect(pooled.filter { $0.provider == "openai-codex" }.allSatisfy {
            UsageLimitsModel.blockBalance($0, report: done("Provider: openai-codex\nCredits balance: $5.00")) == nil })
        let limited = try #require(UsageLimitsModel.blocks(ModelOptions(json: catalog), currentProvider: "openrouter", now: now).first { $0.provider == "openrouter" })
        #expect(UsageLimitsModel.blockBalance(limited, report: done(usageText)) == .amount("$12.34"))
    }
}

@Suite("Menu extras · Model Prices")
struct ModelPricesTests {
    private static let modelsDev = Data("""
    {"anthropic": {"id": "anthropic", "models": {
        "claude-opus-5-5": {"name": "Claude Opus 5.5", "cost": {"input": 5, "output": 25, "cache_read": 0.5, "cache_write": 6.25}},
        "claude-haiku-4-5": {"cost": {"input": 1, "output": 5}}}},
     "deepseek": {"models": {"deepseek-v4": {"cost": {"input": 0.0000042, "output": 0.0011}}}},
     "openai": {"models": {"gpt-5.5": {"cost": {"input": 1.25, "output": 10}}}},
     "empty": {"models": {"x": {"name": "no cost"}}}}
    """.utf8)

    nonisolated static let formats: [(Double, String)] = [(3, "$3.00"), (0.3, "$0.30"), (0.0042, "$0.0042"), (0.000015, "$0.000015"),
                                              (0, "free"), (1250.5, "$1250.50")]

    @Test(arguments: formats)
    func format(value: Double, text: String) {
        #expect(ModelPrice.format(value) == text)
    }

    @Test func lines() {
        #expect(ModelPrice(input: "$3.00", output: "$15.00", cache: "$0.30").line == "$3.00 in · $15.00 out · $0.30 cached")
        #expect(ModelPrice(input: "free", output: "free", free: true).line == "Free")
        #expect(ModelPrice(input: "", output: "").known == false)
    }

    @Test func modelsDevDecodesAndMatches() throws {
        let prices = try #require(ModelsDevPrices(data: Self.modelsDev))
        #expect(prices.costs["empty"] == nil)
        let anthropic = prices.prices(provider: "anthropic", models: ["claude-opus-5-5[1m]", "anthropic/claude-haiku-4-5", "claude-x"])
        #expect(anthropic["claude-opus-5-5[1m]"]?.line == "$5.00 in · $25.00 out · $0.50 cached")
        #expect(anthropic["anthropic/claude-haiku-4-5"]?.line == "$1.00 in · $5.00 out")
        #expect(anthropic["claude-x"] == nil)
        #expect(prices.prices(provider: "unknown-provider", models: ["a"]).isEmpty)
        // The stored copy round-trips.
        let encoded = try #require(prices.encoded())
        let stored = try #require(ModelsDevPrices.decodeStored(encoded))
        #expect(stored.costs == prices.costs)
    }

    @Test func sections() throws {
        let options = ModelOptions(json: catalog)
        let fallback = ModelsDevPrices(data: Self.modelsDev)
        let sections = ModelPricesModel.sections(options, fallback: fallback, current: ("claude-opus-5-5[1m]", "anthropic"))
        // Signed-out Google never shows; the chat's provider leads.
        #expect(sections.map(\.id) == ["anthropic", "openai-codex", "openrouter", "nous", "deepseek"])
        let anthropic = sections[0]
        #expect(anthropic.rows.first?.current == true)
        #expect(anthropic.rows.first?.detail == "$5.00 in · $25.00 out · $0.50 cached")
        #expect(anthropic.footer == "Per million tokens. List prices from models.dev.")
        // A subscription is never priced by the token, even where models.dev knows the model.
        #expect(sections[1].rows.map(\.detail) == [ModelPricesModel.included])
        #expect(sections[2].rows.map(\.detail) == ["$2.00 in · $10.00 out · $0.20 cached", "Free"])
        #expect(sections[2].footer == ModelPricesModel.perMillion)
        #expect(sections[3].rows.map(\.detail) == [ModelPricesModel.included])
        #expect(sections[4].rows.first?.detail == "$0.0000042 in · $0.0011 out")
        // Without models.dev, unpriced models say so.
        let bare = ModelPricesModel.sections(options, fallback: nil, current: nil)
        #expect(bare.first { $0.id == "deepseek" }?.rows.first?.detail == ModelPricesModel.noPrice)
        #expect(bare.first { $0.id == "deepseek" }?.footer == nil)
        // models.dev couldn't be reached: the sections it would have filled say so; the gateway's own prices don't.
        let failed = ModelPricesModel.sections(options, fallback: nil, fallbackFailed: true, current: nil)
        #expect(failed.first { $0.id == "deepseek" }?.footer == ModelPricesModel.fallbackFailedFooter)
        #expect(failed.first { $0.id == "anthropic" }?.footer == ModelPricesModel.fallbackFailedFooter)
        #expect(failed.first { $0.id == "openrouter" }?.footer == ModelPricesModel.perMillion)
        #expect(failed.first { $0.id == "nous" }?.footer != ModelPricesModel.fallbackFailedFooter)
        // Search narrows to matching models; a provider with none drops out.
        let found = ModelPricesModel.sections(options, fallback: fallback, query: "kimi", current: nil)
        #expect(found.map(\.id) == ["openrouter"] && found[0].rows.count == 1)
    }

    @Test func sectionsMergeTwins() {
        // Two ids with one display name are one row, as on the Model sheet: the chat's model, else the priced one.
        let row = ModelProviderRow(slug: "openrouter", name: "OpenRouter", models: ["gpt-5.5-mini", "openai/gpt-5.5-mini"],
                                   aliases: [], capabilities: [:],
                                   pricing: ["openai/gpt-5.5-mini": ModelPrice(perMillionInput: 0.25, output: 2, cacheRead: nil)])
        let options = ModelOptions(providers: [row])
        let plain = ModelPricesModel.sections(options, fallback: nil, current: nil)
        #expect(plain[0].rows.map(\.model) == ["openai/gpt-5.5-mini"])
        let current = ModelPricesModel.sections(options, fallback: nil, current: ("gpt-5.5-mini", "openrouter"))
        #expect(current[0].rows.map(\.model) == ["gpt-5.5-mini"] && current[0].rows[0].current)
    }

    @Test func subtitlesAndFallbackNeed() {
        let options = ModelOptions(json: catalog)
        #expect(ModelPricesModel.menuSubtitle(options, model: "moonshotai/kimi-k3", provider: "openrouter") == "$2.00 in · $10.00 out")
        #expect(ModelPricesModel.menuSubtitle(options, model: "free/model:free", provider: "openrouter") == "Free")
        #expect(ModelPricesModel.menuSubtitle(options, model: "gpt-5.5", provider: "openai-codex") == ModelPricesModel.included)
        #expect(ModelPricesModel.menuSubtitle(options, model: "claude-haiku-4-5", provider: "anthropic") == nil)
        // With the list prices already on the device, as the page shows them.
        let listed = ModelsDevPrices(data: Self.modelsDev)
        #expect(ModelPricesModel.menuSubtitle(options, model: "claude-haiku-4-5", provider: "anthropic", fallback: listed) == "$1.00 in · $5.00 out")
        #expect(ModelPricesModel.needsFallback(options))
        #expect(ModelPricesModel.isSubscription("claude-subscription-directsdk-experimental"))
        #expect(ModelPricesModel.isSubscription("xai-oauth"))
        #expect(!ModelPricesModel.isSubscription("anthropic"))
    }
}

@Suite("Menu extras · prompt library")
@MainActor
struct PromptLibraryTests {
    private func fresh() -> (PromptLibrary, UserDefaults, String) {
        let suite = "hq.tests.prompts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (PromptLibrary(defaults: defaults, key: "prompts"), defaults, suite)
    }

    @Test func addEditDeleteMoveAndKeep() throws {
        let (library, defaults, suite) = fresh()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(library.add(text: "   ") == nil)
        let a = try #require(library.add(text: "Summarize this thread\nin three bullets"))
        let b = try #require(library.add(title: "Review", text: "Review the diff for bugs"))
        #expect(library.prompts.map(\.id) == [b.id, a.id])
        #expect(a.displayTitle == "Summarize this thread" && a.preview == "in three bullets")
        #expect(b.displayTitle == "Review" && b.preview == "Review the diff for bugs")
        // The same words again keep one, moved to the top.
        library.add(text: " Summarize this thread\nin three bullets ")
        #expect(library.prompts.map(\.id) == [a.id, b.id])
        #expect(library.contains(text: "Review the diff for bugs"))
        library.update(b.id, title: "", text: "Review the diff for bugs and races")
        #expect(library.prompts[1].text == "Review the diff for bugs and races")
        library.move(from: IndexSet(integer: 1), to: 0)
        #expect(library.prompts.map(\.id) == [b.id, a.id])
        // Kept across launches.
        let again = PromptLibrary(defaults: defaults, key: "prompts")
        #expect(again.prompts.map(\.id) == [b.id, a.id])
        library.update(a.id, title: "x", text: "  ")   // blank words delete it
        library.delete([b.id])
        #expect(library.prompts.isEmpty)
        #expect(PromptLibrary(defaults: defaults, key: "prompts").prompts.isEmpty)
    }

    @Test func deleteRestoresWhereItWasAndSignOutClears() throws {
        let (library, defaults, suite) = fresh()
        defer { defaults.removePersistentDomain(forName: suite) }
        let c = try #require(library.add(text: "third"))
        let b = try #require(library.add(text: "second"))
        let a = try #require(library.add(text: "first"))
        #expect(library.prompts.map(\.id) == [a.id, b.id, c.id])
        let gone = library.delete([a.id, c.id])
        #expect(gone.map(\.index) == [0, 2] && gone.map(\.prompt.id) == [a.id, c.id])
        #expect(library.delete([UUID()]).isEmpty)
        #expect(PromptsPageModel.deletedLabel(gone) == "Deleted 2 Prompts")
        #expect(PromptsPageModel.deletedLabel([gone[0]]) == "Deleted “first”")
        library.restore(gone)
        #expect(library.prompts.map(\.id) == [a.id, b.id, c.id])
        library.restore(gone)   // twice puts nothing back twice
        #expect(library.prompts.count == 3)
        #expect(PromptLibrary(defaults: defaults, key: "prompts").prompts.map(\.id) == [a.id, b.id, c.id])
        library.removeAll()
        #expect(library.prompts.isEmpty)
        #expect(PromptLibrary(defaults: defaults, key: "prompts").prompts.isEmpty)
    }

    /// The Prompts sheet's Edit: shown only with prompts, Done (prominent) while editing, and ended when Edit empties
    /// the list; back when Undo brings a prompt back.
    @Test func editButtonFollowsTheList() async throws {
        let (library, defaults, suite) = fresh()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PromptsPageModel(library: library, draft: "", insert: { _ in })
        let edit = UIBarButtonItem(title: "Edit", primaryAction: nil)
        PromptsSheet.followEdit(edit, model: model)
        #expect(edit.isHidden && !model.showsEdit)
        let prompt = try #require(library.add(text: "one"))
        #expect(await waitUntil { !edit.isHidden })
        model.editing = true
        #expect(await waitUntil { edit.title == "Done" && edit.style == .prominent })
        let gone = library.delete([prompt.id])
        #expect(await waitUntil { edit.isHidden && !model.editing })
        #expect(edit.title == "Edit" && edit.style == .plain)
        library.restore(gone)
        #expect(await waitUntil { !edit.isHidden && edit.title == "Edit" })
    }
}
