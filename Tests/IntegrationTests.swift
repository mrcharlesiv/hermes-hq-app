import Foundation
import Testing
@testable import HermesHQNative

/// The integration layer's own pieces: the sign-in driver's error mapping, the chat warmer's choice of tails, and the
/// live fold's scoping of tool ids to the running turn.
@Suite("Integration")
@MainActor
struct IntegrationTests {
    // MARK: Sign-in driver

    @Test func signInErrorsCarryTheStableCodeAndPlainWords() {
        let offline = SignInServiceDriver.signInError(GatewayFailure.offline)
        #expect(offline.code == "network")
        #expect(offline.detail == GatewayFailure.offline.message)
        // A code the form has no words for says the Net module's own words…
        #expect(SignInCopy.message(for: offline) == GatewayFailure.offline.message)
        // …one it knows keeps the form's (address-specific) copy.
        let rejected = SignInServiceDriver.signInError(GatewayFailure.authRejected)
        #expect(rejected.code == "auth-rejected")
        #expect(SignInCopy.message(for: rejected) == SignInCopy.messages["auth-rejected"])
        #expect(SignInCopy.marksPassword(SignInCopy.code(for: rejected)))
        // A cancelled sheet says nothing.
        #expect(SignInCopy.message(for: SignInServiceDriver.signInError(GatewayFailure.nousCancelled)) == "")
        // Transport errors map through GatewayFailure.
        #expect(SignInServiceDriver.signInError(URLError(.cannotConnectToHost)).code == "unreachable")
    }

    // MARK: Chat warmer (spec 03 §4.1)

    @Test func warmerPicksMissingAndStaleTailsNewestFirst() {
        let client = FakeGatewayClient()
        let cache = makeTempCache()
        let warmer = ChatWarmer(client: client, account: client.account, cache: cache)
        let now = Date()
        func bot(_ id: String, chat: String?, active: Date?, hidden: Bool = false) -> Bot {
            Bot(id: id, name: id.capitalized, role: nil, preview: nil, lastActive: active, isWorking: false, unread: false,
                pinned: false, pinOrder: nil, sectionName: nil, hidden: hidden, canonicalSessionId: chat, head: nil)
        }
        let message = ChatMessage(id: "stored-row-1-assistant", role: .assistant, parts: [.text("hi")], timestamp: now, rowId: 1)
        cache.save([message], meta: [:], account: client.account.id, profile: "fresh", storedId: "s-fresh", savedAt: now)
        cache.save([message], meta: [:], account: client.account.id, profile: "stale", storedId: "s-stale",
                   savedAt: now.addingTimeInterval(-60))
        let bots = [
            bot("fresh", chat: "s-fresh", active: now.addingTimeInterval(-30)),        // saved after its last activity
            bot("stale", chat: "s-stale", active: now.addingTimeInterval(-10)),        // saved 50 s before it
            bot("never", chat: "s-never", active: now.addingTimeInterval(-5)),         // never saved
            bot("nochat", chat: nil, active: now),                                    // no Bot Chat yet
            bot("hidden", chat: "s-hidden", active: now, hidden: true),
            bot("open", chat: "s-open", active: now),
        ]
        warmer.isOpen = { $0 == "open" }
        #expect(warmer.staleBots(bots).map(\.id) == ["never", "stale"])
    }

    /// Verification round 2: on a slow link the full roster lands while the first pass still reads. That must not cancel
    /// the pass (which then pushed the next one ~30 s out); the pass carries on with the newer roster.
    @Test func aRosterChangeDuringAPassNeverCancelsIt() async throws {
        let client = FakeGatewayClient()
        let cache = makeTempCache()
        client.onRest { path, _ in
            usleep(250_000)                                       // a slow link: every read takes 250 ms
            let sid = path.split(separator: "/").dropLast().last.map(String.init) ?? "?"
            let row: JSONValue = ["role": "assistant", "content": .string("hello \(sid)"), "row_id": 7, "timestamp": 1791590000]
            return encodeJSON(["messages": [row], "pagination": ["limit": 24, "offset": 0, "order": "latest", "returned": 1]])
        }
        let warmer = ChatWarmer(client: client, account: client.account, cache: cache, settle: .milliseconds(20))
        let now = Date()
        func bot(_ id: String, active: Date) -> Bot {
            Bot(id: id, name: id, role: nil, preview: nil, lastActive: active, isWorking: false, unread: false, pinned: false,
                pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: "s-\(id)", head: nil)
        }
        // The slim roster names one bot; the full one, landing mid-read, adds a newer one.
        warmer.rosterChanged([bot("a", active: now.addingTimeInterval(-20))])
        #expect(await waitUntil { !client.restLog.isEmpty })
        warmer.rosterChanged([bot("a", active: now.addingTimeInterval(-20)), bot("b", active: now.addingTimeInterval(-5))])
        let both = await waitUntil(timeout: .seconds(3)) {
            cache.savedAt(account: client.account.id, profile: "a", storedId: "s-a") != nil
                && cache.savedAt(account: client.account.id, profile: "b", storedId: "s-b") != nil
        }
        #expect(both)
        warmer.stop()
    }

    /// The slim roster names no chats (no `canonical_session` yet): its pass reads nothing and must not hold the full
    /// roster's pass back by the 30 s gap.
    @Test func aPassWithNothingToReadDoesNotDelayTheNext() async throws {
        let client = FakeGatewayClient()
        let cache = makeTempCache()
        client.onRest { path, _ in
            let row: JSONValue = ["role": "assistant", "content": "hello", "row_id": 7, "timestamp": 1791590000]
            return encodeJSON(["messages": [row], "pagination": ["limit": 24, "offset": 0, "order": "latest", "returned": 1]])
        }
        let warmer = ChatWarmer(client: client, account: client.account, cache: cache, settle: .milliseconds(20))
        func bot(_ chat: String?) -> Bot {
            Bot(id: "a", name: "A", role: nil, preview: nil, lastActive: Date(), isWorking: false, unread: false, pinned: false,
                pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: chat, head: nil)
        }
        warmer.rosterChanged([bot(nil)])                          // slim: no chat to read
        try await Task.sleep(for: .milliseconds(150))
        warmer.rosterChanged([bot("s-a")])                        // full: the chat is known
        #expect(await waitUntil(timeout: .seconds(2)) { cache.savedAt(account: client.account.id, profile: "a", storedId: "s-a") != nil })
        warmer.stop()
    }

    /// [13-15] A gateway whose clock runs an hour ahead of the phone: a chat the warmer has read is not stale again
    /// until its activity moves (it was read on every pass).
    @Test func aChatJustReadIsNotStaleAgainWhenTheGatewaysClockRunsAhead() async throws {
        let client = FakeGatewayClient()
        let cache = makeTempCache()
        client.onRest { _, _ in
            let row: JSONValue = ["role": "assistant", "content": "hello", "row_id": 7, "timestamp": 1791590000]
            return encodeJSON(["messages": [row], "pagination": ["limit": 24, "offset": 0, "order": "latest", "returned": 1]])
        }
        let warmer = ChatWarmer(client: client, account: client.account, cache: cache, settle: .milliseconds(20))
        let ahead = Date().addingTimeInterval(3600)
        func bot(_ active: Date) -> Bot {
            Bot(id: "a", name: "A", role: nil, preview: nil, lastActive: active, isWorking: false, unread: false, pinned: false,
                pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: "s-a", head: nil)
        }
        warmer.rosterChanged([bot(ahead)])
        #expect(await waitUntil(timeout: .seconds(2)) { cache.savedAt(account: client.account.id, profile: "a", storedId: "s-a") != nil })
        try await Task.sleep(for: .milliseconds(50))
        #expect(warmer.staleTargets([bot(ahead)]).isEmpty, "read at this activity: fresh")
        #expect(warmer.staleTargets([bot(ahead.addingTimeInterval(5))]).count == 1, "a newer activity is stale again")
        warmer.stop()
    }

    /// [perf] The staleness check reads saved tails' headers only: checking more chats than the memory LRU holds
    /// leaves memory as it was (it used to decode each one and evict the tails the owner opens).
    @Test func checkingStalenessLeavesTheMemoryCacheAlone() {
        let client = FakeGatewayClient()
        let seed = makeTempCache()
        let now = Date()
        let message = ChatMessage(id: "stored-row-1-assistant", role: .assistant, parts: [.text("hi")], timestamp: now, rowId: 1)
        for i in 0..<12 { seed.save([message], meta: [:], account: client.account.id, profile: "b\(i)", storedId: "s\(i)", savedAt: now) }
        seed.flush()
        let cache = TranscriptCache(root: seed.root)
        let warmer = ChatWarmer(client: client, account: client.account, cache: cache)
        let bots = (0..<12).map { i in
            Bot(id: "b\(i)", name: "B\(i)", role: nil, preview: nil, lastActive: now.addingTimeInterval(i < 3 ? 60 : -60), isWorking: false,
                unread: false, pinned: false, pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: "s\(i)", head: nil)
        }
        #expect(Set(warmer.staleTargets(bots).map(\.target.profile)) == ["b0", "b1", "b2"])
        #expect(cache.memoryCount == 0)
    }

    /// [perf] A pass that hit its limit with stale chats left plans the next one itself (the roster no longer notifies
    /// on every poll); a pass whose reads all failed does not.
    @Test func aPassThatLeftStaleChatsPlansAnother() async throws {
        let client = FakeGatewayClient()
        let cache = makeTempCache()
        client.onRest { _, _ in
            let row: JSONValue = ["role": "assistant", "content": "hello", "row_id": 7, "timestamp": 1791590000]
            return encodeJSON(["messages": [row], "pagination": ["limit": 24, "offset": 0, "order": "latest", "returned": 1]])
        }
        let warmer = ChatWarmer(client: client, account: client.account, cache: cache, settle: .milliseconds(20),
                                minimumGap: .milliseconds(50))
        let now = Date()
        let bots = (0..<10).map { i in
            Bot(id: "b\(i)", name: "B\(i)", role: nil, preview: nil, lastActive: now.addingTimeInterval(-Double(i)), isWorking: false,
                unread: false, pinned: false, pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: "s\(i)", head: nil)
        }
        warmer.rosterChanged(bots)                                // one roster change only
        let all = await waitUntil(timeout: .seconds(3)) {
            (0..<10).allSatisfy { cache.savedAt(account: client.account.id, profile: "b\($0)", storedId: "s\($0)") != nil }
        }
        #expect(all, "the first pass reads 8, the next one the other 2")
        warmer.stop()

        let failingClient = FakeGatewayClient()
        failingClient.onRest { _, _ in throw HTTPError(status: 500, body: nil) }
        let idle = ChatWarmer(client: failingClient, account: failingClient.account, cache: makeTempCache(), settle: .milliseconds(20),
                              minimumGap: .milliseconds(50))
        idle.rosterChanged(bots)
        #expect(await waitUntil(timeout: .seconds(2)) { failingClient.restLog.count >= 8 })
        try await Task.sleep(for: .milliseconds(300))
        let afterPass = failingClient.restLog.count
        try await Task.sleep(for: .milliseconds(400))
        #expect(failingClient.restLog.count == afterPass, "nothing read: no pass planned after it")
        idle.stop()
    }

    /// [perf] Chats that read back empty (new bots) are not stale forever: once each was read, the warmer stops
    /// instead of reading the same four every `minimumGap`; one is read again when its activity moves.
    @Test func chatsThatReadEmptyDoNotKeepPlanningPasses() async throws {
        let client = FakeGatewayClient()
        client.onRest { _, _ in
            encodeJSON(["messages": [], "pagination": ["limit": 24, "offset": 0, "order": "latest", "returned": 0]])
        }
        let warmer = ChatWarmer(client: client, account: client.account, cache: makeTempCache(), settle: .milliseconds(20),
                                minimumGap: .milliseconds(50))
        let now = Date()
        func bots(_ firstActive: Date) -> [Bot] {
            (0..<10).map { i in
                Bot(id: "b\(i)", name: "B\(i)", role: nil, preview: nil, lastActive: i == 0 ? firstActive : now.addingTimeInterval(-Double(i)),
                    isWorking: false, unread: false, pinned: false, pinOrder: nil, sectionName: nil, hidden: false,
                    canonicalSessionId: "s\(i)", head: nil)
            }
        }
        warmer.rosterChanged(bots(now))
        #expect(await waitUntil(timeout: .seconds(2)) { client.restLog.count >= 10 }, "the first pass reads 8, the next one the other 2")
        try await Task.sleep(for: .milliseconds(300))
        let settled = client.restLog.count
        try await Task.sleep(for: .milliseconds(400))
        #expect(client.restLog.count == settled && settled == 10, "no pass re-reads the empty chats")
        warmer.rosterChanged(bots(now.addingTimeInterval(5)))     // b0 has new activity
        #expect(await waitUntil(timeout: .seconds(1)) { client.restLog.count == 11 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(client.restLog.count == 11)
        warmer.stop()
    }

    /// [perf] A pass planned before the owner left is planned again on the return, even when the roster didn't change
    /// (an unchanged roster no longer notifies on the return's read).
    @Test func aPassCancelledByLeavingIsPlannedOnReturn() async throws {
        let client = FakeGatewayClient()
        let cache = makeTempCache()
        client.onRest { _, _ in
            let row: JSONValue = ["role": "assistant", "content": "hello", "row_id": 7, "timestamp": 1791590000]
            return encodeJSON(["messages": [row], "pagination": ["limit": 24, "offset": 0, "order": "latest", "returned": 1]])
        }
        let warmer = ChatWarmer(client: client, account: client.account, cache: cache, settle: .milliseconds(200))
        let bot = Bot(id: "a", name: "A", role: nil, preview: nil, lastActive: Date(), isWorking: false, unread: false, pinned: false,
                      pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: "s-a", head: nil)
        warmer.rosterChanged([bot])
        warmer.appActive = false                                  // left before the roster settled
        try await Task.sleep(for: .milliseconds(400))
        #expect(client.restLog.isEmpty)
        warmer.appActive = true                                   // back, with the roster unchanged
        #expect(await waitUntil(timeout: .seconds(2)) { cache.savedAt(account: client.account.id, profile: "a", storedId: "s-a") != nil })
        #expect(client.restLog.count == 1)
        warmer.stop()
    }

    // MARK: Live fold: tool ids are scoped to the running turn

    @Test func aToolIdAnEarlierTurnUsedStaysInThisTurn() async throws {
        let h = try ChatHarness()
        // History: an earlier reply that ran a tool with id "performance-tool-0".
        let rows: [JSONValue] = [
            ["role": "user", "content": "first", "row_id": 10, "timestamp": 1791590000],
            ["role": "assistant", "content": "", "row_id": 11, "timestamp": 1791590001,
             "tool_calls": [["id": "performance-tool-0", "type": "function", "function": ["name": "terminal", "arguments": "{\"command\":\"ls\"}"]]]],
            ["role": "tool", "content": "{\"stdout\":\"a\",\"exit_code\":0}", "tool_call_id": "performance-tool-0", "row_id": 12, "timestamp": 1791590002],
            ["role": "assistant", "content": "Done.", "row_id": 13, "timestamp": 1791590003],
        ]
        h.setPage("24", rows: rows)
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        let earlier = try #require(s.messages.last { $0.role == .assistant })
        let earlierTools = earlier.parts.filter { if case .tool = $0 { return true } else { return false } }.count
        h.client.onCall { method, _ in
            method == "prompt.submit" ? ["status": "streaming", "user_row_id": 14] : [:]
        }
        s.send("second")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Here "]),
                      h.event("tool.start", ["tool_id": "performance-tool-0", "name": "terminal", "args": ["command": "pwd"]]),
                      h.event("tool.complete", ["tool_id": "performance-tool-0", "name": "terminal",
                                                "result": ["stdout": "/fixture", "exit_code": 0]])])
        let live = try #require(h.assistant)
        #expect(live.id != earlier.id)
        let liveTools = live.parts.compactMap { if case .tool(let c) = $0 { return c } else { return nil } }
        #expect(liveTools.map(\.id) == ["performance-tool-0"])                 // the call shows in this turn's reply
        let after = try #require(s.messages.first { $0.id == earlier.id })
        #expect(after.parts.filter { if case .tool = $0 { return true } else { return false } }.count == earlierTools)
        #expect(after.parts == earlier.parts)                                  // the earlier reply is untouched
    }
}
