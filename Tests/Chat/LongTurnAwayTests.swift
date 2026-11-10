// Owner 2026-10-24, Hermes chat, build 359: a voice memo about a wrong Amazon item. The turn ran 6½ minutes over 62 stored
// rows (rows 27589–27650: the prompt, ~30 tool calls, a progress note before the phone left, one after, the reply). The
// phone left after the first note and came back by tapping the reply's alert with the chat still open. The screen showed
// the whole turn in one bubble, then a second bubble from "Refund confirmed" on: the newest 24 rows start mid-turn.
// Hermes stored every row once; the doubled-reply watch logged nothing (the two bubbles open with different words).

import Foundation
import Testing
@testable import HermesHQNative

@Suite("A long turn that finished while the link was down shows once", .serialized)
@MainActor
struct LongTurnAwayTests {
    private static let ready: JSONValue = ["heartbeat": true, "change_events": true, "replay_epoch": "fixture-epoch"]
    private static let memo = "MEDIA:\"/Users/x/.hermes/attachments/voice-memo-175.m4a\"\n\nVoice memo transcript: They sent me the wrong product."
    private static let note1 = "I ordered the right item (the blue USB-C cable), so Amazon packed the wrong one. Starting the return."
    private static let note2 = "Refund confirmed. Reordering the correct item."
    private static let final = "My order was correct, so Amazon packed the wrong item. It's fixed: refund confirmed, reorder arriving today."

    /// `connectionReplay`: the connection's own replay hands over the rest of the turn while the chat's activate is out
    /// (owner 2026-10-29, build 475, Hermes "To Inbox": the reply showed twice until the chat was opened again).
    enum Return { case restRead, emptyReplay, replayedEnd, connectionReplay }
    enum Alert { case none, beforeReturn, afterReturn }

    /// The calls before the first note, the calls between the notes, and the calls after the second.
    private static let lead = 3, middle = 20, tail = 2

    /// Stored rows of the turn: each call is an assistant row (a note rides on the call it made) and its tool row.
    private func storedTurn(_ now: Double, prompt: String) -> [JSONValue] {
        var rows: [JSONValue] = [["role": "user", "content": .string(prompt), "row_id": 9000, "timestamp": .number(now - 400)]]
        var row = 9001
        func call(_ k: Int, note: String? = nil) {
            let id = "c\(k)"
            rows.append(["role": "assistant", "content": .string(note ?? ""), "row_id": .number(Double(row)),
                         "timestamp": .number(now - 390 + Double(k * 10)), "finish_reason": "tool_calls",
                         "tool_calls": [["id": .string(id), "type": "function", "function": ["name": "terminal", "arguments": "{\"command\":\"amazon\"}"]]]])
            rows.append(["role": "tool", "content": "{\"output\":\"ok\",\"exit_code\":0}", "tool_call_id": .string(id),
                         "row_id": .number(Double(row + 1)), "timestamp": .number(now - 389 + Double(k * 10))])
            row += 2
        }
        var k = 0
        for _ in 0..<Self.lead { call(k); k += 1 }
        call(k, note: Self.note1); k += 1
        for _ in 0..<Self.middle { call(k); k += 1 }
        call(k, note: Self.note2); k += 1
        for _ in 0..<Self.tail { call(k); k += 1 }
        rows.append(["role": "assistant", "content": .string(Self.final), "row_id": .number(Double(row)), "finish_reason": "stop",
                     "timestamp": .number(now - 10)])
        return rows
    }

    private static var finalRow: Int { 9001 + 2 * (lead + 1 + middle + 1 + tail) }

    /// The core history route over `rows`, newest first by offset, as Hermes pages it.
    private func serve(_ h: ChatHarness, _ rows: [JSONValue]) {
        let stored = h.stored
        h.client.onRest { _, query in
            let limit = Int(query.first { $0.name == "limit" }?.value ?? "500") ?? 500
            let offset = Int(query.first { $0.name == "offset" }?.value ?? "0") ?? 0
            let end = max(0, rows.count - offset)
            let start = max(0, end - limit)
            let slice = Array(rows[start..<end])
            let body: JSONValue = ["session_id": .string(stored), "profile": "default", "messages": .array(slice),
                                   "pagination": ["limit": .number(Double(limit)), "offset": .number(Double(offset)), "order": "latest",
                                                  "returned": .number(Double(slice.count)), "has_more": .bool(start > 0),
                                                  "next_offset": .number(Double(offset + slice.count))]]
            return encodeJSON(body)
        }
    }

    private func toolFrames(_ k: Int, _ seq: inout Int, runtime: String) -> [JSONValue] {
        defer { seq += 2 }
        return [["type": "tool.start", "session_id": .string(runtime), "seq": .number(Double(seq)),
                 "payload": ["tool_id": .string("c\(k)"), "name": "terminal", "args": ["command": "amazon"]]],
                ["type": "tool.complete", "session_id": .string(runtime), "seq": .number(Double(seq + 1)),
                 "payload": ["tool_id": .string("c\(k)"), "name": "terminal", "result": ["stdout": "ok", "exit_code": 0]]]]
    }

    private func run(_ way: Return, alert: Alert, ackRow: Bool = true) async throws {
        let h = try ChatHarness(ready: Self.ready)
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        h.client.onCall { method, _ in method == "prompt.submit" ? (ackRow ? ["status": "streaming", "user_row_id": 9000] : ["status": "streaming"]) : [:] }
        s.send(Self.memo)
        #expect(await waitUntil { h.lastUser?.isPending == false })
        let runtime = try #require(s.runtimeSessionId)

        // Heard live: the first calls, the first note, the note's own call starting.
        var seq = 8
        var live: [JSONValue] = [["type": "message.start", "session_id": .string(runtime), "seq": 8]]
        seq += 1
        for k in 0..<Self.lead { live += toolFrames(k, &seq, runtime: runtime) }
        live.append(["type": "message.delta", "session_id": .string(runtime), "seq": .number(Double(seq)), "payload": ["text": .string(Self.note1)]])
        seq += 1
        let noteCall = toolFrames(Self.lead, &seq, runtime: runtime)
        live.append(noteCall[0])
        await h.emit(live.map { frame in
            h.event(frame["type"]!.string!, frame["payload"] ?? .null, seq: frame["seq"]?.int, sid: runtime)
        })
        let lastHeard = seq - 2   // the note's call started; its completion was missed
        #expect(s.isRunning)

        // Missed while away: the rest of the turn.
        var missed: [JSONValue] = [noteCall[1]]
        var k = Self.lead + 1
        for _ in 0..<Self.middle { missed += toolFrames(k, &seq, runtime: runtime); k += 1 }
        missed.append(["type": "message.delta", "session_id": .string(runtime), "seq": .number(Double(seq)), "payload": ["text": .string(Self.note2)]])
        seq += 1
        missed += toolFrames(k, &seq, runtime: runtime); k += 1
        for _ in 0..<Self.tail { missed += toolFrames(k, &seq, runtime: runtime); k += 1 }
        missed.append(["type": "message.delta", "session_id": .string(runtime), "seq": .number(Double(seq)), "payload": ["text": .string(Self.final)]])
        seq += 1
        missed.append(["type": "message.complete", "session_id": .string(runtime), "seq": .number(Double(seq)),
                       "payload": ["text": .string(Self.final), "status": "complete", "final_assistant_row_id": .number(Double(Self.finalRow))]])
        let latest = seq
        let replay = missed

        let now = Date().timeIntervalSince1970
        let base = try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []
        serve(h, base + storedTurn(now, prompt: Self.memo))

        var snapshots: [[String]] = []
        func look(_ times: Int) async {
            for _ in 0..<times {
                try? await Task.sleep(for: .milliseconds(100))
                s.flushChanges()
                snapshots.append(s.messages.filter { $0.role == .assistant }.map(\.plainText))
            }
        }
        if alert == .beforeReturn {
            let before = h.client.restLog.count
            s.probeTailSoon(after: .zero, force: true)
            _ = await waitUntil { h.client.restLog.count > before && s.refreshTask == nil }
            await look(3)
        }
        let client = h.client
        let connectionReplay = replay.map { f in h.event(f["type"]!.string!, f["payload"] ?? .null, seq: f["seq"]?.int, sid: runtime) }
        h.client.onCall { method, _ in
            switch method {
            case "session.activate":
                // The connection's own replay lands while the chat's activate is out (parked by the chat). On a real
                // socket `replayDone` holds the reconnect until all of it is handed over; here the answer waits for it.
                if way == .connectionReplay {
                    connectionReplay.forEach { client.emit(frame: $0) }
                    try? await Task.sleep(for: .milliseconds(150))
                }
                return ["session_id": .string(runtime), "running": false]
            case "session.events.since":
                switch way {
                case .restRead: return ["events": [], "latest_seq": .number(Double(latest)), "truncated": true, "epoch": "fixture-epoch"]
                case .emptyReplay: return ["events": [], "latest_seq": .number(Double(lastHeard)), "truncated": false, "epoch": "fixture-epoch"]
                case .replayedEnd, .connectionReplay:
                    return ["events": .array(replay), "latest_seq": .number(Double(latest)), "truncated": false, "epoch": "fixture-epoch"]
                }
            case "session.active_list": return ["sessions": []]
            default: return [:]
            }
        }
        h.client.setConnection(.reconnecting(attempt: 1))
        h.client.setConnection(.ready)
        h.client.setReady(Self.ready)
        #expect(await waitUntil(timeout: .seconds(3)) { !h.client.calls("session.activate").isEmpty && !s.parking })
        if way == .connectionReplay { #expect(h.client.calls("session.events.since").isEmpty, "the parked replay should cover the gap") }
        await look(15)
        if alert == .afterReturn {
            // The alert tapped with the chat on screen: one forced tail read (AppModel.openNotifiedChat).
            s.probeTailSoon(after: .zero, force: true)
        }
        await look(20)

        let worstFinal = snapshots.map { $0.filter { $0.contains("My order was correct") }.count }.max() ?? 0
        let worstNote = snapshots.map { $0.filter { $0.contains("Refund confirmed") }.count }.max() ?? 0
        let shown = s.messages.filter { $0.role == .assistant }.suffix(3).map { "[\($0.id) row \($0.rowId.map(String.init) ?? "-")] \($0.plainText.prefix(40))" }
        #expect(worstFinal == 1, "reply shown \(worstFinal)× (\(way), alert \(alert)); last: \(shown)")
        #expect(worstNote == 1, "second note shown \(worstNote)× (\(way), alert \(alert)); last: \(shown)")
        #expect(!s.isRunning)
    }

    /// The owner's morning: away 8 s after sending, back mid-turn (the gateway's in-flight text over a partial stored
    /// turn), 18 s on screen, away again, back by the alert after the turn ended.
    /// `ringOverflow`: the gateway's replay ring (512 frames, 4 MB) lost the turn's middle while the phone was away, so
    /// the end return's replays (the connection's own, then the chat's) hand over only the frames from just before the
    /// second note, marked truncated.
    private func runTwoTrips(midTruncated: Bool, endTruncated: Bool, alert: Alert, ackRow: Bool = true, heardStart: Bool = true,
                             ringOverflow: Bool = false, lostCursor: Bool = false) async throws {
        let h = try ChatHarness(ready: Self.ready)
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        h.client.onCall { method, _ in method == "prompt.submit" ? (ackRow ? ["status": "streaming", "user_row_id": 9000] : ["status": "streaming"]) : [:] }
        s.send(Self.memo)
        #expect(await waitUntil { h.lastUser?.isPending == false })
        let runtime = try #require(s.runtimeSessionId)

        // Every frame of the turn, and where each trip falls in it.
        var seq = 8
        var frames: [JSONValue] = [["type": "message.start", "session_id": .string(runtime), "seq": 8]]
        seq += 1
        func delta(_ text: String, interim: Bool = true) {
            frames.append(["type": "message.delta", "session_id": .string(runtime), "seq": .number(Double(seq)), "payload": ["text": .string(text)]])
            seq += 1
            guard interim else { return }
            // A note beside tool calls is sealed as its own segment (tui_gateway prompt_turn `_interim_assistant_cb`).
            frames.append(["type": "message.interim", "session_id": .string(runtime), "seq": .number(Double(seq)),
                           "payload": ["text": .string(text), "already_streamed": true]])
            seq += 1
        }
        var k = 0
        frames += toolFrames(k, &seq, runtime: runtime); k += 1
        let leftFirst = frames.count                     // heard before the first trip away
        for _ in 1..<Self.lead { frames += toolFrames(k, &seq, runtime: runtime); k += 1 }
        delta(Self.note1)
        frames += toolFrames(k, &seq, runtime: runtime); k += 1
        frames += toolFrames(k, &seq, runtime: runtime); k += 1
        let backMid = frames.count                       // stored by the mid-turn return
        frames += toolFrames(k, &seq, runtime: runtime); k += 1
        frames += toolFrames(k, &seq, runtime: runtime); k += 1
        let leftAgain = frames.count                     // heard live in the 18 s on screen
        for _ in 0..<(Self.middle - 2) { frames += toolFrames(k, &seq, runtime: runtime); k += 1 }
        let ringStart = frames.count - 4                 // what the ring still holds at the end: two calls before the note
        delta(Self.note2)
        frames += toolFrames(k, &seq, runtime: runtime); k += 1
        for _ in 0..<Self.tail { frames += toolFrames(k, &seq, runtime: runtime); k += 1 }
        delta(Self.final, interim: false)
        frames.append(["type": "message.complete", "session_id": .string(runtime), "seq": .number(Double(seq)),
                       "payload": ["text": .string(Self.final), "status": "complete", "final_assistant_row_id": .number(Double(Self.finalRow))]])
        let all = frames
        func emit(_ range: Range<Int>) async {
            await h.emit(all[range].map { f in h.event(f["type"]!.string!, f["payload"] ?? .null, seq: f["seq"]?.int, sid: runtime) })
        }
        func since(upTo end: Int, truncated: Bool) -> CallResponderAnswer {
            let shown = Array(all[..<end])
            let latest = shown.last?["seq"]?.int ?? 0
            return { params in
                let after = params["last_seen"]?.int ?? 0
                let events = truncated ? [] : shown.filter { ($0["seq"]?.int ?? 0) > after }
                return ["events": .array(events), "latest_seq": .number(Double(latest)), "truncated": .bool(truncated), "epoch": "fixture-epoch"]
            }
        }
        func reconnect(activate: JSONValue, since answer: @escaping CallResponderAnswer, connectionReplay: [JSONValue] = []) async {
            let client = h.client
            h.client.onCall { method, params in
                switch method {
                case "session.activate":
                    // The connection's own replay lands while the chat's activate is out (parked by the chat).
                    connectionReplay.forEach { client.emit(frame: $0) }
                    return activate
                case "session.events.since": return answer(params)
                case "session.active_list": return ["sessions": []]
                default: return [:]
                }
            }
            let before = h.client.calls("session.activate").count
            h.client.setConnection(.reconnecting(attempt: 1))
            h.client.setConnection(.ready)
            h.client.setReady(Self.ready)
            #expect(await waitUntil(timeout: .seconds(3)) { h.client.calls("session.activate").count > before && !s.parking })
        }

        var snapshots: [[String]] = []
        func look(_ times: Int) async {
            for _ in 0..<times {
                try? await Task.sleep(for: .milliseconds(100))
                s.flushChanges()
                snapshots.append(s.messages.filter { $0.role == .assistant }.map(\.plainText))
            }
        }
        if heardStart { await emit(0..<leftFirst) }

        let now = Date().timeIntervalSince1970
        let base = try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []
        let turnRows = storedTurn(now, prompt: Self.memo)
        // Back mid-turn: the prompt, the first calls and the first note are stored; the gateway runs the turn.
        serve(h, base + turnRows.prefix(1 + 2 * (Self.lead + 2)))
        await reconnect(activate: ["session_id": .string(runtime), "running": true, "turn_started_at": .number(now - 400),
                                   "inflight": ["user": .string(Self.memo), "assistant": .string(Self.note1), "streaming": true]],
                        since: since(upTo: backMid, truncated: midTruncated))
        await look(10)
        await emit(backMid..<leftAgain)
        await look(5)

        // Back by the alert: the turn ended while away.
        serve(h, base + turnRows)
        if lostCursor { s.lastSeq = nil }                // a chat with no cursor of its own: the connection's replay still parks
        if ringOverflow {
            let ring = Array(all[ringStart...])
            let latest = ring.last?["seq"]?.int ?? 0
            let replay = ring.map { f in h.event(f["type"]!.string!, f["payload"] ?? .null, seq: f["seq"]?.int, sid: runtime) }
            await reconnect(activate: ["session_id": .string(runtime), "running": false],
                            since: { params in
                                let after = params["last_seen"]?.int ?? 0
                                return ["events": .array(ring.filter { ($0["seq"]?.int ?? 0) > after }), "latest_seq": .number(Double(latest)),
                                        "truncated": true, "epoch": "fixture-epoch"]
                            },
                            connectionReplay: replay)
        } else {
            await reconnect(activate: ["session_id": .string(runtime), "running": false], since: since(upTo: all.count, truncated: endTruncated))
        }
        if alert == .afterReturn { s.probeTailSoon(after: .milliseconds(300), force: true) }
        await look(30)

        let worstFinal = snapshots.map { $0.filter { $0.contains("My order was correct") }.count }.max() ?? 0
        let worstNote = snapshots.map { $0.filter { $0.contains("Refund confirmed") }.count }.max() ?? 0
        let worstFirst = snapshots.map { $0.filter { $0.contains("I ordered the right item") }.count }.max() ?? 0
        let shown = s.messages.filter { $0.role == .assistant }.suffix(3).map { "[\($0.id) row \($0.rowId.map(String.init) ?? "-")] \($0.plainText.prefix(40))" }
        #expect(worstFinal == 1, "reply shown \(worstFinal)×; last: \(shown)")
        #expect(worstNote == 1, "second note shown \(worstNote)×; last: \(shown)")
        #expect(worstFirst == 1, "first note shown \(worstFirst)×; last: \(shown)")
        #expect(!s.isRunning)
    }

    typealias CallResponderAnswer = @Sendable (JSONValue) -> JSONValue

    @Test func twoTripsRingOverflow() async throws {
        try await runTwoTrips(midTruncated: false, endTruncated: true, alert: .afterReturn, ringOverflow: true)
    }
    @Test func twoTripsRingOverflowNoAlert() async throws {
        try await runTwoTrips(midTruncated: false, endTruncated: true, alert: .none, ringOverflow: true)
    }
    @Test func twoTripsRingOverflowMidTruncated() async throws {
        try await runTwoTrips(midTruncated: true, endTruncated: true, alert: .afterReturn, ringOverflow: true)
    }
    @Test func twoTripsRingOverflowLostCursor() async throws {
        try await runTwoTrips(midTruncated: false, endTruncated: true, alert: .afterReturn, ringOverflow: true, lostCursor: true)
    }
    @Test func twoTripsTruncatedBoth() async throws { try await runTwoTrips(midTruncated: true, endTruncated: true, alert: .afterReturn) }
    @Test func twoTripsReplayedMidTruncatedEnd() async throws { try await runTwoTrips(midTruncated: false, endTruncated: true, alert: .afterReturn) }
    @Test func twoTripsReplayedBoth() async throws { try await runTwoTrips(midTruncated: false, endTruncated: false, alert: .afterReturn) }
    @Test func twoTripsTruncatedMidReplayedEnd() async throws { try await runTwoTrips(midTruncated: true, endTruncated: false, alert: .afterReturn) }
    @Test func twoTripsNoAlert() async throws { try await runTwoTrips(midTruncated: true, endTruncated: true, alert: .none) }
    @Test func twoTripsNoAckRow() async throws { try await runTwoTrips(midTruncated: true, endTruncated: true, alert: .afterReturn, ackRow: false) }
    @Test func twoTripsNothingHeard() async throws { try await runTwoTrips(midTruncated: true, endTruncated: true, alert: .afterReturn, heardStart: false) }
    @Test func twoTripsNothingHeardNoAckRow() async throws {
        try await runTwoTrips(midTruncated: true, endTruncated: true, alert: .afterReturn, ackRow: false, heardStart: false)
    }

    @Test func restRead() async throws { try await run(.restRead, alert: .none) }
    @Test func emptyReplay() async throws { try await run(.emptyReplay, alert: .none) }
    @Test func replayedEnd() async throws { try await run(.replayedEnd, alert: .none) }
    @Test func restReadThenAlert() async throws { try await run(.restRead, alert: .afterReturn) }
    @Test func emptyReplayThenAlert() async throws { try await run(.emptyReplay, alert: .afterReturn) }
    @Test func replayedEndThenAlert() async throws { try await run(.replayedEnd, alert: .afterReturn) }
    @Test func alertThenRestRead() async throws { try await run(.restRead, alert: .beforeReturn) }
    @Test func alertThenReplayedEnd() async throws { try await run(.replayedEnd, alert: .beforeReturn) }
    @Test func noAckRowRestReadThenAlert() async throws { try await run(.restRead, alert: .afterReturn, ackRow: false) }
    @Test func noAckRowReplayedEndThenAlert() async throws { try await run(.replayedEnd, alert: .afterReturn, ackRow: false) }
    @Test func connectionReplay() async throws { try await run(.connectionReplay, alert: .none) }
    @Test func connectionReplayThenAlert() async throws { try await run(.connectionReplay, alert: .afterReturn) }
    @Test func noAckRowConnectionReplay() async throws { try await run(.connectionReplay, alert: .none, ackRow: false) }

    // MARK: The doubled-reply watch

    @Test func theWatchSeesATurnsTailDrawnAgain() {
        func message(_ id: String, _ role: ChatMessage.Role, _ text: String, row: Int?) -> ChatMessage {
            ChatMessage(id: id, role: role, parts: [.text(text)], timestamp: Date(), rowId: row)
        }
        let whole = message("stored-row-9001-assistant", .assistant, [Self.note1, Self.note2, Self.final].joined(separator: "\n\n"), row: 9001)
        let tail = message("local-assistant-3", .assistant, [Self.note2, Self.final].joined(separator: "\n\n"), row: nil)
        #expect(LiveChatSession.doubledReply(in: [whole, tail][...])?.1.id == "local-assistant-3")
        // The same closing words on the next turn's reply are not the same reply twice.
        let prompt = message("stored-row-9100-user", .user, "And the other order?", row: 9100)
        let next = message("local-assistant-4", .assistant, "The other order arrives Monday. " + Self.final, row: nil)
        #expect(LiveChatSession.doubledReply(in: [whole, prompt, next][...]) == nil)
    }
}
