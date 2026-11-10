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
