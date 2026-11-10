// History fixes from the build 863 audit (chat logic): paging in a long-open chat, tail reads that overlap, the
// watchdog's card, releasing old rows off screen, and the tail recheck's reach.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@Suite("History paging and merge (audit 863)", .serialized)
@MainActor
struct HistoryPagingAuditTests {
    /// A newest-end page holding all of `rows` (nothing older), as `ChatHarness.setPage` writes it.
    private func page(_ h: ChatHarness, _ rows: [JSONValue]) -> Data {
        encodeJSON(["session_id": .string(h.stored), "profile": "default", "messages": .array(rows),
                    "pagination": ["limit": 24, "offset": 0, "order": "latest", "returned": .number(Double(rows.count)),
                                   "has_more": false]])
    }

    private func base() throws -> [JSONValue] {
        Array((try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []).suffix(20))
    }

    /// Rows saved while a chat stays open push the older window back: an older page that keeps meeting only newer rows
    /// picks up where its reads stopped next time, instead of starting over from the stale offset.
    @Test func olderPagingContinuesWhereAMovedWindowLeftIt() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        s.olderFailed = false
        s.hasOlder = true
        let newer: [JSONValue] = (0..<3).map { i -> JSONValue in
            ["role": "assistant", "content": .string("later \(i)"), "row_id": .number(Double(900_000 + i))]
        }
        h.setPage("121", rows: newer, hasMore: true)
        let before = s.nextOffset
        await s.loadOlderPage(fill: false)
        #expect(s.nextOffset == before + LiveChatSession.olderReads * newer.count)
        #expect(s.hasOlder)
    }

    /// Two tail reads that overlap (the reconnect's beside the watchdog's): one started later and applied first holds
    /// the newer rows; the slow earlier one never cuts them away.
    @Test func aSlowEarlierTailReadNeverUndoesANewerOne() async throws {
        let h = try ChatHarness()
        let rows = try base()
        h.setPage("24", rows: rows, hasMore: false)
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil && s.refreshTask == nil }
        let older = rows + [["role": "user", "content": "q", "row_id": 6000, "timestamp": 1791590000],
                            ["role": "assistant", "content": "a1", "row_id": 6001, "timestamp": 1791590001]]
        let newer = older + [["role": "user", "content": "from the Mac", "row_id": 6002, "timestamp": 1791590002],
                             ["role": "assistant", "content": "the Mac's answer", "row_id": 6003, "timestamp": 1791590003]]
        let olderBody = page(h, older)
        let newerBody = page(h, newer)
        let reads = Mutex(0)
        h.client.onRest { _, _ in
            let n = reads.withLock { $0 += 1; return $0 }
            if n == 1 { Thread.sleep(forTimeInterval: 0.3); return olderBody }
            return newerBody
        }
        let slow = Task { await s.refreshTail(force: true) }
        try? await Task.sleep(for: .milliseconds(60))
        await s.refreshTail(force: true)
        s.flushChanges()
        #expect(s.messages.contains { $0.plainText == "the Mac's answer" })
        await slow.value
        s.flushChanges()
        #expect(s.messages.contains { $0.plainText == "the Mac's answer" })
        #expect(s.messages.contains { $0.plainText == "from the Mac" })
    }

    /// The watchdog's "ended without a reply" card is about the turn it settled: a message sent during its read keeps
    /// the card above it, not under it.
    @Test func theWatchdogsCardStaysWithTheTurnItSettled() async throws {
        let h = try ChatHarness()
        let rows = try base()
        h.setPage("24", rows: rows, hasMore: false)
        let s = h.make()
        s.silenceTimeout = .milliseconds(150)
        s.turnEndReadDelay = .seconds(10)
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil && s.refreshTask == nil }
        let body = page(h, rows)
        h.client.onRest { _, _ in Thread.sleep(forTimeInterval: 0.4); return body }
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.active_list": return ["sessions": []]
            default: return [:]
            }
        }
        s.send("first")
        #expect(await waitUntil { !s.isRunning })                              // the watchdog settled it; its read runs
        s.send("second")
        #expect(await waitUntil { s.messages.contains { $0.error == "Hermes ended this turn without a reply." } })
        s.flushChanges()
        let card = try #require(s.messages.firstIndex { $0.error == "Hermes ended this turn without a reply." })
        let first = try #require(s.messages.firstIndex { $0.role == .user && $0.plainText == "first" })
        let second = try #require(s.messages.firstIndex { $0.role == .user && $0.plainText == "second" })
        #expect(first < card)
        #expect(card < second)
    }

    /// Releasing the oldest messages off screen rewinds the paging offset by every stored row below the new top, the
    /// ones the screen never drew too, so scrolling back up leaves no gap.
    @Test func releasingOldRowsCountsTheOnesNeverDrawn() throws {
        let h = try ChatHarness()
        let s = h.make()
        s.messages = []
        s.rebuildIndex()
        let shown: [(Int, ChatMessage.Role)] = [(10, .user), (11, .assistant), (14, .user), (15, .assistant), (16, .user), (17, .assistant)]
        for (row, role) in shown {
            s.appendMessage(ChatMessage(id: "stored-row-\(row)-\(role == .user ? "user" : "assistant")", role: role,
                                        parts: [.text("row \(row)")], timestamp: Date(), rowId: row))
        }
        s.loadedRowIds = Set(10...17)                                           // 12 and 13 fold to nothing
        s.oldestRowId = 10
        s.nextOffset = 8
        s.releaseOlderHistory(keepingNewest: 2)
        #expect(s.messages.map(\.rowId) == [16, 17])
        #expect(s.nextOffset == 2)                                              // rows 16 and 17 are what is left
        #expect(s.oldestRowId == 16)
    }

    /// The tail recheck after a cut-off reply reaches past the newest 24 rows when its prompt isn't among them.
    @Test func theTailRecheckReachesTheTurnsPrompt() async throws {
        let h = try ChatHarness()
        let s = h.make()
        let steps: [JSONValue] = (0..<24).map { i -> JSONValue in
            let role: JSONValue = i % 2 == 0 ? "assistant" : "tool"
            return ["role": role, "content": .string("step \(i)"), "row_id": .number(Double(7001 + i))]
        }
        h.setPage("24", rows: steps, hasMore: true)
        let whole: [JSONValue] = [["role": "user", "content": "do the long thing", "row_id": 7000]] + steps
        h.setPage("120", rows: whole, hasMore: true)
        let read = try await s.tailRecheckRows()
        #expect(read.count == whole.count)
        #expect(TailRecheck.savedReply(read, TailRecheck.Shown(prompt: "do the long thing", reply: 1)) != .nothing)
        // Short turns keep the one 24-row read.
        h.setPage("24", rows: Array(whole.prefix(4)), hasMore: true)
        let short = try await s.tailRecheckRows()
        #expect(short.count == 4)
    }
}
