// Memo views drawn for real (spec 1x-voice §3.5, §5): the hold row's "Release to Cancel" and its orange last 10 s (E-4
// and E-16 can't see them: the finger owns the hold row, hidden from the accessibility tree, and XCUITest can't look
// while a press is held), the locked row's orange timer, and a reused cell that leaves a memo behind.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@Suite("Memo views")
@MainActor
struct MemoViewTests {
    @Test func holdRowSaysReleaseToCancelPastTheLine() {
        let row = MemoHoldRow(frame: CGRect(x: 0, y: 0, width: 300, height: 40))
        row.update(seconds: 2, limit: 600, dx: -20, armed: false)
        #expect(row.slideWords == "Slide to cancel")
        #expect(row.slideColor == ChatPalette.label2)
        row.update(seconds: 2, limit: 600, dx: -150, armed: true)
        #expect(row.slideWords == "Release to Cancel")
        #expect(row.slideColor == ChatPalette.red)
        row.update(seconds: 2, limit: 600, dx: -10, armed: false)
        #expect(row.slideWords == "Slide to cancel", "back over the line: the words come back")
    }

    @Test func timersTurnOrangeInTheLastTenSeconds() {
        let hold = MemoHoldRow(frame: CGRect(x: 0, y: 0, width: 300, height: 40))
        hold.update(seconds: 1.5, limit: 12, dx: 0, armed: false)
        #expect(hold.timerColor == ChatPalette.label, "0:01 of a 12 s limit")
        hold.update(seconds: 2.1, limit: 12, dx: 0, armed: false)
        #expect(hold.timerColor == ChatPalette.orange, "0:02 of a 12 s limit: orange")
        let locked = MemoLockedRow(frame: CGRect(x: 0, y: 0, width: 300, height: 40))
        locked.showLocked(seconds: 1, limit: 12, level: 0.6, levels: [0.3, 0.6], ending: false)
        #expect(locked.timerColor == ChatPalette.label)
        locked.showLocked(seconds: 2.5, limit: 12, level: 0.6, levels: [0.3, 0.6], ending: false)
        #expect(locked.timerColor == ChatPalette.orange)
    }

    /// A reused cell that now shows a text bubble hides its memo view and makes it forget the memo.
    @Test func aReusedCellLetsTheMemoGo() throws {
        let style = ChatStyle.make(category: .large)
        func row(_ text: String) -> ChatRow {
            let message = ChatMessage(id: "stored-row-9-user", role: .user, parts: [.text(text)], timestamp: Date(), rowId: 9)
            let input = ChatRowBuilder.Input(messages: [message], isRunning: false, botName: "Ivy", expanded: [], scope: "t|ivy|s")
            return ChatRowBuilder.build(input).first(where: \.isBubble)!
        }
        let memoRow = row("MEDIA:\"/g/voice-memo.m4a\"\n\nVoice memo transcript: Pick up milk.")
        let textRow = row("Just words.")
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: nil)
        let memoLayout = TextLayout.make(memoRow, width: 402, style: style)
        cell.frame = CGRect(x: 0, y: 0, width: 402, height: memoLayout.height)
        cell.configure(memoRow, layout: memoLayout)
        let view = try #require(Self.memoView(in: cell))
        #expect(view.geometry != nil && !view.isHidden)
        let textLayout = TextLayout.make(textRow, width: 402, style: style)
        cell.configure(textRow, layout: textLayout)
        #expect(view.isHidden)
        #expect(view.geometry == nil, "the hidden view keeps no memo")
    }

    // MARK: Helpers (shared with the layout tests)

    static func memoView(in view: UIView) -> MemoBubbleView? {
        if let memo = view as? MemoBubbleView { return memo }
        for sub in view.subviews { if let hit = memoView(in: sub) { return hit } }
        return nil
    }

    /// The frames of what a memo view draws: each visible part, a button by its title (its 44 pt target may reach into
    /// the padding).
    static func drawnFrames(_ view: MemoBubbleView) -> [CGRect] {
        view.subviews.filter { !$0.isHidden && $0.alpha > 0 }.compactMap { sub -> CGRect? in
            if let button = sub as? UIButton {
                button.layoutIfNeeded()
                guard let title = button.titleLabel, title.bounds.height > 0 else { return nil }
                return view.convert(title.bounds, from: title)
            }
            return sub.frame
        }
    }

    /// Every part's frame by identity (visible or not), to compare before and after.
    static func frames(_ view: MemoBubbleView) -> [CGRect] { view.subviews.map(\.frame) }
}
