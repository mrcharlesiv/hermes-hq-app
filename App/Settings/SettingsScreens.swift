// Where Settings opens (spec 1x-settings §3.1): the Bots bar's Settings button presents it as a page sheet holding a
// navigation stack; a More tab (pages stream) pushes the same pages through `SettingsScreens`. Other streams plug rows
// in through `SettingsHooks`.

import SwiftUI
import UIKit

/// Rows other streams own. A row is shown only when its owner registered it (never a control that does nothing).
@MainActor enum SettingsHooks {
    /// Set by the activity stream at launch: its tool-call settings screen ("Tool Calls" / "Chat Display").
    static var toolCallsScreen: (() -> UIViewController)?
    /// The row's title (the activity stream calls its screen "Chat Display").
    static var toolCallsTitle = "Tool Calls"
    /// e.g. "Rows" or "At the Bottom" — shown as the row's value.
    static var toolCallsSummary: (() -> String)?
    /// Set once something calls `CompletionCue.turnEnded(sessionKey:)` for every live `message.complete` (§3.7).
    static var completionCueWired = false
    /// The pages stream's Kanban decision for an account: "on" / "unused" / "absent" (nil: not known yet). The Kanban Tab
    /// picker (Settings › Appearance › Tabs) shows only when this is set and not "absent" (§3.9).
    static var kanbanAvailability: ((GatewayAccount) -> String?)?
    /// Set by the pages stream: what opens Status & Maintenance for the signed-in gateway, nil while it can't open. The
    /// Gateway page links to it for the version, Restart Gateway and Update Hermes (UX study #189).
    static var commandCenter: (() -> (() -> UIViewController)?)?
}

/// The Kanban tab override the pages stream reads (`pages.kanbanTab.override.<account>` = auto|on|off, §3.9).
enum KanbanTabOverride: String, CaseIterable, Identifiable {
    case auto, on, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Automatic"
        case .on: "On"
        case .off: "Off"
        }
    }

    static func key(_ account: GatewayAccount) -> String { "pages.kanbanTab.override.\(account.id)" }

    static func value(for account: GatewayAccount) -> KanbanTabOverride {
        UserDefaults.standard.string(forKey: key(account)).flatMap(KanbanTabOverride.init(rawValue:)) ?? .auto
    }

    static func set(_ value: KanbanTabOverride, for account: GatewayAccount) {
        UserDefaults.standard.set(value.rawValue, forKey: key(account))
        // Integration: the pages stream applies it now (never under the user's finger on tab 3), not at the next probe.
        NotificationCenter.default.post(name: didChange, object: account.id)
    }

    static let didChange = Notification.Name("hq.pages.kanbanTabOverrideDidChange")
}

/// Pushes and presents for SwiftUI pages that live on UIKit navigation.
@MainActor final class SettingsRouter {
    weak var navigation: UINavigationController?
    /// [mac] A chooser presented as a sheet (`openChooser`), while it is up.
    weak var chooserSheet: UINavigationController?
    let services: any AppServices
    var settings: (any SettingsServices)? { services as? SettingsServices }

    init(services: any AppServices, navigation: UINavigationController?) {
        self.services = services
        self.navigation = navigation
    }

    func push(_ controller: UIViewController) {
        controller.navigationItem.largeTitleDisplayMode = .never
        navigation?.pushViewController(controller, animated: true)
    }

    /// The controller to present alerts and sheets from.
    var presenter: UIViewController? { navigation?.topViewController ?? navigation }
}

@MainActor enum SettingsScreens {
    /// The Settings root page (for a navigation stack someone else owns, e.g. a More tab).
    static func makeSettings(services: any AppServices, navigation: UINavigationController? = nil) -> UIViewController {
        let page = SettingsRootController(services: services)
        page.router.navigation = navigation
        return page
    }

    /// The Bots bar's Settings button: a page sheet (large detent) holding its own navigation stack.
    static func presentSettings(from presenter: UIViewController, services: any AppServices, then: ((UINavigationController) -> Void)? = nil) {
        #if targetEnvironment(macCatalyst)
        // [mac] Settings has its own window (⌘,): Voice Settings…, Fix… and Manage Gateways… push their page there, as
        // Add Provider… does, not over a second Settings in a sheet that could disagree with it (Mac polish #35).
        if MacSettingsWindow.open(then: { router in if let navigation = router.navigation { then?(navigation) } }) { return }
        #endif
        if openInPane(from: presenter, then: then) { return }   // [m9/ipad]
        let root = SettingsRootController(services: services)
        let navigation = UINavigationController(rootViewController: root)
        root.router.navigation = navigation
        root.isSheetRoot = true
        root.navigationItem.largeTitleDisplayMode = .never
        SheetStyle.apply(navigation, from: presenter)   // [m9/ipad] a centred form sheet in two panes (§4.8)
        navigation.sheetPresentationController?.prefersGrabberVisible = false
        presenter.present(navigation, animated: true) {
            then?(navigation)
            // UX study 2026-10-21 #188: a shortcut (Voice Settings…, Fix…, Manage Gateways…) lands on a page pushed over
            // Settings. That page closes the sheet too, so the way back to the chat isn't Back and then ✕; Back stays.
            for page in navigation.viewControllers.dropFirst() { addClose(to: page, closing: navigation) }
        }
    }

    private static func addClose(to page: UIViewController, closing navigation: UINavigationController) {
        page.loadViewIfNeeded()   // a page that sets its own bar items does so first; the ✕ goes after them
        let close = UIBarButtonItem.hqClose(action: UIAction { [weak navigation] _ in
            navigation?.dismiss(animated: true)
        })
        close.accessibilityIdentifier = "settings.close"
        page.navigationItem.rightBarButtonItems = [close] + (page.navigationItem.rightBarButtonItems ?? [])
    }

    /// [m9/ipad] Two panes with nothing presented over the window and Settings already in the right pane: that
    /// Settings is reused, back on its root, not shadowed by a second Settings stack in a sheet that could disagree
    /// with it. A chat, job or empty right pane keeps the sheet, so closing it lands back where you were; so does
    /// the phone. False: not handled here.
    private static func openInPane(from presenter: UIViewController, then: ((UINavigationController) -> Void)?) -> Bool {
        guard let window = presenter.viewIfLoaded?.window, window.rootViewController?.presentedViewController == nil,
              let tabs = AppRoot.tabs(window), let split = tabs.split, split.isDouble else { return false }
        guard split.detail.viewControllers.first is SettingsRootController else { return false }
        split.detail.popToRootViewController(animated: false)
        then?(split.detail)
        return true
    }

    /// Settings with the Gateway page pushed (the title menu's Manage Gateways…).
    static func presentGateways(from presenter: UIViewController, services: any AppServices) {
        presentSettings(from: presenter, services: services) { navigation in
            guard let root = navigation.viewControllers.first as? SettingsRootController else { return }
            root.router.push(GatewayPageController(services: services, router: root.router))
        }
    }
}

extension UIApplication {
    /// [mac] The window that is really key: the Settings window while it is in front. `connectedScenes` is a set, so its
    /// first scene's key window could be the main window behind it, and a question asked there looked like nothing
    /// happened (Mac polish #36). One window: the same as before.
    var hqKeyWindow: UIWindow? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.compactMap(\.keyWindow).first
    }
}
