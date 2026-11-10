// [restated] Owner, 2026-10-30: in Hermes's chat, a long turn compressed the chat while it ran, and Hermes restated the
// unfinished request after its summary ("[STILL IN PROGRESS — this is the active request, restated after the compaction
// boundary …]" then the voice memo, MEDIA line and all). History hands that carrier back as a user row whose
// `display_content` is the restatement, so the chat drew it as a second bubble of the owner's, under the reply to the
// first: "Shouldn't this still in progress message be wrapped up in to a small notification?"

import Foundation
import Testing
@testable import HermesHQNative

@Suite("A request Hermes restated after compressing the chat")
@MainActor
struct RestatedRequestTests {
    static let header = "[STILL IN PROGRESS — this is the active request, restated after the compaction boundary because it "
        + "was not finished yet. Continue it; do not start over.]"
    static let memo = "MEDIA:\"/Users/me/.hermes/attachments/voice-memo-207.m4a\"\n\nVoice memo transcript: I need you "
        + "to work on it until it's fixed, figure it out, get it working properly."
    static let summary = "[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted into the summary below.\n\n"
        + "## Active Task\nFix the daily review.\n\n--- END OF CONTEXT SUMMARY — respond to the message below, not the summary above ---"

    /// The rows of the owner's chat (session 20260101_090000_aa0001, rows 38212-38271), as `/messages` returns them with
    /// `include_compacted`: the voice memo, its first reply, and the carrier Hermes wrote at 9:38.
    private var rows: [JSONValue] {
        [
            ["role": "user", "content": .string(Self.memo), "row_id": 38212, "timestamp": 1793370749],
            ["role": "assistant", "content": "I'm on it. My approach: take the \"decide when it's done\" step away from the bot.",
             "row_id": 38213, "timestamp": 1793370770],
            ["role": "user", "content": .string(Self.summary + "\n\n" + Self.header + "\n" + Self.memo),
             "display_content": .string(Self.header + "\n" + Self.memo), "_compressed_summary": true,
             "row_id": 38271, "timestamp": 1793371102],
            ["role": "assistant", "content": "KPI weekly reports are paused.", "row_id": 38272, "timestamp": 1793384520],
        ]
    }

    @Test func theHeaderIsReadAndTheMemoReadsAsALine() throws {
        let restated = try #require(TimelineNotes.restatedRequest(Self.header + "\n" + Self.memo))
        #expect(restated.before.isEmpty)
        #expect(restated.request == "Voice Memo: I need you to work on it until it's fixed, figure it out, get it working properly.")
        let typed = try #require(TimelineNotes.restatedRequest(Self.header + "\nFix the scheduled job."))
        #expect(typed.request == "Fix the scheduled job.")
    }

    @Test func wordsTheCarrierKeptInFrontStay() throws {
        let restated = try #require(TimelineNotes.restatedRequest("Earlier words.\n\n" + Self.header + "\nFix it."))
        #expect(restated.before == "Earlier words.")
        #expect(restated.request == "Fix it.")
    }

    @Test func yourOwnBracketsAreNotHermesHeader() {
        #expect(TimelineNotes.restatedRequest("[STILL IN PROGRESS] the logo, will send tonight") == nil)
        #expect(TimelineNotes.restatedRequest("Is the review [STILL IN PROGRESS — or done]?") == nil)
        #expect(TimelineNotes.restatedRequest("Fix the scheduled job.") == nil)
    }

    @Test func theChatDrawsANoteNotASecondBubble() throws {
        let page = Hydration.fold(rows, pageSeq: 1)
        let resolved = TimelineNotes.resolve(page.messages)
        let users = resolved.filter { $0.role == .user }
        #expect(users.count == 1, "only the voice memo you sent")
        #expect(!resolved.contains { $0.plainText.contains("STILL IN PROGRESS") || $0.plainText.contains("CONTEXT COMPACTION") })
        let note = try #require(resolved.first { $0.role == .system })
        #expect(note.plainText == TimelineNotes.restatedTitle)
        #expect(note.report?.hasPrefix("Voice Memo: I need you to work on it") == true)
        #expect(resolved.map(\.role) == [.user, .assistant, .system, .assistant], "positions are kept")
    }

    @Test func theNoteIsOneLineWithTheInfoGlyph() throws {
        let resolved = TimelineNotes.resolve(Hydration.fold(rows, pageSeq: 1).messages)
        let noteId = try #require(resolved.first { $0.role == .system }?.id)
        let built = ChatRowBuilder.build(ChatRowBuilder.Input(messages: resolved, isRunning: false, botName: "Hermes", expanded: []))
        let row = try #require(built.first { $0.messageId == noteId })
        guard case .backgroundResult(let b) = row.kind else { Issue.record("expected a one-line note"); return }
        #expect(b.note && b.glyph == .note)
        #expect(b.result.hasPrefix("Voice Memo: I need you"))
        #expect(!built.contains { if case .bubble = $0.kind { return $0.messageId == noteId } else { return false } })
    }

    @Test func theSessionsRowSkipsTheRepeat() {
        // The bot is still working: the restated request is the newest row, and the row shows the reply before it.
        let preview = SessionLatestRules.latest(Array(rows.prefix(3)))
        #expect(preview == "I'm on it. My approach: take the \"decide when it's done\" step away from the bot.")
    }
}
