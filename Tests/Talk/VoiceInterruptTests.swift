// Words spoken over a running reply (docs/spec/3x-gpt-live.md §4, 3x-talk.md §3.6): the reply stops and the words are
// the next turn. They never wait in the queue, and never go out with `queued`, which would hold them behind the reply.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Voice interrupts the running reply", .serialized)
@MainActor
struct VoiceInterruptTests {
    private func running() async throws -> (ChatHarness, LiveChatSession) {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming"] : ["status": "interrupted"] }
        s.send("one")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Working on it"])])
        #expect(s.turn.busy)
        return (h, s)
    }

    @Test func spokenWordsStopTheReplyAndGoOutUnqueued() async throws {
        let (h, s) = try await running()
        s.sendSpoken("actually, never mind that", interrupted: false)
        #expect(s.queuedMessages.isEmpty)
        #expect(await waitUntil { h.client.calls("session.interrupt").count == 1 })
        await h.emit([h.event("message.complete", ["status": "interrupted"])])
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        let submit = try #require(h.client.calls("prompt.submit").last)
        #expect(submit.params["queued"] == nil)
        #expect(submit.params["interrupted"] == true)
    }

    @Test func aGPTLiveRequestStopsTheReplyAndGoesOutUnqueuedWhereItCannotGoIntoIt() async throws {
        let (h, s) = try await running()
        s.redirectUnsupported = true
        s.sendDelegated("check the weather instead", voiceContext: "User: check the weather instead")
        #expect(s.queuedMessages.isEmpty)
        #expect(await waitUntil { h.client.calls("session.interrupt").count == 1 })
        await h.emit([h.event("message.complete", ["status": "interrupted"])])
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        let submit = try #require(h.client.calls("prompt.submit").last)
        #expect(submit.params["queued"] == nil)
        #expect(submit.params["surface"] == "voice-live")
    }

    /// Owner, 2026-10-28 20:49:23: the stopped turn's own "not running" landed just after the voice's new request began
    /// its turn and ended it there: the voice was told nothing came back, and the answer that followed was never said.
    @Test func theStoppedTurnsLateNotRunningDoesNotEndTheRequestThatReplacedIt() async throws {
        let (h, s) = try await running()
        s.redirectUnsupported = true
        s.sendDelegated("look up the decisions API", voiceContext: "User: look up the decisions API")
        #expect(await waitUntil { h.client.calls("session.interrupt").count == 1 })
        await h.emit([h.event("message.complete", ["status": "interrupted"])])
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        await h.emit([h.event("message.start"), h.event("session.info", ["running": false])])
        #expect(s.turn.busy)
        await h.emit([h.event("message.delta", ["text": "It takes a POST."]),
                      h.event("message.complete", ["text": "It takes a POST.", "status": "complete"])])
        #expect(await waitUntil { !s.turn.busy })
        #expect(s.newestReply?.text == "It takes a POST.")
        // Once the snapshot is ignored, the next one counts.
        s.sendDelegated("and the auth?", voiceContext: "User: and the auth?")
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 3 })
        await h.emit([h.event("message.start"), h.event("session.info", ["running": false])])
        #expect(!s.turn.busy)
    }

    /// Owner, 2026-10-28 20:46: the voice split one thought into two requests 3 s apart and the second stopped the
    /// first's searches. A request made while the reply runs now goes into it, keeping the work under way.
    @Test func aGPTLiveRequestWhileTheReplyRunsGoesIntoIt() async throws {
        let (h, s) = try await running()
        h.client.onCall { method, _ in method == "session.redirect" ? ["status": "redirected"] : ["status": "streaming"] }
        s.sendDelegated("and check the auth too", voiceContext: "User: and check the auth too")
        #expect(await waitUntil { h.client.calls("session.redirect").count == 1 })
        #expect(h.client.calls("session.redirect").first?.params["text"] == "and check the auth too")
        #expect(h.client.calls("session.interrupt").isEmpty)
        #expect(h.client.calls("prompt.submit").count == 1)
        #expect(s.turn.busy)
        #expect(s.messages.last?.role == .user && s.messages.last?.isPending == false)
    }

    @Test func aGPTLiveRequestTheReplyDoesNotTakeStopsItAndGoesOutAlone() async throws {
        let (h, s) = try await running()
        h.client.onCall { method, _ in
            switch method {
            case "session.redirect": return ["status": "rejected"]
            case "prompt.submit": return ["status": "streaming"]
            default: return ["status": "interrupted"]
            }
        }
        s.sendDelegated("check the weather instead", voiceContext: "User: check the weather instead")
        #expect(await waitUntil { h.client.calls("session.interrupt").count == 1 })
        await h.emit([h.event("message.complete", ["status": "interrupted"])])
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        let submit = try #require(h.client.calls("prompt.submit").last)
        #expect(submit.params["surface"] == "voice-live")
        #expect(submit.params["queued"] == nil)
        #expect(s.queuedMessages.isEmpty)
    }

    @Test func aStopThatTakesTooLongStillDoesNotQueueTheWords() async throws {
        let (h, s) = try await running()
        s.stopHoldWindow = .milliseconds(100)
        s.sendSpoken("stop, do this instead", interrupted: true)
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        #expect(h.client.calls("prompt.submit").last?.params["queued"] == nil)   // the gateway's busy mode interrupts
    }

    /// Typed words don't stop the reply: they go into it (desktop parity), or wait in the queue where they can't.
    @Test func typedWordsWhileAReplyRunsGoIntoItWithoutAStop() async throws {
        let (h, s) = try await running()
        h.client.onCall { method, _ in method == "session.redirect" ? ["status": "redirected"] : ["status": "streaming"] }
        s.send("and after that")
        #expect(s.queuedMessages.isEmpty)
        #expect(await waitUntil { h.client.calls("session.redirect").count == 1 })
        #expect(h.client.calls("session.interrupt").isEmpty)
        #expect(h.client.calls("prompt.submit").count == 1)
        s.redirectUnsupported = true
        s.send("and then this")
        #expect(s.queuedMessages.map(\.text) == ["and then this"])
        #expect(h.client.calls("session.interrupt").isEmpty)
    }
}
