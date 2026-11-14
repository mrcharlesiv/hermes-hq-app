// Mac polish audit 2026-11-06, batch 1 (window, panes and inspector): the pure rules behind the fixes. The inspector
// takes its room only where the panes keep their layout beside it (#1), and a chat opens at the right pane's own width
// (#85).

import CoreGraphics
import Testing
@testable import HermesHQNative

@Suite struct MacPolish1Tests {
    // MARK: #1 The inspector never decides one pane or two

    /// A laptop's ~1,000 pt window is 1,299 here; the open sidebar (248) leaves 1,051 for the panes. Beside the Sessions
    /// list the inspector's 340 would leave 711, one pane: it makes way, so the chat stays beside the list. Beside a
    /// list folded into the sidebar the chat keeps its minimum, so it takes its room there.
    @Test func theInspectorMakesWayWhereTakingItWouldLeaveOnePane() {
        let laptop = CGSize(width: 1051, height: 760)
        #expect(!PaneLayout.inspectorFits(panes: laptop, inspector: 340, listFolded: false))
        #expect(PaneLayout.inspectorFits(panes: laptop, inspector: 340, listFolded: true))
        let wide = CGSize(width: 1415, height: 1000)
        #expect(PaneLayout.inspectorFits(panes: wide, inspector: 340, listFolded: false))
        #expect(PaneLayout.inspectorFits(panes: wide, inspector: 340, listFolded: true))
        // The edges: two panes need 768 beside it, the chat alone 448.
        #expect(PaneLayout.inspectorFits(panes: CGSize(width: 1108, height: 800), inspector: 340, listFolded: false))
        #expect(!PaneLayout.inspectorFits(panes: CGSize(width: 1107.5, height: 800), inspector: 340, listFolded: false))
        #expect(PaneLayout.inspectorFits(panes: CGSize(width: 788, height: 800), inspector: 340, listFolded: true))
        #expect(!PaneLayout.inspectorFits(panes: CGSize(width: 787, height: 800), inspector: 340, listFolded: true))
        // A window too short for two panes has none to keep.
        #expect(!PaneLayout.inspectorFits(panes: CGSize(width: 1415, height: 480), inspector: 340, listFolded: false))
    }

    /// The loop's cause: wherever the inspector takes its room, the panes are two both with it and without it, so a chat
    /// arriving or leaving beside it can never change one pane into two or back.
    @Test func wheneverTheInspectorFitsThePanesAreTwoEitherWay() {
        for width in stride(from: CGFloat(300), through: 2400, by: 7.5) {
            for height in [CGFloat(400), 501, 900] {
                let panes = CGSize(width: width, height: height)
                guard PaneLayout.inspectorFits(panes: panes, inspector: 340, listFolded: false) else { continue }
                #expect(PaneLayout.decide(size: panes, pad: true).isDouble)
                #expect(PaneLayout.decide(size: CGSize(width: width - 340, height: height), pad: true).isDouble)
            }
        }
    }

    // MARK: #85 A chat opens at the width it lands at

    /// The right pane as the split cuts it: the list and the hairline out, but no hairline beside a list folded into the
    /// sidebar (the opening size took a pixel off there, and the chat laid out again at 1050 → 1051).
    @Test func theRightPaneWidthMatchesTheSplitsCut() {
        #expect(PaneLayout.double(sidebar: 0).detailWidth(panes: 1051, pixel: 0.5) == 1051)
        #expect(PaneLayout.double(sidebar: 320).detailWidth(panes: 1051, pixel: 0.5) == 730.5)
        #expect(PaneLayout.double(sidebar: 375).detailWidth(panes: 1000, pixel: 1) == 624)
        #expect(PaneLayout.single.detailWidth(panes: 402, pixel: 1) == 402)
    }

    // MARK: #101 The Settings window stays on the screen

    /// A 13-inch laptop: 1470 × 956 pt, the menu bar's 33 pt and a 74 pt Dock taken off (system-frame terms, y down).
    private let laptop = CGRect(x: 0, y: 33, width: 1470, height: 849)

    @Test func theSettingsWindowOpensWhereAskedWhenItFits() {
        let asked = CGRect(x: 140, y: 120, width: 600, height: 640)
        #expect(WindowFit.inside(asked, visible: laptop) == asked)
        #expect(WindowFit.inside(asked, visible: nil) == asked)
    }

    /// Below a main window that sits low, its foot went under the Dock: it moves up, never shrinks while it fits.
    @Test func theSettingsWindowMovesUpOffTheDockAndInFromTheEdge() {
        #expect(WindowFit.inside(CGRect(x: 140, y: 400, width: 600, height: 640), visible: laptop)
                == CGRect(x: 140, y: 242, width: 600, height: 640))
        #expect(WindowFit.inside(CGRect(x: 1200, y: 10, width: 600, height: 640), visible: laptop)
                == CGRect(x: 870, y: 33, width: 600, height: 640))
        // A screen smaller than the window: as big as the visible part.
        #expect(WindowFit.inside(CGRect(x: 50, y: 50, width: 600, height: 640), visible: CGRect(x: 0, y: 25, width: 800, height: 500))
                == CGRect(x: 50, y: 25, width: 600, height: 500))
    }

    /// AppKit's screens count up from the main screen's bottom; a system frame counts down from its top.
    @Test func appKitScreenFramesTurnIntoSystemFrames() {
        let main = CGRect(x: 0, y: 0, width: 1470, height: 956)
        // The main screen's visible part: the Dock's 74 pt at the bottom, the menu bar's 33 at the top.
        #expect(WindowFit.flipped(CGRect(x: 0, y: 74, width: 1470, height: 849), main: main) == laptop)
        // A second screen above the main one.
        #expect(WindowFit.flipped(CGRect(x: 0, y: 956, width: 1920, height: 1080), main: main) == CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    // MARK: Mac feel list, section D #29: a remembered Settings window, file windows that fan out

    @Test func aWindowFrameSurvivesBeingKept() {
        let frame = CGRect(x: 412.4, y: 96.6, width: 900, height: 700)
        #expect(WindowFit.encode(frame) == "412,97,900,700")
        #expect(WindowFit.decode(WindowFit.encode(frame), minimum: CGSize(width: 320, height: 240)) == CGRect(x: 412, y: 97, width: 900, height: 700))
        // A second screen to the left or above: negative corners are kept.
        #expect(WindowFit.decode("-1500,-200,860,640", minimum: CGSize(width: 320, height: 240)) == CGRect(x: -1500, y: -200, width: 860, height: 640))
    }

    @Test func nothingKeptOrADamagedFrameIsNoFrame() {
        let minimum = CGSize(width: 320, height: 240)
        #expect(WindowFit.decode(nil, minimum: minimum) == nil)
        #expect(WindowFit.decode("", minimum: minimum) == nil)
        #expect(WindowFit.decode("10,20,860", minimum: minimum) == nil)
        #expect(WindowFit.decode("10,20,860,tall", minimum: minimum) == nil)
        #expect(WindowFit.decode("10,20,100,640", minimum: minimum) == nil)   // narrower than a window can be
        #expect(WindowFit.decode("10,20,860,0", minimum: minimum) == nil)
    }

    @Test func theFirstFileWindowOpensWhereAsked() {
        let asked = CGRect(x: 120, y: 110, width: 700, height: 500)
        #expect(WindowFit.cascaded(asked, taken: [], visible: laptop) == asked)
        // One sitting somewhere else is not in the way.
        #expect(WindowFit.cascaded(asked, taken: [CGPoint(x: 400, y: 300)], visible: laptop) == asked)
    }

    @Test func eachFurtherFileWindowOpensAStepDownAndRight() {
        let asked = CGRect(x: 120, y: 110, width: 700, height: 500)
        #expect(WindowFit.cascaded(asked, taken: [CGPoint(x: 120, y: 110)], visible: laptop) == asked.offsetBy(dx: 28, dy: 28))
        #expect(WindowFit.cascaded(asked, taken: [CGPoint(x: 120, y: 110), CGPoint(x: 148, y: 138)], visible: laptop)
                == asked.offsetBy(dx: 56, dy: 56))
        // The first one was closed or moved away: its place is free again.
        #expect(WindowFit.cascaded(asked, taken: [CGPoint(x: 148, y: 138)], visible: laptop) == asked)
        // No screen known: still a step apart.
        #expect(WindowFit.cascaded(asked, taken: [CGPoint(x: 120, y: 110)], visible: nil) == asked.offsetBy(dx: 28, dy: 28))
    }

    @Test func aFanThatReachesTheScreensFootStartsAgainAtTheTop() {
        // 849 pt of screen from y 33: a 500 pt window at y 362 has 20 pt under it, less than a step.
        let asked = CGRect(x: 120, y: 362, width: 700, height: 500)
        let next = WindowFit.cascaded(asked, taken: [CGPoint(x: 120, y: 362)], visible: laptop)
        #expect(next == CGRect(x: 28, y: 61, width: 700, height: 500))
        // And never loops: with the top place taken too it stays on screen.
        let third = WindowFit.cascaded(asked, taken: [CGPoint(x: 120, y: 362), CGPoint(x: 28, y: 61)], visible: laptop)
        #expect(laptop.contains(third))
        #expect(third == CGRect(x: 56, y: 89, width: 700, height: 500))
    }
}
