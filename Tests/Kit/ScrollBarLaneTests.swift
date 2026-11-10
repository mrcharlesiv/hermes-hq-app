import Testing
import UIKit
@testable import HermesHQNative

/// Owner 2026-10-29: "the scrollbar (at least on horizontal scrolling) sits over the text in a bunch of places. make sure
/// the scrollbar doesn't get in the way of anything." A strip that scrolls sideways keeps `ScrollBarLane.height` under
/// its words, and the system's bar has to fit in it.
@MainActor @Suite struct ScrollBarLaneTests {
    let style = ChatStyle.make(category: .large)

    /// The bar the system really draws (found by its class name: a test-only look at UIKit's own views) starts inside
    /// the lane, so a strip that keeps the lane never has it over its words. Fails if a system update grows the bar.
    @Test func theSystemsSidewaysBarFitsInTheLane() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for height in [CGFloat(30), 120] {
            let scroll = UIScrollView(frame: CGRect(x: 20, y: 100, width: 300, height: height))
            scroll.contentSize = CGSize(width: 900, height: height)
            window.rootViewController?.view.addSubview(scroll)
            scroll.layoutIfNeeded()
            scroll.flashScrollIndicators()
            scroll.layoutIfNeeded()
            let bars = scroll.subviews.filter {
                let name = String(describing: type(of: $0))
                return (name.contains("ScrollIndicator") || name.contains("Scroller")) && $0.frame.width > $0.frame.height
            }
            let bar = try #require(bars.first, "no sideways bar among \(scroll.subviews.map { type(of: $0) })")
            #expect(bar.frame.minY >= height - ScrollBarLane.height, "bar at \(bar.frame) in a \(height) pt strip")
            #expect(bar.frame.maxY <= height + 0.5)
            scroll.removeFromSuperview()
        }
    }

    /// A code line wider than the card scrolls sideways: the card keeps the bar's lane under its last line, labelled or
    /// compact (no language, under 3 lines). Code that fits keeps its 10 pt.
    @Test func wideCodeKeepsTheBarsLaneUnderItsLastLine() throws {
        let wide = String(repeating: "let value = compute(alpha, beta, gamma) ", count: 6)
        let cases: [(String, CGFloat)] = [
            ("```swift\n\(wide)\nlet b = 2\nlet c = 3\n```", ScrollBarLane.height),
            ("```\n\(wide)\n```", ScrollBarLane.height),
            ("```swift\nlet a = 1\nlet b = 2\nlet c = 3\n```", ChatMetrics.codePadV),
        ]
        for (index, (text, least)) in cases.enumerated() {
            let row = ChatRow(id: "m\(index)|b0", messageId: "m\(index)", scope: "s", fingerprint: index,
                              kind: .bubble(BubbleRow(mine: false, text: text, markdown: true, partIndex: 0, joinsAbove: false,
                                                      joinsBelow: false, tail: false, time: nil, pending: false, streaming: false,
                                                      speaker: nil)),
                              gapAbove: 0, variant: 0)
            guard case .bubble(let b) = TextLayout.make(row, width: 402, style: style).content else {
                Issue.record("not a bubble"); continue
            }
            let placed = try #require(b.blocks.first { if case .code = $0.block { return true } else { return false } })
            let lastLine = placed.pieces.map(\.frame.maxY).max() ?? 0
            let below = placed.contentHeight - lastLine
            #expect(below >= least - 0.5, "case \(index): \(below) pt under the last line, wants \(least)")
            #expect((placed.contentWidth > placed.textFrame.width + 0.5) == (least == ScrollBarLane.height), "case \(index) scrolls")
            if least == ChatMetrics.codePadV { #expect(abs(below - ChatMetrics.codePadV) < 0.5, "fitting code keeps its pad") }
        }
    }
}
