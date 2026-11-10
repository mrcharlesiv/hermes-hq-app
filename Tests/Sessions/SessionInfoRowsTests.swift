import Foundation
import Testing
@testable import HermesHQNative

/// [sessions-m9] Session Info's rows (docs/spec/3x-sessions.md §10), with the web's cases (`sessionInfoRows`).
@MainActor @Suite struct SessionInfoRowsTests {
    private var names: SessionInfoNames {
        var n = SessionInfoNames()
        n.model = { $0 == "anthropic/claude-opus-5.5" ? "Opus 5.5" : $0 == "openai/gpt-5" ? "GPT-5" : $0 }
        n.provider = { $0 == "anthropic" ? "Claude subscription" : $0 }
        n.profile = { $0 == "bike-shop" ? "Bike Shop" : $0 == "default" ? "Hermes" : $0 }
        return n
    }

    private var full: SessionInfoSource {
        var s = SessionInfoSource()
        s.model = "anthropic/claude-opus-5.5"; s.provider = "anthropic"; s.reasoning = "Extra High"; s.fast = true
        s.usage = SessionUsage(total: 15_400, input: 14_200, output: 1_200, contextUsed: 48_200, contextMax: 200_000, contextPercent: 24)
        s.row = SessionInfoStoredRow(model: "anthropic/claude-opus-5.5", cwd: "/home/hermes/reading", gitBranch: "main",
                                     estimatedCostUsd: 0.34, messageCount: 14, source: "desktop")
        s.profile = "bike-shop"; s.sessionId = "20260101_090000_aa0003"; s.gateway = "127.0.0.1:9970"; s.gatewayNote = "Connected"
        return s
    }

    private func row(_ label: String, _ rows: [SessionInfoRow]) -> SessionInfoRow? { rows.first { $0.label == label } }

    @Test func twelveRowsInTheWebsOrder() throws {
        var source = full
        source.answeredBy = ModelFallback(primary: "anthropic/claude-opus-5.5", fallback: "openai/gpt-5", reason: "overloaded")
        source.row?.handoffPlatform = "telegram"
        let rows = SessionInfoRows.rows(source, names: names)
        #expect(rows.map(\.label) == ["Answered By", "Chat Model", "Reasoning", "Context", "Tokens", "Cost", "Messages", "Folder",
                                      "Bot", "Source", "Gateway", "Chat ID"])
        #expect(row("Answered By", rows) == SessionInfoRow(label: "Answered By", value: "GPT-5",
                                                           note: "Opus 5.5 is unavailable on the gateway (overloaded)",
                                                           copy: "Answered By: openai/gpt-5 (anthropic/claude-opus-5.5 is unavailable on the gateway (overloaded))"))
        #expect(row("Chat Model", rows)?.value == "Opus 5.5" && row("Chat Model", rows)?.note == "Claude subscription")
        #expect(row("Reasoning", rows)?.value == "Extra High · Fast")
        #expect(row("Context", rows)?.value == "24%" && row("Context", rows)?.note == "48.2K of 200K · 151.8K left")
        #expect(row("Tokens", rows)?.value == "15.4K" && row("Tokens", rows)?.note == "14.2K in · 1.2K out")
        #expect(row("Cost", rows)?.value == "$0.34" && row("Cost", rows)?.note == "Estimated")
        #expect(row("Messages", rows)?.value == "14")
        #expect(row("Folder", rows) == SessionInfoRow(label: "Folder", value: "/home/hermes/reading", note: "main", mono: true))
        #expect(row("Bot", rows)?.value == "Bike Shop" && row("Bot", rows)?.copy == "Bot: Bike Shop (bike-shop)")
        #expect(row("Source", rows)?.value == "Telegram")
        #expect(row("Gateway", rows)?.value == "127.0.0.1:9970" && row("Gateway", rows)?.note == "Connected")
        #expect(row("Chat ID", rows)?.mono == true)
        #expect(rows.map(\.identifier).prefix(2) == ["info.row.answered-by", "info.row.chat-model"])
        #expect(row("Chat ID", rows)?.identifier == "info.row.chat-id")
    }

    @Test func copyTextKeepsTheRawIds() {
        var source = full
        source.answeredBy = ModelFallback(primary: "anthropic/claude-opus-5.5", fallback: "openai/gpt-5", reason: nil)
        let text = SessionInfoRows.copyText(SessionInfoRows.rows(source, names: names))
        #expect(text == """
        Answered By: openai/gpt-5 (anthropic/claude-opus-5.5 is unavailable on the gateway)
        Chat Model: anthropic/claude-opus-5.5 (anthropic)
        Reasoning: Extra High · Fast
        Context: 24% (48.2K of 200K · 151.8K left)
        Tokens: 15.4K (14.2K in · 1.2K out)
        Cost: $0.34 (Estimated)
        Messages: 14
        Folder: /home/hermes/reading (main)
        Bot: Bike Shop (bike-shop)
        Gateway: 127.0.0.1:9970 (Connected)
        Chat ID: 20260101_090000_aa0003
        """)
    }

    @Test func rowsOnlyWhenTheyHaveAValue() {
        // A new chat, nothing sent.
        var fresh = SessionInfoSource()
        fresh.model = "hermes-4"; fresh.profile = "default"; fresh.sessionId = "s1"; fresh.gateway = "gw"; fresh.gatewayNote = "Offline"
        #expect(SessionInfoRows.rows(fresh, names: names).map(\.label) == ["Model", "Bot", "Gateway", "Chat ID"])
        #expect(row("Bot", SessionInfoRows.rows(fresh, names: names))?.value == "Hermes")
        #expect(row("Gateway", SessionInfoRows.rows(fresh, names: names))?.note == "Offline")
        // Not resumed yet: the stored row speaks for the model and the cost; no Reasoning, Context or Tokens.
        var stored = SessionInfoSource()
        stored.row = SessionInfoStoredRow(model: "hermes-4", actualCostUsd: 0.02, messageCount: 2)
        stored.sessionId = "s1"
        let rows = SessionInfoRows.rows(stored)
        #expect(rows.map(\.label) == ["Model", "Cost", "Messages", "Chat ID"])
        #expect(row("Cost", rows)?.value == "$0.02" && row("Cost", rows)?.note == nil)             // an actual cost: no note
        #expect(SessionInfoRows.rows(SessionInfoSource()).isEmpty)
    }

    @Test func contextTokensAndCost() {
        func rows(_ usage: SessionUsage, row stored: SessionInfoStoredRow? = nil) -> [SessionInfoRow] {
            var s = SessionInfoSource()
            s.usage = usage; s.row = stored
            return SessionInfoRows.rows(s)
        }
        #expect(row("Context", rows(SessionUsage(contextUsed: 48_200, contextMax: 200_000)))?.value == "24%")          // used ÷ max
        #expect(row("Context", rows(SessionUsage(contextUsed: 10, contextMax: 200_000, contextPercent: 24.4, contextEstimated: true)))?.value == "~24%")
        #expect(row("Context", rows(SessionUsage(contextUsed: 900_000, contextMax: 200_000)))?.value == "100%")        // clamped
        #expect(row("Context", rows(SessionUsage(contextMax: 200_000, contextPercent: -3)))?.value == "0%")
        #expect(row("Context", rows(SessionUsage(contextUsed: 5, contextMax: 0))) == nil)
        #expect(row("Context", rows(SessionUsage(contextMax: 1_000)))?.note == "0 of 1K · 1K left")
        #expect(row("Tokens", rows(SessionUsage(total: 999)))?.value == "999" && row("Tokens", rows(SessionUsage(total: 999)))?.note == nil)
        #expect(row("Tokens", rows(SessionUsage(total: 0))) == nil)
        #expect(row("Tokens", rows(SessionUsage(total: 1_500_000, input: 1_400_000)))?.note == "1.4M in · 0 out")
        // Live usage first, then the row's actual cost, then its estimate; only above zero; four decimals below a cent.
        #expect(row("Cost", rows(SessionUsage(costUsd: 0.0042)))?.value == "$0.0042")
        #expect(row("Cost", rows(SessionUsage(costUsd: 1.5), row: SessionInfoStoredRow(actualCostUsd: 9)))?.value == "$1.50")
        #expect(row("Cost", rows(SessionUsage(costUsd: 1.5)))?.note == nil)
        #expect(row("Cost", rows(SessionUsage(), row: SessionInfoStoredRow(actualCostUsd: 9, estimatedCostUsd: 2)))?.value == "$9.00")
        #expect(row("Cost", rows(SessionUsage(), row: SessionInfoStoredRow(estimatedCostUsd: 2)))?.note == "Estimated")
        #expect(row("Cost", rows(SessionUsage(costUsd: 0), row: SessionInfoStoredRow(estimatedCostUsd: 2))) == nil)   // the live zero wins, as the web
        #expect(SessionInfoRows.count(999) == "999" && SessionInfoRows.count(1_000) == "1K" && SessionInfoRows.count(15_400) == "15.4K")
        #expect(SessionInfoRows.count(200_000) == "200K" && SessionInfoRows.count(1_500_000) == "1.5M" && SessionInfoRows.count(0) == "0")
        // Stress round 1: billions and trillions have their own letters, a figure never reads "1000K", and a broken
        // gateway's 1e18 is capped instead of spelled out ("1000000000000M").
        #expect(SessionInfoRows.count(999_949) == "999.9K" && SessionInfoRows.count(999_950) == "1M" && SessionInfoRows.count(999_999) == "1M")
        #expect(SessionInfoRows.count(2_500_000_000) == "2.5B" && SessionInfoRows.count(999_960_000) == "1B")
        #expect(SessionInfoRows.count(3_000_000_000_000) == "3T" && SessionInfoRows.count(999_900_000_000_000) == "999.9T")
        #expect(SessionInfoRows.count(1_000_000_000_000_000_000) == "999T+" && SessionInfoRows.count(Int.max) == "999T+")
        #expect(SessionInfoRows.count(-5) == "-5")
        #expect(row("Tokens", rows(SessionUsage(total: 1_000_000_000_000_000_000)))?.value == "999T+")
    }

    /// Tester 2026-10-27: the figures Hermes already sends, as rows (their mockup's numbers).
    @Test func usageCard() {
        let usage = SessionUsage(total: 17_184_800, input: 342_000, output: 84_800, contextUsed: 264_000, contextMax: 1_000_000,
                                 contextPercent: 26, contextEstimated: false, costUsd: 0.037, prompt: 17_100_000,
                                 reasoning: 12_400, calls: 96, compressions: 2, cacheHitPercent: 98,
                                 tokensPerSecond: 82.4, secondsPerCall: 1.24)
        let rows = SessionInfoRows.usageRows(usage, price: "$0.15 in · $0.60 out")
        #expect(rows.map(\.label) == ["Context", "Tokens", "Cache", "Speed", "Cost"])
        #expect(rows[0] == SessionInfoRow(label: "Context", value: "26%", note: "264K of 1M · 736K left · compressed 2×", bar: 0.26))
        // In counts the cache reads, so in + out make the total.
        #expect(rows[1].value == "17.2M" && rows[1].note == "17.1M in · 84.8K out · 12.4K reasoning" && rows[1].bar == nil)
        #expect(rows[2] == SessionInfoRow(label: "Cache", value: "98%", note: "~16.8M from cache · 342K new", bar: 0.98))
        #expect(rows[3].value == "82 tokens/s" && rows[3].note == "1.2 s a call · 96 calls")
        #expect(rows[4].value == "$0.04" && rows[4].note == "$0.15 in · $0.60 out per 1M")
        #expect(SessionInfoRows.copyText(rows).contains("Cache: 98% (~16.8M from cache · 342K new)"))

        // Only what was sent: no cache reads, no timings (Codex), one compression, a slow model.
        var plain = SessionUsage(total: 2_000, input: 1_500, output: 500, contextUsed: 900_000, contextMax: 1_000_000, prompt: 1_500,
                                 calls: 1, compressions: 1)
        var labels = SessionInfoRows.usageRows(plain).map(\.label)
        #expect(labels == ["Context", "Tokens", "Calls"])
        #expect(SessionInfoRows.usageRows(plain)[0].note == "900K of 1M · 100K left · compressed 1×")
        #expect(SessionInfoRows.usageRows(plain)[2].value == "1" && SessionInfoRows.usageRows(plain)[2].note == nil)
        plain.tokensPerSecond = 7.26; plain.secondsPerCall = 3
        #expect(SessionInfoRows.usageRows(plain).first { $0.label == "Speed" }?.value == "7.3 tokens/s")
        #expect(SessionInfoRows.usageRows(plain).first { $0.label == "Speed" }?.note == "3 s a call · 1 call")
        labels = SessionInfoRows.usageRows(SessionUsage(cacheHitPercent: 50)).map(\.label)
        #expect(labels.isEmpty)                                                       // a hit rate with nothing sent: no row
        // The price words: a plan, a free model; the stored estimate keeps "Estimated" first.
        #expect(SessionInfoRows.usageRows(SessionUsage(costUsd: 1), price: "Included")[0].note == "Included in your plan")
        #expect(SessionInfoRows.usageRows(SessionUsage(costUsd: 1), price: "Free")[0].note == "Free model")
        #expect(SessionInfoRows.usageRows(nil, storedCost: 2, price: "$3.00 in")[0].note == "Estimated · $3.00 in per 1M")
        #expect(SessionInfoRows.usageRows(nil, storedCost: 2, storedCostIsActual: true)[0].note == nil)
    }

    @Test func usageDecodesTheNewFields() throws {
        let usage = try #require(SessionUsage.decode(try JSONValue.parse(Data("""
        {"total": 10, "input": 2, "output": 3, "prompt": 7, "reasoning": 1, "calls": 4, "compressions": 0,
         "cache_hit_pct": 71, "avg_tps": 55.5, "avg_latency_s": 0.8}
        """.utf8))))
        #expect(usage.prompt == 7 && usage.reasoning == 1 && usage.calls == 4 && usage.compressions == 0)
        #expect(usage.cacheHitPercent == 71 && usage.tokensPerSecond == 55.5 && usage.secondsPerCall == 0.8)
        let odd = try #require(SessionUsage.decode(try JSONValue.parse(Data(#"{"cache_hit_pct": 140, "avg_tps": 0, "avg_latency_s": -1}"#.utf8))))
        #expect(odd.cacheHitPercent == 100 && odd.tokensPerSecond == nil && odd.secondsPerCall == nil)
    }

    @Test func folderPrefersTheLiveValues() {
        var s = SessionInfoSource()
        s.row = SessionInfoStoredRow(cwd: "/stored", gitBranch: "main")
        #expect(row("Folder", SessionInfoRows.rows(s))?.value == "/stored" && row("Folder", SessionInfoRows.rows(s))?.note == "main")
        s.liveCwd = "/live"; s.liveBranch = "feature"
        #expect(row("Folder", SessionInfoRows.rows(s))?.value == "/live" && row("Folder", SessionInfoRows.rows(s))?.note == "feature")
        s.row = nil; s.liveBranch = nil
        #expect(row("Folder", SessionInfoRows.rows(s))?.note == nil)
    }

    @Test func sourceNames() {
        let cases = ["telegram": "Telegram", "Discord": "Discord", "teams": "Microsoft Teams", "cron": "Scheduled job", "cli": "Terminal",
                     "oneshot": "One-off run", "imessage": "iMessage", "sms": "SMS", "api": "API", "my_custom-thing": "My custom thing",
                     "desktop": "", "dispatch": "", "tui": "", "ios": "", "app": "", " ": ""]
        for (raw, shown) in cases { #expect(SessionInfoRows.sourceName(raw) == shown, "\(raw)") }
        #expect(SessionInfoRows.sourceName(nil) == "")
        var s = SessionInfoSource()
        s.row = SessionInfoStoredRow(source: "desktop", handoffPlatform: "telegram")              // the handoff wins
        #expect(row("Source", SessionInfoRows.rows(s))?.value == "Telegram")
        s.row = SessionInfoStoredRow(source: "desktop")
        #expect(row("Source", SessionInfoRows.rows(s)) == nil)
    }

    @Test func fallbackShowsWhileTheModelIsOneOfThePair() {
        var s = full
        s.answeredBy = ModelFallback(primary: "anthropic/claude-opus-5.5[1m]", fallback: "openai/gpt-5", reason: nil)
        #expect(SessionInfoRows.rows(s, names: names).first?.label == "Answered By")              // tags and paths are ignored
        s.model = "OPENAI/GPT-5"
        #expect(SessionInfoRows.rows(s, names: names).first?.label == "Answered By")
        s.model = "mistral/large"                                                                 // the user changed the model
        #expect(SessionInfoRows.rows(s, names: names).first?.label == "Model")
        s.model = nil
        #expect(SessionInfoRows.rows(s, names: names).map(\.label).prefix(2) == ["Answered By", "Chat Model"])
        #expect(SessionInfoRows.bareModel(" Anthropic/Claude-Opus-5.5[1m] ") == "claude-opus-5.5")
    }

    @Test func fallbackLinesParse() {
        let model = ModelFallback.parse("Model fallback: claude-opus-5.5 via anthropic unavailable (overloaded); using gpt-5 via openai. Retrying")
        #expect(model == ModelFallback(primary: "claude-opus-5.5", fallback: "gpt-5", reason: "overloaded"))
        #expect(ModelFallback.parse("Model fallback: a via p unavailable; using b via q.") == ModelFallback(primary: "a", fallback: "b", reason: nil))
        #expect(ModelFallback.parse("Provider fallback: anthropic unavailable; using openai for this response")
                == ModelFallback(primary: "anthropic", fallback: "openai", reason: nil))
        #expect(ModelFallback.parse("Compacting the conversation") == nil && ModelFallback.parse("") == nil)
        #expect(ModelFallback.restores("Primary model restored: claude-opus-5.5") && !ModelFallback.restores("Model fallback: x"))
    }

    @Test func gatewayWords() {
        #expect(SessionInfoRows.gatewayNote(.ready) == "Connected" && SessionInfoRows.gatewayNote(.offline(reason: "x")) == "Offline")
        #expect(SessionInfoRows.gatewayNote(.reconnecting(attempt: 2)) == "Reconnecting…" && SessionInfoRows.gatewayNote(.connecting) == "Connecting…")
        #expect(SessionInfoRows.gatewayNote(.signedOut(reason: "x")) == "Signed Out")
        #expect(SessionInfoRows.host(URL(string: "http://127.0.0.1:9970")!) == "127.0.0.1:9970")
        #expect(SessionInfoRows.host(URL(string: "https://hq.example.com/path")!) == "hq.example.com")
    }
}
