// [m9/composer] Queue Paused / Resume, the empty-field Return and the model list's two tries against a scripted
// gateway (docs/spec/3x-composer.md §1.6, §12.4, §16.3).

import Foundation
import Testing
@testable import HermesHQNative

@MainActor @Suite("Composer · queue pause, Resume and the empty Return", .serialized)
struct ComposerQueueTests {
    /// A chat with a reply running and "second", "third" queued behind it.
    private func busyWithTwoQueued() async throws -> (ChatHarness, LiveChatSession) {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.queueDrainFallback = .milliseconds(30)
        #expect(await h.open())
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.interrupt": return ["status": "interrupted"]
            default: return [:]
            }
        }
        s.send("first")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Long answer"])])
        // A gateway that can't add to a running reply: messages typed now wait in the queue (TypedSteerTests covers
        // the one that can).
        s.redirectUnsupported = true
        s.send("second")
        s.send("third")
        return (h, s)
    }

    private func endTurn(_ h: ChatHarness, interrupted: Bool) async {
        await h.emit([h.event("message.complete", ["text": "Long answer", "status": interrupted ? "interrupted" : "complete"]),
                      h.event("session.info", ["running": false])])
    }

    @Test func stopPausesAndResumeSendsInOrder() async throws {
        let (h, s) = try await busyWithTwoQueued()
        #expect(QueueWords.header(count: s.queuedMessages.count, paused: s.isQueueParked, running: s.isRunning)
                == "2 Queued · Send After This Reply")
        s.stop()
        #expect(s.isQueueParked)
        await endTurn(h, interrupted: true)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(h.client.calls("prompt.submit").count == 1, "paused: nothing went out")
        #expect(QueueWords.header(count: s.queuedMessages.count, paused: s.isQueueParked, running: s.isRunning) == "Queue Paused · 2 Messages")
        #expect(QueueWords.showsResume(count: s.queuedMessages.count, paused: s.isQueueParked))

        s.resumeQueue()
        #expect(!s.isQueueParked)
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        #expect(h.client.calls("prompt.submit").last?.params["text"] == "second", "the oldest goes first")
        #expect(s.queuedMessages.map(\.text) == ["third"])
        // The second waits for the first one's reply.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.client.calls("prompt.submit").count == 2)
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "ok"])])
        await endTurn(h, interrupted: false)
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 3 })
        #expect(h.client.calls("prompt.submit").last?.params["text"] == "third")
        #expect(s.queuedMessages.isEmpty)
    }

    @Test func resumeDoesNothingWhenNotPausedAndTwiceIsOnce() async throws {
        let (h, s) = try await busyWithTwoQueued()
        s.resumeQueue()                                    // not paused: nothing
        #expect(h.client.calls("prompt.submit").count == 1)
        #expect(s.queuedMessages.count == 2)
        s.stop()
        await endTurn(h, interrupted: true)
        s.resumeQueue(); s.resumeQueue(); s.resumeQueue()  // a triple tap
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(h.client.calls("prompt.submit").count == 2, "one message per Resume, the rest wait for its reply")
        #expect(s.queuedMessages.map(\.text) == ["third"])
    }

    @Test func resumeWhileAReplyRunsWaitsForItsEnd() async throws {
        let (h, s) = try await busyWithTwoQueued()
        s.stop()
        #expect(s.isQueueParked)
        // Still unwinding (no message.complete yet): Resume un-pauses but sends nothing until the reply ends.
        s.resumeQueue()
        #expect(!s.isQueueParked)
        #expect(h.client.calls("prompt.submit").count == 1)
        await endTurn(h, interrupted: true)
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        #expect(h.client.calls("prompt.submit").last?.params["text"] == "second")
    }

    @Test func theEmptyReturnNeverDrainsAPausedQueue() async throws {
        let (h, s) = try await busyWithTwoQueued()
        #expect(!s.sendNextQueued(), "a reply is running: that is Send Now's case, not this one")
        s.stop()
        await endTurn(h, interrupted: true)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!s.sendNextQueued(), "paused: Return does nothing, it needs Resume")
        #expect(h.client.calls("prompt.submit").count == 1)
        #expect(s.queuedMessages.count == 2)
    }

    @Test func theEmptyReturnSendsTheNextWhenIdleAndNotPaused() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming"] : [:] }
        // An idle chat holding a waiting, un-paused queue (as after a drain that was held back).
        s.adoptStashedQueue([QueuedMessage(id: "q1", text: "next"), QueuedMessage(id: "q2", text: "later")], parked: false)
        #expect(s.sendNextQueued())
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 1 })
        #expect(h.client.calls("prompt.submit").last?.params["text"] == "next")
        #expect(s.queuedMessages.map(\.text) == ["later"])
        #expect(!s.sendNextQueued(), "its reply is running now")
        #expect(h.client.calls("prompt.submit").count == 1)
    }
}

@MainActor @Suite("Composer · the model list is tried twice", .serialized)
struct ComposerModelLoadTests {
    private func chatWithoutCatalog() -> MenusFixtureChat {
        let f = MenusFixtureChat()
        ModelCatalogCache.shared.forget(account: f.session.account.id)
        return f
    }

    @Test func oneFailureIsNeverSeen() async throws {
        let f = chatWithoutCatalog()
        f.script.on("model.options") { _, attempt in
            if attempt == 1 { throw RPCError(code: 5033, message: "model inventory failed", data: nil) }
            return MenusFixtureChat.options
        }
        let rows = try await f.context.load()
        #expect(!rows.isEmpty)
        #expect(f.client.calls("model.options").count == 2)
        #expect(!f.context.loadFailed)
    }

    @Test func twoFailuresShowAndNoThirdCallIsMade() async {
        let f = chatWithoutCatalog()
        f.script.on("model.options") { _, _ in throw RPCError(code: 5033, message: "model inventory failed", data: nil) }
        do {
            _ = try await f.context.load()
            Issue.record("the load should have failed")
        } catch {
            #expect(ModelLoad.words(for: error, offline: false) == "model inventory failed")
        }
        #expect(f.client.calls("model.options").count == 2, "exactly two tries")
        #expect(f.context.loadFailed)
        // Try Again runs the two-try load again and clears the failure when it works.
        f.script.on("model.options") { _, _ in MenusFixtureChat.options }
        _ = try? await f.context.load(refresh: true)
        #expect(f.client.calls("model.options").count == 3)
        #expect(!f.context.loadFailed)
    }

    @Test func aRefusedShapeOrAnOldGatewayIsAskedOnce() async {
        for code in [4000, -32601] {
            let f = chatWithoutCatalog()
            f.script.on("model.options") { _, _ in throw RPCError(code: code, message: "no", data: nil) }
            _ = try? await f.context.load()
            #expect(f.client.calls("model.options").count == 1, "code \(code)")
        }
    }

    @Test func offlineIsNeverAsked() async {
        let f = chatWithoutCatalog()
        f.session.connection = .offline(reason: "x")
        do {
            _ = try await f.context.load()
            Issue.record("offline with nothing cached should throw")
        } catch {
            #expect(ModelLoad.words(for: error, offline: true) == "You’re offline.")
        }
        #expect(f.client.calls("model.options").isEmpty)
    }

    @Test func aFailedRefreshKeepsTheRowsItHad() async {
        let f = MenusFixtureChat()                       // the catalog is cached
        f.script.on("model.options") { _, _ in throw RPCError(code: 5033, message: "down", data: nil) }
        _ = try? await f.context.load(refresh: true)
        #expect(!f.context.models().isEmpty)
        #expect(!f.context.loadFailed, "with rows on show the menu does not call it a failure")
    }
}
