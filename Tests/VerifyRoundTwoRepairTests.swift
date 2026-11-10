// Regression tests for the m2/integrate verify round 2 repairs: the composer field measured at its own width, the
// activity shelf's room, a reopened chat's shelf from its first frame, and the can't-reach wording on the pages.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor
@Suite("Verify round 2 repairs", .serialized)
struct VerifyRoundTwoRepairTests {

    // MARK: Composer: the field's height follows the width its text gets

    private func hostedComposer(width: CGFloat) -> (UIWindow, ComposerView)? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return nil }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 874)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let composer = ComposerView(frame: .zero)
        composer.showsCommands = true
        composer.leadingAccessories = [UIView()]
        root.view.addSubview(composer)
        return (window, composer)
    }

    /// The field's height for the text view's current width, as the composer computes it (no scrolling below the cap).
    private func expectedHeight(_ composer: ComposerView) -> CGFloat {
        let text = composer.textView
        let fitting = text.sizeThatFits(CGSize(width: text.bounds.width, height: .greatestFiniteMagnitude)).height
        let line = text.font?.lineHeight ?? 20
        let inset = text.textContainerInset
        let cap = ceil(line * 6 + inset.top + inset.bottom)
        // [composer-expand] The iOS look's bar holding words is two rows: the text, then the buttons' row below it.
        let rows = composer.toolbarHeight
        return rows > 0 ? min(ceil(fitting), cap) + rows : max(ChatMetrics.control, min(ceil(fitting), cap))
    }

    @Test func aDraftRestoredBeforeLayoutIsMeasuredAtTheFieldsRealWidth() {
        guard let (window, composer) = hostedComposer(width: 402) else { Issue.record("no window scene"); return }
        // The draft lands before the row has any width (a reopened chat restores it in viewDidLoad).
        composer.text = (1...17).map { ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                                        "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen"][$0 - 1] }.joined(separator: " ")
        composer.frame = CGRect(x: 0, y: 700, width: 402, height: composer.intrinsicContentSize.height)
        composer.layoutIfNeeded()
        composer.frame.size.height = composer.intrinsicContentSize.height
        composer.layoutIfNeeded()
        #expect(composer.textView.bounds.width > 100)
        #expect(abs(composer.intrinsicContentSize.height - expectedHeight(composer)) < 0.5,
                "field \(composer.intrinsicContentSize.height) vs its text \(expectedHeight(composer)) at \(composer.textView.bounds.width) pt")
        _ = window
    }

    @Test func aNarrowerRowMeasuresTheDraftAgain() {
        guard let (window, composer) = hostedComposer(width: 402) else { Issue.record("no window scene"); return }
        composer.frame = CGRect(x: 0, y: 700, width: 402, height: 40)
        composer.layoutIfNeeded()
        composer.text = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen"
        composer.frame.size.height = composer.intrinsicContentSize.height
        composer.layoutIfNeeded()
        let wide = composer.intrinsicContentSize.height
        // The same row 120 pt narrower (what the keyboard's side inset and the recorder do to the field's width).
        composer.frame.size.width = 282
        composer.layoutIfNeeded()
        composer.frame.size.height = composer.intrinsicContentSize.height
        composer.layoutIfNeeded()
        #expect(composer.intrinsicContentSize.height > wide, "more lines in a narrower field")
        #expect(abs(composer.intrinsicContentSize.height - expectedHeight(composer)) < 0.5)
        _ = window
    }

    // MARK: Activity shelf: never taller than the room it has

    private final class FixedBody: UIView {
        let height: CGFloat
        init(height: CGFloat) { self.height = height; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority h: UILayoutPriority,
                                              verticalFittingPriority v: UILayoutPriority) -> CGSize {
            CGSize(width: targetSize.width, height: height)
        }
    }

    @Test func openedCardsGiveWayWhenTheShelfRunsOutOfRoom() {
        let shelf = ActivityShelfView(frame: .zero)
        let goal = shelf.piece(.goal) { ShelfPieceView(kind: .goal, body: FixedBody(height: 300)) }
        let tasks = shelf.piece(.tasks) { ShelfPieceView(kind: .tasks, body: FixedBody(height: 160)) }
        let subagents = shelf.piece(.subagents) { ShelfPieceView(kind: .subagents, body: FixedBody(height: 10)) }
        for piece in [goal, tasks, subagents] { piece.setPresent(true, animated: false) }
        goal.setOpen(true, animated: false)
        tasks.setOpen(true, animated: false)
        shelf.maxCardHeight = 280
        let natural = shelf.height(for: 386)
        #expect(natural == 280 + (44 + 160) + 44 + 2 * ActivityShelfView.gap)
        shelf.maxHeight = 300
        #expect(shelf.height(for: 386) <= 300.5, "the shelf fits its room")
        let frames = shelf.targetFrames(width: 386)
        #expect(frames[.subagents]?.height == 44, "a folded chip never shrinks")
        #expect((frames[.goal]?.height ?? 0) >= 44 + ActivityShelfView.minCardBody - 0.5)
        #expect((frames[.tasks]?.height ?? 0) >= 44 + ActivityShelfView.minCardBody - 0.5)
        shelf.maxHeight = 100
        #expect(shelf.height(for: 386) == 2 * (44 + ActivityShelfView.minCardBody) + 44 + 2 * ActivityShelfView.gap,
                "no further than a header and a little body each")
    }

    // MARK: Activity: a chat not bound yet shows what an earlier open of it knew

    @Test func anUnboundChatReadsItsStateByStoredId() {
        let store = ActivityStore(client: FakeGatewayClient(), frameMode: .manual)
        store.bind(runtimeId: "rt-1", profile: "default", storedId: "s1")
        store.applyResume(["session_id": "rt-1", "running": false,
                           "todo_state": ["todos": [["id": "1", "content": "A", "status": "completed"]], "revision": 3]],
                          runtimeId: "rt-1")
        let reopened = store.activity(storedIds: ["s1"], profile: "default")
        #expect(reopened.liveTodos == nil, "a finished list on an idle open goes straight to Previous tasks")
        #expect(reopened.retainedTodos.count == 1)
        #expect(store.activity(storedIds: ["s1"], profile: "ivy").retainedTodos.isEmpty, "another bot's chat")
        #expect(store.activity(storedIds: ["s2"], profile: "default").retainedTodos.isEmpty)
    }

    // MARK: Pages: a gateway that can't be reached says so

    @Test func transportFailuresReadAsCantReachTheGateway() {
        let unreachable = GatewayFailure.unreachable.message
        for code in [URLError.Code.cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost] {
            #expect(PagesREST.reason(URLError(code)) == unreachable, "\(code)")
            #expect(CapabilitiesStore.detail(URLError(code)) == unreachable, "\(code)")
        }
        #expect(PagesREST.reason(URLError(.timedOut)) == GatewayFailure.timeout.message)
        #expect(PagesREST.reason(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)) == unreachable)
        // A refusal keeps the gateway's own words.
        #expect(PagesREST.reason(HTTPError(status: 409, body: #"{"detail": "Refused by the probe"}"#)) == "Refused by the probe")
    }
}
