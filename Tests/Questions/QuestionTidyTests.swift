// [question-tidy] Owner 2026-11-10 (design pick 2): the first pick-one page has no foot until it has an answer, since a
// tap on a choice moves on by itself.

import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite struct QuestionTidyTests {
    private let branch = ClarifyQuestion(qid: "q0", question: "Branch?", choices: ["main (Recommended)", "staging"], multiSelect: false)
    private let checks = ClarifyQuestion(qid: "q1", question: "Checks?", choices: ["Tests", "Lint"], multiSelect: true)
    private let branch2 = ClarifyQuestion(qid: "q3", question: "Region?", choices: ["us", "eu"], multiSelect: false)
    private let name = ClarifyQuestion(qid: "q2", question: "Name?", choices: nil, multiSelect: false)

    private func dock(_ questions: [ClarifyQuestion], _ draft: ClarifyDraft = ClarifyDraft(page: 0, stages: [:])) -> QuestionDockView {
        QuestionDockView(prompt: ClarifyPrompt(id: "srq-t", questions: questions), draft: draft)
    }

    @Test func theFirstPickOnePageHasNoFootUntilItIsAnswered() {
        #expect(dock([branch, checks]).footHidden)
        let answered = ClarifyDraft(page: 0, stages: ["q0": ClarifyStage(choices: ["staging"])])
        #expect(!dock([branch, checks], answered).footHidden, "Next is back, so the page can be left again after Back")
        let typing = ClarifyDraft(page: 0, stages: ["q0": ClarifyStage(choices: [], draft: "", other: true)])
        #expect(!dock([branch, checks], typing).footHidden, "Something else… needs Next")
    }

    private func find<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if view.accessibilityIdentifier == id, let hit = view as? T { return hit }
        for sub in view.subviews { if let hit: T = find(id, in: sub) { return hit } }
        return nil
    }

    /// The whole move on a card that is on screen: a tap on a choice shows page 2 by itself, Back returns to an
    /// answered page 1 that has Next again, and a tap on the last page never sends.
    @Test func aTapOnAPickOneChoiceMovesOn() async throws {
        let dock = dock([branch, checks, branch2])
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.isHidden = false
        dock.frame = CGRect(x: 8, y: 300, width: 374, height: 400)
        host.view.addSubview(dock)
        dock.layoutIfNeeded()
        defer { window.isHidden = true }

        let page0 = try #require(find("question.page.0", in: dock))
        let choice: UIControl = try #require(find("question.choice.1", in: page0))
        choice.sendActions(for: .touchUpInside)
        #expect(dock.page == 0, "the mark shows first")
        try await Task.sleep(for: .milliseconds(Int(QuestionDockView.advanceDelay * 1000) + 250))
        #expect(dock.page == 1, "then the next question")
        #expect(dock.draft.stages["q0"]?.choices == ["staging"])

        let back: UIButton = try #require(find("question.back", in: dock))
        back.sendActions(for: .primaryActionTriggered)
        #expect(dock.page == 0)
        #expect(!dock.footHidden, "answered: Next is there to leave the page again")

        // Page 2 is choose-any: a tap stays. The last page is pick-one: a tap stays too (Send sends).
        let next: UIButton = try #require(find("question.primary", in: dock))
        next.sendActions(for: .primaryActionTriggered)
        let page1 = try #require(find("question.page.1", in: dock))
        let any: UIControl = try #require(find("question.choice.0", in: page1))
        any.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(Int(QuestionDockView.advanceDelay * 1000) + 250))
        #expect(dock.page == 1, "choose any: Next moves on, not the tap")
        next.sendActions(for: .primaryActionTriggered)
        #expect(dock.page == 2)
        let page2 = try #require(find("question.page.2", in: dock))
        let last: UIControl = try #require(find("question.choice.0", in: page2))
        last.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(Int(QuestionDockView.advanceDelay * 1000) + 250))
        #expect(dock.page == 2, "the last page's tap never sends")
        #expect(dock.sending == .none)
    }

    @Test func otherPagesKeepTheirFoot() {
        #expect(!dock([branch]).footHidden, "one question: its page is the last, and Send sends")
        #expect(!dock([checks, branch]).footHidden, "choose any: Next moves on")
        #expect(!dock([name, branch]).footHidden, "a typed answer: Next moves on")
        #expect(!dock([branch, checks], ClarifyDraft(page: 1, stages: [:])).footHidden, "a later page has Back")
    }
}
