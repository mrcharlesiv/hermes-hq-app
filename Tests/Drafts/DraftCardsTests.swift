// [drafts] A bot's draft for review (HermesKit/Drafts/DraftCards.swift, App/Questions/PromptRows.swift): the id the
// add-on makes too, the answer messages, the card's row in each state and its layout.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor
@Suite("Drafts: the card, its answers and its layout")
struct DraftCardsTests {
    let body = "Hi Dana, the Q3 numbers are in the shared folder. Can we meet Thursday at 2 to go through them?"

    func call(app: String = "Slack", to: String? = "#finance", subject: String? = nil, body: String? = nil,
              state: ToolCall.State = .done, name: String = DraftCards.tool) -> ToolCall {
        var args: [String: JSONValue] = ["app": .string(app), "body": .string(body ?? self.body)]
        if let to { args["to"] = .string(to) }
        if let subject { args["subject"] = .string(subject) }
        return ToolCall(id: "c1", name: name, title: name, argsText: ChatJSON.stringify(.object(args)), summary: nil, state: state,
                        durationSeconds: nil)
    }

    func bot(_ call: ToolCall) -> ChatMessage {
        ChatMessage(id: "m1", role: .assistant, parts: [.tool(call), .text("The draft is ready.")], timestamp: nil, rowId: 1)
    }

    func you(_ text: String, id: String = "m2") -> ChatMessage {
        ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: nil, rowId: 2)
    }

    func input(_ messages: [ChatMessage], edits: [String: String] = [:], editing: String? = nil, expanded: Set<String> = []) -> ChatRowBuilder.Input {
        var input = ChatRowBuilder.Input(messages: messages, isRunning: false, botName: "Hermes", expanded: expanded, now: Date(),
                                         scope: "t", modelName: nil, prompts: nil)
        input.drafts = DraftRowsInput(answers: DraftCards.answers(messages), edits: edits, editing: editing)
        return input
    }

    func card(_ messages: [ChatMessage], edits: [String: String] = [:], editing: String? = nil, expanded: Set<String> = []) -> DraftCardRow? {
        guard let first = messages.first, case .tool(let call)? = first.parts.first,
              let row = PromptRows.draftRow(call, message: first, input: input(messages, edits: edits, editing: editing, expanded: expanded)),
              case .prompt(let prompt) = row.kind, case .draft(let card) = prompt.kind else { return nil }
        return card
    }

    // MARK: The call

    @Test func theIdIsTheAddOnsOwn() throws {
        // hermes-hq-push test_drafts.py holds the same value (drafts.draft_id).
        #expect(DraftCards.id(app: "Slack", to: "#finance", subject: "", body: body) == "d-0629889e")
        let draft = try #require(DraftCards.draft(call(body: "  " + body + "\n")))
        #expect(draft.id == "d-0629889e")
        #expect(draft.body == body)
        #expect(DraftCards.draft(call(subject: "Q3"))?.id != draft.id)
    }

    @Test func onlyAWholeDraftCallIsACard() {
        #expect(DraftCards.draft(call(name: "send_message")) == nil)
        #expect(DraftCards.draft(call(state: .failed)) == nil)
        #expect(DraftCards.draft(call(body: "   ")) == nil)
        #expect(DraftCards.draft(call(app: "")) == nil)
        #expect(DraftCards.draft(call(state: .running)) != nil)
        var cut = call()
        cut.argsText = String(cut.argsText!.prefix(40))
        #expect(DraftCards.draft(cut) == nil)
        cut.argsText = nil
        #expect(DraftCards.draft(cut) == nil)
    }

    @Test func aDraftCallKeepsItsWholeArguments() throws {
        let long = String(repeating: "A long line of the message. ", count: 400)   // ~11 KB, past every other call's 4 KB
        let text = try #require(DraftCards.wholeArgsText(name: DraftCards.tool, args: ["app": .string("Email"), "body": .string(long)]))
        #expect(text.utf8.count > ToolArgs.maxBytes)
        #expect(ChatJSON.parse(string: text)?.object?["body"]?.string == long)
        #expect(DraftCards.wholeArgsText(name: "terminal", args: ["command": .string("ls")]) == nil)
        #expect(DraftCards.wholeArgsText(name: DraftCards.tool, args: [:]) == nil)
        let huge = String(repeating: "x", count: DraftCards.maxArgsBytes)
        #expect(DraftCards.wholeArgsText(name: DraftCards.tool, args: ["app": .string("Email"), "body": .string(huge)]) == nil)
    }

    @Test func theHeadingNamesWhereItGoes() throws {
        let slack = try #require(DraftCards.draft(call()))
        #expect(DraftCards.heading(slack) == "Slack draft")
        #expect(DraftCards.fields(slack) == [DraftCards.Field(label: "To", value: "#finance")])
        #expect(DraftCards.fields(try #require(DraftCards.draft(call(to: nil)))).isEmpty)
    }

    /// Owner 2026-11-09, build 912: a bot wrote `app` as "Email — from alex@example.com", and the card's one
    /// header line wrapped over the subject. The header is a letter's now: To, From, Subject on their own lines.
    @Test func whatABotAddsToTheAppBecomesItsOwnLine() throws {
        func parts(_ app: String) -> [String] { let p = DraftCards.split(app: app); return [p.name, p.from, p.via] }
        #expect(parts("Email — from me@example.com") == ["Email", "me@example.com", ""])
        #expect(parts("Email from me@example.com") == ["Email", "me@example.com", ""])
        #expect(parts("Slack (Acme workspace)") == ["Slack", "", "Acme workspace"])
        #expect(parts("Slack") == ["Slack", "", ""])
        #expect(parts("X") == ["X", "", ""])
        let args: [String: JSONValue] = ["app": "Email — from me@example.com", "to": "dana@example.com", "subject": "Q3", "body": .string(body)]
        let tool = ToolCall(id: "c9", name: DraftCards.tool, title: "Draft", argsText: ChatJSON.stringify(.object(args)), summary: nil, state: .done, durationSeconds: nil)
        let mail = try #require(DraftCards.draft(tool))
        #expect(DraftCards.heading(mail) == "Email draft")
        #expect(DraftCards.fields(mail).map(\.label) == ["To", "From", "Subject"])
        #expect(DraftCards.fields(mail).map(\.value) == ["dana@example.com", "me@example.com", "Q3"])
        #expect(mail.id == DraftCards.id(app: "Email — from me@example.com", to: "dana@example.com", subject: "Q3", body: body), "the id is still made from what the bot sent")
        #expect(DraftCards.sendMessage(mail, body: body).contains("\nSend this to dana@example.com (Email) from me@example.com exactly as written:\nSubject: Q3\n\n"))
        var named = args
        named["app"] = "Email"; named["from"] = "work@example.com"
        let given = try #require(DraftCards.draft(ToolCall(id: "c8", name: DraftCards.tool, title: "Draft", argsText: ChatJSON.stringify(.object(named)), summary: nil, state: .done, durationSeconds: nil)))
        #expect(given.from == "work@example.com")
        // The card: the words on their panel, and every line inside the card.
        let row = DraftCardRow(draft: mail, rowId: "r", messageId: "m", body: body, edited: false, state: .waiting, editing: false, expanded: false)
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            guard case .prompt(let layout) = PromptLayout.draft(row, gap: 6, width: 402, category: category).content else { Issue.record("layout"); return }
            let frame = try #require(layout.cardFrame)
            let paper = try #require(layout.draft?.paper)
            #expect(layout.rules.isEmpty && frame.contains(paper))
            #expect(layout.texts.contains { $0.text.text.string == body && paper.contains($0.frame) })
            #expect(layout.texts.allSatisfy { frame.insetBy(dx: -1, dy: -1).contains($0.frame) })
            #expect(layout.accessibility.contains("From: me@example.com") && layout.accessibility.contains("Subject: Q3"))
        }
    }

    @Test func theMarkSaysWhatKindOfMessage() throws {
        func glyph(_ app: String) throws -> String {
            let call = ToolCall(id: "g", name: DraftCards.tool, title: "Draft", argsText: ChatJSON.stringify(.object(["app": .string(app), "body": .string("Hello there")])),
                                summary: nil, state: .done, durationSeconds: nil)
            return DraftCards.glyph(try #require(DraftCards.draft(call)))
        }
        #expect(try glyph("Email — from me@example.com") == "envelope.circle.fill")
        #expect(try glyph("Gmail") == "envelope.circle.fill")
        #expect(try glyph("Slack") == "bubble.left.circle.fill")
        #expect(try glyph("X") == "square.and.pencil.circle.fill")
    }

    // MARK: The conversation it answers

    func threaded(_ thread: JSONValue) -> ToolCall {
        ToolCall(id: "c1", name: DraftCards.tool, title: "Draft", argsText: ChatJSON.stringify(.object([
            "app": .string("Slack"), "to": .string("#finance"), "body": .string(body), "thread": thread])), summary: nil, state: .done, durationSeconds: nil)
    }

    @Test func theConversationIsReadFromTheCall() throws {
        let long = (1...40).map { "Line \($0) of what Dana wrote." }.joined(separator: "\n")
        let call = threaded(.array([
            .object(["from": .string("Dana"), "when": .string("Mon 4:52 PM"), "text": .string("Are the Q3 numbers final?")]),
            .object(["sender": .string("Luis"), "body": .string("Tomorrow morning.")]),
            .object(["from": .string("Nobody")]),
            .string("  "),
            .object(["from": .string("Dana"), "text": .string(long)])]))
        let draft = try #require(DraftCards.draft(call))
        #expect(draft.thread.map(\.from) == ["Dana", "Luis", "Dana"])
        #expect(draft.thread[0].when == "Mon 4:52 PM" && draft.thread[1].text == "Tomorrow morning.")
        #expect(draft.id == DraftCards.id(app: "Slack", to: "#finance", subject: "", body: body), "the conversation isn't part of the id")
        #expect(DraftCards.threadTitle(draft) == "Show Conversation (3)")
        let many = try #require(DraftCards.draft(threaded(.array((1...45).map { .object(["text": .string("message \($0)")]) }))))
        #expect(many.thread.count == DraftCards.maxThread && many.thread.last?.text == "message 45")
        #expect(DraftCards.draft(self.call())?.thread.isEmpty == true)
        #expect(try #require(DraftCards.draft(threaded(.string("not a list")))).thread.isEmpty)

        // The preview: the message being answered fills it (its lines run together, cut), and a button opens the rest.
        func layout(_ call: ToolCall, _ category: UIContentSizeCategory = .large) throws -> PromptRowLayout {
            let row = try #require(card([bot(call)]))
            guard case .prompt(let layout) = PromptLayout.draft(row, gap: 6, width: 402, category: category).content else { throw CancellationError() }
            return layout
        }
        func has(_ layout: PromptRowLayout, _ words: String) -> Bool { layout.texts.contains { $0.text.text.string.contains(words) } }
        let preview = try layout(call)
        #expect(preview.draft?.threadTitle == "Show Conversation (3)")
        #expect(has(preview, "Line 1 of") && has(preview, "Line 2 of") && !has(preview, "Line 40 of") && !has(preview, "Tomorrow morning."))
        #expect(preview.accessibility.contains("Line 1 of") && !preview.accessibility.contains("Line 40 of"))
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            let l = try layout(call, category)
            let frame = try #require(l.cardFrame), d = try #require(l.draft)
            let toggle = try #require(d.threadFrame), quote = try #require(d.quote)
            #expect(l.texts.allSatisfy { frame.insetBy(dx: -1, dy: -1).contains($0.frame) })
            #expect(toggle.height >= 44 && frame.contains(quote) && quote.maxY <= d.paper.minY && toggle.maxY <= d.paper.minY + 22)
        }
    }

    @Test func aShortLastMessageBringsTheOnesBeforeIt() throws {
        func layout(_ thread: [JSONValue]) throws -> PromptRowLayout {
            let row = try #require(card([bot(threaded(.array(thread)))]))
            guard case .prompt(let layout) = PromptLayout.draft(row, gap: 6, width: 402, category: .large).content else { throw CancellationError() }
            return layout
        }
        func says(_ who: String, _ words: String) -> JSONValue { .object(["from": .string(who), "text": .string(words)]) }
        func has(_ layout: PromptRowLayout, _ words: String) -> Bool { layout.texts.contains { $0.text.text.string.contains(words) } }
        // A quick back-and-forth: "ok?" alone says nothing, so the messages before it show too. All of it fits: no button.
        let chat = try layout([says("Dana", "Are the Q3 numbers final?"), says("Luis", "Tomorrow morning."), says("Dana", "ok?")])
        #expect(has(chat, "Are the Q3 numbers final?") && has(chat, "Tomorrow morning.") && has(chat, "ok?") && has(chat, "Luis"))
        #expect(chat.draft?.threadFrame == nil && chat.draft?.quote != nil)
        // More messages than the preview holds: the newest ones, and the button counts them all.
        let busy = try layout((1...9).map { says("Dana", "Short note \($0).") })
        #expect(has(busy, "Short note 9.") && has(busy, "Short note 6.") && !has(busy, "Short note 5."))
        #expect(busy.draft?.threadTitle == "Show Conversation (9)" && busy.draft?.threadFrame != nil)
        // One message that fits whole: nothing more to open. One that doesn't: "Show Whole Message".
        #expect(try layout([says("Ivy", "Thanks!")]).draft?.threadFrame == nil)
        let long = (1...40).map { "Line \($0) of the email." }.joined(separator: "\n")
        #expect(try layout([says("Ivy", long)]).draft?.threadTitle == "Show Whole Message")
        // An email's greeting and the lines it quotes don't take the preview's room.
        let email = DraftThreadText.flat("Hi Alex,\n\nThe proposal is attached.\nCan you sign by Friday?\n> On Monday you wrote:\n> Send it over.")
        #expect(email.words == "The proposal is attached. Can you sign by Friday?" && !email.whole)
        #expect(DraftThreadText.flat("Thanks!").whole && DraftThreadText.flat("> only a quote").words == "> only a quote")
    }

    // MARK: The answer

    @Test func sendNamesTheDraftThePlaceAndTheWords() throws {
        let draft = try #require(DraftCards.draft(call()))
        let sent = DraftCards.sendMessage(draft, body: body)
        #expect(sent == "[Hermes HQ draft d-0629889e: send]\nSend this to #finance (Slack) exactly as written:\n\n" + body)
        let found = try #require(DraftCards.answer(in: sent))
        #expect(found.id == draft.id)
        #expect(found.answer == .send(body: body))
        #expect(DraftCards.bubbleWords(sent) == "Send it")

        let edited = DraftCards.sendMessage(draft, body: "Hi Dana,\n\nFriday at 3 instead?\n")
        #expect(edited.hasPrefix("[Hermes HQ draft d-0629889e: send]\nI edited it. Send this to #finance (Slack) exactly as written:\n\n"))
        // The words keep their own blank lines.
        #expect(DraftCards.answer(in: edited)?.answer == .send(body: "Hi Dana,\n\nFriday at 3 instead?"))
        #expect(DraftCards.bubbleWords(edited) == "Send it with my edits")

        let mail = try #require(DraftCards.draft(call(app: "Email", to: nil, subject: "Q3 numbers")))
        #expect(DraftCards.sendMessage(mail, body: body) ==
                "[Hermes HQ draft \(mail.id): send]\nSend this on Email exactly as written:\nSubject: Q3 numbers\n\n" + body)
    }

    @Test func dontSendNamesTheDraft() throws {
        let draft = try #require(DraftCards.draft(call()))
        let skipped = DraftCards.skipMessage(draft)
        #expect(skipped == "[Hermes HQ draft d-0629889e: skip]\nDon't send this draft.")
        #expect(DraftCards.answer(in: skipped)?.answer == .skip)
        #expect(DraftCards.bubbleWords(skipped) == "Don’t send it")
    }

    @Test func onlyTheAppsOwnFirstLineIsAnAnswer() {
        #expect(DraftCards.answer(in: "please [Hermes HQ draft d-0123abcd: send]") == nil)
        #expect(DraftCards.answer(in: "[Hermes HQ draft d-XYZ: send]") == nil)
        #expect(DraftCards.answer(in: "Send it") == nil)
        #expect(DraftCards.bubbleWords("Send it") == nil)
        #expect(DraftCards.answer(in: "[Hermes HQ draft d-0123abcd: send]")?.answer == .send(body: nil))
        // Only your messages answer, and the newest answer wins.
        let quoted = ChatMessage(id: "a", role: .assistant, parts: [.text("[Hermes HQ draft d-0123abcd: send]")], timestamp: nil, rowId: 1)
        #expect(DraftCards.answers([quoted]).isEmpty)
        let both = [you("[Hermes HQ draft d-0123abcd: skip]\nDon't send this draft."), you("[Hermes HQ draft d-0123abcd: send]\nGo:\n\nwords", id: "m3")]
        #expect(DraftCards.answers(both) == ["d-0123abcd": .send(body: "words")])
    }

    @Test func anAnswerWaitingInTheQueueCountsAndReadsShort() throws {
        let draft = try #require(DraftCards.draft(call()))
        let waiting = DraftCards.sendMessage(draft, body: body)
        #expect(DraftCards.answers([bot(call())], queued: [waiting]) == [draft.id: .send(body: body)])
        // The queued answer is the newer one.
        #expect(DraftCards.answers([you(DraftCards.skipMessage(draft))], queued: [waiting]) == [draft.id: .send(body: body)])
        #expect(ChatQueueCard.rowText(QueuedMessage(id: "q1", text: waiting, display: waiting)).text == "Send it")
        #expect(ChatQueueCard.rowText(QueuedMessage(id: "q2", text: "plain\nwords")).text == "plain words")
    }

    @Test func aSavedChatKeepsADraftsWords() throws {
        let long = String(repeating: "A long line of the message. ", count: 60)
        var other = call(body: long, name: "send_message")
        other.id = "c2"
        let message = ChatMessage(id: "m1", role: .assistant, parts: [.tool(call(body: long)), .tool(other)], timestamp: nil, rowId: 1)
        let kept = TranscriptCache.withoutToolDetails(TranscriptEntry(messages: [message], meta: [:], savedAt: Date()))
        guard case .tool(let draft) = kept.messages[0].parts[0], case .tool(let plain) = kept.messages[0].parts[1] else { Issue.record("parts"); return }
        #expect(DraftCards.draft(draft)?.body == long.trimmingCharacters(in: .whitespaces))
        #expect((plain.argsText?.utf8.count ?? 0) < 600)
    }

    @Test func theAddOnIsToldOnceItOffersCards() {
        #expect(DraftCards.cardsUntold(["draftCards": true, "pluginUpdates": true, "draftCardsShown": false]))
        #expect(DraftCards.cardsUntold(["draftCards": true, "pluginUpdates": true]))
        #expect(!DraftCards.cardsUntold(["draftCards": true, "pluginUpdates": true, "draftCardsShown": true]))
        #expect(!DraftCards.cardsUntold(["draftCards": false]))
        #expect(!DraftCards.cardsUntold(["version": "0.9.46"]))
        #expect(!DraftCards.cardsUntold(nil))
    }

    // MARK: The row

    @Test func theCardFollowsTheChatsAnswers() throws {
        let draft = try #require(DraftCards.draft(call()))
        let waiting = try #require(card([bot(call())]))
        #expect(waiting.state == .waiting)
        #expect(waiting.body == body)
        #expect(!waiting.edited)

        let changed = try #require(card([bot(call())], edits: [draft.id: "Friday at 3?"], editing: draft.id))
        #expect(changed.state == .waiting)
        #expect(changed.body == "Friday at 3?")
        #expect(changed.edited)
        #expect(changed.editing)

        let sent = try #require(card([bot(call()), you(DraftCards.sendMessage(draft, body: "Friday at 3?"))], editing: draft.id))
        #expect(sent.state == .sent)
        #expect(sent.body == "Friday at 3?")
        #expect(sent.edited)
        #expect(!sent.editing)

        let skipped = try #require(card([bot(call()), you(DraftCards.skipMessage(draft))], edits: [draft.id: "ignored"]))
        #expect(skipped.state == .skipped)
        #expect(skipped.body == body)
    }

    @Test func theChatDrawsTheCardAndShortAnswerBubbles() throws {
        let draft = try #require(DraftCards.draft(call()))
        let rows = ChatRowBuilder.build(input([bot(call()), you(DraftCards.sendMessage(draft, body: body))]))
        let cards = rows.filter { if case .prompt(let p) = $0.kind, case .draft = p.kind { return true } else { return false } }
        #expect(cards.count == 1)
        // The call isn't also a tool row, and a failed call is the plain step it is.
        #expect(!rows.contains { if case .toolRun = $0.kind { return true } else { return false } })
        let failed = ChatRowBuilder.build(input([bot(call(state: .failed))]))
        #expect(!failed.contains { if case .prompt = $0.kind { return true } else { return false } })
    }

    // MARK: Layout

    @Test func aWaitingCardHasItsThreeButtonsInsideIt() throws {
        let row = try #require(card([bot(call())]))
        let made = PromptLayout.draft(row, gap: 6, width: 402, category: .large)
        guard case .prompt(let layout) = made.content, let draft = layout.draft else { Issue.record("layout"); return }
        #expect(draft.buttons.map(\.0) == [.send, .edit, .skip])   // placed from the trailing edge: Send is rightmost
        #expect(draft.buttons.first?.1.maxX == draft.buttons.map(\.1.maxX).max())
        #expect(!draft.stacked)
        #expect(draft.showAllFrame == nil)
        let frame = try #require(layout.cardFrame)
        #expect(draft.buttons.allSatisfy { frame.contains($0.1) && $0.1.height >= 44 })
        #expect(layout.accessibility.contains("Slack draft") && layout.accessibility.contains("To: #finance"))
        #expect(layout.accessibility.contains(body))

        let ax = PromptLayout.draft(row, gap: 6, width: 402, category: .accessibilityExtraExtraExtraLarge)
        guard case .prompt(let big) = ax.content, let stacked = big.draft else { Issue.record("ax"); return }
        #expect(stacked.stacked)
        #expect(stacked.buttons.first?.0 == .send)
        let bigFrame = try #require(big.cardFrame)
        #expect(stacked.buttons.allSatisfy { bigFrame.contains($0.1) })
    }

    @Test func anAnsweredCardSaysWhatYouChose() throws {
        let draft = try #require(DraftCards.draft(call()))
        let sent = try #require(card([bot(call()), you(DraftCards.sendMessage(draft, body: body))]))
        #expect(PromptLayout.draftStatus(sent) == "Approved to send")
        let edited = try #require(card([bot(call()), you(DraftCards.sendMessage(draft, body: "Friday at 3?"))]))
        #expect(PromptLayout.draftStatus(edited) == "Approved to send, with your edits")
        let skipped = try #require(card([bot(call()), you(DraftCards.skipMessage(draft))]))
        #expect(PromptLayout.draftStatus(skipped) == "Not sent")
        let made = PromptLayout.draft(skipped, gap: 6, width: 402, category: .large)
        guard case .prompt(let layout) = made.content else { Issue.record("layout"); return }
        #expect(layout.draft?.buttons.isEmpty == true)
        #expect(layout.accessibility.hasSuffix("Not sent"))
    }

    @Test func aLongDraftClampsUntilShowAll() throws {
        let long = (1...40).map { "Line \($0) of a long message." }.joined(separator: "\n")
        let first = bot(call(body: long))
        let clamped = try #require(card([first]))
        let short = PromptLayout.draft(clamped, gap: 6, width: 402, category: .large)
        guard case .prompt(let s) = short.content else { Issue.record("layout"); return }
        #expect(s.draft?.showAllFrame != nil)
        #expect(s.draft?.showAllTitle == "Show All")
        let open = try #require(card([first], expanded: [clamped.rowId]))
        #expect(open.expanded)
        let tall = PromptLayout.draft(open, gap: 6, width: 402, category: .large)
        guard case .prompt(let t) = tall.content else { Issue.record("layout"); return }
        #expect(t.draft?.showAllTitle == "Show Less")
        #expect(t.draft?.showAllFrame != nil)
        #expect(tall.height > short.height)
    }

    // MARK: Calm chat readability ([calm-chat])

    @Test func supersededDraftFoldsAndDropsLiveButtons() throws {
        var firstCall = call(body: "First version of the update.")
        firstCall.id = "c1"
        var secondCall = call(body: "Second cleaner version of the update.")
        secondCall.id = "c2"
        var otherTargetCall = call(to: "#design", body: "Separate note for design.")
        otherTargetCall.id = "c3"

        let m1 = ChatMessage(id: "m1", role: .assistant, parts: [.tool(firstCall)], timestamp: nil, rowId: 1)
        let m2 = ChatMessage(id: "m2", role: .assistant, parts: [.tool(secondCall)], timestamp: nil, rowId: 2)
        let m3 = ChatMessage(id: "m3", role: .assistant, parts: [.tool(otherTargetCall)], timestamp: nil, rowId: 3)
        let rows = ChatRowBuilder.build(input([m1, m2, m3]))
        let drafts = rows.compactMap { row -> DraftCardRow? in
            if case .prompt(let p) = row.kind, case .draft(let d) = p.kind { return d }
            return nil
        }
        #expect(drafts.map(\.state) == [.superseded, .waiting, .waiting])

        let collapsed = PromptLayout.draft(drafts[0], gap: 6, width: 402, category: .large)
        guard case .prompt(let cl) = collapsed.content, let cd = cl.draft else { Issue.record("layout"); return }
        #expect(cl.cardFrame == nil && cd.buttons.isEmpty && cd.toggleFrame != nil)
        #expect(cl.accessibility.contains("Revised below"))
        #expect(collapsed.height < 56)

        var openedRow = drafts[0]
        openedRow.expanded = true
        let expanded = PromptLayout.draft(openedRow, gap: 6, width: 402, category: .large)
        guard case .prompt(let el) = expanded.content, let ed = el.draft else { Issue.record("expanded"); return }
        #expect(el.cardFrame != nil && ed.buttons.isEmpty && ed.toggleExpanded)
        #expect(expanded.height > collapsed.height)

        // An earlier sent draft keeps its sent state even if another draft to the same channel arrives later.
        let firstDraft = try #require(DraftCards.draft(firstCall))
        let sentThenNew = ChatRowBuilder.build(input([m1, you(DraftCards.sendMessage(firstDraft, body: firstDraft.body), id: "u1"), m2]))
        let states = sentThenNew.compactMap { row -> DraftCardRow.State? in
            if case .prompt(let p) = row.kind, case .draft(let d) = p.kind { return d.state }
            return nil
        }
        #expect(states == [.sent, .waiting])
    }

    @Test func sentDraftRendersCompactExpandableReceipt() throws {
        let multiLine = "Hi Dana,\n\nThe Q3 numbers are ready in the shared folder.\nCan we review them Thursday at 2?\nI added the chart breakdown too."
        let c = call(body: multiLine)
        let draft = try #require(DraftCards.draft(c))
        let messages = [bot(c), you(DraftCards.sendMessage(draft, body: multiLine))]
        let collapsedRow = try #require(card(messages))
        #expect(collapsedRow.state == .sent && !collapsedRow.expanded)
        let collapsed = PromptLayout.draft(collapsedRow, gap: 6, width: 402, category: .large)
        guard case .prompt(let cl) = collapsed.content, let cd = cl.draft else { Issue.record("layout"); return }
        #expect(cl.cardFrame != nil && cd.buttons.isEmpty && cd.toggleFrame != nil && cd.bodyBar != nil && !cd.bodyBarTint)

        let expandedRow = try #require(card(messages, expanded: [collapsedRow.rowId]))
        let expanded = PromptLayout.draft(expandedRow, gap: 6, width: 402, category: .large)
        guard case .prompt(let el) = expanded.content, let ed = el.draft else { Issue.record("expanded"); return }
        #expect(el.cardFrame != nil && ed.toggleExpanded && expanded.height > collapsed.height)
    }

    @Test func wideCardsCapToCalmReadableRail() throws {
        let row = try #require(card([bot(call())]))
        let wide = PromptLayout.draft(row, gap: 6, width: 1280, category: .large)
        guard case .prompt(let dl) = wide.content, let df = dl.cardFrame else { Issue.record("draft"); return }
        #expect(df.width <= PromptLayout.maxCardWidth && df.width < 1280 - 32)
        // Narrow phone keeps full width.
        let phone = PromptLayout.draft(row, gap: 6, width: 402, category: .large)
        guard case .prompt(let pl) = phone.content, let pf = pl.cardFrame else { Issue.record("phone"); return }
        #expect(pf.width == 402 - 2 * PromptLayout.cardSide)
    }

    @Test func adjacentDraftAnswerEchoAndBoilerplateAreSuppressed() throws {
        var c1 = call(body: "First draft for Dana.")
        c1.id = "c1"
        var c2 = call(body: "Revised draft for Dana.")
        c2.id = "c2"
        let d2 = try #require(DraftCards.draft(c2))
        let messages = [
            ChatMessage(id: "m1", role: .assistant, parts: [.tool(c1), .text("Your Slack draft for #finance is ready to review. Nothing's been sent.")], timestamp: nil, rowId: 1),
            ChatMessage(id: "m2", role: .assistant, parts: [.tool(c2), .text("Your revised Slack draft for #finance is ready. Nothing's been sent.")], timestamp: nil, rowId: 2),
            you(DraftCards.sendMessage(d2, body: d2.body), id: "u1"),
            ChatMessage(id: "m3", role: .assistant, parts: [.text("Sent and verified in #finance.")], timestamp: nil, rowId: 4),
        ]
        let rows = ChatRowBuilder.build(input(messages))
        let bubbleTexts = rows.compactMap { row -> String? in
            if case .bubble(let b) = row.kind { return b.text }
            return nil
        }
        #expect(bubbleTexts == ["Sent and verified in #finance."])

        // Genuine commentary next to a draft card is never suppressed.
        let withNote = ChatRowBuilder.build(input([
            ChatMessage(id: "m4", role: .assistant, parts: [.tool(c2), .text("I left out the Q4 projection until we confirm it.")], timestamp: nil, rowId: 5),
        ]))
        #expect(withNote.contains { if case .bubble(let b) = $0.kind { return b.text.contains("Q4 projection") } else { return false } })

        // Non-adjacent draft answer (another message came in between) still shows the user bubble.
        let nonAdjacent = ChatRowBuilder.build(input([
            ChatMessage(id: "m2", role: .assistant, parts: [.tool(c2)], timestamp: nil, rowId: 1),
            you("One quick side question first.", id: "u0"),
            ChatMessage(id: "m3", role: .assistant, parts: [.text("Sure, go ahead.")], timestamp: nil, rowId: 3),
            you(DraftCards.sendMessage(d2, body: d2.body), id: "u1"),
        ]))
        #expect(nonAdjacent.contains { if case .bubble(let b) = $0.kind { return b.mine && b.text == "Send it" } else { return false } })
    }

    @Test func partialRebuildFoldsSupersededDraftLive() throws {
        var c1 = call(body: "First draft.")
        c1.id = "c1"
        var c2 = call(body: "Revised draft.")
        c2.id = "c2"
        let m1 = ChatMessage(id: "m1", role: .assistant, parts: [.tool(c1)], timestamp: nil, rowId: 1)
        let m2 = ChatMessage(id: "m2", role: .assistant, parts: [.tool(c2)], timestamp: nil, rowId: 2)
        var model = ChatRowModel()
        model.rebuildAll(input([m1]), syncMessages: 160, oldestShown: nil)
        model.rebuildNewest(input([m1, m2]), touching: ["m2"])
        let held = Array(model.allRows.reversed())
        let full = ChatRowBuilder.build(input([m1, m2]))
        #expect(held.map(\.id) == full.map(\.id))
        for i in held.indices { #expect(ChatRowDiff.same(held[i], full[i])) }
        let states = held.compactMap { row -> DraftCardRow.State? in
            if case .prompt(let p) = row.kind, case .draft(let d) = p.kind { return d.state }
            return nil
        }
        #expect(states == [.superseded, .waiting])
    }

    @Test func wrongRecipientSameAppSupersedesAcrossHumanTurnButSiblingsStayLive() {
        var wrong = call(app: "Slack", to: "#finance", body: "Hey team, ready for Q3.")
        wrong.id = "c1"
        var corrected = call(app: "Slack", to: "Dana Reyes", body: "Hey Dana, ready for Q3.")
        corrected.id = "c2"
        let correctedThread = ChatRowBuilder.build(input([
            ChatMessage(id: "m1", role: .assistant, parts: [.tool(wrong)], timestamp: nil, rowId: 1),
            you("Actually send that to Dana Reyes instead.", id: "u1"),
            ChatMessage(id: "m2", role: .assistant, parts: [.tool(corrected)], timestamp: nil, rowId: 3),
        ]))
        let correctedStates = correctedThread.compactMap { row -> DraftCardRow.State? in
            if case .prompt(let p) = row.kind, case .draft(let d) = p.kind { return d.state }
            return nil
        }
        #expect(correctedStates == [.superseded, .waiting])

        // Two sibling drafts in the same assistant turn to different people stay live together.
        var sibA = call(app: "Slack", to: "#finance", body: "Finance note.")
        sibA.id = "s1"
        var sibB = call(app: "Slack", to: "#design", body: "Design note.")
        sibB.id = "s2"
        let siblingRows = ChatRowBuilder.build(input([
            ChatMessage(id: "m3", role: .assistant, parts: [.tool(sibA), .tool(sibB)], timestamp: nil, rowId: 1),
        ]))
        let siblingStates = siblingRows.compactMap { row -> DraftCardRow.State? in
            if case .prompt(let p) = row.kind, case .draft(let d) = p.kind { return d.state }
            return nil
        }
        #expect(siblingStates == [.waiting, .waiting])

        // Different apps across a human turn stay live independently.
        var email = call(app: "Email", to: "dana@example.com", subject: "Q3", body: "Email version.")
        email.id = "e1"
        let crossApp = ChatRowBuilder.build(input([
            ChatMessage(id: "m1", role: .assistant, parts: [.tool(wrong)], timestamp: nil, rowId: 1),
            you("Also draft an email to Dana.", id: "u1"),
            ChatMessage(id: "m2", role: .assistant, parts: [.tool(email)], timestamp: nil, rowId: 3),
        ]))
        let crossStates = crossApp.compactMap { row -> DraftCardRow.State? in
            if case .prompt(let p) = row.kind, case .draft(let d) = p.kind { return d.state }
            return nil
        }
        #expect(crossStates == [.waiting, .waiting])
    }

    @Test func abandonedDraftFoldsAsStaleAfterTwoHumanTurns() throws {
        let m1 = bot(call())
        // One side-question keeps the draft live.
        let oneTurn = try #require(card([m1, you("Did Dana reply yet?", id: "u1")]))
        #expect(oneTurn.state == .waiting)

        // Two normal human turns fold it quietly as Left unsent.
        let staleMessages = [m1, you("Did Dana reply yet?", id: "u1"), you("Okay let's check Monday's agenda instead.", id: "u2")]
        let staleRow = try #require(card(staleMessages))
        #expect(staleRow.state == .stale && staleRow.isQuietFolded)
        #expect(PromptLayout.draftStatus(staleRow) == "Left unsent")
        let collapsed = PromptLayout.draft(staleRow, gap: 6, width: 402, category: .large)
        guard case .prompt(let cl) = collapsed.content, let cd = cl.draft else { Issue.record("collapsed"); return }
        #expect(cl.cardFrame == nil && cd.buttons.isEmpty && cd.toggleFrame != nil)
        #expect(cl.accessibility.contains("Left unsent"))
        #expect(collapsed.height < 56)

        let opened = try #require(card(staleMessages, expanded: [staleRow.rowId]))
        let expanded = PromptLayout.draft(opened, gap: 6, width: 402, category: .large)
        guard case .prompt(let el) = expanded.content, let ed = el.draft else { Issue.record("expanded"); return }
        #expect(el.cardFrame != nil && ed.buttons.isEmpty && ed.toggleExpanded && expanded.height > collapsed.height)

        // Partial rebuild folds it live when the second human turn lands.
        var model = ChatRowModel()
        model.rebuildAll(input([m1, staleMessages[1]]), syncMessages: 160, oldestShown: nil)
        model.rebuildNewest(input(staleMessages), touching: ["u2"])
        let held = Array(model.allRows.reversed())
        let full = ChatRowBuilder.build(input(staleMessages))
        #expect(held.map(\.id) == full.map(\.id))
        for i in held.indices { #expect(ChatRowDiff.same(held[i], full[i])) }
    }

    @Test func broadenedDraftReadyBoilerplateIsSuppressed() {
        let c1 = call(app: "iMessage", to: "Dana Reyes", body: "See you at 3.")
        let c2 = call(app: "Email", to: "dana@example.com", subject: "Follow-up", body: "Attached.")
        let rows = ChatRowBuilder.build(input([
            ChatMessage(id: "m1", role: .assistant, parts: [.tool(c1), .text("Your text to Dana is ready to send.")], timestamp: nil, rowId: 1),
            ChatMessage(id: "m2", role: .assistant, parts: [.tool(c2), .text("Your email to Dana is ready for review. Nothing has been sent.")], timestamp: nil, rowId: 2),
        ]))
        #expect(!rows.contains { if case .bubble = $0.kind { return true } else { return false } })
    }
}
