// [helper-note] Owner, 2026-10-30: Hermes ran the "Fleet failure review" job by hand; when it finished, its note
// ("[ASYNC DELEGATION COMPLETE — deleg_b03ef153] …", the job's output and all) started a turn. The chat, opened while
// that turn ran, drew the note's whole text as a bubble of the owner's, under the one-line note history already showed:
// the resume snapshot's `inflight.user` is the note, and its `display_kind` was not read.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("A turn started by a helper's note", .serialized)
@MainActor
struct HelperNoteInflightTests {
    static let note = """
        [ASYNC DELEGATION COMPLETE — deleg_b03ef153]
        A background subagent you dispatched earlier has finished. You may have moved on since dispatching it; the full task \
        source is below so you can act on the result or re-dispatch if things have changed.

        Dispatched: 2026-10-30 08:41:12 (3m4s ago)
        Original goal: Manual run of cron job 'Fleet failure review' (4bcc04325d3d)
        Context you provided: Triggered via cronjob(action='run'). The job executed in its own fresh cron session; this block reports its outcome.
        Role: cron_run   Model: ?
        Status: completed   API calls: 0
        Duration: 184.11s
        --- RESULT ---
        Cron job 'Fleet failure review' (4bcc04325d3d) finished its manual run.
        Result: ok
        Delivery target: origin (output was delivered there by the job itself)
        Next scheduled run: 2026-10-30T12:00:00-05:00
        --- JOB OUTPUT ---
        # Cron Job: Fleet failure review

        Two failures this week, both fixed.
        """
    static let title = "Subagent Task Completed: Manual run of cron job 'Fleet failure review' (4bcc04325d3d)"
    static let metadata: JSONValue = ["display_text": .string(title), "delegation_id": "deleg_b03ef153", "task_count": 1,
                                      "completed_count": 1, "failed_count": 0, "duration_seconds": .number(184.11)]

    private func base() throws -> [JSONValue] {
        Array((try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []).suffix(20))
    }

    private func noteRow(_ row: Int) -> JSONValue {
        ["role": "user", "content": .string(Self.note), "display_kind": "async_delegation_complete",
         "display_metadata": Self.metadata, "row_id": .number(Double(row)), "timestamp": 1793367857]
    }

    private func resume(_ h: ChatHarness, inflight: JSONValue) {
        h.client.onCall { method, _ in
            switch method {
            case "session.resume", "session.activate":
                return ["session_id": "5cc537d1", "session_key": .string(h.stored), "running": true, "status": "streaming",
                        "turn_started_at": 1793367857, "inflight": inflight]
            case "session.active_list": return ["sessions": []]
            case "session.events.since": return ["events": [], "latest_seq": 0, "truncated": false, "epoch": "fixture-epoch"]
            default: return [:]
            }
        }
    }

    private var inflight: JSONValue {
        ["user": .string(Self.note), "assistant": "Heads up first:", "streaming": true,
         "display_kind": "async_delegation_complete", "display_metadata": Self.metadata]
    }

    private func raw(_ s: LiveChatSession) -> [ChatMessage] {
        s.messages.filter { $0.plainText.contains("ASYNC DELEGATION") }
    }

    private func notes(_ s: LiveChatSession) -> [ChatMessage] {
        s.messages.filter { $0.role == .system && $0.plainText == Self.title }
    }

    @Test func theStoredNoteAnchorsTheReplyAndNoBubbleIsDrawn() async throws {
        let h = try ChatHarness()
        h.setPage("24", rows: try base() + [noteRow(38006)], hasMore: true)
        resume(h, inflight: inflight)
        let s = h.make()
        #expect(await h.open())
        #expect(s.isRunning)
        #expect(raw(s).isEmpty, "the note's text is never a bubble")
        #expect(notes(s).count == 1)
        let note = try #require(notes(s).first)
        #expect(s.turn.userAnchorId == note.id)
        #expect(s.messages.last?.role == .assistant && s.messages.last?.isStreaming == true)
        #expect(texts(s.messages.last) == "Heads up first:")
        #expect(s.metaById[note.id]?.asyncResult?.hasPrefix("# Cron Job: Fleet failure review") == true)
    }

    @Test func aNoteNotOnThePageYetIsDrawnAsANoteAndGivesWayToItsRow() async throws {
        let h = try ChatHarness()
        let rows = try base()
        h.setPage("24", rows: rows, hasMore: true)
        resume(h, inflight: inflight)
        let s = h.make()
        #expect(await h.open())
        #expect(raw(s).isEmpty)
        let note = try #require(notes(s).first)
        #expect(note.id.hasPrefix("local-note-inflight-"))
        #expect(s.turn.userAnchorId == note.id)
        #expect(s.metaById[note.id]?.asyncResult != nil)
        // The turn ends and the read brings the stored note and the reply: one note, the reply after it.
        h.setPage("24", rows: Array((rows + [noteRow(38006),
                                             ["role": "assistant", "content": "Heads up first: the retainer is due.",
                                              "row_id": 38024, "timestamp": 1793367987]]).suffix(24)), hasMore: true)
        await h.emit([h.event("message.complete", ["text": "Heads up first: the retainer is due.", "status": "complete"])])
        #expect(await waitUntil { s.messages.last?.plainText == "Heads up first: the retainer is due." && !s.isRunning })
        try await Task.sleep(for: .milliseconds(150))
        s.flushChanges()
        #expect(raw(s).isEmpty)
        #expect(notes(s).count == 1)
        let at = try #require(s.messages.firstIndex { $0.role == .system && $0.plainText == Self.title })
        #expect(s.messages[(at + 1)...].filter { $0.role == .assistant }.map(\.plainText) == ["Heads up first: the retainer is due."])
    }

    @Test func aPromptWithNoKindIsStillABubble() async throws {
        let h = try ChatHarness()
        h.setPage("24", rows: try base(), hasMore: true)
        resume(h, inflight: ["user": "Write about a lighthouse keeper", "assistant": "The lamp", "streaming": true])
        let s = h.make()
        #expect(await h.open())
        #expect(h.lastUser?.plainText == "Write about a lighthouse keeper")
        #expect(h.lastUser?.id.hasPrefix("local-user-inflight-") == true)
    }

    @Test func anOlderGatewaysNoteWithNoKindIsANote() throws {
        let note = try #require(LiveChatSession.inflightNote(Self.note, [:]))
        #expect(note.message.role == .system)
        #expect(note.meta.asyncResult?.hasPrefix("# Cron Job: Fleet failure review") == true)
        #expect(LiveChatSession.inflightNote("Write about a lighthouse keeper", [:]) == nil)
    }

    // MARK: The backstop: a note that reaches the chat as a prompt is drawn as one

    @Test func aNoteAsAPromptIsOneLineWithItsResultUnder() {
        let prompt = ChatMessage(id: "local-user-queued-1", role: .user, parts: [.text(Self.note)], timestamp: nil, rowId: nil)
        let out = TimelineNotes.resolve([prompt])
        #expect(out[0].role == .system)
        #expect(out[0].plainText == Self.title)
        #expect(out[0].report?.hasPrefix("# Cron Job: Fleet failure review") == true)
        #expect(BackgroundResults.plainTitle(out[0].plainText) == "Fleet failure review finished")
    }

    @Test func helperTitlesReadFromTheNotesText() {
        #expect(TimelineNotes.helperTitle(Self.note) == Self.title)
        let failed = "[ASYNC DELEGATION COMPLETE — deleg_1]\nOriginal goal: Check the build\nStatus: failed   API calls: 3\n--- ERROR ---\nboom"
        #expect(TimelineNotes.helperTitle(failed) == "Subagent Task Failed: Check the build")
        #expect(TimelineNotes.helperTitle("[ASYNC DELEGATION COMPLETE — deleg_2]\nStatus: completed") == "1 background agent finished")
        let batch = "[ASYNC DELEGATION BATCH COMPLETE — deleg_2dabd46b] A background fan-out unit you dispatched earlier — 2 subagents finished."
        #expect(TimelineNotes.helperTitle(batch) == "2 background agents finished")
    }

    // MARK: The line's words

    @Test func helperLinesSayWhatFinishedAndHow() {
        #expect(BackgroundResults.plainTitle(Self.title) == "Fleet failure review finished")
        #expect(BackgroundResults.plainTitle("Subagent Task Failed: Manual run of cron job 'Inbox sweep' (ab12)") == "Inbox sweep failed")
        #expect(BackgroundResults.plainTitle("Subagent Task Completed: Index the docs") == "Helper finished: Index the docs")
        #expect(BackgroundResults.plainTitle("Subagent Task Failed: Index the docs") == "Helper failed: Index the docs")
        #expect(BackgroundResults.plainTitle("Subagent Task Timed Out: Index the docs") == "Helper timed out: Index the docs")
        #expect(BackgroundResults.plainTitle("Subagent Task Incomplete: Index the docs") == "Helper stopped early: Index the docs")
        #expect(BackgroundResults.plainTitle("Subagent Tasks Completed: Audit; Fix (2 tasks)") == "2 helpers finished: Audit; Fix")
        #expect(BackgroundResults.plainTitle("Subagent Tasks Finished with Issues: Sweep (3 tasks)") == "3 helpers finished with problems: Sweep")
        #expect(BackgroundResults.plainTitle("Subagent Task Failed") == "Helper failed")
    }
}

private func texts(_ m: ChatMessage?) -> String {
    (m?.parts ?? []).compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
}
