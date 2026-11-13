import Foundation
import Testing
import UIKit
@testable import HermesHQNative

/// Owner 2026-11-01: every tab's top is the chat's. In the iOS look the bar is clear and the list's soft edge blurs rows
/// out under it; in the Desktop Look the bar is the look's frost. Bots had a page-coloured band over the pinned heads
/// and Sessions, Jobs, Kanban and More an opaque bar with a hard cut, so no two tabs looked alike.
@MainActor @Suite(.serialized) struct TabTopTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let tabs = ["App/Bots/BotsViewController.swift", "App/Sessions/SessionsViewController.swift",
                       "App/Pages/Jobs/JobsViewController.swift", "App/Pages/Kanban/KanbanViewController.swift",
                       "App/Pages/MoreViewController.swift", "App/Pages/Artifacts/ArtifactsViewController.swift"]

    /// Each tab root hands its list to the soft edge; none pins its title without it (the opaque bar).
    @Test func everyTabListSitsUnderTheSoftEdge() throws {
        for file in Self.tabs {
            let source = try String(contentsOf: Self.repo.appending(path: file), encoding: .utf8)
            let calls = source.components(separatedBy: "pinTitle(in:").dropFirst().map { $0.prefix(80) }
            #expect(!calls.isEmpty, "\(file) pins its title")
            #expect(calls.allSatisfy { $0.contains("softEdgeAround:") }, "\(file): \(calls)")
        }
    }

    private func pinned(desktop: Bool, grouped: Bool = false) -> (UIViewController, UICollectionView) {
        var state = ThemeTable.current.state
        state.desktopLook = desktop
        return ThemeTable.$testSet.withValue(ThemeResolver.resolve(state)) {
            let controller = UIViewController()
            controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            let list = UICollectionView(frame: controller.view.bounds, collectionViewLayout: UICollectionViewFlowLayout())
            controller.view.addSubview(list)
            ListBarAppearance.pinTitle(in: controller, grouped: grouped, softEdgeAround: list)
            return (controller, list)
        }
    }

    /// The iOS look: a clear bar in every state, and nothing painted behind it on the phone (no band).
    @Test func iOSLookBarIsClearWithNoBand() {
        for grouped in [false, true] {
            let (controller, list) = pinned(desktop: false, grouped: grouped)
            let item = controller.navigationItem
            for appearance in [item.standardAppearance, item.scrollEdgeAppearance, item.compactAppearance, item.compactScrollEdgeAppearance] {
                let bar = appearance
                #expect(bar != nil)
                #expect(bar?.backgroundEffect == nil, "no material")
                #expect((bar?.backgroundColor ?? .clear).cgColor.alpha == 0, "no colour")
            }
            #expect(list.topEdgeEffect.isHidden, "the still host draws the edge")
            guard let host = list.superview as? UIScrollView else { Issue.record("the list sits in the still host"); continue }
            #expect(host.topEdgeEffect.style == TopEdgeStyle.current, "Theme › Themes › Top Edge (Hard unless Soft was picked)")
            // Owner 2026-11-03: at rest the edge's fade blurred Artifacts' picker, the first row; it shows once rows are under.
            list.contentSize = CGSize(width: 402, height: 3000)
            list.contentOffset = CGPoint(x: 0, y: -list.adjustedContentInset.top)
            #expect(host.topEdgeEffect.isHidden, "no edge at rest")
            list.contentOffset = CGPoint(x: 0, y: 40 - list.adjustedContentInset.top)
            #expect(!host.topEdgeEffect.isHidden, "the edge once rows are under the bar")
            #if !targetEnvironment(macCatalyst)
            #expect(host.subviews == [list], "no backing over the list on the phone")
            #endif
            let opaque = controller.view.subviews.filter { $0 !== host && !$0.isHidden && ($0.backgroundColor?.cgColor.alpha ?? 0) > 0 }
            #expect(opaque.isEmpty, "nothing solid over the top: \(opaque)")
        }
    }

    /// Owner 2026-11-13 (a recording of Tasks, build 975): the bar wore the edge's band and a hard line at rest, gone the
    /// moment the list was pulled. Soft Cards' room over the first card (1.7 pt) left the list resting 0.03 pt past its
    /// top, and that read as rows under the bar.
    @Test func aListRestingAHairPastItsTopShowsNoEdge() {
        let (_, list) = pinned(desktop: false)
        guard let host = list.superview as? UIScrollView else { Issue.record("the list sits in the still host"); return }
        list.contentSize = CGSize(width: 402, height: 3000)
        for hair in [0.01, 0.034, 1.0 / 3, 0.49] as [CGFloat] {
            list.contentOffset = CGPoint(x: 0, y: hair - list.adjustedContentInset.top)
            #expect(host.topEdgeEffect.isHidden, "at rest, \(hair) pt past the top")
        }
        list.contentOffset = CGPoint(x: 0, y: 2 - list.adjustedContentInset.top)
        #expect(!host.topEdgeEffect.isHidden, "the edge once rows are under the bar")
        list.contentOffset = CGPoint(x: 0, y: -30 - list.adjustedContentInset.top)
        #expect(host.topEdgeEffect.isHidden, "none while the list is pulled down")
    }

    /// And the room itself is whole pixels, so the list rests exactly at its top.
    @Test func roomOverTheFirstCardIsWholePixels() {
        let (_, list) = pinned(desktop: false)
        list.contentSize = CGSize(width: 402, height: 3000)
        let scale = max(list.traitCollection.displayScale, 1)
        for room in [1.7, 1.3, 4.355, 10] as [CGFloat] {
            BackdropCards.setTopRoom(room, of: list)
            let pixels = list.contentInset.top * scale
            #expect(abs(pixels - pixels.rounded()) < 0.001, "\(room) pt is \(pixels) px")
            #expect(abs(list.contentInset.top - room) <= 0.5 / scale + 0.001)
            #expect(abs(list.contentOffset.y + list.adjustedContentInset.top) < 0.001, "still at its top")
        }
        BackdropCards.setTopRoom(0, of: list)
        #expect(list.contentInset.top == 0)
    }

    /// The same recording's other half: Settings and Files, whose lists Soft Cards moves up (18 and 12 pt) so the
    /// first card stands one gap under the bar. iOS goes by the bar, took the moved start for rows under it, and drew
    /// its band at rest. Such a list's edge is hidden while it rests or is pulled, and shows once rows go under.
    @Test func aListMovedUpShowsNoEdgeUntilRowsGoUnder() {
        #expect(BackdropPlates.hidesTopEdge(lifted: -17.67, past: 0))
        #expect(BackdropPlates.hidesTopEdge(lifted: -17.67, past: 0.33), "a hair off a whole pixel is rest")
        #expect(BackdropPlates.hidesTopEdge(lifted: -11.67, past: -60), "pulled down")
        #expect(!BackdropPlates.hidesTopEdge(lifted: -17.67, past: 3), "rows under the bar: the edge")
        #expect(!BackdropPlates.hidesTopEdge(lifted: 0, past: 0), "a list not moved keeps the system's own say")
        #expect(!BackdropPlates.hidesTopEdge(lifted: 6, past: 0), "nor one moved down")
    }

    /// SwiftUI shows a list's edge again on each of its updates; the hold hears of it (the setter is observable).
    @Test func showingAnEdgeAgainIsHeard() {
        let list = UIScrollView()
        list.topEdgeEffect.isHidden = true
        var heard = 0
        let watch = list.topEdgeEffect.observe(\.isHidden, options: [.new]) { _, change in if change.newValue == false { heard += 1 } }
        list.topEdgeEffect.isHidden = false
        watch.invalidate()
        #expect(heard == 1)
    }

    /// The Desktop Look: the look's frost, on the phone as on the Mac (it was solid on the phone).
    @Test func desktopLookBarIsFrosted() {
        var state = ThemeTable.current.state
        state.desktopLook = true
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(state)) {
            let item = UINavigationItem(title: "Jobs")
            ListBarAppearance.apply(to: item)
            #expect(item.standardAppearance?.backgroundEffect != nil, "frosted")
            #expect(item.scrollEdgeAppearance?.backgroundEffect != nil, "frosted at rest too")
        }
    }
}
