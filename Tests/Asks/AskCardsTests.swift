// [asks] A bot's ask-to-act card (HermesKit/Asks/AskCards.swift, App/Asks): lenient parsing and its defaults, the id
// the add-on makes too, the answer messages and their bubble words, the state read back from the chat (queued answers
// too), the row and its layout, whole arguments and the add-on handshake. Made-up names only.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor
@Suite("Asks: the ask-to-act card and its answers")
struct AskCardsTests {
    var args: [String: JSONValue] {
        ["question": .string("Start with the pilot group?"), "then": .string("I'll draft the reply. Nothing gets sent."),
         "app": .string("Slack"), "from": .string("Dana Reyes"), "where": .string("DM"), "when": .string("11:03 AM"),
         "quote": .string("Ready to go live. Start with the pilot group?"),
         "attachments": .array([.object(["name": .string("Q3_Plan"), "note": .string("This is what I have so far.")])]),
         "link": .object(["title": .string("Open Dana's DM"), "url": .string("https://example.com/slack/dm")])]
    }

    func call(_ args: [String: JSONValue], id: String = "c1", state: ToolCall.State = .done) -> ToolCall {
        ToolCall(id: id, name: AskCards.tool, title: "Ask to act", argsText: ChatJSON.stringify(.object(args)), summary: nil, state: state,
                 durationSeconds: nil)
    }

    func bot(_ calls: [ToolCall], id: String = "m1") -> ChatMessage {
        ChatMessage(id: id, role: .assistant, parts: [.text("One DM needs your call.")] + calls.map { .tool($0) }, timestamp: nil, rowId: 1)
    }

    func you(_ text: String, id: String = "u1") -> ChatMessage {
        ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: nil, rowId: 2)
    }

    func ask(_ a: [String: JSONValue]? = nil) throws -> AskCards.Ask { try #require(AskCards.parse(call(a ?? args))) }

    func input(_ messages: [ChatMessage], answering: String? = nil) -> ChatRowBuilder.Input {
        var input = ChatRowBuilder.Input(messages: messages, isRunning: false, botName: "Hermes", expanded: [], now: Date(),
                                         scope: "t", modelName: nil, prompts: nil)
        input.asks = AskRowsInput(answers: AskCards.answers(messages), answering: answering)
        return input
    }

    func askRow(_ messages: [ChatMessage], answering: String? = nil) -> (ChatRow, AskCardRow)? {
        for row in ChatRowBuilder.build(input(messages, answering: answering)) {
            if case .prompt(let p) = row.kind, case .ask(let card) = p.kind { return (row, card) }
        }
        return nil
    }

    // MARK: Parsing

    @Test func aCallIsReadWhole() throws {
        let a = try ask()
        #expect(a.question == "Start with the pilot group?")
        #expect(a.then == "I'll draft the reply. Nothing gets sent.")
        #expect(a.choices == ["Yes", "No"])
        #expect(a.app == "Slack" && a.from == "Dana Reyes" && a.place == "DM" && a.when == "11:03 AM")
        #expect(a.quote == "Ready to go live. Start with the pilot group?")
        #expect(a.attachments == [AskCards.Attachment(name: "Q3_Plan", note: "This is what I have so far.")])
        #expect(a.link == AskCards.Link(title: "Open Dana's DM", url: URL(string: "https://example.com/slack/dm")!))
        #expect(AskCards.sourceDetail(a) == "Dana Reyes · DM · 11:03 AM")
        #expect(AskCards.glyph(a) == "bubble.left.circle.fill")
    }

    @Test func leftOutAndWrongValuesFallBackToDefaults() throws {
        // Only a question is needed.
        let bare = try ask(["question": .string("  Go ahead?  ")])
        #expect(bare.question == "Go ahead?")
        #expect(bare.choices == AskCards.defaultChoices)
        #expect(bare.then.isEmpty && bare.app.isEmpty && bare.quote.isEmpty && bare.attachments.isEmpty && bare.link == nil)
        #expect(AskCards.glyph(bare) == "questionmark.circle.fill")
        // One choice, blanks or repeats: Yes / No. Three distinct: kept, in order; more than three: the first three.
        #expect(AskCards.choices(.array([.string("Sure")])) == ["Yes", "No"])
        #expect(AskCards.choices(.array([.string("Sure"), .string(" "), .string("Sure")])) == ["Yes", "No"])
        #expect(AskCards.choices(.array([.string(" Now "), .string("Later"), .string("Never")])) == ["Now", "Later", "Never"])
        #expect(AskCards.choices(.array(["A", "B", "C", "D"].map { .string($0) })) == ["A", "B", "C"])
        #expect(AskCards.choices(.string("Yes")) == ["Yes", "No"])
        // A link that isn't https is left out; one without a title is named for the app.
        var a = args
        a["link"] = .object(["url": .string("http://example.com/x")])
        #expect(try ask(a).link == nil)
        a["link"] = .object(["url": .string("https://example.com/x")])
        #expect(try ask(a).link?.title == "Open in Slack")
        // At most four attachments; one without a name is left out; a bare string is a name.
        a["attachments"] = .array([.object(["note": .string("no name")]), .string("Notes.txt")] + (1...6).map { .object(["name": .string("F\($0)")]) })
        #expect(try ask(a).attachments.map(\.name) == ["Notes.txt", "F1", "F2", "F3"])
        // No question, a failed call or another tool: not a card.
        #expect(AskCards.parse(call(["then": .string("x")])) == nil)
        #expect(AskCards.parse(call(args, state: .failed)) == nil)
        var other = call(args)
        other.name = "clarify"
        #expect(AskCards.parse(other) == nil)
        var cut = call(args)
        cut.argsText = String(cut.argsText!.prefix(40))
        #expect(AskCards.parse(cut) == nil)
    }

    // MARK: The id (the add-on's Python checks against this)

    @Test func theIdIsTheAddOnsOwn() throws {
        // hashlib.sha256("Start with the pilot group?\nDana Reyes\nReady to go live. Start with the pilot group?\nYes\nNo"
        //                .encode()).hexdigest()[:8] == "9cfc6386"
        let fixed = AskCards.id(question: "Start with the pilot group?", from: "Dana Reyes",
                                quote: "Ready to go live. Start with the pilot group?", choices: ["Yes", "No"])
        #expect(fixed == "a-9cfc6386")
        #expect(try ask().id == "a-9cfc6386")   // choices defaulted before the id is made
        // Each value is trimmed; the choices count.
        var spaced = args
        spaced["question"] = .string("  Start with the pilot group?\n")
        spaced["choices"] = .array([.string(" Yes"), .string("No ")])
        #expect(try ask(spaced).id == "a-9cfc6386")
        spaced["choices"] = .array([.string("No"), .string("Yes")])
        #expect(try ask(spaced).id != "a-9cfc6386")
        // What the id leaves out (the app, where, when, then) doesn't change it.
        var moved = args
        moved["when"] = .string("Yesterday")
        moved["then"] = .string("Something else")
        #expect(try ask(moved).id == "a-9cfc6386")
    }

    // MARK: Answers

    @Test func aChoiceGoesBackNumberedAndReadsBack() throws {
        let a = try ask()
        let yes = try #require(AskCards.choiceMessage(a, index: 0))
        #expect(yes == """
        [Hermes HQ ask a-9cfc6386: 1]
        Yes.
        (Your question was: "Start with the pilot group?" Go on as you said: I'll draft the reply. Nothing gets sent.)
        """)
        #expect(AskCards.answer(in: yes)?.id == "a-9cfc6386")
        #expect(AskCards.answer(in: yes)?.answer == .choice(1, "Yes."))
        let no = try #require(AskCards.choiceMessage(a, index: 1))
        #expect(no.hasPrefix("[Hermes HQ ask a-9cfc6386: 2]\nNo.\n"))
        #expect(AskCards.choiceMessage(a, index: 2) == nil)
        // A choice that ends in its own mark keeps it; without `then` the line just names the question.
        #expect(AskCards.sentence("Really?") == "Really?" && AskCards.sentence("Not yet") == "Not yet.")
        var bare = args
        bare["then"] = nil
        bare["choices"] = .array([.string("Now"), .string("Later"), .string("Wait!")])
        let threeChoices = try ask(bare)
        let third = try #require(AskCards.choiceMessage(threeChoices, index: 2))
        #expect(third.hasSuffix(": 3]\nWait!\n(Your question was: \"Start with the pilot group?\")"))
    }

    @Test func somethingElseGoesBackAsYourWords() throws {
        let a = try ask()
        let other = AskCards.otherMessage(a, text: "  Only the two team leads first.\n")
        #expect(other == "[Hermes HQ ask a-9cfc6386: other]\nOnly the two team leads first.\n(Your question was: \"Start with the pilot group?\")")
        #expect(AskCards.answer(in: other)?.answer == .other("Only the two team leads first."))
        #expect(AskCards.bubbleWords(other) == "Only the two team leads first.")
        #expect(AskCards.status(a, .other("Only the two team leads first.")) == "You answered: Only the two team leads first.")
        // Several lines typed: the bubble shows the first.
        let lines = AskCards.otherMessage(a, text: "Leads first.\nThen everyone.")
        #expect(AskCards.bubbleWords(lines) == "Leads first.")
    }

    @Test func bubbleWordsAreTheChoice() throws {
        let a = try ask()
        let yes = try #require(AskCards.choiceMessage(a, index: 0))
        #expect(AskCards.bubbleWords(yes) == "Yes")
        let no = try #require(AskCards.choiceMessage(a, index: 1))
        #expect(AskCards.bubbleWords(no) == "No")
        #expect(AskCards.bubbleWords("Yes, start with the pilot group") == nil)
        #expect(AskCards.bubbleWords("Please [Hermes HQ ask a-9cfc6386: 1]") == nil)   // only a first line is an answer
        #expect(AskCards.bubbleWords("[Hermes HQ ask a-9cfc6386: 4]\nFour.") == nil)   // 1…3 only
        #expect(AskCards.bubbleWords("[Hermes HQ ask a-9cfc6386: 2]") == "Choice 2")
        #expect(AskCards.status(a, .choice(1, "Yes.")) == "You answered: Yes")
        // The queue shows the same short words; an adjacent answer echo is suppressed because the card right above
        // already shows the choice, while a non-adjacent answer still draws the short user bubble.
        #expect(ChatQueueCard.rowText(QueuedMessage(id: "q1", text: yes, display: yes)).text == "Yes")
        let adjacent = ChatRowBuilder.build(input([bot([call(args)]), you(yes)]))
        #expect(!adjacent.contains { if case .bubble(let b) = $0.kind { return b.mine && b.text == "Yes" } else { return false } })
        let nonAdjacent = ChatRowBuilder.build(input([
            bot([call(args)]),
            you("One quick check first.", id: "u0"),
            ChatMessage(id: "m2", role: .assistant, parts: [.text("Sure, go ahead.")], timestamp: nil, rowId: 3),
            you(yes),
        ]))
        #expect(nonAdjacent.contains { if case .bubble(let b) = $0.kind { return b.mine && b.text == "Yes" } else { return false } })
    }

    @Test func theStateIsReadFromTheChatAndTheQueue() throws {
        let a = try ask()
        let card = bot([call(args)])
        let yes = try #require(AskCards.choiceMessage(a, index: 0)), no = try #require(AskCards.choiceMessage(a, index: 1))
        #expect(AskCards.answers([card]).isEmpty)
        #expect(AskCards.answers([card, you(yes)]) == [a.id: .choice(1, "Yes.")])
        // The newest answer wins.
        #expect(AskCards.answers([card, you(yes), you(no, id: "u2")]) == [a.id: .choice(2, "No.")])
        // An answer still waiting behind a running reply counts (it is newer).
        #expect(AskCards.answers([card, you(yes)], queued: [AskCards.otherMessage(a, text: "Wait")]) == [a.id: .other("Wait")])
        // A bot's own words that look like an answer are not one.
        let botSays = ChatMessage(id: "m9", role: .assistant, parts: [.text(yes)], timestamp: nil, rowId: 9)
        #expect(AskCards.answers([card, botSays]).isEmpty)
    }

    // MARK: The row and its layout

    @Test func theChatDrawsTheCardWithItsChoices() throws {
        let (row, card) = try #require(askRow([bot([call(args)])]))
        #expect(row.id == "m1|askc1")
        #expect(card.waiting && !card.answering)
        #expect(!ChatRowBuilder.build(input([bot([call(args)])])).contains { if case .toolRun = $0.kind { return true } else { return false } })
        let made = AskCardLayout.make(card, gap: 6, width: 402, category: .large)
        guard case .prompt(let layout) = made.content, let g = layout.ask else { Issue.record("layout"); return }
        let frame = try #require(layout.cardFrame)
        #expect(g.buttons.map(\.0) == [0, 1] && !g.stacked)
        #expect(g.buttons.allSatisfy { frame.contains($0.1) && $0.1.height >= 44 })
        #expect(g.buttons[0].1.minX < g.buttons[1].1.minX && g.buttons[0].1.width == g.buttons[1].1.width)
        #expect(g.other != nil && g.link != nil && g.quote != nil && g.chips.count == 1)
        #expect(g.linkTitle == "Open Dana's DM ↗")
        #expect(layout.accessibility.contains("Start with the pilot group?") && layout.accessibility.contains("Q3_Plan"))
        // Nothing past the card's bottom.
        #expect(layout.texts.allSatisfy { $0.frame.maxY <= frame.maxY + 0.5 })
        // At accessibility sizes the choices stack, the bot's pick on top.
        let big = AskCardLayout.make(card, gap: 6, width: 402, category: .accessibilityExtraLarge)
        guard case .prompt(let bl) = big.content, let bg = bl.ask else { Issue.record("big"); return }
        #expect(bg.stacked && bg.buttons[0].1.minY < bg.buttons[1].1.minY)
        // While its strip is open the buttons wait.
        let (_, open) = try #require(askRow([bot([call(args)])], answering: "a-9cfc6386"))
        #expect(open.answering)
        guard case .prompt(let ol) = AskCardLayout.make(open, gap: 6, width: 402, category: .large).content else { return }
        #expect(ol.ask?.disabled == true)
    }

    @Test func anAnsweredCardSaysWhatYouChose() throws {
        let a = try ask()
        let no = try #require(AskCards.choiceMessage(a, index: 1))
        let (_, card) = try #require(askRow([bot([call(args)]), you(no)]))
        #expect(card.answer == .choice(2, "No.") && !card.waiting)
        let made = AskCardLayout.make(card, gap: 6, width: 402, category: .large)
        guard case .prompt(let layout) = made.content, let g = layout.ask else { Issue.record("layout"); return }
        #expect(g.buttons.isEmpty && g.other == nil)
        #expect(layout.accessibility.hasSuffix("You answered: No"))
        // The row changes with its state (the fingerprint), so the cell draws it again.
        let (waitingRow, _) = try #require(askRow([bot([call(args)])]))
        let (answeredRow, _) = try #require(askRow([bot([call(args)]), you(no)]))
        #expect(waitingRow.fingerprint != answeredRow.fingerprint)
    }

    // MARK: Whole arguments and the add-on

    @Test func askCallsKeepTheirWholeArguments() throws {
        var long = args
        long["quote"] = .string(String(repeating: "Their words run on. ", count: 100))
        let whole = try #require(AskCards.wholeArgsText(name: AskCards.tool, args: long))
        #expect(whole.utf8.count > 1500)
        #expect(AskCards.wholeArgsText(name: "web_search", args: long) == nil)
        #expect(AskCards.wholeArgsText(name: AskCards.tool, args: [:]) == nil)
        // A saved chat keeps them (cut, the card would draw as a plain step).
        let message = ChatMessage(id: "m1", role: .assistant, parts: [.tool(call(long))], timestamp: nil, rowId: 1)
        let kept = TranscriptCache.withoutToolDetails(TranscriptEntry(messages: [message], meta: [:], savedAt: Date()))
        guard case .tool(let card) = kept.messages[0].parts[0] else { Issue.record("parts"); return }
        #expect(AskCards.parse(card) != nil)
    }

    // MARK: v2: a ready reply per choice

    let yesReply = "Yes — let's start with the pilot group. Once they're through it we'll open it to everyone."

    var replyArgs: [String: JSONValue] {
        var a = args
        a["replies"] = .array([.string("  \(yesReply)\n"), .string("")])
        a["reply_to"] = .object(["app": .string("Slack"), "to": .string("Dana Reyes")])
        return a
    }

    func rows(_ messages: [ChatMessage], picked: Int? = nil, edit: String? = nil, editing: Bool = false) -> AskCardRow? {
        var i = input(messages)
        if let picked { i.asks.picked["a-9cfc6386"] = picked }
        if let edit, let picked { i.asks.edits[AskRowsInput.editKey("a-9cfc6386", picked)] = edit }
        if editing { i.asks.editingReply = "a-9cfc6386" }
        for row in ChatRowBuilder.build(i) {
            if case .prompt(let p) = row.kind, case .ask(let card) = p.kind { return card }
        }
        return nil
    }

    @Test func repliesAndWhereTheyGoAreRead() throws {
        let a = try ask(replyArgs)
        #expect(a.id == "a-9cfc6386")   // replies aren't part of the id
        #expect(a.replies == [yesReply, ""])
        #expect(a.replyTo == AskCards.ReplyTo(app: "Slack", to: "Dana Reyes"))
        #expect(AskCards.reply(a, index: 0) == yesReply)
        #expect(AskCards.reply(a, index: 1) == nil && AskCards.reply(a, index: 2) == nil)
        #expect(AskCards.replyHeading(a.replyTo!) == "Reply to Dana Reyes · Slack")
        #expect(AskCards.replyHeading(AskCards.ReplyTo(app: "Email")) == "Reply on Email")
        #expect(AskCards.replySpoken(a.replyTo!, "Hi") == "Reply to Dana Reyes on Slack: Hi")
        // Subject and from are kept; without reply_to.app the ask's own app stands in.
        var full = replyArgs
        full["reply_to"] = .object(["to": .string("dana@example.com"), "subject": .string("Q3 plan"), "from": .string("me@example.com")])
        #expect(try ask(full).replyTo == AskCards.ReplyTo(app: "Slack", to: "dana@example.com", subject: "Q3 plan", from: "me@example.com"))
    }

    @Test func mismatchedOrEmptyRepliesAreIgnored() throws {
        // One reply for two choices: no reply blocks at all.
        var short = replyArgs
        short["replies"] = .array([.string(yesReply)])
        let s = try ask(short)
        #expect(s.replies.isEmpty && s.replyTo == nil && AskCards.reply(s, index: 0) == nil)
        // Three for two, too.
        short["replies"] = .array([.string("a"), .string("b"), .string("c")])
        #expect(try ask(short).replies.isEmpty)
        // All blank: none.
        short["replies"] = .array([.string(" "), .string("")])
        #expect(try ask(short).replies.isEmpty)
        // No app anywhere: nowhere to send them.
        var nowhere = replyArgs
        nowhere["app"] = nil
        nowhere["reply_to"] = .object(["to": .string("Dana Reyes")])
        #expect(try ask(nowhere).replies.isEmpty)
        // A reply past the limit is left out (the other stays).
        var long = replyArgs
        long["replies"] = .array([.string(String(repeating: "x", count: AskCards.maxReply + 1)), .string("Not yet.")])
        let l = try ask(long)
        #expect(AskCards.reply(l, index: 0) == nil && AskCards.reply(l, index: 1) == "Not yet.")
        // Their row draws plain v1 buttons: a tap answers at once.
        let (_, card) = try #require(askRow([bot([call(short)])]))
        #expect(card.picked == nil && card.reply == nil)
    }

    @Test func sendCarriesTheChoiceAndTheReplyExactly() throws {
        let a = try ask(replyArgs)
        let send = try #require(AskCards.sendMessage(a, index: 0, reply: yesReply))
        #expect(send == """
        [Hermes HQ ask a-9cfc6386: 1 send]
        Yes. Send this to Dana Reyes (Slack) exactly as written:

        \(yesReply)
        """)
        // A choice without a reply has no Send.
        #expect(AskCards.sendMessage(a, index: 1, reply: "x") == nil)
        // Subject, from, and nobody named.
        var full = replyArgs
        full["reply_to"] = .object(["app": .string("Email"), "to": .string("dana@example.com"), "subject": .string("Q3 plan"),
                                    "from": .string("me@example.com")])
        let mail = try #require(AskCards.sendMessage(try ask(full), index: 0, reply: yesReply))
        #expect(mail == "[Hermes HQ ask a-9cfc6386: 1 send]\nYes. Send this to dana@example.com (Email) from me@example.com exactly as written:\n"
                + "Subject: Q3 plan\n\n" + yesReply)
        var nobody = replyArgs
        nobody["reply_to"] = .object(["app": .string("Slack")])
        let on = try #require(AskCards.sendMessage(try ask(nobody), index: 0, reply: yesReply))
        #expect(on.hasPrefix("[Hermes HQ ask a-9cfc6386: 1 send]\nYes. Send this on Slack exactly as written:\n\n"))
    }

    @Test func anEditedReplySaysSo() throws {
        let a = try ask(replyArgs)
        let edited = "Yes, pilot group first. Everyone else after."
        let send = try #require(AskCards.sendMessage(a, index: 0, reply: "  \(edited)\n"))
        #expect(send == "[Hermes HQ ask a-9cfc6386: 1 send]\nI edited it. Yes. Send this to Dana Reyes (Slack) exactly as written:\n\n" + edited)
        #expect(AskCards.answer(in: send)?.answer == .sent(1, "Yes.", reply: edited))
        #expect(AskCards.bubbleWords(send) == "Yes · Send it with my edits")
        // Unchanged words (spaces aside) aren't an edit.
        let same = try #require(AskCards.sendMessage(a, index: 0, reply: yesReply + "  "))
        #expect(!same.contains("I edited it."))
    }

    @Test func theMarkReadsWithAndWithoutSend() throws {
        let a = try ask(replyArgs)
        let send = try #require(AskCards.sendMessage(a, index: 0, reply: yesReply))
        let found = try #require(AskCards.answer(in: send))
        #expect(found.id == "a-9cfc6386" && found.answer == .sent(1, "Yes.", reply: yesReply))
        #expect(AskCards.answer(in: "  [Hermes HQ ask a-9cfc6386: 2 send]\nNo. Send this on Slack exactly as written:\n\nNot yet.")?.answer
                == .sent(2, "No.", reply: "Not yet."))
        // Without " send": v1's plain answer, unchanged.
        let plain = try #require(AskCards.choiceMessage(a, index: 0))
        #expect(AskCards.answer(in: plain)?.answer == .choice(1, "Yes."))
        // A send mark without a reply after it still names the card.
        #expect(AskCards.answer(in: "[Hermes HQ ask a-9cfc6386: 1 send]")?.answer == .sent(1, "", reply: ""))
        // Anything else in the brackets isn't an answer.
        #expect(AskCards.answer(in: "[Hermes HQ ask a-9cfc6386: 1 sent]") == nil)
        #expect(AskCards.answer(in: "[Hermes HQ ask a-9cfc6386: 1send]") == nil)
        #expect(AskCards.answer(in: "[Hermes HQ ask a-9cfc6386: 4 send]") == nil)
        #expect(AskCards.answer(in: "[Hermes HQ ask a-9cfc6386: other send]\nHi") == nil)   // only a choice carries a reply
        #expect(AskCards.answer(in: "[Hermes HQ ask a-9cfc6386: other]\nHi")?.answer == .other("Hi"))
    }

    @Test func answersCountSendsAndTheNewestWins() throws {
        let a = try ask(replyArgs)
        let card = bot([call(replyArgs)])
        let send = try #require(AskCards.sendMessage(a, index: 0, reply: yesReply))
        let no = try #require(AskCards.choiceMessage(a, index: 1))
        #expect(AskCards.answers([card, you(send)]) == [a.id: .sent(1, "Yes.", reply: yesReply)])
        #expect(AskCards.answers([card, you(send), you(no, id: "u2")]) == [a.id: .choice(2, "No.")])
        #expect(AskCards.answers([card, you(no)], queued: [send]) == [a.id: .sent(1, "Yes.", reply: yesReply)])
    }

    @Test func bubbleWordsAndStatusForASend() throws {
        let a = try ask(replyArgs)
        let send = try #require(AskCards.sendMessage(a, index: 0, reply: yesReply))
        #expect(AskCards.bubbleWords(send) == "Yes · Send the reply")
        #expect(AskCards.status(a, .sent(1, "Yes.", reply: yesReply)) == "You answered: Yes · Reply approved")
        #expect(AskCards.status(a, .choice(1, "Yes.")) == "You answered: Yes")   // v1
        // The queue reads the same; an adjacent echo is omitted while a non-adjacent one still draws the short bubble.
        #expect(ChatQueueCard.rowText(QueuedMessage(id: "q1", text: send, display: send)).text == "Yes · Send the reply")
        let adjacent = ChatRowBuilder.build(input([bot([call(replyArgs)]), you(send)]))
        #expect(!adjacent.contains { if case .bubble(let b) = $0.kind { return b.mine && b.text == "Yes · Send the reply" } else { return false } })
        let nonAdjacent = ChatRowBuilder.build(input([
            bot([call(replyArgs)]),
            you("Quick check first.", id: "u0"),
            ChatMessage(id: "m2", role: .assistant, parts: [.text("All clear.")], timestamp: nil, rowId: 3),
            you(send),
        ]))
        #expect(nonAdjacent.contains { if case .bubble(let b) = $0.kind { return b.mine && b.text == "Yes · Send the reply" } else { return false } })
    }

    @Test func pickingShowsTheReplyBlock() throws {
        let messages = [bot([call(replyArgs)])]
        // Nothing picked: v1's buttons, no reply block.
        let plain = try #require(rows(messages))
        #expect(plain.picked == nil && plain.reply == nil)
        guard case .prompt(let pl) = AskCardLayout.make(plain, gap: 6, width: 402, category: .large).content, let pg = pl.ask else { Issue.record("plain"); return }
        #expect(pg.paper == nil && pg.replyButtons.isEmpty && pg.picked == nil)
        // Yes picked: its reply on the panel, Send and Edit under it, the choices still there.
        let card = try #require(rows(messages, picked: 0))
        #expect(card.picked == 0 && card.reply == yesReply && !card.edited && card.waiting)
        let made = AskCardLayout.make(card, gap: 6, width: 402, category: .large)
        guard case .prompt(let layout) = made.content, let g = layout.ask else { Issue.record("layout"); return }
        let frame = try #require(layout.cardFrame)
        let paper = try #require(g.paper)
        #expect(g.picked == 0 && g.buttons.count == 2 && g.other != nil)
        #expect(Set(g.replyButtons.map(\.0)) == [.send, .edit] && !g.replyStacked)
        let sendFrame = try #require(g.replyButtons.first { $0.0 == .send }?.1), editFrame = try #require(g.replyButtons.first { $0.0 == .edit }?.1)
        #expect(editFrame.maxX < sendFrame.minX && sendFrame.height >= 44)
        #expect(g.buttons.allSatisfy { $0.1.maxY < paper.minY } && paper.maxY <= sendFrame.minY && sendFrame.maxY < g.other!.midY)
        #expect(frame.contains(paper) && frame.contains(sendFrame))
        #expect(layout.texts.contains { $0.text.text.string == "Reply to Dana Reyes · Slack" })
        #expect(layout.texts.contains { $0.text.text.string == yesReply && paper.contains($0.frame) })
        #expect(layout.texts.allSatisfy { $0.frame.maxY <= frame.maxY + 0.5 })
        #expect(layout.accessibility.contains("Reply to Dana Reyes on Slack: \(yesReply)"))
        // Picking No (no reply) doesn't show a block; a picked choice that has none is left out.
        let none = try #require(rows(messages, picked: 1))
        #expect(none.picked == nil && none.reply == nil)
        // Your edit shows, and the header says so; while it is in the message field the buttons wait.
        let edited = try #require(rows(messages, picked: 0, edit: "Pilot group first.", editing: true))
        #expect(edited.reply == "Pilot group first." && edited.edited && edited.editingReply)
        guard case .prompt(let el) = AskCardLayout.make(edited, gap: 6, width: 402, category: .large).content, let eg = el.ask else { return }
        #expect(eg.disabled && el.texts.contains { $0.text.text.string == "Reply to Dana Reyes · Slack · Edited" })
        // The row changes with the pick and the edit (the cell draws it again).
        let (r0, _) = try #require(askRow(messages))
        var i = input(messages)
        i.asks.picked["a-9cfc6386"] = 0
        let r1 = try #require(ChatRowBuilder.build(i).first { $0.id == r0.id })
        #expect(r0.fingerprint != r1.fingerprint)
        // At accessibility sizes Send and Edit stack, Send on top, inside the card.
        let big = AskCardLayout.make(card, gap: 6, width: 402, category: .accessibilityExtraExtraExtraLarge)
        guard case .prompt(let bl) = big.content, let bg = bl.ask, let bf = bl.cardFrame else { Issue.record("big"); return }
        let bs = try #require(bg.replyButtons.first { $0.0 == .send }?.1), be = try #require(bg.replyButtons.first { $0.0 == .edit }?.1)
        #expect(bg.replyStacked && bs.minY < be.minY && bf.contains(be))
        #expect(bl.texts.allSatisfy { $0.frame.maxY <= bf.maxY + 0.5 })
    }

    @Test func aSentCardShowsTheReplyQuietly() throws {
        let a = try ask(replyArgs)
        let long = (1...12).map { "Line \($0) of the reply runs on for a while so it wraps." }.joined(separator: " ")
        let send = try #require(AskCards.sendMessage(a, index: 0, reply: long))
        let card = try #require(rows([bot([call(replyArgs)]), you(send)], picked: 0))
        #expect(card.answer == .sent(1, "Yes.", reply: long) && card.picked == nil && card.reply == nil)
        let made = AskCardLayout.make(card, gap: 6, width: 402, category: .large)
        guard case .prompt(let layout) = made.content, let g = layout.ask else { Issue.record("layout"); return }
        #expect(g.buttons.isEmpty && g.replyButtons.isEmpty && g.paper == nil && g.other == nil)
        #expect(layout.texts.contains { $0.text.text.string == "You answered: Yes · Reply approved" })
        let shown = try #require(layout.texts.first { $0.text.text.string.hasPrefix("Line 1 of the reply") })
        #expect(PromptLayout.lineCount(shown.text) <= PromptRows.askSentLines)
    }

    // MARK: v2: a stored chat (a scheduled job's report, drawn from history)

    @Test func aStoredAskCallHydratesWhole() throws {
        // A job's turn as the gateway stores it: the assistant row with its `tool_calls` (arguments as a JSON string),
        // the tool's own result row, then the bot's words.
        // Long enough that the 4 KB every other call keeps would clip the quote and the replies (1,024 characters each).
        let quote = String(repeating: "Their words run on. ", count: 99).trimmingCharacters(in: .whitespaces)
        let longNo = String(repeating: "Not yet: the pilot group needs another week. ", count: 70).trimmingCharacters(in: .whitespaces)
        var stored = replyArgs
        stored["quote"] = .string(quote)
        stored["replies"] = .array([.string(yesReply), .string(longNo)])
        stored["attachments"] = .array((1...4).map { .object(["name": .string("File\($0)"), "note": .string(String(repeating: "n", count: 150))]) })
        let argsJSON = ChatJSON.stringify(.object(stored))
        #expect(argsJSON.utf8.count > ToolArgs.maxBytes)
        let rows: [JSONValue] = [
            ["role": "user", "content": "[Scheduled job] Check Slack", "id": 1, "timestamp": 10],
            ["role": "assistant", "content": "One DM needs your call.", "id": 2, "timestamp": 11,
             "tool_calls": [["id": "call-ask-1", "type": "function", "function": ["name": .string(AskCards.tool), "arguments": .string(argsJSON)]]]],
            ["role": "tool", "tool_call_id": "call-ask-1", "tool_name": .string(AskCards.tool), "id": 3, "timestamp": 12,
             "content": "{\"ask\": \"waiting\", \"id\": \"a-9cfc6386\", \"note\": \"Waiting for the person.\"}"],
            ["role": "assistant", "content": "Waiting on you.", "id": 4, "timestamp": 13],
        ]
        let folded = Hydration.fold(rows, pageSeq: 1)
        let reply = try #require(folded.messages.last)
        let calls = reply.parts.compactMap { if case .tool(let c) = $0 { return c } else { return nil } }
        let toolCall = try #require(calls.first { $0.name == AskCards.tool })
        #expect(toolCall.id == "call-ask-1" && toolCall.state == .done)
        let a = try #require(AskCards.parse(toolCall))
        #expect(a.id == AskCards.id(question: "Start with the pilot group?", from: "Dana Reyes", quote: quote, choices: ["Yes", "No"]))
        #expect(a.quote == quote)
        #expect(a.replies == [yesReply, longNo] && a.replyTo == AskCards.ReplyTo(app: "Slack", to: "Dana Reyes"))
        #expect(a.attachments.count == 4 && a.link != nil)
        // And the chat draws it as the card.
        let (_, card) = try #require(askRow(folded.messages))
        #expect(card.ask == a)
    }

    @Test func theAddOnIsToldOnceItOffersTheTool() {
        #expect(AskCards.cardsUntold(["actCards": true, "actCardsShown": false]))
        #expect(AskCards.cardsUntold(["actCards": true]))
        #expect(!AskCards.cardsUntold(["actCards": true, "actCardsShown": true]))
        #expect(!AskCards.cardsUntold(["actCards": false]))
        // `askCards` is the add-on's older clarify note (0.9.12), on every add-on since: it never means ask_to_act.
        #expect(!AskCards.cardsUntold(["askCards": true, "askCardsShown": false]))
        #expect(!AskCards.cardsUntold(["draftCards": true, "shoppingCards": true]))
        #expect(!AskCards.cardsUntold(nil))
        #expect(AskCards.cardsPath == "/asks/cards")
        #expect(PushPolicy.actCardsKnown(["actCards": false]))
        #expect(!PushPolicy.actCardsKnown(["askCards": true]))
    }

    // MARK: Calm chat readability ([calm-chat])

    @Test func staleUnansweredAskFoldsQuietlyAndDropsLiveButtons() throws {
        let messages = [bot([call(args)]), you("Let's hold off and check Friday instead.", id: "u2")]
        let (_, card) = try #require(askRow(messages))
        #expect(card.stale && !card.waiting && card.isQuietFolded)
        let collapsed = AskCardLayout.make(card, gap: 6, width: 402, category: .large)
        guard case .prompt(let cl) = collapsed.content, let cg = cl.ask else { Issue.record("collapsed"); return }
        #expect(cl.cardFrame == nil && cg.buttons.isEmpty && cg.other == nil && cg.toggleFrame != nil)
        #expect(cl.accessibility.contains("Unanswered"))
        #expect(collapsed.height < 56)

        var opened = card
        opened.expanded = true
        let expanded = AskCardLayout.make(opened, gap: 6, width: 402, category: .large)
        guard case .prompt(let el) = expanded.content, let eg = el.ask else { Issue.record("expanded"); return }
        #expect(el.cardFrame != nil && eg.buttons.isEmpty && eg.other == nil && eg.toggleExpanded)
        #expect(expanded.height > collapsed.height)

        // A newer ask card also retires an earlier unanswered ask while staying live itself.
        var newerArgs = args
        newerArgs["question"] = .string("Share the draft with #design instead?")
        let twoAsks = ChatRowBuilder.build(input([bot([call(args, id: "c1")], id: "m1"), bot([call(newerArgs, id: "c2")], id: "m2")]))
        let cards = twoAsks.compactMap { row -> AskCardRow? in
            if case .prompt(let p) = row.kind, case .ask(let a) = p.kind { return a }
            return nil
        }
        #expect(cards.map(\.stale) == [true, false])
        #expect(cards.map(\.waiting) == [false, true])
    }

    @Test func answeredAskRendersCompactExpandableReceipt() throws {
        let a = try ask(replyArgs)
        let send = try #require(AskCards.sendMessage(a, index: 0, reply: yesReply))
        let messages = [bot([call(replyArgs)]), you(send)]
        let (_, collapsedCard) = try #require(askRow(messages))
        #expect(collapsedCard.answer != nil && !collapsedCard.expanded)
        let collapsed = AskCardLayout.make(collapsedCard, gap: 6, width: 402, category: .large)
        guard case .prompt(let cl) = collapsed.content, let cg = cl.ask else { Issue.record("collapsed"); return }
        #expect(cl.cardFrame != nil && cg.buttons.isEmpty && cg.toggleFrame != nil && !cg.toggleExpanded)
        #expect(cg.bodyBar != nil && !cg.bodyBarTint)

        var expandedCard = collapsedCard
        expandedCard.expanded = true
        let expanded = AskCardLayout.make(expandedCard, gap: 6, width: 402, category: .large)
        guard case .prompt(let el) = expanded.content, let eg = el.ask else { Issue.record("expanded"); return }
        #expect(el.cardFrame != nil && eg.buttons.isEmpty && eg.toggleExpanded)
        #expect(expanded.height > collapsed.height)
    }

    @Test func askReadyBoilerplateSuppressedWhileRealProseKept() {
        let boilerplate = ChatMessage(id: "m1", role: .assistant, parts: [.tool(call(args)), .text("Let me know how you'd like to proceed.")], timestamp: nil, rowId: 1)
        let boilerRows = ChatRowBuilder.build(input([boilerplate]))
        #expect(!boilerRows.contains { if case .bubble = $0.kind { return true } else { return false } })

        let commentary = ChatMessage(id: "m2", role: .assistant, parts: [.tool(call(args)), .text("Dana mentioned the client wants this before noon.")], timestamp: nil, rowId: 2)
        let proseRows = ChatRowBuilder.build(input([commentary]))
        #expect(proseRows.contains { if case .bubble(let b) = $0.kind { return b.text.contains("before noon") } else { return false } })
    }

    @Test func partialRebuildFoldsStaleAskLive() throws {
        let m1 = bot([call(args)], id: "m1")
        let u2 = you("Let's pause that for now.", id: "u2")
        var model = ChatRowModel()
        model.rebuildAll(input([m1]), syncMessages: 160, oldestShown: nil)
        model.rebuildNewest(input([m1, u2]), touching: ["u2"])
        let held = Array(model.allRows.reversed())
        let full = ChatRowBuilder.build(input([m1, u2]))
        #expect(held.map(\.id) == full.map(\.id))
        for i in held.indices { #expect(ChatRowDiff.same(held[i], full[i])) }
        let askCard = held.compactMap { row -> AskCardRow? in
            if case .prompt(let p) = row.kind, case .ask(let a) = p.kind { return a }
            return nil
        }.first
        #expect(askCard?.stale == true)
    }
}
