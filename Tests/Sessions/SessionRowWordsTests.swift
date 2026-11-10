import Foundation
import Testing
@testable import HermesHQNative

/// [sessions-m9] The row's figures, second line and VoiceOver label (docs/spec/3x-sessions.md §9).
@Suite struct SessionRowWordsTests {
    private func chat(title: String = "Garden plan", preview: String? = "Water the beds", tokens: Int = 0, cost: Double = 0,
                      status: SessionStatus = .idle, metadata: String = "", pending: SessionPending? = nil) -> SessionSummary {
        var s = SessionSummary(id: "s", profile: "default", title: title, preview: preview, lastActive: nil, source: nil,
                               unread: status == .unread, isRunning: status == .working)
        s.tokens = tokens; s.cost = cost; s.status = status; s.metadata = metadata; s.pending = pending
        return s
    }

    /// Audit 05-20: one hidden chat is "chat".
    @Test func showMoreSaysChatForOne() {
        #expect(SessionRowWords.showMoreLabel(1) == "Show 1 more chat")
        #expect(SessionRowWords.showMoreLabel(4) == "Show 4 more chats")
        #expect(SessionRowWords.showMoreLabel(0) == "Show fewer chats")
    }

    @Test func compactTokens() {
        let cases: [(Int, String?)] = [(0, nil), (-5, nil), (1, "1"), (999, "999"), (1_000, "1k"), (1_230, "1.2k"), (15_400, "15.4k"),
                                       (999_949, "999.9k"), (999_950, "1M"), (1_500_000, "1.5M"), (2_000_000, "2M"),
                                       (Int.max, String(format: "%.1fM", Double(Int.max) / 1_000_000))]
        for (value, words) in cases { #expect(SessionRowWords.compactTokens(value) == words, "\(value)") }
        #expect(SessionRowWords.compactTokens(999_499) == "999.5k")
    }

    @Test func cost() {
        #expect(SessionRowWords.cost(0) == nil && SessionRowWords.cost(0.004) == nil && SessionRowWords.cost(0.0099) == nil)
        #expect(SessionRowWords.cost(0.01) == "$0.01" && SessionRowWords.cost(0.34) == "$0.34" && SessionRowWords.cost(12.5) == "$12.50")
        #expect(SessionRowWords.cost(.nan) == nil && SessionRowWords.cost(.infinity) == nil && SessionRowWords.cost(-3) == nil)
        #expect(SessionRowWords.cost(1234.5) == "$1234.50")                                    // a point, never a locale's comma
    }

    @Test func trailingText() {
        let garden = chat(tokens: 1_230, cost: 0.02)
        #expect(SessionRowWords.trailing(garden, detail: [.time], time: "9:05 AM") == "9:05 AM")
        #expect(SessionRowWords.trailing(garden, detail: [.tokens, .time], time: "9:05 AM") == "1.2k · 9:05 AM")
        #expect(SessionRowWords.trailing(garden, detail: [.tokens, .cost, .time], time: "Yesterday") == "1.2k · $0.02 · Yesterday")
        #expect(SessionRowWords.trailing(chat(tokens: 15_400, cost: 12.5), detail: [.tokens, .cost], time: "9:05 AM") == "15.4k · $12.50")
        #expect(SessionRowWords.trailing(garden, detail: [.preview], time: "9:05 AM") == nil)
        // Sub-cent spend says nothing; no tokens says nothing.
        #expect(SessionRowWords.trailing(chat(tokens: 999, cost: 0.004), detail: [.tokens, .cost, .time], time: "Mon") == "999 · Mon")
        #expect(SessionRowWords.trailing(chat(), detail: [.tokens, .cost, .time], time: "Mon") == "Mon")
        #expect(SessionRowWords.trailing(chat(), detail: [.tokens, .cost, .time], time: "") == nil)
    }

    @Test func metadata() {
        #expect(SessionRowWords.metadata(branch: "main", model: "anthropic/hermes-4", messages: 2, toolCalls: 0) == "main · hermes-4 · 2 messages")
        #expect(SessionRowWords.metadata(branch: nil, model: "hermes-4", messages: 1, toolCalls: 1) == "hermes-4 · 1 message · 1 tool call")
        #expect(SessionRowWords.metadata(branch: " ", model: "", messages: 14, toolCalls: 3) == "14 messages · 3 tool calls")
        #expect(SessionRowWords.metadata(branch: nil, model: nil, messages: nil, toolCalls: nil) == "")
    }

    @Test func secondLineOrder() {
        let meta = "main · hermes-4 · 2 messages"
        // Preview on: the preview; off: the metadata; neither: the owner alone.
        #expect(SessionRowWords.detailText(chat(metadata: meta), detail: [.preview, .time]) == "Water the beds")
        #expect(SessionRowWords.detailText(chat(metadata: meta), detail: [.time]) == meta)
        #expect(SessionRowWords.detailText(chat(preview: nil, metadata: meta), detail: [.preview]) == meta)
        #expect(SessionRowWords.detailText(chat(preview: nil), detail: [.preview]) == nil)
        // No title of its own: the title already is the preview, so the detail is the metadata.
        #expect(SessionRowWords.detailText(chat(title: " ", metadata: meta), detail: [.preview]) == meta)
        // A live status wins over the pending line, which wins over the detail.
        let draft = SessionPending(failed: false, text: "call the plumber")
        #expect(SessionRowWords.detailText(chat(status: .draft, pending: draft), detail: [.preview]) == "Draft: call the plumber")
        #expect(SessionRowWords.detailText(chat(status: .working, pending: draft), detail: [.preview]) == "Working…")
        #expect(SessionRowWords.detailText(chat(status: .needsInput, pending: draft), detail: [.preview]) == "Needs your input")
    }

    @Test func pendingLine() {
        #expect(SessionPending.pending(lost: nil, draft: nil) == nil && SessionPending.pending(lost: nil, draft: "  \n") == nil)
        #expect(SessionPending.pending(lost: nil, draft: " call the plumber ") == SessionPending(failed: false, text: "call the plumber"))
        let both = SessionPending.pending(lost: "send the quote", draft: "call the plumber")
        #expect(both == SessionPending(failed: true, text: "send the quote"))              // a lost send wins over a draft
        #expect(both?.prefix == "Not Delivered:" && SessionPending(failed: false, text: "x").prefix == "Draft:")
    }

    @Test func voiceOverLabel() {
        var s = chat(tokens: 1_230, cost: 0.34, status: .unread, metadata: "main")
        s.pinned = true
        let label = SessionRowWords.accessibilityLabel(title: "Garden plan", session: s, ownerName: "Hermes", detail: [.preview, .time, .tokens, .cost],
                                                       time: "9:05 AM", colorName: "Red")
        #expect(label == "Garden plan. Hermes: Water the beds. 1.2k tokens. $0.34. 9:05 AM. Unread. Pinned. Color: Red")
        let working = SessionRowWords.accessibilityLabel(title: "Garden plan", session: chat(status: .working), ownerName: "Hermes",
                                                         detail: [.preview, .time], time: "Now", busy: true)
        #expect(working == "Garden plan. Working. Hermes. Now. Deleting")
        let lost = chat(pending: SessionPending(failed: true, text: "send the quote"))
        #expect(SessionRowWords.accessibilityLabel(title: "T", session: lost, ownerName: "Hermes", detail: [.preview], time: "Now")
                == "T. Hermes: Not Delivered: send the quote")
        let hit = SessionRowWords.accessibilityLabel(title: "T", session: chat(), ownerName: "Hermes", detail: [.time], time: "Now", snippet: "the match")
        #expect(hit == "T. Hermes: the match. Now")
    }

    @Test func usageDecodesLeniently() {
        let usage = SessionUsage.decode(BotsFixture.parse(#"{"total":15400,"input":14200,"output":1200,"context_used":48200,"context_max":200000,"context_percent":24,"context_estimated":false,"cost_usd":0.34,"calls":9}"#))
        #expect(usage == SessionUsage(total: 15_400, input: 14_200, output: 1_200, contextUsed: 48_200, contextMax: 200_000,
                                      contextPercent: 24, contextEstimated: false, costUsd: 0.34, calls: 9))
        let odd = SessionUsage.decode(BotsFixture.parse(#"{"total":"many","input":-4,"output":null,"context_max":{"x":1},"cost_usd":"free"}"#))
        #expect(odd == SessionUsage())
        #expect(SessionUsage.decode(.string("x")) == nil && SessionUsage.decode(nil) == nil && SessionUsage.decode(.array([])) == nil)
    }

    @Test func rowDecodesNewFieldsLeniently() throws {
        let good = try #require(SidebarSessionRow(json: BotsFixture.parse(#"{"id":"a","profile":"p","input_tokens":1000,"output_tokens":230,"actual_cost_usd":0.02,"estimated_cost_usd":0.5,"git_branch":" main ","handoff_platform":"telegram"}"#)))
        #expect(good.totalTokens == 1_230 && good.costUsd == 0.02 && good.gitBranch == "main" && good.handoffPlatform == "telegram")
        let estimate = try #require(SidebarSessionRow(json: BotsFixture.parse(#"{"id":"a","profile":"p","estimated_cost_usd":0.34}"#)))
        #expect(estimate.costUsd == 0.34 && estimate.totalTokens == 0)
        let bad = try #require(SidebarSessionRow(json: BotsFixture.parse(#"{"id":"a","profile":"p","input_tokens":"lots","output_tokens":-9,"actual_cost_usd":null,"estimated_cost_usd":"x","git_branch":null,"handoff_platform":""}"#)))
        #expect(bad.totalTokens == 0 && bad.costUsd == 0 && bad.gitBranch == nil && bad.handoffPlatform == nil)
        // An older cache file without the keys still loads.
        let old = try JSONDecoder().decode(SidebarSessionRow.self, from: Data(#"{"id":"a","profile":"p"}"#.utf8))
        #expect(old.inputTokens == nil && old.costUsd == 0)
    }
}
