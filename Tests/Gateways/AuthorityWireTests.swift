import Foundation
import Testing
@testable import HermesHQNative

// [authority] A gateway-hosted Hermes answers /api/ws from its session authority, which admits a `prompt.submit` only
// with a request id; the plain sidecar refuses that key (tester log 2026-11-06: every send "Invalid_params").
@Suite struct AuthorityWireTests {
    private let send: JSONValue = ["session_id": "rt-1", "text": "Hi", "profile": "default"]

    @Test func authoritySendGetsARequestId() {
        let out = AuthorityWire.adapt("prompt.submit", send, authority: true).params
        #expect(out["submission_id"]?.string?.isEmpty == false)
        #expect(out["text"]?.string == "Hi" && out["session_id"]?.string == "rt-1")
    }

    @Test func aSendKeepsItsOwnIdThroughRetries() {
        var params = send.object!
        params["submission_id"] = AuthorityWire.submissionId(for: "local-user-3-42")
        let first = AuthorityWire.adapt("prompt.submit", .object(params), authority: true).params
        let again = AuthorityWire.adapt("prompt.submit", .object(params), authority: true).params
        #expect(first["submission_id"] == again["submission_id"])
        #expect(first["submission_id"]?.string == "hq-local-user-3-42")
    }

    @Test func sidecarNeverSeesTheId() {
        var params = send.object!
        params["submission_id"] = AuthorityWire.submissionId(for: "local-user-3-42")
        let out = AuthorityWire.adapt("prompt.submit", .object(params), authority: false).params
        #expect(out["submission_id"] == nil)
        #expect(out == send)
    }

    @Test func otherCallsPassUntouched() {
        let params: JSONValue = ["session_id": "rt-1"]
        let out = AuthorityWire.adapt("session.resume", params, authority: true, generation: 3)
        #expect(out.method == "session.resume" && out.params == params)
        let plain = AuthorityWire.adapt("session.activate", params, authority: false, generation: 3)
        #expect(plain.method == "session.activate" && plain.params == params)
    }

    @Test func activateIsAResumeOnTheAuthority() {
        let params: JSONValue = ["session_id": "rt-1", "cols": 96, "omit_messages": true, "profile": "default"]
        let out = AuthorityWire.adapt("session.activate", params, authority: true, generation: 2)
        #expect(out.method == "session.resume" && out.params == params)
    }

    @Test func turnControlsNameTheRunningTurn() {
        for method in ["session.redirect", "session.interrupt"] {
            let out = AuthorityWire.adapt(method, ["session_id": "rt-1", "text": "also this"], authority: true, generation: 4)
            #expect(out.method == method && out.params["execution_generation"]?.int == 4)
            // Unknown turn: nothing invented; the sidecar never gets the key.
            #expect(AuthorityWire.adapt(method, ["session_id": "rt-1"], authority: true).params["execution_generation"] == nil)
            #expect(AuthorityWire.adapt(method, ["session_id": "rt-1"], authority: false, generation: 4).params["execution_generation"] == nil)
        }
    }

    @Test func approvalAnswerUsesTheAuthorityShape() {
        let params: JSONValue = ["session_id": "rt-1", "choice": "once", "all": false, "request_id": "p-9", "profile": "default"]
        let out = AuthorityWire.adapt("approval.respond", params, authority: true, generation: 1).params
        #expect(out == ["session_id": "rt-1", "choice": "once", "prompt_id": "p-9", "profile": "default", "execution_generation": 1])
        #expect(AuthorityWire.adapt("approval.respond", params, authority: false, generation: 1).params == params)
    }

    @Test func createUsesTheAuthorityShape() {
        let chat: JSONValue = ["profile": "default", "source": "desktop", "cwd": "/w", "cwd_explicit": true]
        #expect(AuthorityWire.adapt("session.create", chat, authority: true).params
                == ["profile": "default", "source": "gui", "cwd": "/w", "cwd_explicit": true])
        #expect(AuthorityWire.adapt("session.create", chat, authority: false).params == chat)
        let member: JSONValue = ["profile": "ops", "title": "Group: r · t", "hidden": true, "room_plumbing": true,
                                 "follow_profile_config": true, "idempotency_key": "k-1"]
        #expect(AuthorityWire.adapt("session.create", member, authority: true).params
                == ["profile": "ops", "title": "Group: r · t", "hidden": true, "follow_profile_config": true,
                    "request_id": "k-1", "source": "gui"])
    }

    @Test func framesCarryTheirTurn() {
        let frame = #"{"jsonrpc":"2.0","method":"event","params":{"authority_epoch":4,"execution_generation":1,"type":"message.start","session_id":"rt-1","payload":{}}}"#
        guard case .event(let event) = RPCFrame.parse(frame) else { Issue.record("not an event"); return }
        #expect(event.generation == 1)
        let replayed = RPCFrame.event(from: ["type": "agent.step", "session_id": "rt-1", "execution_generation": 2] as JSONValue)
        #expect(replayed?.generation == 2)
    }
}
