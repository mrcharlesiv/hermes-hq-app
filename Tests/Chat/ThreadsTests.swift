import Foundation
import Testing
import UIKit
@testable import HermesHQNative

/// [threads] A bot chat's threads: what a thread starts out knowing, where it hangs, open or folded, and its rows.
@MainActor
struct ThreadsTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func you(_ id: String, _ text: String, _ s: Double, row: Int? = nil) -> ChatMessage {
        ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: t0 + s, rowId: row)
    }
    private func bot(_ id: String, _ text: String, _ s: Double, row: Int? = nil, streaming: Bool = false) -> ChatMessage {
        var m = ChatMessage(id: id, role: .assistant, parts: [.text(text)], timestamp: t0 + s, rowId: row)
        m.isStreaming = streaming
        return m
    }

    private func thread(_ id: String = "t1", at s: Double, anchorId: String? = nil, anchorRow: Int? = nil,
                        messages: [ChatMessage]? = nil, running: Bool = false, title: String? = nil) -> ChatThread {
        ChatThread(id: id, storedId: id, title: title, startedAt: t0 + s, anchorMessageId: anchorId, anchorRow: anchorRow,
                   messages: messages ?? [you("\(id)-u1", "What time is my flight?", s), bot("\(id)-a1", "7:05 AM.", s + 20)],
                   running: running, problem: nil, scope: "acct|bot|\(id)")
    }

    /// The main chat: a question answered, then a request the bot is (or was) working on.
    private var main: [ChatMessage] {
        [you("u1", "Shortlist three CRMs", 0, row: 10), bot("a1", "HubSpot, Pipedrive and Close.", 30, row: 11),
         you("u2", "Build the comparison sheet", 60, row: 14)]
    }

    private func input(_ messages: [ChatMessage], threads: [ChatThread], running: Bool = false) -> ChatRowBuilder.Input {
        var input = ChatRowBuilder.Input(messages: messages, isRunning: running, botName: "Hermes", expanded: [])
        input.scope = "acct|bot|main"
        for (index, hung) in ThreadRules.byAnchor(threads, in: messages) {
            input.threads[messages[index].id] = hung.map { ThreadRowInput(thread: $0, open: ThreadRules.isOpen($0, anchor: index, in: messages)) }
        }
        return input
    }

    private func ids(_ input: ChatRowBuilder.Input) -> [String] {
        ChatRowBuilder.build(input).map(\.id).filter { !$0.hasSuffix("|day") }
    }

    // MARK: The seed

    @Test func theSeedIsTheNewestPartOfTheChatAndEveryRowIsHidden() {
        let rows = ThreadSeed.rows(from: main, running: true, anchorRow: 14)
        #expect(rows.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(rows[2].text == "Build the comparison sheet")
        #expect(rows[3].text.contains("still working on that in the main chat"), "the running job is left to the main chat")
        let params = ThreadSeed.params(rows)
        #expect(params.allSatisfy { $0["display_kind"]?.string == "hidden" })
        #expect(params.first?["role"]?.string == "user")
    }

    @Test func anIdleChatsSeedEndsOnTheLastReplyWithTheNoteInTheSameRow() {
        let idle = Array(main.prefix(2))
        let rows = ThreadSeed.rows(from: idle, running: false, anchorRow: 11)
        #expect(rows.map(\.role) == [.user, .assistant], "the roles alternate up to the thread's first message")
        #expect(rows[1].text.hasPrefix("HubSpot, Pipedrive and Close."))
        #expect(rows[1].text.contains("side thread of the main chat"))
        #expect(!rows[1].text.contains("still working"))
    }

    @Test func theAnchorRowRidesInTheSeedAndReadsBack() {
        let rows = ThreadSeed.rows(from: main, running: true, anchorRow: 14)
        #expect(ThreadSeed.anchorRow(in: rows.last?.text ?? "") == 14)
        #expect(ThreadSeed.anchorRow(in: "no marker here") == nil)
        #expect(ThreadSeed.anchorRow(in: ThreadSeed.closingNote(running: false, anchorRow: nil)) == nil)
    }

    @Test func theSeedSkipsTheReplyStillArrivingAndRowsThatAreNotTheConversation() {
        var messages = main
        messages.append(bot("a2", "Working: 3 of 9 rows…", 70, streaming: true))
        var failed = you("u3", "never arrived", 80)
        failed.error = "Not delivered"
        messages.append(failed)
        messages.append(ChatMessage(id: "n1", role: .system, parts: [.text("Model changed")], timestamp: t0 + 90, rowId: nil))
        let rows = ThreadSeed.rows(from: messages, running: true)
        #expect(!rows.contains { $0.text.contains("3 of 9") })
        #expect(!rows.contains { $0.text.contains("never arrived") })
        #expect(!rows.contains { $0.text.contains("Model changed") })
    }

    @Test func aLongChatsSeedIsBoundedAndStartsWithYourWords() {
        var messages: [ChatMessage] = []
        for i in 0..<60 {
            messages.append(you("u\(i)", String(repeating: "word ", count: 300), Double(i * 10)))
            messages.append(bot("a\(i)", String(repeating: "answer ", count: 900), Double(i * 10 + 5)))
        }
        let rows = ThreadSeed.rows(from: messages, running: false)
        #expect(rows.count <= ThreadSeed.maxTurns)
        #expect(rows.first?.role == .user)
        // The closing note rides on the last row, over the budget by its own length only.
        #expect(rows.reduce(0) { $0 + $1.text.count } <= ThreadSeed.maxCharacters + 200)
        #expect(rows.dropLast().allSatisfy { $0.text.count <= ThreadSeed.perRowCharacters })
    }

    @Test func aNewChatWithNothingSaidGivesNoSeed() {
        #expect(ThreadSeed.rows(from: [], running: false).isEmpty)
        #expect(ThreadSeed.rows(from: [bot("a0", "Hi, I'm here.", 0)], running: false).isEmpty, "nothing of yours to open with")
    }

    // MARK: Reading a thread back

    @Test func aStoredThreadsHiddenSeedGivesItsAnchorAndIsNotAmongItsMessages() {
        let seed = ThreadSeed.params(ThreadSeed.rows(from: main, running: true, anchorRow: 14))
        var rows: [JSONValue] = seed.enumerated().map { index, row in
            var record = row.object ?? [:]
            record["id"] = .number(Double(index + 1))
            record["timestamp"] = .number(1_790_000_100)
            return .object(record)
        }
        rows.append(["id": 5, "role": "user", "content": "What time is my flight?", "timestamp": 1_790_000_200])
        rows.append(["id": 6, "role": "assistant", "content": "7:05 AM from DFW.", "timestamp": 1_790_000_220])
        let read = ThreadFetch.read(rows: rows)
        #expect(read.anchorRow == 14)
        #expect(read.messages.map(\.role) == [.user, .assistant])
        #expect(ChatTranscript.messageText(read.messages[0]) == "What time is my flight?")
    }

    @Test func hiddenSeedRowsDrawNothingInTheThreadsOwnChat() {
        // The thread's own chat reads every stored row: the hidden ones must fold away there too.
        let rows: [JSONValue] = [
            ["id": 1, "role": "user", "content": "Shortlist three CRMs", "display_kind": "hidden", "timestamp": 1_790_000_100],
            ["id": 2, "role": "assistant", "content": "HubSpot, Pipedrive and Close.", "display_kind": "hidden", "timestamp": 1_790_000_110],
            ["id": 3, "role": "user", "content": "What time is my flight?", "timestamp": 1_790_000_200],
        ]
        let messages = Hydration.fold(rows).messages
        #expect(messages.count == 1)
        #expect(messages.first.map(ChatTranscript.messageText) == "What time is my flight?")
    }

    // MARK: Where a thread hangs

    @Test func aThreadHangsUnderTheMessageThisDeviceStartedItUnder() {
        #expect(ThreadRules.anchorIndex(of: thread(at: 70, anchorId: "u2"), in: main) == 2)
        #expect(ThreadRules.anchorIndex(of: thread(at: 70, anchorId: "a1"), in: main) == 1, "Reply in Thread on an older message")
    }

    @Test func onAnotherDeviceTheStoredRowPlacesIt() {
        #expect(ThreadRules.anchorIndex(of: thread(at: 70, anchorRow: 14), in: main) == 2)
        // A reply folded from several stored rows carries its first row: the anchor falls inside it.
        #expect(ThreadRules.anchorIndex(of: thread(at: 70, anchorRow: 12), in: main) == 1)
        // The message it hangs under is older than what is loaded: it draws nowhere.
        #expect(ThreadRules.anchorIndex(of: thread(at: 70, anchorRow: 3), in: main) == nil)
    }

    @Test func withNoAnchorItsStartTimePlacesItUnderYourNewestMessageBeforeIt() {
        #expect(ThreadRules.anchorIndex(of: thread(at: 70), in: main) == 2)
        #expect(ThreadRules.anchorIndex(of: thread(at: 45), in: main) == 0)
        #expect(ThreadRules.anchorIndex(of: thread(at: -5), in: main) == nil)
    }

    // MARK: Open or folded

    @Test func aThreadIsOpenWhileItIsTheNewestThingAndFoldsOnceTheMainReplyIsDone() {
        let hung = thread(at: 70, anchorId: "u2")
        #expect(ThreadRules.isOpen(hung, anchor: 2, in: main))
        // The main reply still arriving after it: open.
        #expect(ThreadRules.isOpen(hung, anchor: 2, in: main + [bot("a2", "Working…", 61, streaming: true)]))
        // The main reply finished: folded.
        #expect(!ThreadRules.isOpen(hung, anchor: 2, in: main + [bot("a2", "The sheet is ready.", 61)]))
        // Your own later message alone does not fold it.
        #expect(ThreadRules.isOpen(hung, anchor: 2, in: main + [you("u3", "and add Zoho", 90)]))
    }

    @Test func aThreadStillAnsweringStaysOpenWhereverItIs() {
        let running = thread(at: 40, anchorId: "u1", running: true)
        #expect(ThreadRules.isOpen(running, anchor: 0, in: main))
        #expect(!ThreadRules.isOpen(thread(at: 40, anchorId: "u1"), anchor: 0, in: main))
    }

    @Test func anOpenThreadShowsYourLastMessageAndWhatFollowed() {
        let long = thread(at: 70, messages: [you("m1", "Flight time?", 70), bot("m2", "7:05 AM.", 75),
                                             you("m3", "Add it to my calendar", 100), bot("m4", "Done.", 110)])
        let shown = ThreadRules.shown(long)
        #expect(shown.messages.map(\.id) == ["m3", "m4"])
        #expect(shown.earlier == 2)
        #expect(ThreadRules.header(long).tail == "4 messages")
        #expect(ThreadRules.header(thread(at: 70)).tail == nil, "nothing more than it shows: no count")
    }

    @Test func aThreadIsNamedThreadUntilItHasATitleOfItsOwn() {
        #expect(ThreadRules.name(thread(at: 70)) == "Thread")
        #expect(ThreadRules.name(thread(at: 70, title: "New Chat")) == "Thread")
        #expect(ThreadRules.name(thread(at: 70, title: "Flight on Friday")) == "Flight on Friday")
    }

    // MARK: Rows

    @Test func anOpenThreadIsOneRowUnderItsMessageWithItsBubblesInside() {
        let rows = ChatRowBuilder.build(input(main, threads: [thread(at: 70, anchorId: "u2")], running: true))
        let ids = rows.map(\.id).filter { !$0.hasSuffix("|day") }
        #expect(ids == ["u1|b0", "a1|b0", "u2|b0", "u2|th:t1", "waiting"])
        guard case .thread(let payload)? = rows.first(where: { $0.id == "u2|th:t1" })?.kind else {
            Issue.record("no thread row")
            return
        }
        #expect(payload.name == "Thread")
        #expect(payload.inner.map(\.id) == ["t1-u1|b0", "t1-a1|b0"])
        #expect(payload.inner.allSatisfy { $0.scope == "acct|bot|t1" }, "its rows are cached under the thread's own chat")
    }

    @Test func aThreadWithNoReplyYetShowsItsOwnWaitingLine() {
        let asked = thread(at: 70, anchorId: "u2", messages: [you("t1-u1", "Flight time?", 70)], running: true)
        let rows = ChatRowBuilder.build(input(main, threads: [asked], running: true))
        guard case .thread(let payload)? = rows.first(where: { $0.id == "u2|th:t1" })?.kind else {
            Issue.record("no thread row")
            return
        }
        #expect(payload.inner.count == 2)
        if case .waiting = payload.inner.last?.kind {} else { Issue.record("the thread's own waiting line is missing") }
    }

    @Test func aFoldedThreadIsOneCentredLineWithItsNameAndCount() {
        let done = main + [bot("a2", "The sheet is ready.", 61)]
        let rows = ChatRowBuilder.build(input(done, threads: [thread(at: 70, anchorId: "u2", title: "Flight on Friday")]))
        let ids = rows.map(\.id).filter { !$0.hasSuffix("|day") }
        #expect(ids == ["u1|b0", "a1|b0", "u2|b0", "u2|thf:t1", "a2|b0"])
        guard case .backgroundResult(let line)? = rows.first(where: { $0.id == "u2|thf:t1" })?.kind else {
            Issue.record("no folded line")
            return
        }
        #expect(line.title == "Flight on Friday")
        #expect(line.group?.tail == "2 messages")
        #expect(line.group?.marks == [.glyph(.thread)])
        #expect(ThreadRows.key(inRowId: "u2|thf:t1") == "t1")
        #expect(ThreadRows.key(inRowId: "u2|b0") == nil)
    }

    @Test func theBubbleAboveAThreadEndsItsRunAndKeepsItsTail() {
        // Two of your messages a moment apart are one run; a thread hung under the first ends the run there.
        let messages = [you("u1", "Build the sheet", 0), you("u2", "and add Zoho", 20)]
        func tail(_ rows: [ChatRow], _ id: String) -> Bool? {
            guard case .bubble(let b)? = rows.first(where: { $0.id == id })?.kind else { return nil }
            return b.tail
        }
        #expect(tail(ChatRowBuilder.build(input(messages, threads: [])), "u1|b0") == false)
        let hung = ChatRowBuilder.build(input(messages, threads: [thread(at: 5, anchorId: "u1", running: true)]))
        #expect(tail(hung, "u1|b0") == true)
    }

    @Test func aRegionRebuildMatchesAFullBuildWithThreads() {
        var messages = main
        let threads = [thread(at: 70, anchorId: "u2", running: true)]
        var model = ChatRowModel()
        model.rebuildAll(input(messages, threads: threads, running: true), syncMessages: 100, oldestShown: nil)
        messages.append(bot("a2", "The sheet is ready.", 61))
        let done = [thread(at: 70, anchorId: "u2")]
        // The main reply finished: the thread's message is touched too (it folds), as the chat screen does.
        model.rebuildNewest(input(messages, threads: done), touching: ["u2", "a2"])
        #expect(Array(model.allRows.reversed()).map(\.id) == ChatRowBuilder.build(input(messages, threads: done)).map(\.id))
        #expect(model.allRows.contains { $0.id == "u2|thf:t1" })
        #expect(!model.allRows.contains { $0.id == "u2|th:t1" })
    }

    @Test func anOpenThreadLaysOutItsRowsInsideItsOwnHeight() {
        let rows = ChatRowBuilder.build(input(main, threads: [thread(at: 70, anchorId: "u2")], running: true))
        guard let row = rows.first(where: { $0.id == "u2|th:t1" }) else {
            Issue.record("no thread row")
            return
        }
        let layout = TextLayout.make(row, width: 390, style: ChatStyle.make(category: .large))
        guard case .thread(let frames) = layout.content else {
            Issue.record("not a thread layout")
            return
        }
        #expect(frames.inner.count == 2)
        #expect(frames.header.minY >= 0 && frames.header.maxY <= frames.inner[0].frame.minY + 0.5)
        #expect(frames.inner[0].frame.maxY <= frames.inner[1].frame.minY + 0.5)
        #expect(frames.inner[1].frame.maxY <= layout.height)
        #expect(frames.inner.allSatisfy { $0.frame.minX == ThreadRows.indent && $0.frame.maxX == 390 })
        #expect(frames.line.minY >= frames.header.minY && frames.line.maxY <= layout.height)
    }

    @Test func anAutoThreadInAnEmptyChatRendersVisibleAtTheFoot() {
        let emptyThread = thread(at: 70, anchorId: nil, anchorRow: nil, running: true)
        let unanchored = ThreadRules.unanchored([emptyThread], in: [])
        #expect(unanchored.map(\.id) == ["t1"])
        var inp = ChatRowBuilder.Input(messages: [], isRunning: false, botName: "Hermes", expanded: [])
        inp.scope = "acct|bot|main"
        inp.threads[ThreadRows.emptyAnchorId] = unanchored.map { ThreadRowInput(thread: $0, open: true) }
        let rows = ChatRowBuilder.build(inp)
        #expect(rows.count == 1)
        #expect(rows[0].id == "\(ThreadRows.emptyAnchorId)|th:t1")
        // Once the main chat has real messages, unanchored returns empty (normal anchor rules apply).
        #expect(ThreadRules.unanchored([emptyThread], in: main).isEmpty)
    }

    @Test func busyReasonSeedEmitsBusyNoteEvenAfterAssistantReply() {
        let idleEndingOnBot = Array(main.prefix(2))
        let rows = ThreadSeed.rows(from: idleEndingOnBot, running: false, anchorRow: 11, busyReason: "a background task")
        #expect(rows.last?.text.contains("currently busy with a background task") == true)
        #expect(ThreadSeed.anchorRow(in: rows.last?.text ?? "") == 11)
    }
}
