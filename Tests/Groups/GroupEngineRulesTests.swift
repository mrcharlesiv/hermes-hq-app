// [groups] The round engine's pure rules (docs/spec/3x-groups.md §6.2, §6.6–§6.7, §7.14): who is asked, in which
// order, which reply is picked from a member's session, what counts as a gone session, and a room's Stop on the wire.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct GroupEngineRulesTests {
    private let seats = GroupsTest.launch

    // MARK: Who is asked (`resolveGroupResponders`)

    @Test func everyoneIsAskedUnlessSomeoneIsMentioned() {
        let plain = [GroupsTest.you("Who has time today?")]
        #expect(GroupEngine.responders(plain, seats: seats).map(\.name) == ["default", "ivy", "research"])
        let one = [GroupsTest.you("@ivy what's next?")]
        #expect(GroupEngine.responders(one, seats: seats).map(\.name) == ["ivy"])
        // Roster order, not the order typed.
        let two = [GroupsTest.you("@research and @hermes, thoughts?")]
        #expect(GroupEngine.responders(two, seats: seats).map(\.name) == ["default", "research"])
        #expect(GroupEngine.responders([GroupsTest.you("@all status")], seats: seats).count == 3)
        #expect(GroupEngine.responders([GroupsTest.you("@everyone status")], seats: seats).count == 3)
        #expect(GroupEngine.responders([], seats: seats).count == 3, "an empty thread asks everyone")
    }

    @Test func aMembersMentionAfterYourMessagePullsThatMemberIn() {
        // Since your last message: Ivy was asked, and Ivy's reply cites Research, so Research answers too.
        let log = [GroupsTest.you("Old question to @research", at: 1), GroupsTest.you("@ivy what's next?", at: 2),
                   GroupsTest.member("ivy", "I need @research for the numbers.", at: 3)]
        #expect(GroupEngine.responders(log, seats: seats).map(\.name) == ["ivy", "research"])
        // A mention before your last message does not count.
        let earlier = [GroupsTest.you("@research first", at: 1), GroupsTest.you("@ivy second", at: 2)]
        #expect(GroupEngine.responders(earlier, seats: seats).map(\.name) == ["ivy"])
        // Someone who is not a member reaches nobody in particular: everyone is asked.
        #expect(GroupEngine.responders([GroupsTest.you("mail bob@example.com please")], seats: seats).count == 3)
    }

    @Test func theOrderTurnsByOneEachRound() {
        #expect(GroupEngine.rotate(seats, round: 0).map(\.name) == ["default", "ivy", "research"])
        #expect(GroupEngine.rotate(seats, round: 1).map(\.name) == ["ivy", "research", "default"])
        #expect(GroupEngine.rotate(seats, round: 2).map(\.name) == ["research", "default", "ivy"])
        #expect(GroupEngine.rotate(seats, round: 3).map(\.name) == ["default", "ivy", "research"])
        #expect(GroupEngine.rotate([seats[0]], round: 5).map(\.name) == ["default"])
        #expect(GroupEngine.rotate([], round: 2).isEmpty)
    }

    @Test func aMemberCitedByAnotherIsOwedATurnUntilItPosts() {
        let cited = [GroupsTest.you("Plan the launch", at: 1), GroupsTest.member("ivy", "@research can you check the papers?", at: 2)]
        #expect(GroupEngine.unaddressed(cited, seats: seats) == ["research"])
        let answered = cited + [GroupsTest.member("research", "Checked: all good.", at: 3)]
        #expect(GroupEngine.unaddressed(answered, seats: seats).isEmpty)
        // A member citing itself, and your own mentions, owe nobody a turn.
        #expect(GroupEngine.unaddressed([GroupsTest.member("ivy", "@ivy note to self", at: 1)], seats: seats).isEmpty)
        #expect(GroupEngine.unaddressed([GroupsTest.you("@ivy hello", at: 1)], seats: seats).isEmpty)
    }

    @Test func theSameWordsFromTheSameMemberSoonAfterAreOneMessage() {
        let first = GroupsTest.member("ivy", "On it.", at: 1_000)
        #expect(GroupEngine.isDuplicate(GroupsTest.member("ivy", "On it.", at: 60_000), in: [first]))
        #expect(!GroupEngine.isDuplicate(GroupsTest.member("ivy", "On it.", at: 700_000), in: [first]), "ten minutes on it is a new message")
        #expect(!GroupEngine.isDuplicate(GroupsTest.member("research", "On it.", at: 2_000), in: [first]))
        #expect(!GroupEngine.isDuplicate(GroupsTest.member("ivy", "On it!", at: 2_000), in: [first]))
        #expect(!GroupEngine.isDuplicate(GroupsTest.member("ivy", "On it.", at: 2_000, thread: "t2"), in: [first]))
        #expect(!GroupEngine.isDuplicate(first, in: []))
        // Only the last entry is compared: something said in between makes it a new message.
        #expect(!GroupEngine.isDuplicate(GroupsTest.member("ivy", "On it.", at: 3_000), in: [first, GroupsTest.you("ok", at: 2_000)]))
    }

    // MARK: A turn the app closed on (stress R1)

    @Test func aTurnCutOffByTheAppClosingBecomesALateReplyToCollect() throws {
        var room = GroupRoom(name: "Launch", roomId: "r1")
        room.log = [GroupsTest.you("Earlier", at: 1, id: "e0"), GroupsTest.you("@ivy finish this", at: 2, id: "e1")]
        let markKey = GroupKeys.watermarkKey(thread: "t1", memberKey: "ivy")
        room.watermarks[markKey] = 1
        room.asking["ivy"] = GroupAsking(before: 4, thread: "t1", at: 9_000, stored: "st-1", markKey: markKey, anchorId: "e1", anchorCount: 2)
        // The marker is in the saved record, so it is still there after the app was closed.
        var loaded = try JSONDecoder().decode(GroupRoom.self, from: JSONEncoder().encode(room))
        #expect(loaded.asking["ivy"]?.before == 4 && loaded.stranded.isEmpty)
        loaded.recoverInterruptedTurns()
        #expect(loaded.asking.isEmpty)
        #expect(loaded.stranded["ivy"] == GroupStranded(before: 4, thread: "t1", at: 9_000, stored: "st-1"), "the reply is read from where the turn began")
        #expect(loaded.watermarks[markKey] == 2, "what the member was shown is not sent to it again")
        // The entry it had read up to left the log meanwhile: the count stands in, never past the log's end.
        var trimmed = room
        trimmed.log.removeLast()
        trimmed.recoverInterruptedTurns()
        #expect(trimmed.watermarks[markKey] == 1)
        // A marker a time-out already left is kept as it is; a record from before this field reads as none.
        var both = room
        both.stranded["ivy"] = GroupStranded(before: 2, thread: "t1", at: 5_000, stored: "st-0")
        both.recoverInterruptedTurns()
        #expect(both.stranded["ivy"]?.before == 2 && both.asking.isEmpty)
        #expect(try JSONDecoder().decode(GroupRoom.self, from: Data(#"{"name":"Old"}"#.utf8)).asking.isEmpty)
    }

    /// Your send and the turn a member is on are handed to the disk writer at once (no 250 ms wait, and the caller is
    /// never blocked); other changes are written within 250 ms of the first one, however many follow (a write that kept
    /// being pushed back lost a send to a closed app).
    @Test func aSendIsQueuedForTheDiskAtOnceAndAWaitingWriteIsNeverPushedBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = GatewayAccount(id: "http://127.0.0.1:9960|disk-\(UUID().uuidString)", baseURL: URL(string: "http://127.0.0.1:9960")!,
                                     kind: .password, username: "t", label: "t")
        var room = GroupRoom(name: "Launch", roomId: "r1")
        room.log = [GroupsTest.you("Earlier", at: 1, id: "e0")]
        RosterDisk.write([room], to: RosterDisk.url(directory, GroupStore.roomsKind, account))
        RosterDiskWriter.shared.flush()
        let store = GroupStore(account: account, directory: directory, bots: nil)
        let key = try #require(store.rooms.first?.key)
        store.update(key, sync: false, now: true) { $0.log.append(GroupsTest.you("@ivy finish this", at: 2, id: "e1")) }
        RosterDiskWriter.shared.flush()      // the writer's queue only: the 250 ms wait has not passed
        let reopened = GroupStore(account: account, directory: directory, bots: nil)
        #expect(reopened.rooms.first?.log.map(\.id) == ["e0", "e1"], "already with the writer, without the 250 ms wait")
        for index in 0..<8 {
            store.update(key, sync: false) { $0.log.append(GroupsTest.you("more \(index)", at: Double(10 + index), id: "m\(index)")) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        RosterDiskWriter.shared.flush()
        let later = GroupStore(account: account, directory: directory, bots: nil)
        #expect((later.rooms.first?.log.count ?? 0) >= 4, "changes that keep coming are written while they come")
        store.saveNow()
        RosterDiskWriter.shared.flush()
    }

    // MARK: A member's session, as read

    @Test func aSessionReadKnowsBusyWaitingAndFailed() throws {
        let idle = try #require(GroupSessionState(["session_id": "run-1", "session_key": "st-1", "running": false,
                                                    "messages": [["role": "user", "content": "hi"], ["role": "assistant", "content": "Hello."]]]))
        #expect(idle.runtime == "run-1" && idle.stored == "st-1" && !idle.busy && !idle.waitingOnUser)
        #expect(idle.rows == [.init(role: "user", text: "hi"), .init(role: "assistant", text: "Hello.")])
        let running = try #require(GroupSessionState(["session_id": "run-1", "running": true]))
        #expect(running.busy)
        let inflight = try #require(GroupSessionState(["session_id": "run-1", "running": false, "inflight": ["status": "streaming"]]))
        #expect(inflight.busy, "a turn in flight is busy even when `running` lags")
        let failed = try #require(GroupSessionState(["session_id": "run-1", "running": false, "turn_started_at": 12,
                                                      "inflight": ["status": "error", "error": "model unavailable"]]))
        #expect(!failed.busy && failed.retainedError == "model unavailable" && failed.retainedKey == "12.0|model unavailable")
        let asking = try #require(GroupSessionState(["session_id": "run-1", "running": true, "open_requests": [["method": "clarify.request"]]]))
        #expect(asking.waitingOnUser)
        let approving = try #require(GroupSessionState(["session_id": "run-1", "running": true, "pending_approval": ["command": "git push"]]))
        #expect(approving.waitingOnUser)
        // Content given as parts is joined; no runtime id is no session.
        let parts = try #require(GroupSessionState(["session_id": "run-1", "messages": [["role": "assistant", "content": [["text": "a"], "b"]]]]))
        #expect(parts.rows == [.init(role: "assistant", text: "ab")])
        #expect(GroupSessionState(["session_id": "  "]) == nil && GroupSessionState(["running": true]) == nil)
    }

    @Test func theNewestRealReplyAfterTheBaselineIsPicked() {
        typealias Row = GroupSessionState.Row
        let rows = [Row(role: "user", text: "old"), Row(role: "assistant", text: "Old answer."), Row(role: "user", text: "prompt"),
                    Row(role: "assistant", text: "First part."), Row(role: "tool", text: "ran"), Row(role: "assistant", text: "Final answer.")]
        #expect(GroupTurn.pick(rows, before: 2) == "Final answer.")
        #expect(GroupTurn.pick(rows, before: 6) == nil, "nothing after the baseline")
        #expect(GroupTurn.pick(Array(rows.prefix(2)), before: 2) == nil, "an answer before the baseline is not this turn's")
        // A pass is silence unless it is all there is; real words win over a pass said after them.
        let passed = [Row(role: "user", text: "prompt"), Row(role: "assistant", text: "(pass)")]
        #expect(GroupTurn.pick(passed, before: 0) == "(pass)")
        let both = [Row(role: "user", text: "prompt"), Row(role: "assistant", text: "Here is the list."), Row(role: "assistant", text: " (pass) ")]
        #expect(GroupTurn.pick(both, before: 0) == "Here is the list.")
        let blank = [Row(role: "user", text: "prompt"), Row(role: "assistant", text: "  \n ")]
        #expect(GroupTurn.pick(blank, before: 0) == nil)
        #expect(GroupTurn.pick([], before: 0) == nil && GroupTurn.pick(rows, before: -3) == "Final answer.")
    }

    @Test func aGoneSessionIsToldFromAnyOtherFailure() {
        #expect(GroupTurn.isGone(RPCError(code: 4001, message: "no such runtime", data: nil)))
        #expect(GroupTurn.isGone(RPCError(code: 5000, message: "Session not in memory", data: nil)))
        #expect(GroupTurn.isGone(RPCError(code: 4007, message: "session not found", data: nil)))
        #expect(!GroupTurn.isGone(RPCError(code: 5000, message: "model unavailable", data: nil)))
        #expect(!GroupTurn.isGone(GroupTurnError.cancelled))
        #expect(GroupTurn.reason(RPCError(code: 5000, message: "model unavailable", data: nil)) == "model unavailable")
        #expect(GroupTurn.reason(GroupTurnError.timedOut(before: 3, stored: "st")) == "took too long")
        #expect(GroupTurn.reason(GroupTurnError.notSent("offline")) == "offline")
    }

    // MARK: Stop on the wire (row L467)

    @Test func stopAsksForTheLiveRuntimeIdThenInterruptsIt() async {
        let client = BotsFakeGatewayClient()
        client.on("session.resume") { params in
            #expect(params["session_id"]?.string == "stored-7" && params["omit_messages"]?.bool == true && params["profile"]?.string == "ivy")
            return ["session_id": "runtime-42", "session_key": "stored-7"]
        }
        client.on("session.interrupt") { _ in ["status": "interrupted"] }
        #expect(await GroupInterrupt.interrupt(client: client, profile: "ivy", storedId: "stored-7"))
        let sent = client.calls("session.interrupt")
        #expect(sent.count == 1 && sent.first?.params["session_id"]?.string == "runtime-42", "the interrupt names the runtime id, never the stored one")
        #expect(sent.first?.params["profile"]?.string == "ivy")
        #expect(client.calls.map(\.method) == ["session.resume", "session.interrupt"])
    }

    @Test func stopIsConfirmedWhenNothingWasRunningAndUnconfirmedOnAnyFailure() async {
        let idle = BotsFakeGatewayClient()
        idle.on("session.resume") { _ in ["session_id": "runtime-1"] }
        idle.on("session.interrupt") { _ in ["status": "not_interrupted"] }
        #expect(await GroupInterrupt.interrupt(client: idle, profile: "ivy", storedId: "s"), "nothing to stop is a confirmed stop")

        let refused = BotsFakeGatewayClient()
        refused.on("session.resume") { _ in ["session_id": "runtime-1"] }
        refused.on("session.interrupt") { _ in throw RPCError(code: 5000, message: "fixture failure", data: nil) }
        #expect(await GroupInterrupt.interrupt(client: refused, profile: "ivy", storedId: "s") == false)

        let odd = BotsFakeGatewayClient()
        odd.on("session.resume") { _ in ["session_id": "runtime-1"] }
        odd.on("session.interrupt") { _ in ["status": "queued"] }
        #expect(await GroupInterrupt.interrupt(client: odd, profile: "ivy", storedId: "s") == false, "an answer that is not a stop is not confirmed")

        // No runtime id, or a session that cannot be resumed: no interrupt is sent at all.
        let blank = BotsFakeGatewayClient()
        blank.on("session.resume") { _ in ["session_id": ""] }
        #expect(await GroupInterrupt.interrupt(client: blank, profile: "ivy", storedId: "s") == false)
        #expect(blank.calls("session.interrupt").isEmpty)
        let gone = BotsFakeGatewayClient()
        gone.on("session.resume") { _ in throw RPCError(code: 4007, message: "session not found", data: nil) }
        #expect(await GroupInterrupt.interrupt(client: gone, profile: "ivy", storedId: "s") == false)
        #expect(gone.calls("session.interrupt").isEmpty)
    }
}
