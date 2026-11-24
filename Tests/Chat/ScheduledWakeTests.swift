// [wake] Automated session wakes (scheduled checks and /loop wakeups) draw as a quiet centred clock line instead of a
// right-aligned user bubble, open on their trigger prompt on tap, and fold consecutive wakes into UpdateGroups.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Automated session wakes")
@MainActor
struct ScheduledWakeTests {
    static let selfDeclared = "Scheduled forum release check (forum-release-0123456789abcdef0123456789abcdef). "
        + "This is an automatic check for this session, not a message from Alex. "
        + "Use the release procedure in /Users/me/workspace/release-posts/README.md. "
        + "Re-read the live candidates. If there is nothing new, return exactly [SILENT]."

    static let genericSelfDeclared = "Scheduled check (check-99887766). "
        + "This is an automatic check for this session, not a message from Alex. Verify nightly status."

    @Test func parsesSelfDeclaredAndBracketedWakes() throws {
        let parsed = try #require(TimelineNotes.scheduledWake(Self.selfDeclared))
        #expect(parsed.title == "Forum release check")
        #expect(parsed.detail.hasPrefix("Use the release procedure in /Users/me/workspace/release-posts/README.md."))
        #expect(parsed.detail.hasSuffix("ID: forum-release-0123456789abcdef0123456789abcdef"))
        #expect(!parsed.detail.contains("not a message from"))

        let generic = try #require(TimelineNotes.scheduledWake(Self.genericSelfDeclared))
        #expect(generic.title == "Scheduled check")
        #expect(generic.detail == "Verify nightly status.\n\nID: check-99887766")

        let bracketed = try #require(TimelineNotes.scheduledWake("[Scheduled wake: Build monitor]\nCheck the nightly build."))
        #expect(bracketed.title == "Build monitor")
        #expect(bracketed.detail == "Check the nightly build.")

        let loop = try #require(TimelineNotes.scheduledWake("[Loop wakeup #3]\nRecheck build status."))
        #expect(loop.title == "Loop wakeup #3")
        #expect(loop.detail == "Recheck build status.")
    }

    @Test func leavesOrdinaryUserMessagesAlone() {
        #expect(TimelineNotes.scheduledWake("Can you set up a scheduled check for releases?") == nil)
        #expect(TimelineNotes.scheduledWake("Scheduled forum release check looks messy right now.") == nil)
        #expect(TimelineNotes.scheduledWake("Please run an automatic check for me.") == nil)
        #expect(TimelineNotes.scheduledWake("Wait — this is not a message from a bot, it's me.") == nil)
    }

    @Test func singleWakeDrawsAsCenteredClockLineWithWaitingRow() throws {
        let rows: [JSONValue] = [
            ["role": "user", "content": "Can we trigger this automatically?", "row_id": 10, "timestamp": 1_790_000_000],
            ["role": "assistant", "content": "Yes, a script wakes this session whenever a build lands.", "row_id": 11, "timestamp": 1_790_000_010],
            ["role": "user", "content": .string(Self.selfDeclared), "row_id": 12, "timestamp": 1_790_000_060],
        ]
        let page = Hydration.fold(rows, pageSeq: 1)
        let resolved = TimelineNotes.resolve(page.messages)
        #expect(resolved.map(\.role) == [.user, .assistant, .system])
        let wake = try #require(resolved.last)
        #expect(wake.plainText == "Forum release check")
        #expect(wake.job == "Forum release check")

        let built = ChatRowBuilder.build(.init(messages: resolved, isRunning: true, botName: "Ivy", expanded: []))
        let wakeRow = try #require(built.first { $0.messageId == wake.id })
        guard case .backgroundResult(let b) = wakeRow.kind else {
            Issue.record("expected a backgroundResult clock row for the wake")
            return
        }
        #expect(b.cron && b.glyph == .clock)
        #expect(b.title == "Forum release check")
        #expect(b.group?.count == 1 && b.group?.opens == true)
        #expect(b.result.hasPrefix("Use the release procedure"))
        #expect(!built.contains { if case .bubble = $0.kind { return $0.messageId == wake.id } else { return false } })
        #expect(built.contains { if case .waiting = $0.kind { return true } else { return false } },
                "running turn after a wake still draws the waiting/working row")
    }

    @Test func consecutiveWakesWithSilentRepliesFoldIntoOneUpdateGroup() throws {
        let t0: Double = 1_790_000_000
        let rows: [JSONValue] = [
            ["role": "user", "content": "Watch releases here.", "row_id": 1, "timestamp": .number(t0)],
            ["role": "assistant", "content": "Watching.", "row_id": 2, "timestamp": .number(t0 + 5)],
            ["role": "user", "content": .string(Self.selfDeclared), "row_id": 3, "timestamp": .number(t0 + 60)],
            ["role": "assistant", "content": "[SILENT]", "row_id": 4, "timestamp": .number(t0 + 65)],
            ["role": "user", "content": .string(Self.selfDeclared), "row_id": 5, "timestamp": .number(t0 + 120)],
            ["role": "assistant", "content": "[SILENT]", "row_id": 6, "timestamp": .number(t0 + 125)],
            ["role": "user", "content": .string(Self.selfDeclared), "row_id": 7, "timestamp": .number(t0 + 180)],
            ["role": "assistant", "content": "Posted build 1042 release notes.", "row_id": 8, "timestamp": .number(t0 + 195)],
        ]
        let resolved = TimelineNotes.resolve(Hydration.fold(rows, pageSeq: 1).messages)
        let input = ChatRowBuilder.Input(messages: resolved, isRunning: false, botName: "Ivy", expanded: [], scope: "t")
        let built = ChatRowBuilder.build(input)

        let groupRows = built.compactMap { row -> (ChatRow, BackgroundResultRow)? in
            if case .backgroundResult(let b) = row.kind, b.group != nil { return (row, b) }
            return nil
        }
        #expect(groupRows.count == 1)
        let (line, bg) = try #require(groupRows.first)
        #expect(bg.title == "Forum release check")
        #expect(bg.group?.count == 3)
        #expect(bg.group?.tail == "2 more")
        #expect(bg.group?.marks == [.glyph(.clock)])

        let sheet = try #require(UpdateGroups.opened(line: line.id, messageId: line.messageId, input: input))
        #expect(sheet.members.count == 3)
        #expect(sheet.members.allSatisfy { $0.title == "Forum release check" && $0.mark == .glyph(.clock) })
    }

    @Test func structuredGatewayDisplayKindHydratesAndSurvivesCacheRoundTrip() throws {
        let rows: [JSONValue] = [
            ["role": "user", "content": "Re-read live candidates and post once.", "display_kind": "scheduled_wake",
             "display_metadata": ["display_text": "Forum release check"], "row_id": 21, "timestamp": 1_790_000_000],
        ]
        let page = Hydration.fold(rows, pageSeq: 1)
        let msg = try #require(page.messages.first)
        #expect(msg.role == .system)
        #expect(msg.plainText == "Forum release check")
        #expect(msg.job == "Forum release check")
        #expect(page.meta[msg.id]?.asyncResult == "Re-read live candidates and post once.")

        // Cache round-trip preserves HQT6 magic and the scheduled wake clock marker.
        let entry = TranscriptEntry(messages: page.messages, meta: page.meta, savedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let encoded = entry.encoded()
        #expect(Array(encoded.prefix(4)) == Array("HQT6".utf8))
        let decoded = try TranscriptEntry.decode(encoded)
        let restored = try #require(decoded.messages.first)
        #expect(restored.role == .system)
        #expect(restored.job == "Forum release check")
        #expect(decoded.meta[restored.id]?.asyncResult == "Re-read live candidates and post once.")

        // Live inflight snapshot with display_kind converts directly to a note.
        let inflight = try #require(LiveChatSession.inflightNote(
            "Re-read live candidates and post once.",
            ["display_kind": "scheduled_wake", "display_metadata": ["display_text": "Forum release check"]]
        ))
        #expect(inflight.message.role == .system)
        #expect(inflight.message.job == "Forum release check")
        #expect(inflight.meta.asyncResult == "Re-read live candidates and post once.")
    }

    @Test func sessionsPreviewSkipsScheduledWakes() {
        let rows: [JSONValue] = [
            ["role": "user", "content": "Watch releases here.", "row_id": 1],
            ["role": "assistant", "content": "Watching every 30 minutes.", "row_id": 2],
            ["role": "user", "content": .string(Self.selfDeclared), "row_id": 3],
        ]
        #expect(SessionLatestRules.latest(rows) == "Watching every 30 minutes.")

        let structuredRows: [JSONValue] = [
            ["role": "assistant", "content": "Watching every 30 minutes.", "row_id": 2],
            ["role": "user", "content": "Check releases.", "display_kind": "scheduled_wake",
             "display_metadata": ["display_text": "Forum release check"], "row_id": 3],
        ]
        #expect(SessionLatestRules.latest(structuredRows) == "Watching every 30 minutes.")
        #expect(RosterPreview.rowPreview(Self.selfDeclared) == "Forum release check")
    }
}
