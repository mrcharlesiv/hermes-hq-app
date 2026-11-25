// [chat-mark-done] A bot's offer to close your task, as a card under its reply (owner 2026-11-22): the card from a
// `tasks_update` with `offer_done` (and from the `tool_call` bridge, stored and live), none from a refusal or a plain
// update, one per task, what it shows in each state of the task now, the card for a task the bot marked done because
// you said so, nothing new for a bot finishing its own, and "Added to Tasks" / "<Bot> Is Helping" as they were.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@Suite("Tasks · a bot's offer to close a task, in the chat")
@MainActor
struct TaskCloseCardTests {
    static let offerAt = "2026-11-22T09:00:00-06:00"
    static let offerResult = #"{"id": "t_1", "rev": 3, "title": "Book the train tickets", "who": "me", "status": "open", "bot": null, "offer": {"kind": "done", "by": "default", "text": "You booked them this morning", "at": "2026-11-22T09:00:00-06:00"}, "offered": "They see Mark Done and Keep Open on the task."}"#
    static let askedResult = #"{"id": "t_cake", "rev": 4, "title": "Pick up the cake", "who": "me", "status": "done", "asked": true}"#
    static let offerArgs: [String: JSONValue] = ["id": "t_1", "offer_done": "You booked them this morning"]

    // MARK: Helpers

    func call(_ id: String, _ card: ToolCard?, name: String = "tasks_update", state: ToolCall.State = .done) -> ToolCall {
        var c = ToolCall(id: id, name: name, title: name, argsText: "{}", summary: nil, state: state, durationSeconds: nil)
        c.card = card
        return c
    }

    func reply(_ id: String, _ calls: [ToolCall], text: String = "The shared task is ready to tap Mark Done.",
               streaming: Bool = false) -> ChatMessage {
        var m = ChatMessage(id: id, role: .assistant, parts: calls.map { .tool($0) } + [.text(text)], timestamp: Date(), rowId: 2)
        m.isStreaming = streaming
        return m
    }

    func prompt(_ id: String = "u") -> ChatMessage {
        ChatMessage(id: id, role: .user, parts: [.text("I booked the tickets, so that one is finished.")], timestamp: Date(), rowId: 1)
    }

    func offer(_ at: String = TaskCloseCardTests.offerAt, kept: Bool = false) -> TodoCloseOffer {
        TodoCloseOffer(by: "default", text: "You booked them this morning", at: at, kept: kept)
    }

    func states(_ tasks: [String: TodoTaskStates.Entry], read: Bool = true, readOnly: Bool = false,
                reopened: Set<String> = []) -> TodoTaskStates.Snapshot {
        TodoTaskStates.Snapshot(tasks: tasks, read: read, readOnly: readOnly, reopened: reopened)
    }

    func rows(_ messages: [ChatMessage], _ s: TodoTaskStates.Snapshot) -> [ChatRow] {
        var a = ActivityRowsInput()
        a.taskStates = s
        a.profile = "default"
        return ChatRowBuilder.build(ChatRowBuilder.Input(messages: messages, isRunning: false, botName: "Hermes", expanded: [],
                                                         scope: "t", activity: a))
    }

    func closeRows(_ rows: [ChatRow]) -> [TaskCloseRow] {
        rows.compactMap { if case .activity(.taskClose(let t)) = $0.kind { return t } else { return nil } }
    }

    func addedRows(_ rows: [ChatRow]) -> [TasksAddedRow] {
        rows.compactMap { if case .activity(.tasksAdded(let t)) = $0.kind { return t } else { return nil } }
    }

    var offerCard: ToolCard? { ToolCards.card(name: "tasks_update", args: Self.offerArgs, result: .string(Self.offerResult)) }

    // MARK: The card from the call

    @Test func anOfferDoneResultIsACloseCard() throws {
        guard case .tasksAdded(let tasks)? = offerCard, let task = tasks.first else { Issue.record("no card"); return }
        #expect(task.closeOffer == offer())
        #expect(!task.askedDone)
        #expect(ToolCard(json: offerCard?.json) == offerCard, "the transcript cache keeps the offer")
        let found = ActivityRows.closeCards([call("c1", offerCard)])
        #expect(found.map(\.id) == ["t_1"])
        let line = TodoLists.closeLine(try #require(task.closeOffer)) { _ in "Hermes" }
        #expect(line == "Hermes: looks done · You booked them this morning", "the task page's own line")
    }

    @Test func aRefusalOrAPlainUpdateDrawsNoCloseCard() {
        let refused = ToolCards.card(name: "tasks_update", args: Self.offerArgs,
                                     result: .string(#"{"error": "They chose to keep this one open."}"#))
        #expect(refused == nil, "a refusal is no card at all")
        // The task still carries an earlier offer, but this call offered nothing: no close card.
        let plain = ToolCards.card(name: "tasks_update", args: ["id": "t_1", "tags": ["travel"]], result: .string(Self.offerResult))
        #expect(plain != nil)
        #expect(ActivityRows.closeCards([call("c1", plain)]).isEmpty)
        // An offer_done whose result has no offer (a done task: the add-on leaves it alone).
        let noOffer = ToolCards.card(name: "tasks_update", args: Self.offerArgs,
                                     result: .string(#"{"id": "t_1", "title": "Book the train tickets", "who": "me", "status": "done"}"#))
        #expect(ActivityRows.closeCards([call("c1", noOffer)]).isEmpty)
        // tasks_add never carries one.
        let add = ToolCards.card(name: "tasks_add", args: Self.offerArgs, result: .string(Self.offerResult))
        #expect(ActivityRows.closeCards([call("c1", add, name: "tasks_add")]).isEmpty)
        let messages = [prompt(), reply("a", [call("c1", plain)])]
        #expect(closeRows(rows(messages, states(["t_1": .init(done: false, offer: offer())]))).isEmpty)
    }

    @Test func oneCardPerTaskPerReplyAndNoneWhileStreaming() {
        let s = states(["t_1": .init(done: false, offer: offer())])
        let twice = [prompt(), reply("a", [call("c1", offerCard), call("c2", offerCard)])]
        #expect(closeRows(rows(twice, s)).count == 1)
        let streaming = [prompt(), reply("a", [call("c1", offerCard)], streaming: true)]
        #expect(closeRows(rows(streaming, s)).isEmpty, "under the settled reply only")
        let running = [prompt(), reply("a", [call("c1", offerCard, state: .running)])]
        #expect(closeRows(rows(running, s)).isEmpty)
    }

    @Test func theStoredBridgeGivesTheCard() throws {
        let inner = ChatJSON.stringify(["calls": [["name": "tasks_update", "arguments": .object(Self.offerArgs)]]])
        let stored: [JSONValue] = [
            ["role": "user", "content": "I booked the tickets.", "row_id": 1, "timestamp": 1793474859],
            ["role": "assistant", "content": "", "row_id": 2, "timestamp": 1793474860,
             "tool_calls": [["id": "call_b", "type": "function", "function": ["name": "tool_call", "arguments": .string(inner)]]]],
            ["role": "tool", "tool_name": "tasks_update", "tool_call_id": "call_b", "row_id": 3, "timestamp": 1793474861,
             "content": .string(Self.offerResult)],
            ["role": "assistant", "content": "The shared task is ready to tap Mark Done.", "row_id": 4, "timestamp": 1793474862],
        ]
        let page = Hydration.fold(stored, pageSeq: 1)
        let calls = page.messages.flatMap(\.parts).compactMap { p -> ToolCall? in if case .tool(let c) = p { return c } else { return nil } }
        let bridged = try #require(calls.first { $0.id == "call_b" })
        #expect(bridged.name == "tasks_update")
        #expect(ActivityRows.closeCards([bridged]).first?.closeOffer == offer())
        let drawn = closeRows(rows(page.messages, states(["t_1": .init(done: false, offer: offer())])))
        #expect(drawn.map(\.taskId) == ["t_1"] && drawn.first?.state == .waiting)
    }

    @Test func theLiveBridgeGivesTheCard() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming", "user_row_id": 5000] : [:] }
        s.send("I booked the tickets.")
        let calls: JSONValue = ["calls": [["name": "tasks_update", "arguments": .object(Self.offerArgs)]]]
        await h.emit([h.event("message.start", seq: 1),
                      h.event("tool.start", ["tool_id": "c1", "name": "tool_call", "args": calls], seq: 2)])
        await h.emit([h.event("tool.complete", ["tool_id": "c1", "name": "tool_call", "result": .string(Self.offerResult)], seq: 3)])
        s.flushChanges()
        let live = try #require(h.assistant)
        let call = try #require(live.parts.compactMap { p -> ToolCall? in if case .tool(let c) = p { return c } else { return nil } }.first)
        #expect(call.name == "tasks_update")
        #expect(ActivityRows.closeCards([call]).first?.closeOffer == offer(), "the live road keeps the offer_done args")
    }

    // MARK: What it shows now

    @Test func eachStateOfTheTaskNow() {
        let rule = { (s: TodoTaskStates.Snapshot, newest: Bool) in
            TodoCloseCards.state(asked: false, offer: self.offer(), id: "t_1", newest: newest, in: s)
        }
        #expect(rule(states(["t_1": .init(done: false, offer: offer())]), true) == .waiting, "pending: the buttons")
        #expect(rule(states(["t_1": .init(done: true, offer: nil)]), true) == .done(undo: true), "done: Marked Done, Undo")
        #expect(rule(states(["t_1": .init(done: true, offer: nil)], readOnly: true), true) == .done(undo: false),
                "the gateway takes no writes: no Undo")
        #expect(rule(states(["t_1": .init(done: true, offer: nil)]), false) == .done(undo: false), "an older card: no Undo")
        #expect(rule(states(["t_1": .init(done: false, offer: offer(kept: true))]), true) == .kept, "Keep Open was chosen")
        #expect(rule(states([:]), true) == .gone, "deleted: no longer on your list")
        #expect(rule(states(["t_1": .init(done: false, offer: nil)]), true) == .settled, "open, its offer gone")
        #expect(rule(states(["t_1": .init(done: false, offer: nil)], reopened: ["t_1"]), true) == .reopened, "Undo here")
        #expect(rule(states(["t_1": .init(done: false, offer: offer())]), false) == .settled, "a newer card stands for it")
        #expect(rule(states(["t_1": .init(done: false, offer: offer("2026-11-22T11:00:00-06:00"))]), true) == .settled,
                "offered again since, elsewhere")
        #expect(rule(states(["t_1": .init(done: false, offer: offer("2026-11-21T11:00:00-06:00"))]), true) == .waiting,
                "the store is behind the bot: the card still offers")
        #expect(rule(states([:], read: false), true) == nil, "not read yet: no card until it is")
        #expect(rule(states(["t_1": .init(done: false, offer: offer())], read: false), true) == .waiting,
                "a list from disk that has it shows it")
        #expect(TodoCloseCards.words(.done(undo: true)) == "Marked Done" && TodoCloseCards.words(.kept) == "Kept Open"
                && TodoCloseCards.words(.gone) == "No longer on your list" && TodoCloseCards.words(.waiting) == nil)
        #expect(TodoCloseCards.allWords.allSatisfy { !$0.isEmpty })
    }

    @Test func theRowsFollowTheStore() {
        let messages = [prompt(), reply("a", [call("c1", offerCard)])]
        let state = { (s: TodoTaskStates.Snapshot) in self.closeRows(self.rows(messages, s)).first?.state }
        #expect(state(states(["t_1": .init(done: false, offer: offer())])) == .waiting)
        #expect(state(states(["t_1": .init(done: true, offer: nil)])) == .done(undo: true))
        #expect(state(states(["t_1": .init(done: false, offer: offer(kept: true))])) == .kept)
        #expect(state(states([:])) == .gone)
        #expect(state(states([:], read: false)) == nil, "not read yet: the row waits")
        let row = closeRows(rows(messages, states(["t_1": .init(done: false, offer: offer())], readOnly: true))).first
        #expect(row?.readOnly == true && row?.line == "Hermes: looks done · You booked them this morning")
        #expect(row?.title == "Book the train tickets")
        // Its id and fingerprint: a new state is a new fingerprint (the chat redraws it), the id stays.
        let a = rows(messages, states(["t_1": .init(done: false, offer: offer())])).first { $0.id.hasSuffix("|close|t_1") }
        let b = rows(messages, states(["t_1": .init(done: true, offer: nil)])).first { $0.id.hasSuffix("|close|t_1") }
        #expect(a != nil && a?.id == b?.id && a?.fingerprint != b?.fingerprint)
    }

    @Test func onlyTheNewestCardInTheChatKeepsItsButtons() {
        let later = "2026-11-22T10:00:00-06:00"
        let second = ToolCards.card(name: "tasks_update", args: Self.offerArgs,
                                    result: .string(Self.offerResult.replacingOccurrences(of: Self.offerAt, with: later)))
        let messages = [prompt("u1"), reply("a1", [call("c1", offerCard)]), prompt("u2"), reply("a2", [call("c2", second)])]
        let drawn = closeRows(rows(messages, states(["t_1": .init(done: false, offer: offer(later))])))
        #expect(drawn.map(\.messageId) == ["a1", "a2"])
        #expect(drawn.map(\.state) == [.settled, .waiting], "never two live Mark Done cards for one task")
        #expect(ActivityRows.newestCloseCard("t_1", in: messages) == "a2")
    }

    @Test func theRowIsOneHeightInEveryState() {
        let style = ChatStyleCache.shared.style(for: .large)
        let big = ChatStyleCache.shared.style(for: .accessibilityExtraExtraExtraLarge)
        for style in [style, big] {
            let heights = [TodoCloseCards.State.waiting, .done(undo: true), .done(undo: false), .reopened, .kept, .gone, .settled]
                .map { state -> CGFloat in
                    let row = TaskCloseRow(messageId: "a", taskId: "t_1", title: "Book the train tickets",
                                           line: "Hermes: looks done · You booked them this morning", asked: false, state: state, readOnly: false)
                    let chat = ChatRow(id: "a|close|t_1", messageId: "a", scope: "t", fingerprint: 0, kind: .activity(.taskClose(row)),
                                       gapAbove: 8, variant: 0)
                    return TextLayout.make(chat, width: 393, style: style).height
                }
            #expect(Set(heights).count == 1, "\(heights)")
        }
    }

    // MARK: Done because you said so

    @Test func aTaskMarkedDoneAsAskedIsTheSettledCard() {
        let card = ToolCards.card(name: "tasks_update", args: ["id": "t_cake", "status": "done"], result: .string(Self.askedResult))
        guard case .tasksAdded(let tasks)? = card else { Issue.record("no card"); return }
        #expect(tasks.first?.askedDone == true && tasks.first?.closeOffer == nil)
        #expect(ToolCard(json: card?.json) == card, "the transcript cache keeps it")
        let messages = [prompt(), reply("a", [call("c1", card)], text: "Done. I marked it done for you.")]
        let done = closeRows(rows(messages, states(["t_cake": .init(done: true, offer: nil)]))).first
        #expect(done?.asked == true && done?.line == nil && done?.state == .done(undo: true), "Marked Done, with Undo")
        #expect(closeRows(rows(messages, states(["t_cake": .init(done: false, offer: nil)]))).first?.state == .reopened,
                "after Undo: back on the list, no buttons")
        #expect(closeRows(rows(messages, states([:]))).first?.state == .gone)
        // Not asked: no card (only "asked" says you told it to).
        let unasked = ToolCards.card(name: "tasks_update", args: ["id": "t_cake", "status": "done"],
                                     result: .string(Self.askedResult.replacingOccurrences(of: #", "asked": true"#, with: "")))
        #expect(ActivityRows.closeCards([call("c1", unasked)]).isEmpty)
    }

    @Test func aBotFinishingItsOwnTaskDrawsNothingNew() {
        let own = #"{"id": "t_bot", "rev": 5, "title": "Rank the applications", "who": "bot", "bot": "default", "status": "done", "asked": true}"#
        let card = ToolCards.card(name: "tasks_update", args: ["id": "t_bot", "status": "done"], result: .string(own))
        #expect(ActivityRows.closeCards([call("c1", card)]).isEmpty)
        let drawn = rows([prompt(), reply("a", [call("c1", card)], text: "Finished.")], states(["t_bot": .init(done: true, offer: nil)]))
        #expect(closeRows(drawn).isEmpty && addedRows(drawn).isEmpty, "as today: no card")
    }

    // MARK: "Added to Tasks" and "<Bot> Is Helping" as they were

    @Test func theAddedAndHelpingCardsAreUnchanged() {
        let s = states([:])
        let added = ToolCards.card(name: "tasks_add", args: [:],
                                   result: .string(#"{"id": "t_9", "rev": 1, "title": "Call the vet", "who": "me", "due": "2026-11-24"}"#))
        let a = addedRows(rows([prompt(), reply("a", [call("c1", added, name: "tasks_add")])], s))
        #expect(a.count == 1 && a.first?.helping == false && a.first?.tasks.map(\.id) == ["t_9"], "Added to Tasks")

        let took = #"{"id": "t_vet", "title": "Call the vet", "who": "together", "bot": "default", "log": [{"by": "default", "text": "took a part"}]}"#
        let helping = ToolCards.card(name: "tasks_update", args: ["id": "t_vet"], result: .string(took))
        let h = rows([prompt(), reply("a", [call("c1", helping)])], s)
        #expect(addedRows(h).first?.helping == true && closeRows(h).isEmpty, "Is Helping, no close card")

        // Added, then updated in the same reply: one Added card with the update (as before).
        let update = ToolCards.card(name: "tasks_update", args: ["id": "t_9"],
                                    result: .string(#"{"id": "t_9", "title": "Call the vet at 9", "who": "me"}"#))
        let both = addedRows(rows([prompt(), reply("a", [call("c1", added, name: "tasks_add"), call("c2", update)])], s))
        #expect(both.count == 1 && both.first?.tasks.first?.title == "Call the vet at 9")

        // Only an offer to close: no Added card (it added nothing, and took no part).
        let offerOnly = rows([prompt(), reply("a", [call("c1", offerCard)])], states(["t_1": .init(done: false, offer: offer())]))
        #expect(addedRows(offerOnly).isEmpty && closeRows(offerOnly).count == 1)

        // Took a part and offered to close in one call: the helping card stays, the close card is added.
        let tookAndOffered = #"{"id": "t_vet", "title": "Call the vet", "who": "together", "bot": "default", "status": "open", "took_part": true, "offer": {"kind": "done", "by": "default", "text": "The clinic confirmed", "at": "2026-11-22T09:00:00-06:00"}}"#
        let edge = ToolCards.card(name: "tasks_update", args: ["id": "t_vet", "offer_done": "The clinic confirmed"],
                                  result: .string(tookAndOffered))
        let e = rows([prompt(), reply("a", [call("c1", edge)])],
                     states(["t_vet": .init(done: false, offer: TodoCloseOffer(by: "default", text: "The clinic confirmed", at: Self.offerAt))]))
        #expect(addedRows(e).first?.helping == true, "the helping card stays")
        #expect(closeRows(e).map(\.state) == [.waiting], "and the close card is added")
    }

    @Test func settledCloseCardFoldsAfterLaterConversationAndExpands() throws {
        let style = ChatStyleCache.shared.style(for: .large)
        let m1 = reply("a", [call("c1", offerCard)])
        let later = prompt("u2")

        // A waiting offer stays open even after a later turn so Mark Done / Keep Open remain actionable.
        let waiting = closeRows(rows([prompt("u1"), m1, later], states(["t_1": .init(done: false, offer: offer())])))
        #expect(waiting.first?.folded == false)

        // A newly settled card with no later conversation stays open as confirmation.
        let newestDone = closeRows(rows([prompt("u1"), m1], states(["t_1": .init(done: true, offer: nil)])))
        #expect(newestDone.first?.folded == false)

        // Once settled AND followed by later conversation, it folds to one quiet disclosure line.
        let foldedRows = rows([prompt("u1"), m1, later], states(["t_1": .init(done: true, offer: nil)]))
        let foldedChatRow = try #require(foldedRows.first { $0.id == "a|close|t_1" })
        guard case .activity(.taskClose(let foldedCard)) = foldedChatRow.kind else { Issue.record("close"); return }
        #expect(foldedCard.folded && !foldedCard.opened)
        let collapsedLayout = TextLayout.make(foldedChatRow, width: 393, style: style)
        guard case .activity(.taskClose(let cl)) = collapsedLayout.content else { Issue.record("layout"); return }
        #expect(!cl.cardShown && cl.foldFrame != nil && collapsedLayout.height < 56)

        // Tapping the disclosure line expands the full card underneath.
        var a = ActivityRowsInput()
        a.taskStates = states(["t_1": .init(done: true, offer: nil)])
        a.profile = "default"
        let expandedRows = ChatRowBuilder.build(ChatRowBuilder.Input(messages: [prompt("u1"), m1, later], isRunning: false,
                                                                     botName: "Hermes", expanded: ["a|close|t_1"], scope: "t", activity: a))
        let expandedChatRow = try #require(expandedRows.first { $0.id == "a|close|t_1" })
        let expandedLayout = TextLayout.make(expandedChatRow, width: 393, style: style)
        guard case .activity(.taskClose(let el)) = expandedLayout.content else { Issue.record("expanded"); return }
        #expect(el.cardShown && el.opened && expandedLayout.height > collapsedLayout.height)
    }
}
