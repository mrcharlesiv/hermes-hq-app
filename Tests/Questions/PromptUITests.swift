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

    @Test func theCardAndTheNoteJoinTheNewestEnd() {
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
        if case .prompt(let row)? = card?.kind, case .settled(let qa) = row.kind { #expect(qa.first?.answer == "main") }
        else { Issue.record("expected the settled card") }
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
}
