// Stream "questions" UI-model checks: the approval card's rows and layout (§4.2), the clarify rows (§4.4), and the
// password sheets' fields (§4.5, check 19's AutoFill types — XCUI can't read `textContentType`).

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor
@Suite("Questions: rows, layout and sheets")
struct PromptUITests {
    let style = ChatStyleCache.shared.style(for: .large)

    func card(command: String = "git push --force origin main", description: String = "git force push",
              session: Bool = true, always: Bool = true, expired: Bool = false) -> ApprovalCardRow {
        ApprovalCardRow(id: "srq-a", stackExpired: expired, command: command, description: description,
                        showsDescription: ApprovalPrompt(id: "", command: command, description: description, allowSession: true,
                                                         allowAlways: true, clockKey: "", firstSeen: Date()).showsDescription,
                        position: 1, total: 1, allowSession: session, allowAlways: always, expired: expired, answering: nil,
                        leaving: false, clockKey: "k", firstSeen: Date())
    }

    func input(_ messages: [ChatMessage], prompts: PromptRowsInput?) -> ChatRowBuilder.Input {
        ChatRowBuilder.Input(messages: messages, isRunning: true, botName: "Hermes", expanded: [], now: Date(), scope: "t",
                             modelName: nil, prompts: prompts)
    }

    @Test func buttonsFollowTheAllowedChoices() {
        #expect(PromptLayout.buttons(card()) == [.reject, .more, .run])
        #expect(PromptLayout.buttons(card(session: true, always: false)) == [.reject, .session, .run])
        #expect(PromptLayout.buttons(card(session: false, always: true)) == [.reject, .always, .run])
        #expect(PromptLayout.buttons(card(session: false, always: false)) == [.reject, .run])
        #expect(PromptLayout.buttons(card(expired: true)) == [.dismiss])
        #expect(ApprovalPrompt(id: "", command: "<browser_exec> (plugin approval rule)", description: "Open x", allowSession: true,
                               allowAlways: true, clockKey: "", firstSeen: Date()).showsDescription)
        #expect(ApprovalPrompt(id: "", command: "  ", description: "x", allowSession: true, allowAlways: true, clockKey: "",
                               firstSeen: Date()).showsDescription)
    }

    @Test func aLongCommandClampsAtEightLinesWithShowAll() throws {
        let long = (1...30).map { "echo line \($0)" }.joined(separator: "\n")
        let short = PromptLayout.approval(card(), gap: 6, width: 402, category: .large)
        let clamped = PromptLayout.approval(card(command: long), gap: 6, width: 402, category: .large)
        guard case .prompt(let s) = short.content, case .prompt(let c) = clamped.content else { Issue.record("layout"); return }
        #expect(s.approval?.showAllFrame == nil)
        #expect(c.approval?.showAllFrame != nil)
        let mono = PromptFonts.mono(.large)
        #expect(clamped.height < short.height + 9 * ceil(mono.lineHeight) + 60, "at most 8 lines of command")
        // Buttons sit in one trailing row at the default size, stacked full width (Run first) at AX sizes.
        #expect(s.approval?.stacked == false)
        let ax = PromptLayout.approval(card(), gap: 6, width: 402, category: .accessibilityExtraExtraExtraLarge)
        guard case .prompt(let a) = ax.content, let buttons = a.approval?.buttons else { Issue.record("ax"); return }
        #expect(a.approval?.stacked == true)
        #expect(buttons.first?.0 == .run)
        #expect(buttons.allSatisfy { $0.1.height >= 44 })
        // The card's buttons sit inside the card; the row leaves 8 pt under it.
        let frame = try #require(s.cardFrame)
        #expect(s.approval?.buttons.allSatisfy { frame.contains($0.1) } == true)
        #expect(short.height == ceil(frame.maxY + 8))
    }

    @Test func theCardAndTheNoteJoinTheNewestEnd() throws {
        let user = ChatMessage(id: "u1", role: .user, parts: [.text("please approve")], timestamp: Date(), rowId: 1)
        var reply = ChatMessage(id: "a1", role: .assistant, parts: [.tool(ToolCall(id: "t1", name: "terminal", title: "Running",
                                                                                   argsText: nil, summary: nil, state: .running,
                                                                                   durationSeconds: nil))],
                                timestamp: Date(), rowId: nil)
        reply.isStreaming = true
        var prompts = PromptRowsInput(approval: card(), clarifyNote: nil)
        let rows = ChatRowBuilder.build(input([user, reply], prompts: prompts))
        #expect(rows.last?.id == "prompts|approval")
        // A question with no running clarify part: its note at the newest end too.
        prompts.clarifyNote = .asked(count: 2, first: "Which branch?")
        let both = ChatRowBuilder.build(input([user, reply], prompts: prompts))
        #expect(both.suffix(2).map(\.id) == ["prompts|note", "prompts|approval"])
        // A running clarify part holds the note in its place.
        var asking = reply
        asking.parts = [.tool(ToolCall(id: "c1", name: "clarify", title: "clarify", argsText: nil, summary: nil, state: .running,
                                       durationSeconds: nil))]
        let inPlace = ChatRowBuilder.build(input([user, asking], prompts: PromptRowsInput(approval: nil, clarifyNote: prompts.clarifyNote)))
        #expect(inPlace.contains { $0.id == "a1|qc1" })
        #expect(!inPlace.contains { $0.id == "prompts|note" })
        // A settled clarify part draws the Q&A card; without prompts, a running one stays a tool row.
        var settled = asking
        settled.parts = [.tool(ToolCall(id: "c1", name: "clarify", title: "clarify", argsText: nil,
                                        summary: ClarifySettled.summary([ClarifyQA(question: "Which?", answer: "main", unanswered: false)]),
                                        state: .done, durationSeconds: nil))]
        let card = ChatRowBuilder.build(input([user, settled], prompts: nil)).first { $0.id == "a1|qc1" }
        if case .prompt(let row)? = card?.kind, case .settled(let qa) = row.kind {
            #expect(qa.rows.first?.answer == "main")
            #expect(!qa.answerable && !qa.answeredLater)
        } else { Issue.record("expected the settled card") }
        // A question that went unanswered offers Answer Now; the answer sent later in the chat fills it.
        let skipped = [ClarifyQA(question: "Proceed?", answer: "", unanswered: true, choices: ["Yes", "No"])]
        settled.parts = [.tool(ToolCall(id: "c1", name: "clarify", title: "clarify", argsText: nil,
                                        summary: ClarifySettled.summary(skipped), state: .done, durationSeconds: nil))]
        func lateCard(_ messages: [ChatMessage]) -> SettledClarifyCard? {
            var i = input(messages, prompts: nil)
            i.clarifyLate = ClarifyLate.answers(messages)
            guard case .prompt(let row)? = ChatRowBuilder.build(i).first(where: { $0.id == "a1|qc1" })?.kind,
                  case .settled(let qa) = row.kind else { return nil }
            return qa
        }
        let open = try #require(lateCard([user, settled]))
        #expect(open.answerable && !open.answeredLater && open.rows.first?.choices == ["Yes", "No"])
        let lateReply = ChatMessage(id: "u2", role: .user, parts: [.text(ClarifyLate.message(key: open.key, answers: [("Proceed?", "Yes")]))],
                                timestamp: nil, rowId: nil)
        let answered = try #require(lateCard([user, settled, lateReply]))
        #expect(!answered.answerable && answered.answeredLater && answered.rows.first?.answer == "Yes")
        // An answer from before the card doesn't count (the same question asked again).
        let before = try #require(lateCard([lateReply, user, settled]))
        #expect(before.answerable)
        let plain = ChatRowBuilder.build(input([user, asking], prompts: nil))
        #expect(plain.contains { if case .toolRun = $0.kind { true } else { false } })
    }

    /// Verify round 1: a reopened chat whose turn waits on the user (an open question or approval) showed "Waiting for
    /// <model>" above the card while the header said "Waiting for your reply". No waiting capsule while it waits on you;
    /// once the answers are sent the capsule is back.
    @Test func noWaitingCapsuleWhileTheTurnWaitsOnTheUser() {
        let user = ChatMessage(id: "u1", role: .user, parts: [.text("ask me")], timestamp: Date(), rowId: 1)
        let waiting: (ChatRow) -> Bool = { if case .waiting = $0.kind { true } else { false } }
        #expect(ChatRowBuilder.build(input([user], prompts: nil)).contains(where: waiting), "a running turn waits on the model")
        let asked = PromptRowsInput(approval: nil, clarifyNote: .asked(count: 3, first: "Which branch?"))
        #expect(!ChatRowBuilder.build(input([user], prompts: asked)).contains(where: waiting), "an open question: no capsule")
        let approval = PromptRowsInput(approval: card(), clarifyNote: nil)
        #expect(!ChatRowBuilder.build(input([user], prompts: approval)).contains(where: waiting), "an open approval: no capsule")
        let sent = PromptRowsInput(approval: nil, clarifyNote: .sent([SentClarifyRow(question: "Q", answer: "main")]))
        #expect(ChatRowBuilder.build(input([user], prompts: sent)).contains(where: waiting), "answers sent: the model works again")
    }

    @Test func notesMeasureAndReadAloud() {
        for note in [ClarifyNote.asked(count: 1, first: "Which?"), .undelivered,
                     .sent([SentClarifyRow(question: "Q", answer: ""), SentClarifyRow(question: "R", answer: nil)])] {
            let layout = PromptLayout.note(note, gap: 6, width: 402, category: .large)
            guard case .prompt(let l) = layout.content else { Issue.record("layout"); continue }
            #expect(layout.height > 40)
            #expect(!l.accessibility.isEmpty)
        }
        let sent = PromptLayout.note(.sent([SentClarifyRow(question: "Q", answer: ""), SentClarifyRow(question: "R", answer: nil)]),
                                     gap: 6, width: 402, category: .large)
        guard case .prompt(let l) = sent.content else { return }
        #expect(l.accessibility == "2 questions skipped. Q: Skipped. R: No answer")
    }

    // Check 19 (the field types XCUI can't see) and Q9 (no empty sudo from Send).
    @Test func sheetsUseAutoFillFieldTypesAndValidate() throws {
        func fields(_ kind: PromptKind, _ params: JSONValue) -> (PromptSheetController, [UITextField]) {
            let sheet = PromptSheetController(prompt: ValuePrompt(id: "srq-x", kind: kind, params: params))
            sheet.loadViewIfNeeded()
            func all(_ v: UIView) -> [UITextField] { (v as? UITextField).map { [$0] } ?? v.subviews.flatMap(all) }
            return (sheet, all(sheet.view))
        }
        let (login, loginFields) = fields(.vaultSaveLogin, ["origin": "https://shop.example.com", "site": "Example Shop"])
        #expect(loginFields.map(\.textContentType) == [.username, .password])
        #expect(loginFields[0].keyboardType == .emailAddress && loginFields[1].isSecureTextEntry)
        #expect(loginFields.allSatisfy { $0.autocorrectionType == .no && $0.autocapitalizationType == .none && $0.smartQuotesType == .no })
        #expect(login.copy.title == "Save Your Example Shop Login?")
        #expect(login.value == nil)
        loginFields[0].text = "  me@example.com "
        #expect(login.value == nil)
        loginFields[1].text = "p"
        #expect(login.value == #"{"identifier":"me@example.com","password":"p"}"#)

        let (sudo, sudoFields) = fields(.sudo, ["command": "apt-get install -y ffmpeg"])
        #expect(sudoFields.map(\.textContentType) == [.password])
        #expect(sudo.value == nil)
        #expect(sudo.copy.chip == "Password requested" && sudo.copy.decline == "Don’t Send")
        let (code, codeFields) = fields(.vaultCode, ["site": "Example Shop"])
        #expect(codeFields.first?.textContentType == .oneTimeCode && codeFields.first?.keyboardType == .numberPad)
        codeFields[0].text = "123 4-56"
        #expect(code.value == "123456")
        #expect(PromptSheetCopy.make(ValuePrompt(id: "", kind: .secret, params: ["env_var": "OPENWEATHER_API_KEY"])).chip
                == "OPENWEATHER_API_KEY requested")
        #expect(PromptSheetCopy.make(ValuePrompt(id: "", kind: .vaultUnlock, params: [:])).chip == "Unlock password manager")
        #expect(PromptSheetCopy.make(ValuePrompt(id: "", kind: .sudo, params: ["command": ""])).commandMissing != nil)
        // The chat's bot is named, never "the agent" or "Hermes"; a secret's variable is a detail, not the title.
        let secret = PromptSheetCopy.make(ValuePrompt(id: "", kind: .secret, params: ["env_var": "OPENWEATHER_API_KEY"]), botName: "Ivy")
        #expect(secret.title == "Ivy Needs a Key" && secret.text == "Ivy needs a key to continue." && secret.key == "OPENWEATHER_API_KEY")
        #expect(PromptSheetCopy.make(ValuePrompt(id: "", kind: .sudo, params: ["command": "ls"]), botName: "Ivy").text.contains("sent to Ivy"))
        #expect(PromptSheetCopy.make(ValuePrompt(id: "", kind: .vaultCode, params: [:])).text.hasSuffix("the bot never sees it."))
    }

    // MARK: Calm chat readability ([calm-chat])

    @Test func settledClarifyFoldsQuietlyAndExpandsInPlace() throws {
        let user = ChatMessage(id: "u1", role: .user, parts: [.text("Deploy the release")], timestamp: Date(), rowId: 1)
        let qa = [ClarifyQA(question: "Which branch?", answer: "main", unanswered: false)]
        let call = ToolCall(id: "c1", name: "clarify", title: "clarify", argsText: nil,
                            summary: ClarifySettled.summary(qa), state: .done, durationSeconds: nil)
        let settled = ChatMessage(id: "a1", role: .assistant, parts: [.tool(call), .text("Using main and starting the build.")],
                                  timestamp: Date(), rowId: 2)
        var i = input([user, settled], prompts: nil)
        i.isRunning = false
        let row = try #require(ChatRowBuilder.build(i).first { $0.id == "a1|qc1" })
        guard case .prompt(let pr) = row.kind, case .settled(let card) = pr.kind else { Issue.record("expected settled"); return }
        #expect(card.folded && !card.expanded && card.isQuietFolded && !card.answerable)

        let collapsed = PromptLayout.settled(card, gap: 6, width: 402, category: .large)
        guard case .prompt(let cl) = collapsed.content else { Issue.record("collapsed"); return }
        #expect(cl.cardFrame == nil && cl.foldToggle != nil && cl.foldToggle?.expanded == false)
        #expect(cl.accessibility.contains("main") && cl.accessibility.contains("Which branch?"))
        #expect(collapsed.height < 56)

        i.expanded = ["a1|qc1"]
        let expandedRow = try #require(ChatRowBuilder.build(i).first { $0.id == "a1|qc1" })
        guard case .prompt(let epr) = expandedRow.kind, case .settled(let expandedCard) = epr.kind else { Issue.record("expanded"); return }
        #expect(expandedCard.folded && expandedCard.expanded && !expandedCard.isQuietFolded)
        let expanded = PromptLayout.settled(expandedCard, gap: 6, width: 402, category: .large)
        guard case .prompt(let el) = expanded.content else { Issue.record("expanded layout"); return }
        #expect(el.cardFrame != nil && el.foldToggle?.expanded == true && expanded.height > collapsed.height)
    }

    @Test func staleUnansweredClarifyDropsAnswerNowAndSuppressesAdjacentEcho() throws {
        let user = ChatMessage(id: "u1", role: .user, parts: [.text("Deploy the release")], timestamp: Date(), rowId: 1)
        let skipped = [ClarifyQA(question: "Proceed?", answer: "", unanswered: true, choices: ["Yes", "No"])]
        let call = ToolCall(id: "c1", name: "clarify", title: "clarify", argsText: nil,
                            summary: ClarifySettled.summary(skipped), state: .done, durationSeconds: nil)
        let settled = ChatMessage(id: "a1", role: .assistant, parts: [.tool(call)], timestamp: Date(), rowId: 2)
        let movedOn = ChatMessage(id: "u2", role: .user, parts: [.text("Actually let's work on the docs instead.")], timestamp: Date(), rowId: 3)

        var staleInput = input([user, settled, movedOn], prompts: nil)
        staleInput.isRunning = false
        let staleRow = try #require(ChatRowBuilder.build(staleInput).first { $0.id == "a1|qc1" })
        guard case .prompt(let sp) = staleRow.kind, case .settled(let staleCard) = sp.kind else { Issue.record("stale"); return }
        #expect(staleCard.staleUnanswered && !staleCard.answerable && staleCard.folded && staleCard.isQuietFolded)
        let staleLayout = PromptLayout.settled(staleCard, gap: 6, width: 402, category: .large)
        guard case .prompt(let sl) = staleLayout.content else { Issue.record("stale layout"); return }
        #expect(sl.cardFrame == nil && sl.accessibility.contains("Question skipped"))

        // Adjacent late answer fills the card and suppresses the redundant user echo bubble.
        let key = ClarifyLate.key(["Proceed?"])
        let lateReply = ChatMessage(id: "u3", role: .user, parts: [.text(ClarifyLate.message(key: key, answers: [("Proceed?", "Yes")]))],
                                    timestamp: Date(), rowId: 4)
        var adjacentInput = input([user, settled, lateReply], prompts: nil)
        adjacentInput.isRunning = false
        adjacentInput.clarifyLate = ClarifyLate.answers(adjacentInput.messages)
        let adjacentRows = ChatRowBuilder.build(adjacentInput)
        #expect(!adjacentRows.contains { if case .bubble(let b) = $0.kind { return b.mine && b.text == "Yes" } else { return false } })
        let filled = try #require(adjacentRows.first { $0.id == "a1|qc1" })
        if case .prompt(let fp) = filled.kind, case .settled(let fc) = fp.kind {
            #expect(fc.answeredLater && fc.rows.first?.answer == "Yes")
        } else { Issue.record("expected filled card") }
    }
}
