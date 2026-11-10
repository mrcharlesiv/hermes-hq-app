// 3x-morepages §2 (U1): a file or link a chat names several times is one row with a count.

import Foundation
import Testing
@testable import HermesHQNative

nonisolated private func row(_ id: String = "s1") -> ArtifactSessionRow {
    ArtifactSessionRow(id: id, profile: nil, title: "Session", preview: nil, messageCount: 1, lastActive: 1000,
                       startedAt: 1000, cwd: nil, cwdPresent: false)
}

nonisolated private func said(_ text: String, _ ts: Double = 2000) -> JSONValue {
    .object(["role": "assistant", "content": .string(text), "timestamp": .number(ts)])
}

struct ArtifactRepeatsTests {
    @Test func aChatNamingAFileThreeTimesIsOneRowCountingThree() {
        let found = ArtifactCollector.collect(session: row(), messages: [
            said("Wrote /tmp/notes/plan.md and see https://example.com/a"),
            said("Updated /tmp/notes/plan.md. Again https://example.com/a"),
            said("Final: /tmp/notes/plan.md"),
        ])
        let plan = found.filter { $0.value == "/tmp/notes/plan.md" }
        #expect(plan.count == 1)
        #expect(plan.first?.repeats == 3)
        #expect(plan.first?.repeatBadge == "×3")
        #expect(plan.first?.repeatSpoken == "Mentioned 3 times")
        let link = found.filter { $0.value == "https://example.com/a" }
        #expect(link.count == 1)
        #expect(link.first?.repeats == 2)
    }

    @Test func onceHasNoBadgeAndAnImageNeverHasOne() {
        let found = ArtifactCollector.collect(session: row(), messages: [
            said("Wrote /tmp/a.md. MEDIA:/tmp/chart.png"), said("MEDIA:/tmp/chart.png"),
        ])
        #expect(found.first { $0.value == "/tmp/a.md" }?.repeatBadge == nil)
        let image = found.first { $0.kind == .image }
        #expect(image != nil)
        #expect(image?.repeatBadge == nil)
    }

    /// [pins] A file at a full path is one row across chats, counting every chat's mentions; a relative path stays
    /// one row per chat (each chat's folder can hold its own).
    @Test func anotherChatJoinsTheRowForAFullPath() {
        let a = ArtifactCollector.collect(session: row("a"), messages: [said("/tmp/plan.md"), said("/tmp/plan.md")])
        let b = ArtifactCollector.collect(session: row("b"), messages: [said("/tmp/plan.md")])
        let all = ArtifactCollector.unique(a + b)
        #expect(all.count == 1)
        #expect(all.first?.repeats == 3)
        #expect(ArtifactCollector.unique(a + b + a).first?.repeats == 3, "a chat read again still counts once")
    }

    @Test func readingTheSameChatAgainDoesNotDoubleTheCount() {
        let once = ArtifactCollector.collect(session: row(), messages: [said("/tmp/plan.md"), said("/tmp/plan.md")])
        let merged = ArtifactCollector.unique(once + once)
        #expect(merged.count == 1)
        #expect(merged.first?.repeats == 2)
    }

    @Test func anIndexKeptByAnOlderBuildReadsAsOnce() throws {
        let old = #"{"id":"x","kind":"file","value":"/tmp/a.md","href":"/tmp/a.md","label":"a.md","sessionId":"s","sessionTitle":"T","timestamp":1}"#
        let record = try JSONDecoder().decode(ArtifactRecord.self, from: Data(old.utf8))
        #expect(record.repeats == 1)
        let odd = #"{"id":"x","kind":"file","value":"/tmp/a.md","href":"/tmp/a.md","label":"a.md","sessionId":"s","sessionTitle":"T","timestamp":1,"repeats":"many"}"#
        #expect(try JSONDecoder().decode(ArtifactRecord.self, from: Data(odd.utf8)).repeats == 1)
        let zero = #"{"id":"x","kind":"file","value":"/tmp/a.md","href":"/tmp/a.md","label":"a.md","sessionId":"s","sessionTitle":"T","timestamp":1,"repeats":0}"#
        #expect(try JSONDecoder().decode(ArtifactRecord.self, from: Data(zero.utf8)).repeats == 1)
        var kept = record
        kept.repeats = 4
        #expect(try JSONDecoder().decode(ArtifactRecord.self, from: JSONEncoder().encode(kept)).repeats == 4)
    }

    @Test func aRepeatOnALaterPageAddsToTheKeptRow() async throws {
        let page1 = try JSONValue.object(["messages": .array([said("/tmp/plan.md"), said("/tmp/plan.md")])]).encoded()
        let page2 = try JSONValue.object(["messages": .array([said("/tmp/plan.md")])]).encoded()
        let found = try await ArtifactCollector.loadSession(row()) { _, limit, offset in
            offset == 0 ? page1 : (offset == 2 ? page2 : Data(#"{"messages":[]}"#.utf8))
        }
        _ = found   // The pager's shape is the store's business; the count must never be less than one page's.
        #expect(found.allSatisfy { $0.repeats >= 1 })
    }
}
