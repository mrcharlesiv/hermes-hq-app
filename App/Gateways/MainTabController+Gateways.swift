// A gateway switch keeps the tab controller and its selected tab (spec 1x-settings §4.4 step 4) but makes every
// per-account tab owner again for the new account: the list screens (an open chat belonged to the old gateway; search
// and collapsed sections reset; both lists paint from the new gateway's caches) and anything another stream built for
// the old account in `MainTabController.installTabs` (the pages stream's Jobs / Kanban / More hold the old client).
// Presented sheets (Settings) stay. `.hqGatewayDidSwitch` tells owners that live outside the tabs.

import UIKit

extension Notification.Name {
    /// Posted on the main thread after a gateway switch (or Add Gateway…) made the new account current and the tabs were
    /// rebuilt. `object` is the new `GatewayAccount`.
    static let hqGatewayDidSwitch = Notification.Name("hq.gatewayDidSwitch")
}

extension MainTabController {
    /// The tab controller on screen, if the app shows one.
    static var current: MainTabController? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if let root = AppRoot.tabs(window) { return root }   // [m9/ipad] also inside the two-pane root
            }
        }
        return nil
    }

    func gatewayDidSwitch() {
        // A search in progress belongs to the screens about to go.
        for controller in [botsViewController, sessionsViewController] as [UIViewController] {
            if let search = controller.navigationItem.searchController, search.isActive { search.isActive = false }
        }
        installTabs(fresh: true)
        connectionDidChange()
        updateBadges()
        NotificationCenter.default.post(name: .hqGatewayDidSwitch, object: services.account)
    }

    /// The chat on top of the selected tab, if one is open.
    var topChatScreen: ChatViewController? {
        chatOnShow   // [m9/ipad] either layout
    }
}
