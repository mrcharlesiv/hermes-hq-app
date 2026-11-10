// [catch-up] Build 292, "Chat catches up on return": a reply that arrived while the app was away shows on the open
// chat as soon as the link is ready, with no reopen (owner's phone, Oct 13–15: 16 reopens found a reply the screen
// had not shown). The reconnect settles a send whose turn came and went unheard, and a read cut by a running turn
// never passes for the newest truth.

import Foundation
import Synchronization
import Testing
import UIKit
@testable import HermesHQNative

@Suite("Open chat catches up on return", .serialized)
@MainActor
struct ChatCatchUpTests {
    private static let ready: JSONValue = ["heartbeat": true, "change_events": true, "replay_epoch": "fixture-epoch"]

    private func calls(_ h: ChatHarness) throws {
        let resume = try ChatFixtures.json("perf-resume.json")["result"] ?? .null
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.resume", "session.activate": return resume          // running: false
            case "session.active_list": return ["sessions": []]
            case "session.events.since": return ["events": [], "latest_seq": 7, "truncated": false, "epoch": "fixture-epoch"]
            default: return [:]
            }
        }
    }

    private func rows(_ h: ChatHarness, prompt: String, reply: String, row: Int) throws -> [JSONValue] {
        let base = Array((try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []).suffix(22))
        return base + [
            ["role": "user", "content": .string(prompt), "row_id": .number(Double(row)), "timestamp": 1791590000],
            ["role": "assistant", "content": .string(reply), "row_id": .number(Double(row + 1)), "timestamp": 1791590030],
        ]
    }

    private func returnToApp(_ h: ChatHarness) {
        h.client.setConnection(.reconnecting(attempt: 1))
        h.client.setConnection(.ready)
        h.client.setReady(Self.ready)
    }

    /// Sent, then the phone was locked before the turn's first frame: the turn ran and ended while the link was paused.
    /// The chat used to stay "running" (no frame of the turn, so the end of it was never heard), cut the stored reply off
    /// every read as part of that turn, and wait 45 s for the silence watchdog.
    @Test func aSendWhoseTurnEndedWhileAwayShowsItsReplyOnReady() async throws {
        let h = try ChatHarness(ready: Self.ready)
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        try calls(h)
        await h.emit([h.event("session.info", ["model": "fixture"], seq: 7)])
        s.send("Ping while leaving")
        #expect(await waitUntil { h.lastUser?.isPending == false })
        #expect(s.isRunning)
        s.turn.armedAt = Date().addingTimeInterval(-60)          // sent a minute ago; nothing heard since
        let fresh = try rows(h, prompt: "Ping while leaving", reply: "Pong, written while you were away.", row: 8000)
        h.setPage("24", rows: Array(fresh.suffix(24)), hasMore: true)
        h.setPage("1", rows: [fresh.last!], hasMore: true)
        // The connection's own frame, held with the session's id until the reconnect ends, is not one of the turn's.
        s.parked.append(GatewayEvent(type: "hq.open_requests", sessionId: s.runtimeSessionId ?? "", seq: nil, payload: .null))
        returnToApp(h)
        #expect(await waitUntil(timeout: .seconds(3)) {
            s.messages.contains { $0.plainText == "Pong, written while you were away." } && !s.isRunning
        })
        s.flushChanges()
        #expect(s.messages.filter { $0.role == .user && $0.plainText == "Ping while leaving" }.count == 1)
    }

    /// A send under 15 s old may not have started on the gateway yet: "not running" then says nothing about it.
    @Test func aFreshSendIsNotSettledByTheReconnect() async throws {
        let h = try ChatHarness(ready: Self.ready)
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        try calls(h)
        await h.emit([h.event("session.info", ["model": "fixture"], seq: 7)])
        s.send("Just sent")
        #expect(await waitUntil { h.lastUser?.isPending == false })
        returnToApp(h)
        #expect(await waitUntil { !h.client.calls("session.activate").isEmpty && !s.parking })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(s.isRunning)
    }

    /// A read made while the turn ran (the alert tapped on the open chat) is cut after the turn's prompt; the turn then
    /// settled on `running:false` with the partial still shown, and the turn-end probe found the newest row "already
    /// read": the reply showed only after a reopen.
    @Test func aReadCutByARunningTurnIsNotTakenAsRead() async throws {
        let h = try ChatHarness(ready: Self.ready)
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        try calls(h)
        s.send("Check the logs")
        #expect(await waitUntil { h.lastUser?.isPending == false })
        let runtime = try #require(s.runtimeSessionId)
        await h.emit([h.event("message.start", seq: 8, sid: runtime),
                      h.event("message.delta", ["text": "Checking the logs"], seq: 9, sid: runtime)])
        #expect(s.isRunning)
        let fresh = try rows(h, prompt: "Check the logs", reply: "Checking the logs. Done: all clear.", row: 8100)
        h.setPage("24", rows: Array(fresh.suffix(24)), hasMore: true)
        h.setPage("1", rows: [fresh.last!], hasMore: true)
        let readsBefore = h.client.restLog.count
        s.probeTailSoon(after: .zero, force: true)
        #expect(await waitUntil { h.client.restLog.count > readsBefore && s.refreshTask == nil })
        #expect(!s.messages.contains { $0.plainText.contains("Done: all clear.") })   // cut: the turn still runs
        await h.emit([h.event("session.info", ["running": false], seq: 10, sid: runtime)])
        #expect(await waitUntil(timeout: .seconds(3)) { s.messages.contains { $0.plainText.contains("Done: all clear.") } })
    }

    @Test func onlyATurnsOwnFramesHoldTheSettle() {
        #expect(LiveChatSession.isTurnFrame("message.complete"))
        #expect(LiveChatSession.isTurnFrame("tool.start"))
        #expect(LiveChatSession.isTurnFrame("error"))
        #expect(!LiveChatSession.isTurnFrame("hq.open_requests"))
        #expect(!LiveChatSession.isTurnFrame("session.info"))
        #expect(!LiveChatSession.isTurnFrame("session.title"))
    }

    // MARK: Activate timeout on a socket that stays up

    private func timingOutActivate(_ h: ChatHarness, failures: Int, error: RPCError = .timedOut("session.activate", after: .seconds(30))) throws {
        let resume = try ChatFixtures.json("perf-resume.json")["result"] ?? .null
        let n = Mutex(0)
        h.client.onCall { method, _ in
            switch method {
            case "session.activate":
                if n.withLock({ $0 += 1; return $0 }) <= failures { throw error }
                return resume
            case "session.active_list": return ["sessions": []]
            case "session.events.since": return ["events": [], "latest_seq": 7, "truncated": false, "epoch": "fixture-epoch"]
            default: return [:]
            }
        }
    }

    @Test func anActivateThatTimesOutIsTriedAgain() async throws {
        let h = try ChatHarness(ready: Self.ready)
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        try timingOutActivate(h, failures: 1)
        let before = h.client.calls("session.activate").count
        let reads = h.client.restLog.count
        returnToApp(h)
        #expect(await waitUntil(timeout: .seconds(3)) { h.client.calls("session.activate").count - before == 2 && !s.parking })
        #expect(await waitUntil { h.client.restLog.count > reads })        // no cursor: the catch-up read ran
    }

    @Test func anActivateThatKeepsTimingOutIsTriedTwiceMore() async throws {
        let h = try ChatHarness(ready: Self.ready)
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        try timingOutActivate(h, failures: 100)
        let before = h.client.calls("session.activate").count
        returnToApp(h)
        #expect(await waitUntil(timeout: .seconds(7)) { h.client.calls("session.activate").count - before == 3 })
        try? await Task.sleep(for: .milliseconds(3500))
        #expect(h.client.calls("session.activate").count - before == 3)
    }

    @Test func aGatewayReadyCancelsTheActivateRetry() async throws {
        let h = try ChatHarness(ready: Self.ready)
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        try timingOutActivate(h, failures: 1)
        let before = h.client.calls("session.activate").count
        returnToApp(h)
        #expect(await waitUntil { h.client.calls("session.activate").count - before == 1 && !s.parking })
        returnToApp(h)
        #expect(await waitUntil { h.client.calls("session.activate").count - before == 2 && !s.parking })
        try? await Task.sleep(for: .milliseconds(1500))
        #expect(h.client.calls("session.activate").count - before == 2)
    }

    @Test func aLostConnectionDuringActivateIsLeftToTheNextReady() async throws {
        let h = try ChatHarness(ready: Self.ready)
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        try timingOutActivate(h, failures: 1, error: RPCError(code: RPCError.connectionLostCode, message: "closed", data: nil))
        let before = h.client.calls("session.activate").count
        returnToApp(h)
        #expect(await waitUntil { h.client.calls("session.activate").count - before == 1 && !s.parking })
        try? await Task.sleep(for: .milliseconds(1500))
        #expect(h.client.calls("session.activate").count - before == 1)
    }

    // MARK: No cursor: the tail read starts beside the activate, and an unchanged tail is not merged again

    private func limits(_ h: ChatHarness, from: Int) -> [String] {
        h.client.restLog.dropFirst(from).compactMap { $0.query.first { $0.name == "limit" }?.value }
    }

    private func heldActivate(_ h: ChatHarness, answer: JSONValue) {
        h.client.onCall { method, _ in
            switch method {
            case "session.activate":
                try await Task.sleep(for: .milliseconds(300))
                return answer
            case "session.active_list": return ["sessions": []]
            default: return [:]
            }
        }
    }

    @Test func anIdleReturnWithNoCursorReadsTheTailOnceBesideTheActivate() async throws {
        let h = try ChatHarness(ready: Self.ready)
        try h.setPage("24", "perf-page-latest-24.json")
        try h.setPage("1", "perf-page-probe-1.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        s.lastSeq = nil
        let rid = try #require(s.runtimeSessionId)
        let shown = s.messages.map(\.id)
        let client = h.client
        let readsAtAnswer = Mutex(-1)
        h.client.onCall { method, _ in
            switch method {
            case "session.activate":
                try await Task.sleep(for: .milliseconds(300))
                readsAtAnswer.withLock { $0 = client.restLog.count }
                return ["session_id": .string(rid), "running": false]
            case "session.active_list": return ["sessions": []]
            default: return [:]
            }
        }
        let reads = h.client.restLog.count
        returnToApp(h)
        #expect(await waitUntil { !h.client.calls("session.activate").isEmpty && !s.parking })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(readsAtAnswer.withLock { $0 } > reads, "the tail read went out before the activate answered")
        #expect(limits(h, from: reads) == ["24"])                  // one read, no probe and no second 24-row read
        s.flushChanges()
        #expect(s.messages.map(\.id) == shown)
    }

    @Test func aNewReplyFoundByTheEarlyReadShowsWithNoSecondRead() async throws {
        let h = try ChatHarness(ready: Self.ready)
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        let rid = try #require(s.runtimeSessionId)
        s.lastSeq = nil
        heldActivate(h, answer: ["session_id": .string(rid), "running": false])
        let fresh = try rows(h, prompt: "Asked from the laptop", reply: "Answered while the phone slept.", row: 8200)
        h.setPage("24", rows: Array(fresh.suffix(24)), hasMore: true)
        let reads = h.client.restLog.count
        returnToApp(h)
        #expect(await waitUntil { !h.client.calls("session.activate").isEmpty && !s.parking })
        #expect(await waitUntil { s.messages.contains { $0.plainText == "Answered while the phone slept." } })
        #expect(limits(h, from: reads) == ["24"])
    }

    @Test func aTurnRunningAfterTheActivateIsReadAfresh() async throws {
        let h = try ChatHarness(ready: Self.ready)
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        let rid = try #require(s.runtimeSessionId)
        s.lastSeq = nil
        heldActivate(h, answer: ["session_id": .string(rid), "running": true,
                                 "inflight": ["user": "From the laptop", "assistant": "Work", "streaming": true]])
        let reads = h.client.restLog.count
        returnToApp(h)
        #expect(await waitUntil { !h.client.calls("session.activate").isEmpty && !s.parking })
        #expect(limits(h, from: reads) == ["24", "24"])            // the early read is dropped; the forced one is made
        #expect(s.isRunning)
    }

    // MARK: A reply cut by the reconnect (O15): the tail recheck's 2 s read is the look-again

    /// The turn ended while away with its reply only journaled: the reconnect reads the tail and starts the recheck
    /// (§6.3), whose first read comes 2 s on. The 1.2 s probe would read the same tail a moment before it.
    @Test func aCutReplyReconnectLeavesTheLookAgainToTheRecheck() async throws {
        let h = try ChatHarness(ready: Self.ready)
        try h.setPage("24", "perf-page-latest-24.json")
        try h.setPage("1", "perf-page-probe-1.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        let rid = try #require(s.runtimeSessionId)
        s.lastSeq = nil
        try #require(UIApplication.shared.applicationState == .active, "the recheck reads only with the app in front")
        heldActivate(h, answer: ["session_id": .string(rid), "running": false,
                                 "inflight": ["user": "Tell me more", "assistant": "Half a reply, cut by the restart"]])
        returnToApp(h)
        #expect(await waitUntil { !h.client.calls("session.activate").isEmpty && !s.parking })
        let reads = h.client.restLog.count
        // The probe would go 1.2 s on, before the recheck's 2 s read: by the time that read is out, it would be logged.
        #expect(await waitUntil(timeout: .seconds(3)) { limits(h, from: reads).contains("24") })
        #expect(limits(h, from: reads) == ["24"], "no probe 1.2 s on: the recheck reads the tail at 2 s")
    }

    /// No partial on show: the read just made gets its look 1.2 s on as before.
    @Test func aReconnectWithNothingCutStillLooksAgain() async throws {
        let h = try ChatHarness(ready: Self.ready)
        try h.setPage("24", "perf-page-latest-24.json")
        try h.setPage("1", "perf-page-probe-1.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        let rid = try #require(s.runtimeSessionId)
        s.lastSeq = nil
        heldActivate(h, answer: ["session_id": .string(rid), "running": false])
        returnToApp(h)
        #expect(await waitUntil { !h.client.calls("session.activate").isEmpty && !s.parking })
        let reads = h.client.restLog.count
        #expect(await waitUntil(timeout: .seconds(2)) { limits(h, from: reads) == ["1"] })
    }

    // MARK: The running turn's prompt (the cut while a turn runs)

    @Test func theCutSkipsAPromptFromBeforeTheTurnAndPrefersTheInflightPrompt() throws {
        let h = try ChatHarness()
        let s = h.make()
        let now = Date()
        func user(_ row: Int, _ text: String, _ at: Date) -> ChatMessage {
            ChatMessage(id: "stored-row-\(row)-user", role: .user, parts: [.text(text)], timestamp: at, rowId: row)
        }
        func reply(_ row: Int) -> ChatMessage {
            ChatMessage(id: "stored-row-\(row)-assistant", role: .assistant, parts: [.text("r\(row)")], timestamp: now, rowId: row)
        }
        let previous = [user(10, "one", now.addingTimeInterval(-900)), reply(11)]
        s.turn.busy = true
        s.turn.userAnchorId = nil
        s.turn.turnStartedAt = now
        // A finished turn's prompt (well before this turn started) and nothing stored of the running turn yet.
        let finished = previous + [user(12, "two", now.addingTimeInterval(-600)), reply(13)]
        #expect(s.liveTurnUserIndex(in: finished, previous: previous) == nil)
        // The running turn's prompt is stored too: the cut lands after it, not after the finished one.
        let both = finished + [user(14, "three", now), reply(15)]
        #expect(s.liveTurnUserIndex(in: both, previous: previous) == 4)
        // The snapshot named the running prompt: it wins over a newer row.
        s.turn.inflightUserKey = Hydration.userDisplayKey("two")
        s.turn.turnStartedAt = now.addingTimeInterval(-700)
        #expect(s.liveTurnUserIndex(in: both, previous: previous) == 2)
        // A live bubble's stored row counts as shown: its prompt is not taken for the running turn's.
        s.turn.inflightUserKey = nil
        let live = ChatMessage(id: "local-user-3", role: .user, parts: [.text("two")], timestamp: now, rowId: 12)
        #expect(s.liveTurnUserIndex(in: finished, previous: previous + [live]) == nil)
    }

    @Test func theOnlyNewerPromptIsOursOnlyOnceAcknowledged() throws {
        let h = try ChatHarness()
        let s = h.make()
        let now = Date()
        let shown = ChatMessage(id: "stored-row-10-user", role: .user, parts: [.text("one")], timestamp: now, rowId: 10)
        var mine = ChatMessage(id: "local-user-1", role: .user, parts: [.text("mine")], timestamp: now, rowId: nil)
        mine.isPending = true
        let foreign = ChatMessage(id: "stored-row-12-user", role: .user, parts: [.text("someone else")], timestamp: now, rowId: 12)
        let fresh = [shown, foreign, ChatMessage(id: "stored-row-13-assistant", role: .assistant, parts: [.text("theirs")], timestamp: now, rowId: 13)]
        s.turn.busy = true
        s.turn.userAnchorId = mine.id
        #expect(s.liveTurnUserIndex(in: fresh, previous: [shown, mine]) == nil)
        mine.isPending = false
        #expect(s.liveTurnUserIndex(in: fresh, previous: [shown, mine]) == 1)
        // …and not when that prompt was stored well before ours went out.
        let older = ChatMessage(id: "stored-row-12-user", role: .user, parts: [.text("someone else")], timestamp: now.addingTimeInterval(-120), rowId: 12)
        #expect(s.liveTurnUserIndex(in: [shown, older], previous: [shown, mine]) == nil)
    }

    /// Our turn A ended while away and a queued B started: the reconnect (no replay) reads A's whole stored reply, B's
    /// prompt once, and B's live bubble; A's partial bubble is not carried as B's.
    @Test func anOwnTurnThatEndedWhileAwayShowsItsWholeReplyBesideTheNextTurn() async throws {
        let h = try ChatHarness(ready: Self.ready)
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming", "user_row_id": 8000] : [:] }
        s.send("Turn A")
        #expect(await waitUntil { h.lastUser?.isPending == false })
        let runtime = try #require(s.runtimeSessionId)
        await h.emit([h.event("message.start", seq: 8, sid: runtime),
                      h.event("message.delta", ["text": "A partial"], seq: 9, sid: runtime)])
        #expect(s.isRunning)
        let now = Date().timeIntervalSince1970
        let base = Array((try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []).suffix(20))
        let page: [JSONValue] = base + [
            ["role": "user", "content": "Turn A", "row_id": 8000, "timestamp": .number(now - 120)],
            ["role": "assistant", "content": "A partial, then the whole of A.", "row_id": 8001, "timestamp": .number(now - 60)],
            ["role": "user", "content": "Turn B", "row_id": 8002, "timestamp": .number(now - 30)],
            ["role": "assistant", "content": "B so far", "row_id": 8003, "timestamp": .number(now - 20)],
        ]
        h.setPage("24", rows: page, hasMore: true)
        h.client.onCall { method, _ in
            switch method {
            case "session.activate":
                return ["session_id": .string(runtime), "running": true, "turn_started_at": .number(now - 30),
                        "inflight": ["user": "Turn B", "assistant": "B so far", "streaming": true]]
            case "session.events.since": return ["events": [], "latest_seq": 99, "truncated": true, "epoch": "fixture-epoch"]
            case "session.active_list": return ["sessions": []]
            default: return [:]
            }
        }
        returnToApp(h)
        #expect(await waitUntil(timeout: .seconds(3)) { !h.client.calls("session.events.since").isEmpty && !s.parking })
        try? await Task.sleep(for: .milliseconds(100))
        s.flushChanges()
        let texts = s.messages.map(\.plainText)
        #expect(texts.filter { $0 == "A partial, then the whole of A." }.count == 1)
        #expect(!texts.contains("A partial"))
        #expect(texts.filter { $0 == "Turn A" }.count == 1)
        #expect(texts.filter { $0 == "Turn B" }.count == 1)
        #expect(texts.filter { $0.hasPrefix("B so far") }.count == 1)
        #expect(texts.suffix(4) == ["Turn A", "A partial, then the whole of A.", "Turn B", "B so far"])
        #expect(s.isRunning)
    }

    /// A skill's bubble shows its invocation while the expanded body went out: a reconnect (no replay) that finds it
    /// still running keeps it as our turn, not a dead partial beside a second live bubble.
    @Test func ownRunningTurnWhoseBubbleShowsOtherTextIsKeptOnReconnect() async throws {
        let h = try ChatHarness(ready: Self.ready)
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming", "user_row_id": 8000] : [:] }
        s.send("Research the tides in depth.", display: "/research tides")
        #expect(await waitUntil { h.lastUser?.isPending == false })
        let runtime = try #require(s.runtimeSessionId)
        await h.emit([h.event("message.start", seq: 8, sid: runtime),
                      h.event("message.delta", ["text": "Tides so far"], seq: 9, sid: runtime)])
        #expect(s.isRunning)
        let now = Date().timeIntervalSince1970
        let base = Array((try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []).suffix(22))
        let page: [JSONValue] = base + [
            ["role": "user", "content": "Research the tides in depth.", "row_id": 8000, "timestamp": .number(now - 30)],
            ["role": "assistant", "content": "Tides so far", "row_id": 8001, "timestamp": .number(now - 20)],
        ]
        h.setPage("24", rows: page, hasMore: true)
        h.client.onCall { method, _ in
            switch method {
            case "session.activate":
                return ["session_id": .string(runtime), "running": true, "turn_started_at": .number(now - 30),
                        "inflight": ["user": "Research the tides in depth.", "assistant": "Tides so far", "streaming": true]]
            case "session.events.since": return ["events": [], "latest_seq": 99, "truncated": true, "epoch": "fixture-epoch"]
            case "session.active_list": return ["sessions": []]
            default: return [:]
            }
        }
        returnToApp(h)
        #expect(await waitUntil(timeout: .seconds(3)) { !h.client.calls("session.events.since").isEmpty && !s.parking })
        try? await Task.sleep(for: .milliseconds(100))
        s.flushChanges()
        let anchor = try #require(s.turn.userAnchorId)
        #expect(s.messages.first { $0.id == anchor }?.role == .user)
        await h.emit([h.event("message.delta", ["text": ", and more"], seq: 100, sid: runtime)])
        s.flushChanges()
        let after = s.messages.drop { $0.id != anchor }.dropFirst()
        #expect(after.count == 1)
        #expect(after.first?.plainText.hasPrefix("Tides so far") == true)
        #expect(after.first?.isStreaming == true)
        #expect(s.isRunning)
    }
}
