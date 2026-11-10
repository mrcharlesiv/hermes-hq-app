// [m9/ipad] The pure rules (docs/spec/3x-ipad.md §9): one pane or two, Escape's ladder, Return, Next / Previous Chat.

import CoreGraphics
import Testing
@testable import HermesHQNative

struct PaneLayoutTests {
    @Test func thresholdsAreTheWebPhoneQuery() {
        #expect(PaneLayout.decide(size: CGSize(width: 767.5, height: 1024), pad: true) == .single)
        #expect(PaneLayout.decide(size: CGSize(width: 768, height: 501), pad: true) == .double(sidebar: 320))
        #expect(PaneLayout.decide(size: CGSize(width: 768, height: 500), pad: true) == .single)
        #expect(PaneLayout.decide(size: CGSize(width: 768, height: 500.9), pad: true) == .single)
        #expect(PaneLayout.decide(size: CGSize(width: 999, height: 800), pad: true) == .double(sidebar: 375))
        #expect(PaneLayout.decide(size: CGSize(width: 1000, height: 800), pad: true) == .double(sidebar: 375))
        #expect(PaneLayout.decide(size: CGSize(width: 1366, height: 1024), pad: true) == .double(sidebar: 375))
        #expect(PaneLayout.decide(size: CGSize(width: 320, height: 480), pad: true) == .single)
        #expect(PaneLayout.decide(size: .zero, pad: true) == .single)
    }

    @Test func iPadMiniIsPhoneLayoutInPortraitAndTwoPanesInLandscape() {
        #expect(PaneLayout.decide(size: CGSize(width: 744, height: 1133), pad: true) == .single)
        #expect(PaneLayout.decide(size: CGSize(width: 1133, height: 744), pad: true) == .double(sidebar: 375))
    }

    /// [duo] iPhone Duo: 466×678 pt folded, 626×890 pt open. Its root is the iPad's, so the iPad's rule applies.
    @Test func iPhoneDuoIsOnePaneFoldedOrUprightAndTwoPanesSideways() {
        #expect(PaneLayout.decide(size: CGSize(width: 466, height: 678), pad: true) == .single)
        #expect(PaneLayout.decide(size: CGSize(width: 626, height: 890), pad: true) == .single)
        #expect(PaneLayout.decide(size: CGSize(width: 890, height: 626), pad: true) == .double(sidebar: 375))
    }

    /// The Duo's open screen (669×951 pt, either way up) turns sideways; the folded one (466×678) stays upright.
    @Test func onlyTheDuosOpenScreenTurns() {
        #expect(PaneLayout.unfolded(screen: CGSize(width: 669, height: 951)))
        #expect(PaneLayout.unfolded(screen: CGSize(width: 951, height: 669)))
        #expect(!PaneLayout.unfolded(screen: CGSize(width: 466, height: 678)))
        #expect(!PaneLayout.unfolded(screen: CGSize(width: 678, height: 466)))
    }

    @Test func onlyAnIPhoneWiderThanAnyFlatOneFolds() {
        for screen in [CGSize(width: 466, height: 678), CGSize(width: 678, height: 466), CGSize(width: 626, height: 890)] {
            #expect(PaneLayout.foldable(screen: screen))
        }
        // SE, mini, 17, Air, 17 Pro Max, upright and sideways.
        for screen in [CGSize(width: 375, height: 667), CGSize(width: 375, height: 812), CGSize(width: 402, height: 874),
                       CGSize(width: 420, height: 912), CGSize(width: 440, height: 956), CGSize(width: 956, height: 440)] {
            #expect(!PaneLayout.foldable(screen: screen))
        }
    }

    /// A Duo launched folded with a pre-27.1 SDK build sees 386×678 (the sensor column left out): its model says it
    /// folds. Open sideways it is 871×669 there, two panes.
    @Test func aDuoLaunchedFoldedIsStillFoldable() {
        let folded = CGSize(width: 386, height: 678)
        #expect(!PaneLayout.foldable(screen: folded))
        #expect(PaneLayout.foldable(model: "iPhone19,4", screen: folded, seenOpen: false))
        #expect(PaneLayout.foldable(model: "iPhone19,9", screen: folded, seenOpen: true))
        #expect(!PaneLayout.foldable(model: "iPhone19,2", screen: CGSize(width: 440, height: 956), seenOpen: false))
        #expect(PaneLayout.unfolded(screen: CGSize(width: 871, height: 669)))
        #expect(!PaneLayout.unfolded(screen: folded))
        #expect(PaneLayout.decide(size: CGSize(width: 871, height: 669), pad: true) == .double(sidebar: 375))
    }

    /// The open Duo upright (669 pt edge to edge, 27.2 SDK) shows a 300 pt list beside the chat, as Hermes Agent does;
    /// folded (466) stays one pane, sideways keeps the iPad's widths. An iPad's narrow window is not a Duo's.
    @Test func anOpenDuoUprightIsTwoPanes() {
        #expect(PaneLayout.decide(size: CGSize(width: 669, height: 951), pad: true, foldable: true) == .double(sidebar: 300))
        #expect(PaneLayout.decide(size: CGSize(width: 466, height: 678), pad: true, foldable: true) == .single)
        #expect(PaneLayout.decide(size: CGSize(width: 589, height: 951), pad: true, foldable: true) == .single)
        #expect(PaneLayout.decide(size: CGSize(width: 951, height: 669), pad: true, foldable: true) == .double(sidebar: 375))
        #expect(PaneLayout.decide(size: CGSize(width: 669, height: 951), pad: true) == .single)
    }

    @Test func aPhoneIsAlwaysOnePane() {
        for size in [CGSize(width: 402, height: 874), CGSize(width: 956, height: 440), CGSize(width: 1366, height: 1024)] {
            #expect(PaneLayout.decide(size: size, pad: false) == .single)
        }
    }

    @Test func theListPaneWidensWhileTheChatKeepsTheWebMinimum() {
        // An 820 pt portrait iPad (Air, 10th gen) gets a phone-wide list, not 320 pt.
        #expect(PaneLayout.decide(size: CGSize(width: 820, height: 1180), pad: true) == .double(sidebar: 372))
        #expect(PaneLayout.decide(size: CGSize(width: 808, height: 1000), pad: true) == .double(sidebar: 360))
        #expect(PaneLayout.decide(size: CGSize(width: 834, height: 1194), pad: true) == .double(sidebar: 375))
        for width in stride(from: CGFloat(768), through: 1400, by: 1) {
            let sidebar = PaneLayout.decide(size: CGSize(width: width, height: 900), pad: true).sidebar
            #expect(sidebar >= 320 && sidebar <= 375)
            #expect(width - sidebar >= 448)
        }
    }

    /// [mac] The width the Mac's list pane was dragged to, kept in bounds.
    @Test func aDraggedListPaneStaysBetweenItsLimits() {
        #expect(PaneLayout.decide(size: CGSize(width: 1662, height: 1039), pad: true, preferred: 440) == .double(sidebar: 440))
        #expect(PaneLayout.decide(size: CGSize(width: 1662, height: 1039), pad: true, preferred: 200) == .double(sidebar: 320))
        #expect(PaneLayout.decide(size: CGSize(width: 1662, height: 1039), pad: true, preferred: 900) == .double(sidebar: 640))
        #expect(PaneLayout.decide(size: CGSize(width: 900, height: 1039), pad: true, preferred: 600) == .double(sidebar: 452))
        #expect(PaneLayout.decide(size: CGSize(width: 768, height: 1039), pad: true, preferred: 600) == .double(sidebar: 320))
        #expect(PaneLayout.decide(size: CGSize(width: 700, height: 1039), pad: true, preferred: 440) == .single)
    }

    @Test func theChatBesideTheNarrowSidebarKeepsTheWebMinimum() {
        #expect(PaneLayout.minWidth - PaneLayout.narrowSidebar == 448)      // the web's --chat-min-width: 28rem
        #expect(PaneLayout.double(sidebar: 320).isDouble)
        #expect(!PaneLayout.single.isDouble)
        #expect(PaneLayout.single.sidebar == 0)
    }

    @Test func readableColumn() {
        #expect(ReadableColumn.fit(pane: 448).width == 448)
        #expect(ReadableColumn.fit(pane: 448).margin == 0)
        #expect(ReadableColumn.fit(pane: 760).width == 760)
        #expect(ReadableColumn.fit(pane: 991).width == 760)
        #expect(ReadableColumn.fit(pane: 991).margin == 115)
    }
}

struct EscapeLadderTests {
    typealias State = EscapeAction.State

    @Test func firstMatchWins() {
        #expect(EscapeAction.decide(State()) == .nothing)
        #expect(EscapeAction.decide(State(alert: true, presented: true, running: true)) == .system)
        #expect(EscapeAction.decide(State(presented: true, find: true, running: true)) == .dismissPresented)
        #expect(EscapeAction.decide(State(find: true, recording: true, running: true)) == .closeFind)
        #expect(EscapeAction.decide(State(recording: true, searching: true, running: true)) == .cancelRecording)
        #expect(EscapeAction.decide(State(searching: true, question: true, running: true)) == .cancelSearch)
        #expect(EscapeAction.decide(State(running: true, fieldFocused: true)) == .stop)
        #expect(EscapeAction.decide(State(running: true)) == .stop)
        #expect(EscapeAction.decide(State(fieldFocused: true)) == .resignField)
    }

    @Test func aWaitingQuestionIsNeverAnsweredOrStopped() {
        #expect(EscapeAction.decide(State(question: true, running: true, fieldFocused: true)) == .nothing)
        #expect(EscapeAction.decide(State(question: true)) == .nothing)
    }

    @Test func aSheetOverARunningReplyOnlyClosesTheSheet() {
        // Every state with something presented never stops the reply behind it.
        for find in [false, true] { for running in [false, true] { for question in [false, true] {
            let action = EscapeAction.decide(State(presented: true, find: find, question: question, running: running))
            #expect(action == .dismissPresented)
        } } }
    }
}

struct ReturnKeyTests {
    @Test func hardwareReturnSends() {
        #expect(ReturnKey.decide(hardware: true, shift: false, option: false, marked: false, empty: false) == .send)
    }

    @Test func shiftOrOptionAddsALine() {
        #expect(ReturnKey.decide(hardware: true, shift: true, option: false, marked: false, empty: false) == .newline)
        #expect(ReturnKey.decide(hardware: true, shift: false, option: true, marked: false, empty: false) == .newline)
        #expect(ReturnKey.decide(hardware: true, shift: true, option: false, marked: false, empty: true) == .newline)
    }

    @Test func anEmptyFieldSendsNothingAndAddsNoLine() {
        #expect(ReturnKey.decide(hardware: true, shift: false, option: false, marked: false, empty: true) == .swallow)
    }

    @Test func aCompositionIsConfirmedNeverSent() {
        #expect(ReturnKey.decide(hardware: true, shift: false, option: false, marked: true, empty: false) == .pass)
        #expect(ReturnKey.decide(hardware: true, shift: true, option: false, marked: true, empty: false) == .pass)
    }

    @Test func theOnScreenKeyboardKeepsItsOwnReturn() {
        #expect(ReturnKey.decide(hardware: false, shift: false, option: false, marked: false, empty: false) == .pass)
    }
}

struct ChatWalkTests {
    let order = ["a", "b", "c"]

    @Test func walksInListOrderWithoutWrapping() {
        #expect(ChatWalk.target(order: order, current: "a", forward: true) == "b")
        #expect(ChatWalk.target(order: order, current: "b", forward: true) == "c")
        #expect(ChatWalk.target(order: order, current: "c", forward: true) == nil)
        #expect(ChatWalk.target(order: order, current: "c", forward: false) == "b")
        #expect(ChatWalk.target(order: order, current: "a", forward: false) == nil)
    }

    @Test func withNothingOpenNextIsTheFirstRow() {
        #expect(ChatWalk.target(order: order, current: nil, forward: true) == "a")
        #expect(ChatWalk.target(order: order, current: nil, forward: false) == nil)
    }

    @Test func aChatThatLeftTheListStartsFromTheTop() {
        // The chat on show is hidden by a filter or a collapsed section: its key is not in the visible order.
        #expect(ChatWalk.target(order: order, current: "hidden", forward: true) == "a")
        #expect(ChatWalk.target(order: order, current: "hidden", forward: false) == nil)
    }

    @Test func anEmptyListGoesNowhere() {
        #expect(ChatWalk.target(order: [], current: nil, forward: true) == nil)
        #expect(ChatWalk.target(order: [], current: "a", forward: false) == nil)
    }

    @Test func aReorderMidWalkContinuesFromTheNewPosition() {
        #expect(ChatWalk.target(order: ["c", "a", "b"], current: "a", forward: true) == "b")
        #expect(ChatWalk.target(order: ["c", "a", "b"], current: "a", forward: false) == "c")
    }
}
