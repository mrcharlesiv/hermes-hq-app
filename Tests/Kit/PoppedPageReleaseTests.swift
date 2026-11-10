// [perf] Build 297, "Smooth back to Bots": a popped page is let go of after the pop, not in the turn that ends it
// (App/Pages/PageKit.swift, `PoppedPageRelease`).

import Testing
import UIKit
@testable import HermesHQNative

@MainActor
@Suite(.serialized)
struct PoppedPageReleaseTests {
    private final class Page: UIViewController {}

    private func settle(_ navigation: UINavigationController, count: Int) async throws {
        for _ in 0..<200 where navigation.transitionCoordinator != nil || navigation.viewControllers.count != count {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(navigation.transitionCoordinator == nil && navigation.viewControllers.count == count)
    }

    @Test func aPoppedPageOutlivesThePopAndIsReleasedSoonAfter() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.delegate = PushedPageTitles.shared
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }

        weak var popped: UIViewController?
        do {
            let page = Page()
            popped = page
            navigation.pushViewController(page, animated: false)
        }
        try await settle(navigation, count: 2)
        navigation.popViewController(animated: true)
        try await settle(navigation, count: 1)
        // The pop is over and the page has left its navigation controller, but its views are not taken down yet.
        #expect(popped != nil)
        #expect(popped?.navigationController == nil)
        try await Task.sleep(for: .seconds(PoppedPageRelease.delay + 0.4))
        #expect(popped == nil)
        #expect(PoppedPageRelease.held.isEmpty)
    }

    @Test func aPageStillOnTheStackIsNotHeld() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.delegate = PushedPageTitles.shared
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }

        let page = Page()
        navigation.pushViewController(page, animated: true)
        try await settle(navigation, count: 2)
        // A push's outgoing page (the root) stays on the stack: nothing is held for it.
        #expect(!PoppedPageRelease.held.contains { $0 === navigation.viewControllers.first })
    }
}
