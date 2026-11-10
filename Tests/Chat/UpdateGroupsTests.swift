import Foundation
import Testing
import UIKit
@testable import HermesHQNative

/// [updates] Finished work, other bots' messages and notes between your messages fold into one centred line.
@MainActor
struct UpdateGroupsTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let ivy = ChatSender(key: "ivy", name: "Ivy", head: nil, profile: "ivy")

    private func you(_ id: String, _ text: String, _ s: Double) -> ChatMessage {
        ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: t0 + s, rowId: 1)
    }
    private func bot(_ id: String, _ text: String, _ s: Double) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, parts: [.text(text)], timestamp: t0 + s, rowId: 2)
    }
    private func note(_ id: String, _ text: String, _ s: Double) -> ChatMessage {
        ChatMessage(id: id, role: .system, parts: [.text(text)], timestamp: t0 + s, rowId: 3)
    }
    /// The bot's "[SILENT]" answer to the delivery, as the timeline pass leaves it.
    private func silent(_ id: String, _ s: Double) -> ChatMessage {
        var m = ChatMessage(id: id, role: .assistant, parts: [], timestamp: t0 + s, rowId: 5)
        m.silentNote = true
        return m
    }
    private func delivery(_ id: String, _ text: String, _ s: Double) -> ChatMessage {
        var m = ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: t0 + s, rowId: 4)
        m.sender = ivy
        return m
    }

    private var thread: [ChatMessage] {
        [you("u1", "Run the tests and ask Ivy", 0),
         bot("a1", "On it.", 5),
         note("n1", "Background Process Finished: npm test", 60),
         note("n2", "Model changed to gpt-5-mini", 70),
         delivery("d1", "Yes, sent Oct 3, paid Oct 9", 80),
         silent("a2", 81),
         you("u2", "thanks", 120)]
    }

    private func input(_ messages: [ChatMessage], expanded: Set<String> = []) -> ChatRowBuilder.Input {
        var input = ChatRowBuilder.Input(messages: messages, isRunning: false, botName: "Hermes", expanded: expanded)
        input.backgroundResults = ["n1": "12 passed"]
        return input
    }

    private func lines(_ rows: [ChatRow]) -> [(String, BackgroundResultRow)] {
        rows.compactMap { if case .backgroundResult(let b) = $0.kind { return ($0.id, b) } else { return nil } }
    }

    @Test func runBetweenYourMessagesIsOneLine() throws {
        let rows = ChatRowBuilder.build(input(thread))
        let found = lines(rows)
        #expect(found.count == 1)
        let (id, line) = try #require(found.first)
        #expect(id == "n1|grp")
        #expect(line.title == "From Ivy", "another bot leads, by name only: the words before the colon")
        #expect(line.group?.tail == "2 more")
        #expect(line.group?.marks.first == .face(ivy))
        #expect(!rows.contains { if case .notice = $0.kind { return true } else { return false } }, "the note is in the group")
    }

    @Test func openedGroupListsEveryMember() {
        let rows = ChatRowBuilder.build(input(thread, expanded: ["n1|grp"]))
        // [updates] One card row per member under the line, in the chat's order; your messages stay bubbles.
        #expect(lines(rows).map(\.0) == ["n1|grp"])
        let members = rows.compactMap { row -> (String, UpdateMemberRow)? in
            if case .updateMember(let m) = row.kind { return (row.id, m) } else { return nil }
        }
        #expect(members.map(\.0) == ["n1|bg|in", "n2|notice|in", "d1|dl|in"])
        #expect(members.map(\.1.first) == [true, false, false] && members.map(\.1.last) == [false, false, true])
        #expect(members.map(\.1.title) == ["npm test finished", "Model changed to gpt-5-mini", "From Ivy"])
        #expect(rows.map(\.messageId).suffix(4) == ["n1", "n2", "d1", "u2"], "each member keeps its own message")
        #expect(rows.contains { $0.id == "u2|b0" } && rows.contains { $0.id == "u1|b0" })
    }

    @Test func groupOfOneKeepsItsOwnRowAndOpensOnItsWords() throws {
        let messages = [you("u1", "go", 0), note("n1", "Background Process Finished: npm test", 60), you("u2", "ok", 90)]
        let shut = try #require(lines(ChatRowBuilder.build(input(messages))).first)
        #expect(shut.0 == "n1|bg")
        #expect(shut.1.title == "npm test finished")
        #expect(shut.1.group?.count == 1)
        #expect(shut.1.group?.opens == true)
        let open = try #require(lines(ChatRowBuilder.build(input(messages, expanded: ["n1|bg"]))).first)
        #expect(open.1.expanded)
        let layout = TextLayout.layout(ChatRowBuilder.build(input(messages, expanded: ["n1|bg"])).first { $0.id == "n1|bg" }!,
                                       width: 390, style: ChatStyle.make(category: .large))
        guard case .tool(let t) = layout.content else { Issue.record("expected a tool layout"); return }
        #expect(t.group != nil)
        #expect(t.thoughtText?.text.string == "12 passed")
    }

    /// [idle] A bot left alone for days: its updates fold into one line under one day line naming the first and last days.
    @Test func idleDaysFoldIntoOneLine() throws {
        let day = 86_400.0
        var messages = [you("u1", "go", 0), bot("a1", "Done.", 5)]
        for n in 1...4 {
            var cron = note("c\(n)", "Inbox watch", Double(n) * day)
            cron.report = "Nothing new."
            messages += [cron, silent("s\(n)", Double(n) * day + 2 * day / 3)]
        }
        let rows = ChatRowBuilder.build(input(messages))
        let ids = rows.map(\.id)
        #expect(ids.filter { $0.hasSuffix("|day") } == ["u1|day", "c1|day"], "no day line inside the run, none for a silent reply")
        #expect(lines(rows).map(\.0) == ["c1|grp"])
        #expect(lines(rows).first?.1.group?.count == 4)
        let line = try #require(rows.first { $0.id == "c1|day" })
        guard case .day(let first, _, let until) = line.kind else { Issue.record("expected a day line"); return }
        #expect(first == t0 + day && until == t0 + 4 * day)

        // Fewer Timestamps: the run starts on the reply's day, and its line still names its days.
        var fewer = input(messages)
        fewer.fewerTimes = true
        messages[1].timestamp = t0 + day - 60
        fewer.messages = messages
        #expect(ChatRowBuilder.build(fewer).contains { if case .day(_, _, let until?) = $0.kind { return $0.id == "c1|day" && until == t0 + 4 * day } else { return false } })

        // Opened, each row says its day.
        let open = ChatRowBuilder.build(input(messages, expanded: ["c1|grp"]))
        let days = open.compactMap { row -> String? in if case .updateMember(let m) = row.kind { return m.day } else { return nil } }
        #expect(days.count == 4 && Set(days).count == 4)
    }

    /// [idle] The bot's own reply on a new day ends the run: it keeps its day line and its bubble.
    @Test func aReplyOnANewDayEndsTheRun() {
        let day = 86_400.0
        let messages = [you("u1", "go", 0), note("m1", "Model changed to a", 60), note("m2", "Model changed to b", 60 + day),
                        bot("a2", "Morning report", 60 + 3 * day), note("m3", "Model changed to c", 60 + 4 * day)]
        let ids = ChatRowBuilder.build(input(messages)).map(\.id)
        #expect(ids.filter { !$0.hasPrefix("u1") } == ["m1|day", "m1|grp", "a2|day", "a2|b0", "m3|day", "m3|notice"])
    }

    @Test func aLoneNoteOnItsOwnDayStaysANote() {
        let messages = [you("u1", "go", 0), note("m1", "Model changed to a", 60), you("u2", "ok", 60 + 3 * 86_400 + 5)]
        let ids = ChatRowBuilder.build(input(messages)).map(\.id).filter { !$0.hasSuffix("|day") }
        #expect(ids == ["u1|b0", "m1|notice", "u2|b0"], "a lone note stays the note it was")
    }

    @Test func rebuildingFromTheNewestUpdateRedrawsTheLine() {
        var messages = Array(thread.prefix(5))
        var model = ChatRowModel()
        model.rebuildAll(input(messages), syncMessages: 100, oldestShown: nil)
        messages.append(note("n3", "Background Process Finished: lint", 100))
        model.rebuildNewest(input(messages), touching: ["n3"])
        #expect(Array(model.allRows.reversed()).map(\.id) == ChatRowBuilder.build(input(messages)).map(\.id))
        let line = lines(Array(model.allRows)).first { $0.0 == "n1|grp" }
        #expect(line?.1.group?.tail == "3 more")
    }

    @Test func silentRunsAndRestartNotesDrawNothing() {
        let messages = [you("u1", "go", 0), note("s1", Hydration.silentRunText, 5), note("s2", Hydration.autoContinueText, 6),
                        note("s3", "Disk watch: " + Hydration.silentRunText, 7)]
        #expect(ChatRowBuilder.build(input(messages)).map(\.id).filter { !$0.hasSuffix("|day") } == ["u1|b0"])
    }

    @Test func noCopyRowUnderTheNewestReply() {
        let rows = ChatRowBuilder.build(input([you("u1", "hi", 0), bot("a1", "Hello there", 3)]))
        #expect(!rows.contains { if case .actions = $0.kind { return true } else { return false } })
    }

    /// Only the words before the colon show; the rest leads the opened card unless the card already says it.
    @Test func linesShowTheWordsBeforeTheColon() throws {
        let messages = [you("u1", "go", 0), note("n1", "Subagent Tasks Completed: Perform actual call review", 60), you("u2", "ok", 90)]
        let rows = ChatRowBuilder.build(input(messages, expanded: ["n1|bg"]))
        let row = try #require(rows.first { $0.id == "n1|bg" })
        let layout = TextLayout.layout(row, width: 390, style: ChatStyle.make(category: .large))
        guard case .tool(let t) = layout.content else { Issue.record("expected a tool layout"); return }
        #expect(t.title == "Helpers finished")
        let opened = t.thoughtText?.text.string ?? ""
        #expect(opened.hasPrefix("Perform actual call review") && opened.hasSuffix("12 passed") && opened.count < 40)
        #expect(BackgroundResults.opened(title: "Ivy: Yes, sent", result: "Yes, sent") == "Yes, sent", "not said twice")
        #expect(BackgroundResults.split("npm test finished").head == "npm test finished")
    }

    /// Another bot's message filed as an update names the bot and opens on its words, formatted like a reply.
    @Test func aBotsMessageNamesTheBotAndOpensFormatted() throws {
        var messages = [you("u1", "go", 0), note("b1", "Background update", 60)]
        messages[1].report = "Message from 🤖 inbox (@inbox): **Fixed.**\n\n- `validation_pending` is False"
        let rows = ChatRowBuilder.build(input(messages, expanded: ["b1|bg"]))
        let row = try #require(rows.first { $0.id == "b1|bg" })
        guard case .backgroundResult(let b) = row.kind else { Issue.record("expected an update"); return }
        #expect(b.title == "From Inbox" && b.delivery)
        #expect(b.face?.name == "inbox", "the sending bot's face, not the message glyph")
        #expect(!b.result.contains("Message from"))
        guard case .tool(let t) = TextLayout.layout(row, width: 390, style: ChatStyle.make(category: .large)).content else {
            Issue.record("expected a tool layout"); return
        }
        let text = try #require(t.thoughtText?.text)
        #expect(!text.string.contains("**") && !text.string.contains("`") && text.string.contains("validation_pending"))
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        #expect((font?.pointSize ?? 0) >= ChatStyle.make(category: .large).body.pointSize - 0.5, "the reply's own size")
    }

    @Test func titlesInPlainWords() {
        #expect(BackgroundResults.plainTitle("Background Process Finished: npm test") == "npm test finished")
        #expect(BackgroundResults.plainTitle("Background task failed: npm test") == "npm test failed")
        #expect(BackgroundResults.plainTitle("Subagent Task Completed: Check the upload test") == "Helper finished: Check the upload test")
        #expect(BackgroundResults.plainTitle("Subagent Tasks Completed: Perform actual call review") == "Helpers finished: Perform actual call review")
        #expect(BackgroundResults.plainTitle("2 Background Processes Finished") == "2 background tasks finished")
    }
}
