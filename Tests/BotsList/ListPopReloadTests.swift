// [perf] A pop back to Bots or Sessions reloads the list once the slide has landed, not in the pop's first frame, and
// changes that arrive mid-slide fold into that one reload (App/Bots/BotsViewController.swift, `reloadWhenTransitionEnds`).

import Testing
import UIKit
@testable import HermesHQNative

@MainActor
@Suite(.serialized)
struct ListPopReloadTests {
    private final class Page: UIViewController {}

    private func bot(_ id: String) -> Bot {
        Bot(id: id, name: id.capitalized, role: nil, preview: nil, lastActive: nil, isWorking: false, unread: false,
            pinned: false, pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: nil, head: nil)
    }

    private func session(_ id: String) -> SessionSummary {
        SessionSummary(id: id, profile: "default", title: "Chat \(id)", preview: nil, lastActive: Date(),
                       source: "desktop", unread: false, isRunning: false)
    }

    private func rows(_ view: UICollectionView) -> Int {
        (0..<view.numberOfSections).reduce(0) { $0 + view.numberOfItems(inSection: $1) }
    }

    /// Hosts `list` in a navigation controller in a window with a page pushed over it.
    private func host(_ list: UIViewController) throws -> (UIWindow, UINavigationController) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let navigation = UINavigationController(rootViewController: list)
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        list.loadViewIfNeeded()
        navigation.pushViewController(Page(), animated: false)
        window.layoutIfNeeded()
        return (window, navigation)
    }

    /// Waits for the pop to start, checks `during` while it runs, then waits for it to end.
    private func pop(_ navigation: UINavigationController, during: () -> Void) async throws {
        navigation.popViewController(animated: true)
        for _ in 0..<50 where navigation.transitionCoordinator == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(navigation.transitionCoordinator != nil, "the pop is still sliding")
        during()
        for _ in 0..<200 where navigation.transitionCoordinator != nil || navigation.viewControllers.count != 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(navigation.transitionCoordinator == nil && navigation.viewControllers.count == 1)
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func botsReloadsAfterThePopLandsAndFoldsMidSlideChanges() async throws {
        let services = TabRecordingServices()
        services.bots = [bot("default"), bot("ada")]
        let list = BotsViewController(services: services) { _ in UIViewController() }
        let (window, navigation) = try host(list)
        defer { window.isHidden = true }
        let before = rows(list.collectionView)
        #expect(before > 0)

        // Off screen: the change waits.
        services.bots.append(bot("grace"))
        services.onBotsChange?()
        #expect(list.needsReload)

        try await pop(navigation) {
            #expect(self.rows(list.collectionView) == before, "the pop's first frames keep the old rows")
            // A stream event mid-slide is held for the end, not reloaded on the next turn.
            services.bots.append(self.bot("linus"))
            services.onBotsChange?()
            #expect(list.needsReload)
        }
        #expect(!list.needsReload)
        #expect(rows(list.collectionView) == before + 2, "both changes landed in the one reload after the pop")
    }

    @Test func sessionsReloadsAfterThePopLands() async throws {
        let services = TabRecordingServices()
        services.sessions = [session("20261020_120000_aa000001")]
        let list = SessionsViewController(services: services, makeChat: { _ in UIViewController() })
        let (window, navigation) = try host(list)
        defer { window.isHidden = true }
        let before = rows(list.collectionView)
        #expect(before == 1)

        services.sessions.append(session("20261020_120000_aa000002"))
        services.onSessionsChange?()
        #expect(list.needsReload)

        try await pop(navigation) {
            #expect(self.rows(list.collectionView) == before, "the pop's first frames keep the old rows")
        }
        #expect(!list.needsReload)
        #expect(rows(list.collectionView) == 2)
    }

    /// The first showing of an empty list reloads in place: nothing waits for a transition.
    @Test func anUnanimatedReturnReloadsInPlace() throws {
        let services = TabRecordingServices()
        services.bots = [bot("default")]
        let list = BotsViewController(services: services) { _ in UIViewController() }
        let (window, navigation) = try host(list)
        defer { window.isHidden = true }
        services.bots.append(bot("ada"))
        services.onBotsChange?()
        navigation.popViewController(animated: false)
        window.layoutIfNeeded()
        #expect(!list.needsReload)
    }
}
