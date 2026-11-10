import Foundation
import Testing
import UIKit
@testable import HermesHQNative

// [perf] The composer stream's fixes (app optimization #31–#35): work that ran with nothing to show for it.

@MainActor
struct ComposerPerfTests {
    // MARK: #33 The status pill's dots stop once it fades out

    @Test func statusPillDotsStopWhenThePillHides() async throws {
        guard !HQMotion.reduced else { return }
        let pill = ChatStatusPill(frame: CGRect(x: 0, y: 0, width: 200, height: 22))
        pill.set("Working…")
        #expect(pill.dotsAnimating)
        pill.set(nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!pill.dotsAnimating)
        pill.set("Working…")
        #expect(pill.dotsAnimating)
        // Quiet words hide the dots: they don't run either.
        pill.set("Offline")
        #expect(!pill.dotsAnimating)
    }

    // MARK: #34 The dark glow re-snapshots only when the text changed

    @Test func darkShimmerSnapshotsOnlyWhenTheTokenChanges() {
        guard !HQMotion.reduced else { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            Issue.record("no window scene"); return
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
        window.overrideUserInterfaceStyle = .dark
        window.isHidden = false
        defer { window.isHidden = true }
        let view = TextDrawView(frame: CGRect(x: 0, y: 0, width: 200, height: 20))
        window.addSubview(view)
        #expect(view.traitCollection.userInterfaceStyle == .dark)
        view.set(NSAttributedString(string: "Running a tool"), width: 200)
        let start = Shimmer.snapshotCount
        Shimmer.set(true, on: view, contentToken: view.drawGeneration)
        #expect(Shimmer.snapshotCount == start + 1)
        Shimmer.set(true, on: view, contentToken: view.drawGeneration)
        #expect(Shimmer.snapshotCount == start + 1)
        // The same string again keeps its drawing (and the glow).
        view.set(NSAttributedString(string: "Running a tool"), width: 200)
        Shimmer.set(true, on: view, contentToken: view.drawGeneration)
        #expect(Shimmer.snapshotCount == start + 1)
        view.set(NSAttributedString(string: "Running a tool, longer"), width: 200)
        Shimmer.set(true, on: view, contentToken: view.drawGeneration)
        #expect(Shimmer.snapshotCount == start + 2)
        // No token: every call, as before.
        Shimmer.set(true, on: view)
        #expect(Shimmer.snapshotCount == start + 3)
    }

    @Test func tickerGenerationFollowsItsText() {
        let ticker = TickerView(frame: CGRect(x: 0, y: 0, width: 200, height: 20))
        let g0 = ticker.drawGeneration
        ticker.set("Reading files", animated: false)
        let g1 = ticker.drawGeneration
        #expect(g1 > g0)
        ticker.set("Reading files", animated: false)
        let (color, font) = (ticker.color, ticker.font)
        ticker.color = color
        ticker.font = font
        #expect(ticker.drawGeneration == g1)
        ticker.set("Writing", animated: false)
        #expect(ticker.drawGeneration > g1)
    }

    // MARK: #35 One drawer refresh per keystroke

    private final class Completing: ChatCompleting {
        var completionsOnline: Bool { false }
        var completionFolder: String? { nil }
        func completeSlash(_ text: String) async throws -> ComposerDrawerModel.Answer { throw CancellationError() }
        func completePath(_ word: String) async throws -> ComposerDrawerModel.Answer { throw CancellationError() }
        func completionFolderReadable(_ folder: String) async -> Bool { true }
    }

    @Test func aKeystrokeRefreshesTheDrawerOnce() {
        let composer = ComposerView(frame: CGRect(x: 0, y: 0, width: 402, height: 60))
        let host = ComposerDrawerHost(
            loadCatalog: { throw CancellationError() }, latestCatalog: { nil }, isBotChat: { true }, ownProfile: { "" },
            bots: { [] }, recentChats: { [] }, sendCommand: { _ in }, openModels: {}, openChat: { _ in }, enabled: { true })
        let drawer = ComposerDrawerController(composer: composer, completing: Completing(), host: host)
        let start = drawer.refreshCount
        composer.text = "hello"                     // the text changed (its own report)
        composer.onDrawerInput?()                   // the selection moved to the same place
        #expect(drawer.refreshCount == start + 1)
        composer.textView.selectedRange = NSRange(location: 2, length: 0)
        composer.onDrawerInput?()
        #expect(drawer.refreshCount > start + 1)
        // A close always refreshes, even for the same text and caret.
        let before = drawer.refreshCount
        drawer.close()
        #expect(drawer.refreshCount == before + 1)
    }

    /// The iOS look's bar is two rows from the start (owner 2026-11-01): the text has the whole top row, so the mic
    /// giving way to Send in the row below moves nothing beside the words.
    @Test func typingKeepsTheInsetAndTheMicLayout() {
        let composer = ComposerView(frame: CGRect(x: 0, y: 0, width: 402, height: 60))
        composer.micAvailable = true
        composer.layoutIfNeeded()
        let emptyWidth = composer.textView.frame.width
        composer.text = "h"
        composer.layoutIfNeeded()
        #expect(composer.textView.frame.width == emptyWidth)   // the words already had the whole row
        composer.text = "hi"
        #expect(!composer.layer.needsLayout())     // nothing moved: no layout for a keystroke
        composer.text = ""
        composer.layoutIfNeeded()
        #expect(composer.textView.frame.width == emptyWidth)   // and keep it when emptied
    }

    // MARK: #31 The delegate cards rebuild only when what they read changed

    @Test func cardsRebuildOnlyWhenWhatTheyReadChanged() {
        let child = SubagentProgress(id: "c1", parentId: nil, goal: "Look", sessionId: nil, delegationId: nil, model: nil,
                                     status: .running, taskCount: 1, taskIndex: 0, startedAt: 1, updatedAt: 1,
                                     durationSeconds: nil, inputTokens: nil, outputTokens: nil, toolCount: nil)
        let controller = ChatViewController(session: SpyChatSession()).activity
        var activity = ChatActivity()
        activity.subagents = [child]
        #expect(controller.cardsNeedRebuild(subagents: activity.subagents, turnAnchor: "m1"))      // the first delivery
        // A todo tick and a tail read leave the cards as they were.
        activity.liveTodos = [TodoItem(id: "1", content: "Do", status: .inProgress)]
        activity.tails["c1"] = SubagentTail(available: true, text: "tail", truncated: false)
        #expect(!controller.cardsNeedRebuild(subagents: activity.subagents, turnAnchor: "m1"))
        // A child's status: once, then not again.
        activity.subagents[0].status = .completed
        #expect(controller.cardsNeedRebuild(subagents: activity.subagents, turnAnchor: "m1"))
        #expect(!controller.cardsNeedRebuild(subagents: activity.subagents, turnAnchor: "m1"))
        // The hidden turn moved on.
        #expect(controller.cardsNeedRebuild(subagents: activity.subagents, turnAnchor: "m2"))
        // A settings or display-flags change: the next delivery rebuilds even with nothing new.
        controller.invalidateCards()
        #expect(controller.cardsNeedRebuild(subagents: activity.subagents, turnAnchor: "m2"))
    }
}
