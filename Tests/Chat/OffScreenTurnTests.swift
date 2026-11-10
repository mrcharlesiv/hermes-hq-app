// Off-screen turns (lifecycle #15, #44): a chat tells the app model when it binds a new runtime id, so a turn that
// started before the bind (or moved during it) is heard by the id it runs by; and each reattach after a reconnect
// asks on its own and says whether it got an answer.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@MainActor
@Suite struct RuntimeBoundTests {
    private func chat(_ client: FakeGatewayClient) -> LiveChatSession {
        LiveChatSession(client: client, account: client.account, profile: "default", storedSessionId: "stored",
                        title: "Hermes", head: nil, cache: makeTempCache(), resolveSessionId: nil)
    }

    @Test func firesWithTheOldAndNewIdOnlyWhenTheIdChanges() {
        let client = FakeGatewayClient()
        let chat = chat(client)
        var binds: [(String?, String)] = []
        chat.onRuntimeBound = { binds.append(($0, $1)) }
        chat.bindRuntime(["session_id": "r1"])
        chat.bindRuntime(["session_id": "r1"])
        chat.bindRuntime(["session_id": "r2"])
        chat.bindRuntime(["session_id": ""])
        #expect(binds.count == 2)
        #expect(binds.first?.0 == nil && binds.first?.1 == "r1")
        #expect(binds.last?.0 == "r1" && binds.last?.1 == "r2")
    }

    @Test func nothingIsReportedRunningBeforeAFlushSaysSo() {
        let chat = chat(FakeGatewayClient())
        #expect(!chat.reportsRunning)
    }
}

@Suite struct UnheardTurnReattachTests {
    private static func unheard() -> Bool { true }

    @Test func aTurnStillRunningUnderAnotherIdSaysWhere() async {
        let client = FakeGatewayClient()
        client.onCall { _, _ in ["running": true, "session_id": "r2"] }
        #expect(await UnheardTurns.reattach("r1", profile: "ivy", client: client, stillUnheard: Self.unheard) == .running(movedTo: "r2"))
        #expect(client.calls("session.activate").first?.params["profile"]?.string == "ivy")
        client.onCall { _, _ in ["running": true, "session_id": "r1"] }
        #expect(await UnheardTurns.reattach("r1", profile: "", client: client, stillUnheard: Self.unheard) == .running(movedTo: nil))
    }

    @Test func aTurnTheGatewayNoLongerRunsEnded() async {
        let client = FakeGatewayClient()
        client.onCall { _, _ in ["running": false] }
        #expect(await UnheardTurns.reattach("r1", profile: "", client: client, stillUnheard: Self.unheard) == .ended)
        client.onCall { _, _ in throw RPCError(code: 4001, message: "no session") }
        #expect(await UnheardTurns.reattach("r1", profile: "", client: client, stillUnheard: Self.unheard) == .ended)
    }

    @Test func noAnswerIsAFailureToAskAgain() async {
        let client = FakeGatewayClient()
        client.onCall { method, _ in throw RPCError.timedOut(method, after: .seconds(30)) }
        #expect(await UnheardTurns.reattach("r1", profile: "", client: client, stillUnheard: Self.unheard) == .failed)
    }

    @Test func aTurnHeardAgainIsNotAsked() async {
        let client = FakeGatewayClient()
        #expect(await UnheardTurns.reattach("r1", profile: "", client: client, stillUnheard: { false }) == .skipped)
        #expect(client.calls("session.activate").isEmpty)
    }

    /// One hung activate no longer holds the others: each turn asks on its own (through `reattachAll`, as AppModel asks).
    @MainActor @Test func aHungActivateDoesNotHoldTheOthers() async {
        let client = FakeGatewayClient()
        client.onCall { _, params in
            if params["session_id"]?.string == "slow" { try await Task.sleep(for: .seconds(30)) }
            return ["running": false]
        }
        let start = ContinuousClock.now
        var answered: [String: UnheardTurns.Outcome] = [:]
        let task = Task { @MainActor in
            await UnheardTurns.reattachAll(client: client, retryDelay: .seconds(10), unheard: { ["slow": "", "fast": ""] },
                                           linkUp: { true }, outcome: { answered[$0] = $1 }, roundOver: {})
        }
        #expect(await waitUntil { answered["fast"] == .ended })
        #expect(answered["slow"] == nil)
        #expect(ContinuousClock.now - start < .seconds(5))
        task.cancel()
    }
}

/// AppModel's reattach rounds (`UnheardTurns.reattachAll`): a turn with no answer asks again after the delay while the
/// link stays up, and what a round ended is shown before the retries.
@MainActor
@Suite struct UnheardTurnRetryTests {
    @Test func noAnswerAsksAgainAfterTheDelay() async {
        let client = FakeGatewayClient()
        let asked = Mutex(0)
        client.onCall { method, _ in
            let n = asked.withLock { $0 += 1; return $0 }
            if n == 1 { throw RPCError.timedOut(method, after: .seconds(30)) }
            return ["running": false]
        }
        var outcomes: [UnheardTurns.Outcome] = []
        var rounds = 0
        let start = ContinuousClock.now
        await UnheardTurns.reattachAll(client: client, retryDelay: .milliseconds(50), unheard: { ["r1": "ivy"] },
                                       linkUp: { true }, outcome: { outcomes.append($1) }, roundOver: { rounds += 1 })
        #expect(outcomes == [.failed, .ended])
        #expect(rounds == 2)
        #expect(client.calls("session.activate").count == 2)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func noRetryOnceTheLinkIsDown() async {
        let client = FakeGatewayClient()
        client.onCall { method, _ in throw RPCError.timedOut(method, after: .seconds(30)) }
        var up = true
        var rounds = 0
        await UnheardTurns.reattachAll(client: client, retryDelay: .milliseconds(50), unheard: { ["r1": ""] },
                                       linkUp: { up }, outcome: { _, _ in up = false }, roundOver: { rounds += 1 })
        #expect(rounds == 1)
        #expect(client.calls("session.activate").count == 1, "the link went down before the retry")
    }

    /// A turn that ended in the first round is shown then, while another still waits on its retry (R17).
    @Test func aRoundsEndsShowBeforeTheRetries() async {
        let client = FakeGatewayClient()
        client.onCall { method, params in
            if params["session_id"]?.string == "b" { throw RPCError.timedOut(method, after: .seconds(30)) }
            return ["running": false]
        }
        var events: [String] = []
        let task = Task { @MainActor in
            await UnheardTurns.reattachAll(client: client, retryDelay: .seconds(10), unheard: { ["a": "", "b": ""] },
                                           linkUp: { true }, outcome: { events.append("\($0) \($1)") },
                                           roundOver: { events.append("round") })
        }
        #expect(await waitUntil { events.contains("round") })
        #expect(events.contains("a ended") && events.last == "round")
        task.cancel()
        await task.value
        #expect(client.calls("session.activate").count == 2, "the retry of b was cancelled")
    }
}
