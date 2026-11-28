import Testing
import UIKit
@testable import HermesHQNative

private func questionControl<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
    if view.accessibilityIdentifier == id, let hit = view as? T { return hit }
    for child in view.subviews { if let hit: T = questionControl(id, in: child) { return hit } }
    return nil
}

extension QuestionsScreenTests {
    #if targetEnvironment(macCatalyst)
    @Test func aMinimizedMacQuestionIgnoresEscapeAndRapidResumeRestoresKeys() async throws {
        deliver("srq-min", "clarify", ServerRequestCenterTests.clarify)
        let (chat, window, _) = try onScreen(PromptSheetStore())
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(await waitUntil { chat.promptsUI?.dockView != nil })
        let ui = try #require(chat.promptsUI)
        let dock = try #require(ui.dockView)
        #expect(await waitUntil { dock.isFirstResponder })
        ui.dockMinimize(dock)
        #expect(!dock.isFirstResponder)
        dock.escapePressed() // the old view can still be in the window during its outgoing animation
        #expect(dock.sending == .none)
        #expect(client.answers.isEmpty)
        let resume: UIButton = try #require(questionControl("question.resume", in: chat.view))
        resume.sendActions(for: .primaryActionTriggered) // before the outgoing view leaves its window
        #expect(dock.isFirstResponder)
        let key = try #require(dock.keyCommands?.first { $0.input == "2" })
        let action = try #require(key.action)
        _ = dock.perform(action, with: key)
        #expect(dock.draft.stages["q0"]?.choices == ["staging"])
        try await Task.sleep(for: .milliseconds(500))
        #expect(client.answers.isEmpty)
        #expect(dock.isFirstResponder)
    }
    #endif

    @Test func minimizeKeepsTheQuestionAndDraftUntilResume() async throws {
        deliver("srq-min", "clarify", ServerRequestCenterTests.clarify)
        let saved = ClarifyDraft(page: 1, stages: ["q0": ClarifyStage(choices: ["staging"]),
                                                  "q1": ClarifyStage(draft: "notes")])
        center.saveDraft("srq-min", saved)
        let (chat, window, spy) = try onScreen(PromptSheetStore())
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(await waitUntil { chat.promptsUI?.dockView != nil })
        let ui = try #require(chat.promptsUI)
        let dock = try #require(ui.dockView)
        let minimize: UIButton = try #require(questionControl("question.minimize", in: dock))
        minimize.sendActions(for: .primaryActionTriggered)
        #expect(await waitUntil { dock.window == nil })
        #expect(center.draft("srq-min")?.minimized == true)
        #expect(center.draft("srq-min")?.stages == saved.stages)
        #expect(center.draft("srq-min")?.page == saved.page)
        #expect(spy.prompts.clarify?.id == "srq-min")
        #expect(client.answers.isEmpty, "minimize is neither an answer nor a skip")
        ui.refresh()
        #expect(dock.window == nil, "a refresh leaves it minimized")
        let resume: UIButton = try #require(questionControl("question.resume", in: chat.view))
        #expect(resume.accessibilityValue == "Question 2 of 2")
        resume.sendActions(for: .primaryActionTriggered)
        #expect(await waitUntil { dock.window != nil })
        #expect(ui.dockView === dock)
        #expect(dock.draft == saved)
        #expect(center.draft("srq-min") == saved)
        let field: UITextView = try #require(questionControl("question.field", in: dock))
        #expect(!field.isFirstResponder)
        #expect(client.answers.isEmpty)
    }

    @Test func aMinimizedQuestionSurvivesReopeningAndIsRemovedOnCancel() async throws {
        deliver("srq-min", "clarify", ServerRequestCenterTests.clarify)
        let (first, window, _) = try onScreen(PromptSheetStore())
        #expect(await waitUntil { first.promptsUI?.dockView != nil })
        let firstUI = try #require(first.promptsUI)
        let old = try #require(firstUI.dockView)
        firstUI.dockMinimize(old)
        await close(window)
        let (chat, nextWindow, _) = try onScreen(PromptSheetStore())
        defer { nextWindow.isHidden = true; nextWindow.rootViewController = nil }
        #expect(await waitUntil { chat.promptsUI?.dockView != nil })
        let ui = try #require(chat.promptsUI)
        let dock = try #require(ui.dockView)
        #expect(dock !== old)
        #expect(dock.draft.minimized)
        #expect(dock.window == nil)
        #expect(questionControl("question.resume", in: chat.view) as UIButton? != nil)
        center.receive(GatewayEvent(type: "request.cancel", sessionId: runtime, seq: nil,
                                    payload: ["id": "srq-min", "reason": "timeout"]))
        #expect(await waitUntil { ui.dockView == nil && !chat.hasPromptDock })
        #expect(center.draft("srq-min") == nil)
        deliver("srq-next", "clarify", ServerRequestCenterTests.clarify)
        let next = try #require(ui.dockView)
        #expect(next.prompt.id == "srq-next")
        #expect(!next.draft.minimized, "the next question must not inherit a hidden presentation")
        #expect(next.window != nil)
        #expect(client.answers.isEmpty)
    }

    @Test func minimizingCancelsAnAutoAdvanceAndRapidReopeningKeepsOneDock() async throws {
        deliver("srq-min", "clarify", ServerRequestCenterTests.clarify)
        let (chat, window, _) = try onScreen(PromptSheetStore())
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(await waitUntil { chat.promptsUI?.dockView != nil })
        let ui = try #require(chat.promptsUI)
        let dock = try #require(ui.dockView)
        let page = try #require(questionControl("question.page.0", in: dock))
        let pick: UIControl = try #require(questionControl("question.choice.1", in: page))
        pick.sendActions(for: .touchUpInside)
        ui.dockMinimize(dock)
        try await Task.sleep(for: .milliseconds(500))
        #expect(dock.page == 0)
        #expect(dock.draft.stages["q0"]?.choices == ["staging"])
        for _ in 0..<3 {
            let resume: UIButton = try #require(questionControl("question.resume", in: chat.view))
            resume.sendActions(for: .primaryActionTriggered)
            ui.dockMinimize(dock)
        }
        #expect(await waitUntil { dock.window == nil })
        #expect(chat.hasPromptDock)
        #expect(client.answers.isEmpty)
        let resume: UIButton = try #require(questionControl("question.resume", in: chat.view))
        resume.sendActions(for: .primaryActionTriggered)
        #expect(await waitUntil { dock.window != nil && dock.alpha == 1 && dock.transform == .identity })
        #expect(ui.dockView === dock)
    }

    // A tester, 2026-11-19: "it asks and then after a minute or two it disappears while I was mid answering … it
    // deleted all my answers" (the gateway's 90 s clarify timeout). Typed answers stay, as Answer Now's.
    @Test func aQuestionTheBotStopsWaitingForKeepsWhatWasTyped() async throws {
        deliver("srq-keep", "clarify", ServerRequestCenterTests.clarify)
        let (chat, window, _) = try onScreen(PromptSheetStore())
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(await waitUntil { chat.promptsUI?.dockView != nil })
        let ui = try #require(chat.promptsUI)
        let live = try #require(ui.dockView)
        let page = try #require(questionControl("question.page.0", in: live))
        let pick: UIControl = try #require(questionControl("question.choice.1", in: page))
        pick.sendActions(for: .touchUpInside)
        #expect(await waitUntil { live.draft.stages["q0"]?.choices == ["staging"] })
        center.receive(GatewayEvent(type: "request.cancel", sessionId: runtime, seq: nil,
                                    payload: ["id": "srq-keep", "reason": "timeout"]))
        #expect(await waitUntil { ui.dockView !== live })
        let kept = try #require(ui.dockView, "the dock stays up with the answers")
        #expect(kept.later)
        #expect(kept.prompt.questions.map(\.question) == live.prompt.questions.map(\.question))
        #expect(kept.draft.stages["q0"]?.choices == ["staging"])
        #expect(chat.hasPromptDock)
        #expect(client.answers.isEmpty)
        ui.dockSkip(kept) // Cancel closes it
        #expect(ui.dockView == nil)
        #expect(!chat.hasPromptDock)
    }

    @Test func anUntouchedQuestionTheBotStopsWaitingForGoes() async throws {
        deliver("srq-blank", "clarify", ServerRequestCenterTests.clarify)
        let (chat, window, _) = try onScreen(PromptSheetStore())
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(await waitUntil { chat.promptsUI?.dockView != nil })
        let ui = try #require(chat.promptsUI)
        center.receive(GatewayEvent(type: "request.cancel", sessionId: runtime, seq: nil,
                                    payload: ["id": "srq-blank", "reason": "timeout"]))
        #expect(await waitUntil { ui.dockView == nil && !chat.hasPromptDock })
    }

    @Test func answerNowReopensAMinimizedLateDraftInsteadOfReplacingIt() async throws {
        let (chat, window, _) = try onScreen(PromptSheetStore())
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(await waitUntil { chat.promptsUI != nil })
        let ui = try #require(chat.promptsUI)
        let card = SettledClarifyCard(rows: [ClarifyQA(question: "Which?", answer: "", unanswered: true, choices: ["A", "B"])],
                                     key: "late-example", messageId: "m-example", answerable: true, answeredLater: false)
        ui.answerLater(card)
        let dock = try #require(ui.dockView)
        let pick: UIControl = try #require(questionControl("question.choice.1", in: dock))
        pick.sendActions(for: .touchUpInside)
        ui.dockMinimize(dock)
        #expect(dock.draft.minimized)
        ui.answerLater(card)
        #expect(ui.dockView === dock)
        #expect(!dock.draft.minimized)
        #expect(dock.draft.stages["q0"]?.choices == ["B"])
        ui.dockSkip(dock) // late questions say Cancel, not Skip
        #expect(ui.dockView == nil)
        #expect(!chat.hasPromptDock)
        #expect(client.answers.isEmpty)
    }

    @Test func minimizeIsDisabledWhileAnAnswerIsSending() async throws {
        deliver("srq-min", "clarify", ServerRequestCenterTests.clarify)
        let (chat, window, _) = try onScreen(PromptSheetStore())
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(await waitUntil { chat.promptsUI?.dockView != nil })
        let ui = try #require(chat.promptsUI)
        let dock = try #require(ui.dockView)
        let minimize: UIButton = try #require(questionControl("question.minimize", in: dock))
        for state: QuestionDockView.Sending in [.send, .skip] {
            dock.sending = state
            #expect(!minimize.isEnabled)
            ui.dockMinimize(dock)
            #expect(!dock.draft.minimized)
        }
        dock.sending = .none
        #expect(minimize.isEnabled)
    }

    @Test func explainFirstSendsContextRequestAndTallDockLeavesTranscriptRoom() async throws {
        let longChoices = (1...6).map { i in
            "Option \(i): Run canary checks across cluster-\(i) with health probes, smoke verification, and automatic rollback on error spikes"
        }
        deliver("srq-exp", "clarify", [
            "questions": [[
                "qid": "q0",
                "question": "Otto and I see different ways to stage the rollout. Which approach should we run?",
                "choices": .array(longChoices.map(JSONValue.string)),
            ]]
        ])
        let (chat, window, _) = try onScreen(PromptSheetStore())
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(await waitUntil { chat.promptsUI?.dockView != nil })
        chat.view.layoutIfNeeded()

        let ui = try #require(chat.promptsUI)
        let dock = try #require(ui.dockView)
        #expect(ui.rowsInput?.clarifyDockExpanded == true)
        #expect(ui.rowsInput?.hidesAskedNote == true)

        // Even with 6 multi-line choices, the dock caps its height when the keyboard is down so chat context stays visible.
        let maxRatio: CGFloat = DeviceWord.isMac ? 0.62 : 0.56
        #expect(dock.frame.height <= round(chat.view.bounds.height * maxRatio) + 2)

        // Minimizing reveals the in-place transcript note (`clarifyDockExpanded == false`); resuming hides it again.
        ui.dockMinimize(dock)
        #expect(ui.rowsInput?.clarifyDockExpanded == false)
        #expect(ui.rowsInput?.hidesAskedNote == false)
        let resume: UIButton = try #require(questionControl("question.resume", in: chat.view))
        resume.sendActions(for: .primaryActionTriggered)
        #expect(await waitUntil { dock.window != nil && !dock.draft.minimized })
        #expect(ui.rowsInput?.clarifyDockExpanded == true)

        // Tapping "Explain first" locks a plain-language request for context in chat rather than cancelling with `{}`.
        let explain: UIButton = try #require(questionControl("question.explain", in: dock))
        #expect(!explain.isHidden && explain.isEnabled)
        explain.sendActions(for: .primaryActionTriggered)
        #expect(await waitUntil { self.client.calls("clarify.lock").count == 1 })
        let lockCall = try #require(client.calls("clarify.lock").first)
        #expect(lockCall.params["question_id"]?.string == "q0")
        #expect(lockCall.params["answer"]?.string == QuestionDockView.explainFirstAnswer)
    }
}

@MainActor @Suite struct QuestionMinimizeLayoutTests {
    @Test func reopeningMergesReplayWithoutExpandingASavedMinimizedQuestion() {
        let prompt = ClarifyPrompt(id: "test", questions: [
            ClarifyQuestion(qid: "q0", question: "Which?", choices: ["A", "B"], multiSelect: false),
            ClarifyQuestion(qid: "q1", question: "Name?", choices: nil, multiSelect: false)
        ], lockedAnswers: ["q0": "A", "q1": "Notes"])
        let saved = ClarifyDraft(page: 1, stages: ["q0": ClarifyStage(choices: ["B"])], minimized: true)
        let draft = ClarifyStaging.initialDraft(prompt, saved: saved)
        #expect(draft.minimized)
        #expect(draft.page == 1)
        #expect(draft.stages["q0"]?.choices == ["B"])
        #expect(draft.stages["q1"]?.draft == "Notes")
        #expect(!ClarifyStaging.initialDraft(prompt, saved: nil).minimized)
    }

    @Test func resumeBarGrowsForLargeTextWithoutLosingTheTouchTarget() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let resume = QuestionResumeView()
        let dock = QuestionDockView(prompt: ClarifyPrompt(id: "test", questions: [
            ClarifyQuestion(qid: "q0", question: "Which?", choices: nil, multiSelect: false)
        ]), draft: ClarifyDraft())
        resume.show(dock)
        host.view.addSubview(resume)
        let button: UIButton = try #require(questionControl("question.resume", in: resume))
        var heights: [CGFloat] = []
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            host.traitOverrides.preferredContentSizeCategory = category
            host.view.layoutIfNeeded()
            #expect(button.traitCollection.preferredContentSizeCategory == category)
            let size = resume.systemLayoutSizeFitting(CGSize(width: 268, height: 0),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
            resume.frame = CGRect(origin: .zero, size: size)
            resume.layoutIfNeeded()
            #expect(size.height >= 44)
            #expect(button.frame.width == 268)
            #expect(button.accessibilityHint?.contains("answers kept") == true)
            heights.append(size.height)
        }
        #expect(heights[1] > heights[0], "the compact bar still respects larger text")
    }
}
