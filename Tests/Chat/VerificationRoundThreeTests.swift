import Foundation
import Synchronization
import Testing
import UIKit
@testable import HermesHQNative

/// Verification round 3: how far a chat was seen when it is left (unread baselines), a first history read that
/// stalls, the error card's Retry, an edit step's empty output, "Sending…", and the roster row patched from a chat.
@Suite("Verification round 3", .serialized)
@MainActor
struct VerificationRoundThreeTests {
    private static let stored = "20260929_120000_aabbcc01"

    private func harness(_ backend: RowBackend) throws -> ChatHarness {
        let h = try ChatHarness()
        let stored = h.stored
        h.client.onRest { _, query in backend.answer(stored: stored, query: query) }
        return h
    }

    /// One plain turn sent from this phone: the prompt, a reply streamed live, Hermes storing both rows (`at`, `at + 50`).
    private func runTurn(_ h: ChatHarness, backend: RowBackend, prompt: String, reply: String, at ts: Double) async throws {
        let s = h.session!
        let firstRow = (backend.rows.withLock { $0.last.flatMap(HistoryPage.rowId) } ?? 0) + 1
        let resume = try ChatFixtures.json("perf-resume.json")["result"] ?? .null
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming", "user_row_id": .number(Double(firstRow))]
            case "session.resume", "session.activate": return resume
            case "session.active_list": return ["sessions": []]
            default: return [:]
            }
        }
        s.send(prompt)
        #expect(await waitUntil { h.lastUser?.isPending == false })
        backend.append([
            ["role": "user", "content": .string(prompt), "row_id": .number(Double(firstRow)), "timestamp": .number(ts)],
            ["role": "assistant", "content": .string(reply), "row_id": .number(Double(firstRow + 1)), "timestamp": .number(ts + 50)],
        ])
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": .string(reply)]),
                      h.event("message.complete", ["text": .string(reply), "status": "complete",
                                                   "persisted_turn": ["user_row_id": .number(Double(firstRow)),
                                                                      "final_assistant_row_id": .number(Double(firstRow + 1))]])])
    }

    // MARK: Unread after your own exchange (protocol, major)

    /// Leaving after a turn sent here reported the previous turn's time (the live rows keep their local ids, and a folded
    /// turn carries its first row's time), so the next roster lit the dot for the user's own exchange.
    @Test func seenThroughCoversYourOwnTurnsLastStoredRow() async throws {
        let backend = RowBackend()
        backend.set(RowBackend.chat(2))                                      // rows 1…4, stamped 1791500001…4
        let h = try harness(backend)
        let s = h.make()
        #expect(await h.open())
        #expect(s.seenThrough?.timeIntervalSince1970 == 1791500004)
        try await runTurn(h, backend: backend, prompt: "Third short", reply: "Done.", at: 1791600000)
        #expect(await waitUntil(timeout: .seconds(5)) { s.lastTurnEndReadAt != nil && s.refreshTask == nil })
        // The displayed rows still carry local ids…
        #expect(s.messages.suffix(2).filter { !$0.isLocal }.isEmpty)
        // …but the reader has seen the turn's end.
        #expect(s.seenThrough?.timeIntervalSince1970 == 1791600050)
    }

    /// Back right after the reply, before its 1.2 s end read: the read still lands, and reports what was seen.
    @Test func leavingBeforeTheTurnEndReadReportsItLater() async throws {
        let backend = RowBackend()
        backend.set(RowBackend.chat(2))
        let h = try harness(backend)
        let s = h.make()
        s.turnEndReadDelay = .milliseconds(300)
        var late: [Date] = []
        s.onSeenAfterLeaving = { late.append($0) }
        #expect(await h.open())
        try await runTurn(h, backend: backend, prompt: "Quick one", reply: "Sure.", at: 1791700000)
        #expect(s.turnEndTask != nil)
        s.stopObserving()
        #expect(s.seenThrough?.timeIntervalSince1970 == 1791500004)          // what the screen knew when it went
        #expect(await waitUntil(timeout: .seconds(5)) { !late.isEmpty })
        #expect(late.first?.timeIntervalSince1970 == 1791700050)
    }

    /// The store side: a roster read on return marked the bot; the late report clears that dot (same activity), and
    /// later activity keeps it.
    @Test func aLateSeenReportClearsTheDotForTheSameActivity() async throws {
        let stamp = BotsTestBox(1_791_000_000.0)
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in
            BotsTest.profilesResult([BotsTest.row("ivy", canonical: BotsTest.session("reg", resolved: "tip", lastActive: stamp.value))])
        }
        let store = BotStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast,
                             autoStart: true)
        #expect(await BotsTest.waitUntil { store.phase == .full })
        store.setFocusedChat(profile: "ivy", sessionId: "tip")
        stamp.value = 1_791_000_100                                           // the user's own exchange
        store.setFocusedChat(profile: nil, sessionId: nil, seenThrough: Date(timeIntervalSince1970: 1_791_000_050))
        await store.refresh()
        #expect(store.bot(named: "ivy")?.unread == true)                      // the end read hadn't landed yet
        store.noteSeenAfterLeaving(profile: "ivy", sessionId: "tip", seenThrough: Date(timeIntervalSince1970: 1_791_000_099.5))
        #expect(store.bot(named: "ivy")?.unread == false)
        stamp.value = 1_791_000_300                                           // a later reply
        await store.refresh()
        #expect(store.bot(named: "ivy")?.unread == true)
        store.noteSeenAfterLeaving(profile: "ivy", sessionId: "tip", seenThrough: Date(timeIntervalSince1970: 1_791_000_099.5))
        #expect(store.bot(named: "ivy")?.unread == true)
        store.stop()
    }

    // MARK: A first open that stalls (looks, major)

    /// The REST read failed but the resume answered: the open is not "no messages yet" — the history is read again and
    /// shows when it lands.
    @Test func aStalledFirstReadIsReadAgainNotShownAsEmpty() async throws {
        let backend = RowBackend()
        backend.set(RowBackend.chat(1))
        let failing = Mutex(true)
        let h = try ChatHarness()
        let stored = h.stored
        h.client.onRest { _, query in
            if failing.withLock({ $0 }) { throw HTTPError(status: 503, body: "stalled") }
            return backend.answer(stored: stored, query: query)
        }
        let s = h.make()
        s.firstPageRetryDelays = [.milliseconds(100), .milliseconds(100), .milliseconds(100)]
        var settled: [Bool] = []
        s.onOpenSettled = { settled.append($0) }
        #expect(await h.open())
        #expect(s.messages.isEmpty)
        #expect(s.openPhase == .opening)                                     // the skeleton stays; never the intro
        #expect(settled == [false])
        failing.withLock { $0 = false }
        #expect(await waitUntil(timeout: .seconds(3)) { !s.messages.isEmpty })
        #expect(s.openPhase == .open)
        #expect(s.messages.map(\.plainText) == ["question 0", "answer 0"])
        #expect(settled == [false, true])                                    // fresh history: the bot can be read now
        #expect(!s.firstPageOwed)
    }

    @Test func aFirstReadThatNeverLandsShowsTheFailure() async throws {
        let h = try ChatHarness()
        h.client.onRest { _, _ in throw HTTPError(status: 503, body: "down") }
        let s = h.make()
        s.firstPageRetryDelays = [.milliseconds(50), .milliseconds(50), .milliseconds(50)]
        #expect(await h.open())
        #expect(s.openPhase == .opening)
        #expect(await waitUntil(timeout: .seconds(3)) { s.openPhase != .opening })
        #expect(s.openPhase == .failed("Couldn't load this chat."))
    }

    // MARK: Error card Retry (looks, major)

    private let now = Date(timeIntervalSince1970: 1_791_600_000)

    private func turn(error: String, running: Bool = false) -> ChatRowBuilder.Input {
        let prompt = ChatMessage(id: "u", role: .user, parts: [.text("Summarise the log")], timestamp: now, rowId: 1)
        var reply = ChatMessage(id: "a", role: .assistant, parts: [.text("Partial")], timestamp: now, rowId: 2)
        reply.error = error
        return .init(messages: [prompt, reply], isRunning: running, botName: "Ivy", expanded: [], now: now, scope: "s")
    }

    private func errorRow(_ input: ChatRowBuilder.Input) -> ErrorRow? {
        for row in ChatRowBuilder.build(input) { if case .error(let e) = row.kind { return e } }
        return nil
    }

    // A failure the app has no words for ("overloaded" became the provider card's, n20 revisit): the card's own Retry.
    @Test func theNewestFailedTurnOffersRetryAsItsPrimary() throws {
        let input = turn(error: "the tool runner went away")
        let e = try #require(errorRow(input))
        #expect(e.retry)
        #expect(e.reason == "the tool runner went away")
        #expect(ChatRowBuilder.retryPrompt(forErrorAt: 1, input: input) == "Summarise the log")
        // While a turn runs, or once a newer message follows, no Retry.
        #expect(errorRow(turn(error: "the tool runner went away", running: true))?.retry == false)
        var later = input
        later.messages.append(ChatMessage(id: "u2", role: .user, parts: [.text("next")], timestamp: now, rowId: 3))
        #expect(errorRow(later)?.retry == false)
        // A refused send's card follows the previous reply (its words went back to the field): no Retry.
        var refused = ChatMessage(id: "local-error-1", role: .assistant, parts: [], timestamp: now, rowId: nil)
        refused.error = "Busy"
        var afterReply = turn(error: "x")
        afterReply.messages[1].error = nil
        afterReply.messages.append(refused)
        #expect(errorRow(afterReply)?.retry == false)
    }

    @Test func retryWordingFollowsTheButton() {
        #expect(ChatRowBuilder.errorReason("", retry: true) == "Hermes ended this turn without a reply. Tap Try Again to send it again.")
        #expect(ChatRowBuilder.errorReason("", retry: false) == "Hermes ended this turn without a reply.")
        #expect(ChatRowBuilder.errorReason("Hermes ended this turn without a reply.", retry: true).hasSuffix("Tap Try Again to send it again."))
        #expect(ChatRowBuilder.errorReason(String(repeating: "x", count: 200), retry: true)
                == "Something went wrong while Hermes was replying. Try again, or copy the details if it keeps happening.")
        // Another bot's card names that bot, even for the gateway's own "Hermes ended…" sentence.
        #expect(ChatRowBuilder.errorReason("Hermes ended this turn without a reply.", retry: false, bot: "Ivy")
                == "Ivy ended this turn without a reply.")
        #expect(ChatRowBuilder.errorReason(String(repeating: "x", count: 200), bot: "Ivy")
                == "Something went wrong while Ivy was replying. Copy the details if it keeps happening.")
    }

    @Test func theCardLaysOutRetryBesideDetails() throws {
        let style = ChatStyle.make(category: .large)
        let rows = ChatRowBuilder.build(turn(error: "the tool runner went away"))
        let row = try #require(rows.first { $0.id.hasSuffix("|err") })
        guard case .error(let e) = TextLayout.make(row, width: 402, style: style).content else { Issue.record("not an error layout"); return }
        let retry = try #require(e.retryFrame)
        #expect(retry.height == 44 && e.detailsFrame.height == 44)
        // [ui-sizing 2026-11-09] Side by side, Retry first, 8 pt apart, when each has room (a column at large sizes).
        #expect(abs(e.detailsFrame.minY - retry.minY) < 0.5 && abs(e.detailsFrame.minX - retry.maxX - 8) < 0.5)
        #expect(retry.minY > e.reasonFrame.maxY)
        #expect(e.cardFrame.height >= e.detailsFrame.maxY)
        // Without Retry: Details alone.
        let quiet = try #require(ChatRowBuilder.build(turn(error: "the tool runner went away", running: true)).first { $0.id.hasSuffix("|err") })
        guard case .error(let q) = TextLayout.make(quiet, width: 402, style: style).content else { return }
        #expect(q.retryFrame == nil)
    }

    // MARK: Step sheet output (looks, minor)

    @Test func anEditWithOnlyItsDiffHasNoEmptyOutput() {
        let result: JSONValue = ["path": "release-notes.md", "inline_diff": "@@ -1 +1 @@\n-old\n+new"]
        let d = ToolPresentation.detail(args: ["path": "release-notes.md"], argsText: "{\"path\":\"release-notes.md\"}",
                                        result: result, isError: false, inlineDiff: nil, payloadRef: nil)
        #expect(d.detail == nil)
        #expect(d.inlineDiff?.contains("+new") == true)
        let call = ToolCall(id: "e", name: "patch", title: "Edited release-notes.md", argsText: "{\"path\":\"release-notes.md\"}",
                            summary: nil, state: .done, durationSeconds: nil)
        var cached = d
        cached.detail = "{\n}"                                                // a step saved before the fix
        let labels = ChatStepSheet.blocks(call: call, detail: cached).map(\.label)
        #expect(!labels.contains("Output"))
        #expect(labels.contains("Changes"))
    }

    // MARK: Send state (feel)

    @Test func aSendShowsSendingOnlyAfterTwoSeconds() {
        var mine = ChatMessage(id: "local-user-1", role: .user, parts: [.text("hi")], timestamp: now, rowId: nil)
        mine.isPending = true
        func caption(_ at: Date) -> String? {
            for row in ChatRowBuilder.build(.init(messages: [mine], isRunning: true, botName: "Ivy", expanded: [], now: at, scope: "s")) {
                if case .sendState(let st) = row.kind { return st.text }
            }
            return nil
        }
        #expect(caption(now.addingTimeInterval(1)) == nil)
        #expect(caption(now.addingTimeInterval(2.5)) == "Sending…")
        mine.isPending = false
        #expect(caption(now.addingTimeInterval(5)) == nil)
    }

    @Test func aPendingBubbleIsNotFaded() throws {
        var mine = ChatMessage(id: "local-user-1", role: .user, parts: [.text("hi")], timestamp: now, rowId: nil)
        mine.isPending = true
        let row = try #require(ChatRowBuilder.build(.init(messages: [mine], isRunning: true, botName: "Ivy", expanded: [], now: now,
                                                          scope: "s")).first { $0.id.hasSuffix("|b0") })
        guard case .bubble(let b) = TextLayout.make(row, width: 402, style: ChatStyle.make(category: .large)).content else { return }
        #expect(!b.dimmed)
    }

    // MARK: Tapping a bot (protocol, minor)

    /// The dot clears only once an open applied fresh history (spec 02 §6.7), never at the tap.
    @Test func tappingABotDoesNotReadItYet() {
        let services = ReadRecordingServices()
        services.bots = [Bot(id: "ivy", name: "Ivy", role: nil, preview: "hi", lastActive: Date(), isWorking: false, unread: true,
                             pinned: false, pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: "tip", head: nil)]
        let list = BotsViewController(services: services) { _ in UIViewController() }
        let navigation = UINavigationController(rootViewController: list)
        navigation.loadViewIfNeeded()
        list.loadViewIfNeeded()
        list.reload(animated: false)
        list.open("ivy")
        #expect(services.reads.isEmpty)
    }

    // MARK: The row after a reply (looks, minor)

    @Test func aReplySeenOrMissedUpdatesTheRowAtOnce() async throws {
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in
            BotsTest.profilesResult([
                BotsTest.row("ivy", canonical: BotsTest.session("reg", resolved: "tip", preview: "old words", lastActive: 1_791_000_000)),
                BotsTest.row("ann", canonical: BotsTest.session("ann-chat", preview: "ann's", lastActive: 1_791_000_500)),
            ])
        }
        let store = BotStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast,
                             autoStart: true)
        #expect(await BotsTest.waitUntil { store.phase == .full })
        #expect(store.bots.map(\.id) == ["ann", "ivy"])
        store.noteChatActivity(profile: "ivy", sessionId: "tip", preview: "The new reply", at: Date(timeIntervalSince1970: 1_791_001_000),
                               unseen: true)
        let ivy = try #require(store.bot(named: "ivy"))
        #expect(ivy.preview?.contains("The new reply") == true)
        #expect(ivy.lastActive == Date(timeIntervalSince1970: 1_791_001_000))
        #expect(ivy.unread)
        #expect(store.bots.map(\.id) == ["ivy", "ann"])                      // newest first
        // A side chat of the bot doesn't patch its row.
        store.noteChatActivity(profile: "ann", sessionId: "side", preview: "x", at: Date(timeIntervalSince1970: 1_791_002_000), unseen: true)
        #expect(store.bot(named: "ann")?.unread == false)
        store.stop()
    }
}

/// Records Mark as Read calls.
@MainActor
final class ReadRecordingServices: AppServices {
    var account: GatewayAccount?
    var bots: [Bot] = []
    var sessions: [SessionSummary] = []
    var connection: ConnectionState = .ready
    var onBotsChange: (() -> Void)?
    var onSessionsChange: (() -> Void)?
    var onConnectionChange: (() -> Void)?
    var reads: [String] = []
    func refreshBots() {}
    func refreshSessions() {}
    func chat(for bot: Bot) -> ChatSessionModel { UnavailableChat(title: bot.name, profile: bot.id, head: nil) }
    func chat(for session: SessionSummary) -> ChatSessionModel { UnavailableChat(title: session.title, profile: session.profile, head: nil) }
    func markRead(_ bot: Bot) { reads.append(bot.id) }
    func signOut() {}
}
