// [authority] A gateway-hosted Hermes's session authority answers a missing session as `4001 not_found` (every one of
// its refusals is 4001 + a reason), where the plain chat helper says 4007. A tester's new group chat never sent: each
// member's first turn stopped at "Couldn't check …'s group session (not_found) — not starting a new one".

import Foundation
import Testing
@testable import HermesHQNative

@Suite(.serialized) @MainActor struct AuthorityGroupSessionTests {
    @Test func notFoundFromTheAuthorityMeansNoSessionYet() {
        #expect(GroupTurn.isAbsent(RPCError(code: 4007, message: "session does not exist", data: nil)))
        #expect(GroupTurn.isAbsent(RPCError(code: 4001, message: "not_found", data: ["reason": "not_found"])))
        #expect(GroupTurn.isAbsent(RPCError(code: 4001, message: "Session gone", data: ["reason": "not_found"])))
        // Any other refusal is a doubtful answer: never a second session.
        #expect(!GroupTurn.isAbsent(RPCError(code: 4001, message: "permission_denied", data: ["reason": "permission_denied"])))
        #expect(!GroupTurn.isAbsent(RPCError(code: 4001, message: "invalid_params", data: nil)))
        #expect(!GroupTurn.isAbsent(RPCError(code: 5001, message: "storage_unavailable", data: nil)))
    }

    private func ensure(_ client: BotsFakeGatewayClient) async throws -> GroupSessionState {
        let turn = GroupTurn(client: client, signals: GroupSignals())
        var room = GroupRoom(name: "Otto & Ivy", roomId: "room-1")
        room.members = [GroupMember(name: "otto"), GroupMember(name: "ivy")]
        return try await turn.ensureSession(room: room, thread: "t1", seat: GroupsTest.seat("ivy"), idempotencyKey: "key-1", save: { _ in })
    }

    @Test func aFirstTurnOnTheAuthorityMakesTheMembersSession() async throws {
        let client = BotsFakeGatewayClient()
        client.on("session.resume") { _ in throw RPCError(code: 4001, message: "not_found", data: ["reason": "not_found"]) }
        client.on("session.create") { _ in ["session_id": "local-ivy", "stored_session_id": "local-ivy"] }
        let state = try await ensure(client)
        #expect(state.fresh && state.stored == "local-ivy")
        #expect(client.calls("session.create").count == 1)
        #expect(client.calls("session.create").first?.params["title"]?.string == "Group: room-1 · t1")
    }

    @Test func anyOtherRefusalStillStopsBeforeMakingASession() async {
        let client = BotsFakeGatewayClient()
        client.on("session.resume") { _ in throw RPCError(code: 4001, message: "permission_denied", data: ["reason": "permission_denied"]) }
        client.on("session.create") { _ in ["session_id": "local-ivy"] }
        await #expect(throws: GroupTurnError.self) { _ = try await ensure(client) }
        #expect(client.calls("session.create").isEmpty)
    }
}
