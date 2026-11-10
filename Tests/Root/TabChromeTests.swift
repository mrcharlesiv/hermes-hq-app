// 3x-morepages §1 (L852) and §9 (U8) against a real tab controller.
import Testing
import UIKit
@testable import HermesHQNative

@MainActor struct TabChromeTests {
    private func tabs() -> MainTabController {
        MainTabController(services: FakeAppServices()) { ChatViewController(session: $0) }
    }

    /// The owner rejected the accessory over the tab bar (docs/owner-todo/morepages.md): nobody adds one by accident.
    @Test func noAccessorySitsOverTheTabBar() {
        let tabs = tabs()
        tabs.loadViewIfNeeded()
        #expect(tabs.bottomAccessory == nil)
        for index in 0..<(tabs.viewControllers?.count ?? 0) {
            tabs.selectedIndex = index
            #expect(tabs.bottomAccessory == nil)
        }
    }

    @Test func escapeContextFromTheControllerTree() throws {
        let tabs = tabs()
        tabs.loadViewIfNeeded()
        let stack = try #require(tabs.selectedViewController as? UINavigationController)
        #expect(EscapeRule.context(KeyCommands.escapeFacts(tabs)) == .tabRoot)
        #expect(KeyCommands.escapePageStep(tabs) == .nothing)

        stack.pushViewController(UIViewController(), animated: false)
        #expect(EscapeRule.context(KeyCommands.escapeFacts(tabs)) == .pushedPage)
        #expect(KeyCommands.escapePageStep(tabs) == .goBack)
        KeyCommands.escapeGoBack(tabs)
        #expect(stack.viewControllers.count == 1)
        KeyCommands.escapeGoBack(tabs)                       // a root is never popped
        #expect(stack.viewControllers.count == 1)

        // A page with unsaved edits runs its own Cancel instead of being popped.
        final class Editing: UIViewController, EscapeCancelling {
            var asked = 0, handles = true
            func escapeCancel() -> Bool { asked += 1; return handles }
        }
        let page = Editing()
        stack.pushViewController(page, animated: false)
        KeyCommands.escapeGoBack(tabs)
        #expect(page.asked == 1)
        #expect(stack.topViewController === page)
        page.handles = false                                 // nothing to guard: plain Back
        KeyCommands.escapeGoBack(tabs)
        #expect(stack.viewControllers.count == 1)

        // Every tab's root is a root.
        for index in 0..<(tabs.viewControllers?.count ?? 0) {
            tabs.selectedIndex = index
            #expect(KeyCommands.escapePageStep(tabs) == .nothing)
        }
    }

    /// ⌘[ (View › Back) goes back a pushed page, as Escape's last step does, and is off at a tab's root.
    @Test func commandBracketGoesBack() throws {
        let tabs = tabs()
        tabs.loadViewIfNeeded()
        let stack = try #require(tabs.selectedViewController as? UINavigationController)
        #expect(!KeyCommands.canGoBack(tabs))
        stack.pushViewController(UIViewController(), animated: false)
        #expect(KeyCommands.canGoBack(tabs))
        let back = KeyCommands.viewItems().compactMap { $0 as? UIMenu }.flatMap(\.children).compactMap { $0 as? UIKeyCommand }
            .first { $0.action == KeyCommands.back }
        #expect(back?.input == "[" && back?.modifierFlags == .command && back?.title == "Back")
        KeyCommands.escapeGoBack(tabs)
        #expect(stack.viewControllers.count == 1)
        #expect(!KeyCommands.canGoBack(tabs))
    }
}
