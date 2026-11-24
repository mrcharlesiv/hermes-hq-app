import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

/// [threads] §9: typed words a bot's own chat cannot take now go on in a thread instead of coming back.
@Suite("Threads: a busy chat's words go on in a thread (3x-threads §9)", .serialized)
@MainActor
struct ThreadBusySendTests {
    /// What the app model's hook was handed, and what it answers.
    private final class Taker {
        var took: [(text: String, localId: String)] = []
        var answer = true
    }

    private func chat(_ h: ChatHarness, _ taker: Taker) -> LiveChatSession {
        let s = h.make()
        s.threadAfter = .milliseconds(150)
        s.silenceTimeout = .milliseconds(50)       // the wait must not trip the silence watchdog
        s.onBusyThread = { text, localId in
            taker.took.append((text, localId))
            return taker.answer
        }
        return s
    }

    nonisolated private static func owned(_ method: String) -> JSONValue {
        method == "session.active_list" ? ["sessions": []] : [:]
    }

    @Test func wordsAnotherRunKeepsOutGoOnInAThread() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let taker = Taker()
        let s = chat(h, taker)
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw LiveChatSessionTests.ownedRefusal("cli") }
            return Self.owned(method)
        }
        s.send("What time is the flight?")
        #expect(await waitUntil { s.ownerWaitNotice == .backgroundTask })   // it waits for the chat first
        let bubble = h.lastUser?.id
        #expect(await waitUntil(timeout: .seconds(3)) { !taker.took.isEmpty })
        #expect(taker.took.count == 1)
        #expect(taker.took.first?.text == "What time is the flight?")
        #expect(taker.took.first?.localId == bubble, "the thread's seed leaves this bubble out")
        #expect(!s.messages.contains { $0.role == .user && $0.plainText == "What time is the flight?" })
        #expect(h.drafts.isEmpty, "nothing is handed back")
        #expect(s.sendFailure == nil, "no Couldn’t Send card")
        #expect(s.ownerWaitNotice == nil)
        #expect(!s.isRunning)
        #expect(h.notices == [ThreadRules.busyNotice])
    }

    @Test func busyPastItsWindowGoesOnInAThread() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let taker = Taker()
        let s = chat(h, taker)
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw RPCError(code: 4009, message: "session busy", data: nil) }
            return [:]
        }
        s.send("Are you there?")
        #expect(await waitUntil(timeout: .seconds(3)) { !taker.took.isEmpty })
        #expect(h.client.calls("prompt.submit").count >= 3, "the busy window is tried out first")
        #expect(taker.took.first?.text == "Are you there?")
        #expect(h.drafts.isEmpty)
        #expect(s.sendFailure == nil)
        #expect(!s.isRunning)
    }

    @Test func aChatThatLetsGoInTimeTakesTheWordsItself() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let taker = Taker()
        let s = chat(h, taker)
        s.threadAfter = .seconds(3)
        #expect(await h.open())
        let n = Mutex(0)
        h.client.onCall { method, _ in
            guard method == "prompt.submit" else { return Self.owned(method) }
            if n.withLock({ $0 += 1; return $0 }) <= 3 { throw LiveChatSessionTests.ownedRefusal("cli") }
            return ["status": "streaming", "user_row_id": 93]
        }
        let before = s.acceptedSends
        s.send("hi")
        #expect(await waitUntil(timeout: .seconds(3)) { h.lastUser?.rowId == 93 })
        #expect(taker.took.isEmpty)
        #expect(s.acceptedSends == before + 1)
        #expect(h.notices.isEmpty)
    }

    @Test func withNoThreadToTakeThemTheWordsComeBackAsBefore() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let taker = Taker()
        taker.answer = false
        let s = chat(h, taker)
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw LiveChatSessionTests.ownedRefusal("cli") }
            return Self.owned(method)
        }
        s.send("hi")
        #expect(await waitUntil(timeout: .seconds(3)) { !h.drafts.isEmpty })
        #expect(taker.took.count == 1)
        #expect(h.drafts.first?.0 == "hi")
        #expect(s.sendFailure != nil)
        #expect(h.notices.isEmpty)
    }

    @Test func stopWhileItWaitsStartsNoThread() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let taker = Taker()
        let s = chat(h, taker)
        s.threadAfter = .seconds(2)
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw LiveChatSessionTests.ownedRefusal("cli") }
            return Self.owned(method)
        }
        s.send("hi")
        #expect(await waitUntil { s.ownerWaitNotice == .backgroundTask })
        s.stop()
        #expect(await waitUntil(timeout: .seconds(3)) { !s.messages.contains { $0.role == .user && $0.plainText == "hi" } })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(taker.took.isEmpty)
    }

    /// A chat with no hook (Sessions, rooms, task chats) is unchanged: the long wait, then the words back.
    @Test func aChatWithNoThreadsWaitsAsBefore() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.threadAfter = .milliseconds(50)
        s.ownerWaitWindow = .milliseconds(600)
        s.silenceTimeout = .milliseconds(50)
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw LiveChatSessionTests.ownedRefusal("cli") }
            return Self.owned(method)
        }
        s.send("hi")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(h.drafts.isEmpty, "still waiting well past threadAfter")
        #expect(h.lastUser?.isPending == true)
        #expect(await waitUntil(timeout: .seconds(3)) { !h.drafts.isEmpty })
    }

    @Test func theSameThreadTakesTheNextWordsUntilTheChatTakesASend() {
        #expect(ThreadRules.takesNextBusySend(heldAt: 4, accepted: 4, live: true, problem: false))
        #expect(!ThreadRules.takesNextBusySend(heldAt: 4, accepted: 5, live: true, problem: false), "the chat took a send since")
        #expect(!ThreadRules.takesNextBusySend(heldAt: 4, accepted: 4, live: false, problem: false))
        #expect(!ThreadRules.takesNextBusySend(heldAt: 4, accepted: 4, live: true, problem: true))
        #expect(!ThreadRules.takesNextBusySend(heldAt: nil, accepted: 0, live: true, problem: false))
    }

    /// Found in the app's walk: hung by time, the thread sat above the bot's last answer and folded when it finished.
    @Test func itHangsUnderTheNewestThingSaidAndStaysOpen() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let asked = ChatMessage(id: "u1", role: .user, parts: [.text("Morning. Anything for me?")], timestamp: t0, rowId: 1)
        let said = ChatMessage(id: "a1", role: .assistant, parts: [.text("Nothing urgent today.")], timestamp: t0 + 5, rowId: 2)
        let bubble = ChatMessage(id: "local-9", role: .user, parts: [.text("What time is the flight?")], timestamp: t0 + 60)
        let anchor = ThreadRules.busyAnchor(in: [asked, said, bubble], leavingOut: "local-9")
        #expect(anchor?.id == "a1", "under the bot's last answer, not the bubble that leaves and not your older message")
        #expect(ThreadRules.busyAnchor(in: [bubble], leavingOut: "local-9") == nil)

        let reply = ChatMessage(id: "t2", role: .assistant, parts: [.text("The flight leaves at 9:40.")], timestamp: t0 + 70)
        let thread = ChatThread(id: "th", storedId: "s-thread", title: nil, startedAt: t0 + 66, anchorMessageId: anchor?.id,
                                anchorRow: anchor?.rowId, messages: [bubble, reply], running: false, problem: nil, scope: "x")
        let main = [asked, said]            // the bubble has left the main chat
        let index = ThreadRules.anchorIndex(of: thread, in: main)
        #expect(index == 1)
        #expect(ThreadRules.isOpen(thread, anchor: index ?? 0, in: main), "finished, it is still the newest thing: open")
        // Hung by time it would be under "Morning…", with the bot's answer after it: folded.
        var byTime = thread
        byTime.anchorMessageId = nil
        byTime.anchorRow = nil
        let old = ThreadRules.anchorIndex(of: byTime, in: main)
        #expect(old == 0)
        #expect(!ThreadRules.isOpen(byTime, anchor: old ?? 0, in: main))
    }

    @Test func aThreadsRefusedWordsComeBackToTheChatTheyWereTypedIn() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        s.threadSendCameBack("What time is the flight?", reason: "Hermes is at the active session limit (4/4).")
        #expect(h.drafts.first?.0 == "What time is the flight?")
        #expect(h.drafts.first?.1 == "Hermes is at the active session limit (4/4).")
        #expect(s.sendFailure != nil)
    }

    // MARK: Upgraded §9 behaviour (proactive routing, bursts, rich payloads, TTL, empty chat, reconciliation)

    @Test func proactiveRoutingSendsDirectlyToThreadWithZeroWaitAndNoMainBubble() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        var payloads: [BusyThreadPayload] = []
        s.shouldRouteToBusyThread = { true }
        s.onBusyThreadSend = { payload in
            payloads.append(payload)
            return true
        }
        #expect(await h.open())
        let beforeCount = s.messages.count
        s.send("Quick follow-up while busy")
        #expect(payloads.count == 1)
        #expect(payloads[0].text == "Quick follow-up while busy")
        #expect(payloads[0].proactive == true)
        #expect(payloads[0].localId == nil, "no main-chat bubble was ever added")
        #expect(s.messages.count == beforeCount)
        #expect(h.client.calls("prompt.submit").isEmpty, "zero gateway wait or round-trip on main chat")
        #expect(s.ownerWaitNotice == nil)
        #expect(s.sendFailure == nil)
    }

    @Test func burstMessageTypedDuringGraceWaitDrainsIntoSameThreadInsteadOfParking() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.threadAfter = .milliseconds(150)
        s.silenceTimeout = .milliseconds(50)
        var payloads: [BusyThreadPayload] = []
        s.onBusyThreadSend = { payload in
            payloads.append(payload)
            return true
        }
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw LiveChatSessionTests.ownedRefusal("cli") }
            return Self.owned(method)
        }
        s.send("First question")
        #expect(await waitUntil { s.ownerWaitNotice == .backgroundTask })
        // User types a second message while the first is still in its grace wait: queues behind turn.busy.
        s.send("Second question right after")
        #expect(s.queuedMessages.count == 1)
        #expect(await waitUntil(timeout: .seconds(3)) { payloads.count == 2 })
        #expect(payloads.map(\.text) == ["First question", "Second question right after"])
        #expect(s.queuedMessages.isEmpty, "burst message drained into thread instead of parking")
        #expect(!s.isQueueParked)
    }

    @Test func richPayloadWithDisplayNoteOrSkillsStillAutoThreads() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.threadAfter = .milliseconds(100)
        s.silenceTimeout = .milliseconds(50)
        var payloads: [BusyThreadPayload] = []
        s.onBusyThreadSend = { payload in
            payloads.append(payload)
            return true
        }
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw LiveChatSessionTests.ownedRefusal("cli") }
            return Self.owned(method)
        }
        // Simulates notesTypedSend (e.g. Phone Calls note) where display != wire text.
        s.send("Call mom\n\n[hidden phone note]", display: "Call mom")
        #expect(await waitUntil(timeout: .seconds(3)) { payloads.count == 1 })
        #expect(payloads[0].text == "Call mom\n\n[hidden phone note]")
        #expect(payloads[0].display == "Call mom")
        #expect(payloads[0].reason == .backgroundTask)
        #expect(s.sendFailure == nil)
    }

    @Test func stickyBusyThreadExpiresAfterTTLOrMainIdleAndSurvivesEviction() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        // Reachable via storedId even when live was trimmed: still continues.
        #expect(ThreadRules.takesNextBusySend(heldAt: 2, accepted: 2, reachable: true, problem: false,
                                              mainIdleSinceHold: false, lastActivity: t0, now: t0 + 300))
        // Past 15 min TTL: starts fresh instead of reviving an old unrelated thread.
        #expect(!ThreadRules.takesNextBusySend(heldAt: 2, accepted: 2, reachable: true, problem: false,
                                               mainIdleSinceHold: false, lastActivity: t0, now: t0 + ThreadRules.busyThreadTTL + 1))
        // Main chat went idle since hold: unlatches cleanly.
        #expect(!ThreadRules.takesNextBusySend(heldAt: 2, accepted: 2, reachable: true, problem: false,
                                               mainIdleSinceHold: true, lastActivity: t0, now: t0 + 10))
    }

    @Test func reconciliationContextNoteAppendsOnNextMainSendAndRestoresIfThreaded() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.threadAfter = .milliseconds(100)
        s.silenceTimeout = .milliseconds(50)
        var pendingNote: String? = ThreadContextNote.format(threads: [(
            title: "Flight",
            messages: [
                ChatMessage(id: "u1", role: .user, parts: [.text("Book the 9:40 flight")], timestamp: Date()),
                ChatMessage(id: "a1", role: .assistant, parts: [.text("Booked 9:40 AM on UA 412.")], timestamp: Date()),
            ]
        )])
        #expect(pendingNote != nil)
        s.consumeThreadContextNote = {
            defer { pendingNote = nil }
            return pendingNote
        }
        s.restoreThreadContextNote = { restored in pendingNote = restored }
        var threaded: [BusyThreadPayload] = []
        s.onBusyThreadSend = { payload in threaded.append(payload); return true }
        #expect(await h.open())

        // First send hits 4090 and threads: reconciliation note must be stripped from the side thread and restored!
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw LiveChatSessionTests.ownedRefusal("cli") }
            return Self.owned(method)
        }
        s.send("Also check hotels")
        #expect(await waitUntil(timeout: .seconds(3)) { threaded.count == 1 })
        #expect(threaded[0].text == "Also check hotels", "side thread does not receive main-chat reconciliation note")
        #expect(pendingNote != nil, "note restored for the next real main-chat send")

        // Main chat is now free: next send carries the note on the wire while SentTitles strips it for display.
        let submitted = Mutex<String?>(nil)
        h.client.onCall { method, params in
            if method == "prompt.submit" {
                submitted.withLock { $0 = params["text"]?.string }
                return ["status": "streaming", "user_row_id": 99]
            }
            return [:]
        }
        s.send("Summarize my trip")
        #expect(await waitUntil(timeout: .seconds(3)) { submitted.withLock { $0 != nil } })
        let wire = submitted.withLock { $0 } ?? ""
        #expect(wire.contains(ThreadContextNote.marker))
        #expect(wire.contains("Booked 9:40 AM on UA 412."))
        #expect(ThreadContextNote.stripped(wire) == "Summarize my trip")
        #expect(SentTitles().title(forStored: wire) == "Summarize my trip", "visible bubble stays clean on reload")
        #expect(pendingNote == nil, "consumed once accepted by main chat")
    }

    @Test func newFinishedReplyAndAvailabilityProbeSignalMainChatFreeAgain() async throws {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let u1 = ChatMessage(id: "u1", role: .user, parts: [.text("Morning")], timestamp: t0, rowId: 1)
        let a1 = ChatMessage(id: "a1", role: .assistant, parts: [.text("Hi")], timestamp: t0 + 1, rowId: 2)
        var streaming = ChatMessage(id: "a2", role: .assistant, parts: [.text("Working...")], timestamp: t0 + 5, rowId: 3)
        streaming.isStreaming = true
        let finished = ChatMessage(id: "a2", role: .assistant, parts: [.text("Job done.")], timestamp: t0 + 10, rowId: 3)
        #expect(!ThreadRules.hasNewFinishedReply(before: [u1, a1], after: [u1, a1]))
        #expect(!ThreadRules.hasNewFinishedReply(before: [u1, a1], after: [u1, a1, streaming]))
        #expect(ThreadRules.hasNewFinishedReply(before: [u1, a1], after: [u1, a1, finished]))
        #expect(ThreadRules.backInMainNotice(botName: "Research") == "Research is back in the main chat.")

        // `probeMainAvailability(checkServerRunning: true)` reports idle once resume + active_list say not running.
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        let busy = Mutex(true)
        h.client.onCall { method, _ in
            if method == "session.resume" {
                return ["session_id": "rt-1", "running": .bool(busy.withLock { $0 })]
            }
            if method == "session.active_list" { return ["sessions": []] }
            return [:]
        }
        #expect(await s.probeMainAvailability(checkServerRunning: true) == false)
        busy.withLock { $0 = false }
        #expect(await s.probeMainAvailability(checkServerRunning: true) == true)
    }
}
