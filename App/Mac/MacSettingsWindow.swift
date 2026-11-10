#if targetEnvironment(macCatalyst)
import UIKit

/// [mac-layout] Owner 2026-11-03 (the Mac layout study, "I'd like to see it all built"): Settings is a window of its own
/// on the Mac, as every Mac app's is: ⌘, (Hermes HQ › Settings…) opens it, or brings it forward when it's open, and it
/// sits beside the main window instead of taking its panes over. The Mac build may have more than one scene for this
/// (project.yml's post-compile step turns `UIApplicationSupportsMultipleScenes` on for the Mac only); the main window
/// stays one, and a Settings window left open at quit is not brought back at the next launch.
@MainActor enum MacSettingsWindow {
    static let configurationName = "Settings"
    static let activityType = "com.hermeshq.settings-window"

    /// The open Settings scene, if any.
    static var scene: UIWindowScene? {
        // By its delegate: a configuration made in code (not in Info.plist) doesn't keep its name on the session, so
        // matching the name never found the window (⌘W, to the front, close; sweep 2026-11-03).
        UIApplication.shared.connectedScenes.first { $0.delegate is SettingsSceneDelegate } as? UIWindowScene
    }

    /// The Settings window is the one in front (⌘W closes it, not the main window's chat).
    static var isKey: Bool { scene?.keyWindow?.isKeyWindow == true }

    /// ⌘, the sidebar's gear and every Settings link: the Settings window, opened or brought forward. Owner 2026-11-09
    /// ("ignore my message from yesterday … set it up the way that it should be set up"): a window of its own again, as
    /// 2026-11-03 to 11-08, now in two columns (categories and search on the left, the controls on the right) instead of
    /// the iPhone's one list in a narrow window, which is what the owner disliked on 11-08. False while the app has no
    /// main window to read its gateway from (the sign-in form): Settings then opens where it did.
    @discardableResult static func open() -> Bool { openWindow(then: nil) }

    /// The window, then `then` on its router (Sidebar Settings…, Add Provider…): a page beside the categories.
    /// `category`: the one marked in the column while that page shows (Sidebar is Appearance's, Providers is Hermes').
    @discardableResult static func open(category: SettingsCategory? = nil, then: @escaping (SettingsRouter) -> Void) -> Bool {
        openWindow { router in
            if let category { root?.model.category = category }
            then(router)
        }
    }

    /// [provider-add] What the window shows once it is up: a page pushed over its index (the model list's Add
    /// Provider… opens Providers there). A window already open goes back to its index first.
    static var pendingPage: ((SettingsRouter) -> Void)?

    /// The window's Settings page, while it is open.
    static var root: SettingsRootController? {
        (scene?.windows.first?.rootViewController as? UINavigationController)?.viewControllers.first as? SettingsRootController
    }

    @discardableResult private static func openWindow(then: ((SettingsRouter) -> Void)?) -> Bool {
        guard MainTabController.current != nil else { return false }
        if let root {
            if let then {
                root.backToIndex()
                then(root.router)
            }
        } else {
            pendingPage = then
        }
        AppLog.note("mac", scene == nil ? "settings window: open" : "settings window: to the front")
        UIApplication.shared.requestSceneSessionActivation(scene?.session, userActivity: NSUserActivity(activityType: activityType), options: nil) { error in
            AppLog.note("mac", "settings window: couldn't open (\(error.localizedDescription))")
        }
        return true
    }

    static func close() {
        guard let scene else { return }
        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
    }

    /// A Settings window's session, also after a relaunch (marked in `userInfo` when it connects).
    static func isSettings(_ session: UISceneSession) -> Bool {
        session.configuration.name == configurationName || session.userInfo?[userInfoKey] as? Bool == true
    }
    static let userInfoKey = "HQSettingsWindow"

    /// The scene configuration for a Settings window being connected (a request from `open`, or one restored).
    static func configuration(for session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration? {
        let asked = options.userActivities.contains { $0.activityType == activityType }
        guard asked || isSettings(session) else { return nil }
        let configuration = UISceneConfiguration(name: configurationName, sessionRole: session.role)
        configuration.delegateClass = SettingsSceneDelegate.self
        return configuration
    }

    #if DEBUG
    /// `-HQDebugSettingsWindow <name>`: the Settings window opens 3 s after launch (and is photographed, above).
    private static var debugAsked = false
    static func openIfAsked() {
        // Once a launch (a gateway switch sets the main window up again).
        guard !debugAsked, UserDefaults.standard.string(forKey: "HQDebugSettingsWindow")?.isEmpty == false else { return }
        debugAsked = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            // [provider-add] Signed in for real, the main window comes once the gateway answers.
            for _ in 0..<60 where MainTabController.current == nil { try? await Task.sleep(for: .seconds(0.5)) }
            try? await Task.sleep(for: .seconds(2))
            // [provider-add] With `HQN_ADD_URL` (a stand-in saved as a second gateway at launch) the window shows that
            // gateway: switched to first, then back and the stand-in forgotten once photographed, and the app quits
            // (the Debug app's sign-in is shared by every run on this Mac).
            let gateways = (MainTabController.current?.services as? any SettingsServices)?.gateways
            var original = gateways?.accounts.first(where: \.isCurrent)?.id
            var added: String?
            // A run cut short left the stand-in in use: it is put back the same way at the end.
            if let gateways, let url = ProcessInfo.processInfo.environment["HQN_ADD_URL"].flatMap(URL.init(string:)),
               let current = gateways.accounts.first(where: \.isCurrent),
               current.account.baseURL.port == url.port, current.account.baseURL.host == url.host,
               let other = gateways.accounts.first(where: { !$0.isCurrent }) {
                added = current.id
                original = other.id
                try? await Task.sleep(for: .seconds(5))
            }
            if let gateways, let url = ProcessInfo.processInfo.environment["HQN_ADD_URL"].flatMap(URL.init(string:)),
               added == nil, let row = gateways.accounts.first(where: { !$0.isCurrent && $0.account.baseURL.port == url.port && $0.account.baseURL.host == url.host }) {
                let before = MainTabController.current
                try? await gateways.switchTo(row.id)
                added = row.id
                // The main window is set up again for the stand-in: Settings opened before that reads the old one.
                for _ in 0..<40 where MainTabController.current == nil || MainTabController.current === before {
                    try? await Task.sleep(for: .seconds(0.5))
                }
                try? await Task.sleep(for: .seconds(3))
            }
            if let gateways, let added, let original {
                let wait = max(4, UserDefaults.standard.double(forKey: "HQDebugSettingsWindowWait"))
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(wait + 8))
                    close()
                    try? await gateways.switchTo(original)
                    try? await Task.sleep(for: .seconds(4))
                    try? await gateways.remove(added)
                    try? await Task.sleep(for: .seconds(2))
                    AppLog.note("mac", "settings window shot: gateways now \(gateways.accounts.map { "\($0.hostAndPort)\($0.isCurrent ? " (current)" : "")" })")
                    exit(0)
                }
            }
            // [provider-add] `-HQDebugSettingsWindowPage providers|add|<preset id>`: Providers, its Add Provider
            // chooser, or a preset's page, in the window.
            guard let page = UserDefaults.standard.string(forKey: "HQDebugSettingsWindowPage"), !page.isEmpty else { open(); return }
            open { router in
                let preset = ProviderPreset.all.first(where: { $0.id == page })
                router.push("Providers", ProvidersPageView(router: router, startAdding: page == "add"))
                guard let preset else { return }
                let api = router.gatewaySettings?.settingsAPI
                let env = EnvKeysModel(api: api, readOnly: false)
                let custom = CustomProvidersModel(api: api, readOnly: false, account: MainTabController.current?.services.account?.id)
                Task { @MainActor in
                    await env.load()
                    await custom.load()
                    try? await Task.sleep(for: .seconds(0.5))
                    let screen: UIViewController = switch ProviderAdding.route(preset, vars: env.vars) {
                    case .key(let info): SettingsPageController(title: preset.name, EnvKeyEditor(key: info.key, label: preset.name, model: env))
                    case .custom(let draft): SettingsPageController(title: preset.name, CustomProviderEditor(model: custom, router: router, original: draft))
                    }
                    screen.navigationItem.largeTitleDisplayMode = .never
                    router.push(screen)
                }
            }
        }
    }
    #endif

    /// The visible part (no menu bar, no Dock) of the screen `frame` (a system frame) is on, in system-frame terms.
    /// AppKit's `NSScreen`, by name: UIKit says nothing of the Dock. Nil when it can't be asked.
    static func visibleScreen(around frame: CGRect) -> CGRect? {
        func rect(_ screen: NSObject, _ key: String) -> CGRect? { (screen.value(forKey: key) as? NSValue)?.cgRectValue }
        guard let type = NSClassFromString("NSScreen") as? NSObject.Type, let screens = type.value(forKey: "screens") as? [NSObject],
              let first = screens.first, let main = rect(first, "frame") else { return nil }
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        let visible = screens.compactMap { screen -> (whole: CGRect, visible: CGRect)? in
            guard let whole = rect(screen, "frame"), let visible = rect(screen, "visibleFrame") else { return nil }
            return (WindowFit.flipped(whole, main: main), WindowFit.flipped(visible, main: main))
        }
        return (visible.first { $0.whole.contains(middle) } ?? visible.first)?.visible
    }

    /// At launch: a Settings window left open last time is not reopened (its page needs the main window's gateway).
    static func forgetRestored(_ application: UIApplication) {
        for session in application.openSessions where isSettings(session) {
            application.requestSceneSessionDestruction(session, options: nil)
        }
    }
}

/// The Settings window: the Settings index and its pages in one stack, titled "Settings", in the app's theme.
final class SettingsSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        session.userInfo = (session.userInfo ?? [:]).merging([MacSettingsWindow.userInfoKey: true]) { $1 }
        guard let windowScene = scene as? UIWindowScene, let services = MainTabController.current?.services else {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
            return
        }
        windowScene.title = "Settings"
        windowScene.titlebar?.titleVisibility = .hidden
        windowScene.titlebar?.toolbar = nil
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 900, height: 600)
        // A settings-sized window (about 860 × 640 pt on the screen at the app's 77 %: the category column and a form
        // beside it, as System Settings), where the main window is.
        // Mac polish #101: a system frame is in the screen's own points, not the app's (780 × 830 opened that big), and
        // the window is kept inside the screen's visible part (its foot went under the Dock on a laptop).
        if let main = MainTabController.current?.view.window?.windowScene?.effectiveGeometry.systemFrame {
            let visible = MacSettingsWindow.visibleScreen(around: main)
            let frame = WindowFit.inside(CGRect(x: main.minX + 60, y: main.minY + 40, width: 860, height: 640), visible: visible)
            AppLog.note("mac", "settings window: \(Int(frame.width))×\(Int(frame.height)) at \(Int(frame.minX)),\(Int(frame.minY)) in \(visible.map { "\(Int($0.width))×\(Int($0.height)) at \(Int($0.minX)),\(Int($0.minY))" } ?? "an unknown screen")")
            windowScene.requestGeometryUpdate(.Mac(systemFrame: frame)) { _ in }
        }
        let window = UIWindow(windowScene: windowScene)
        MacToolTips.install(on: window)
        AppearanceSetting.apply(to: window)
        Theme.shared.adopt(window)
        let root = SettingsRootController(services: services)
        root.model.ownWindow = true
        let navigation = UINavigationController(rootViewController: root)
        root.router.navigation = navigation
        root.navigationItem.largeTitleDisplayMode = .never
        navigation.navigationBar.prefersLargeTitles = false
        // Mac polish #2: its pages take the main window's solid page bar as they show (`MacWindow.pageBar`); a plain
        // stack left them the system's clear one, so rows showed through under the title in a frosted band.
        navigation.delegate = PushedPageTitles.shared
        MacWindow.pageBar(root)
        navigation.view.backgroundColor = HQPalette.groupedPage
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window
        AppLog.note("mac", "settings window: shown")
        if let page = MacSettingsWindow.pendingPage {   // [provider-add]
            MacSettingsWindow.pendingPage = nil
            // Once the window is laid out: the page goes beside the categories (the pane's own stack), not over them.
            DispatchQueue.main.async {
                navigation.view.layoutIfNeeded()
                root.settleColumns()
                page(root.router)
            }
        }
        #if DEBUG
        // `-HQDebugSettingsWindow <name>`: the window as <name>.png (POSTed with -HQDebugMacShotsPost) 4 s after it opens.
        if let name = UserDefaults.standard.string(forKey: "HQDebugSettingsWindow"), !name.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(4, UserDefaults.standard.double(forKey: "HQDebugSettingsWindowWait"))) { [weak window] in
                guard let window else { return }
                MacShots.shoot(window, to: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "\(name).png"))
                let nav = window.rootViewController as? UINavigationController
                let top = nav?.topViewController
                let scroll = top?.view.settingsScroll
                let text = """
                window \(window.bounds) traits \(window.traitCollection.horizontalSizeClass.rawValue)
                bar \(nav?.navigationBar.frame ?? .zero) large \(nav?.navigationBar.prefersLargeTitles ?? false) mode \(top?.navigationItem.largeTitleDisplayMode.rawValue ?? -1)
                safe \(top?.view.safeAreaInsets ?? .zero) search \(top?.navigationItem.searchController != nil)
                stack \(nav?.viewControllers.map { "\($0.title ?? "-")/\($0.navigationItem.title ?? "-")/\($0.navigationItem.backButtonTitle ?? "-")" } ?? [])
                items \(nav?.navigationBar.items?.map { "\($0.title ?? "-")/\($0.backButtonTitle ?? "-")" } ?? [])
                scroll \(scroll.map { "\($0.frame) inset \($0.adjustedContentInset) offset \($0.contentOffset)" } ?? "none")
                save \(nav.flatMap { KeyCommands.saveCommand(in: $0) }.map { "\(type(of: $0.owner)) \"\($0.command.title)\" \($0.command.action.map(NSStringFromSelector) ?? "-")" } ?? "none")
                """
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "\(name)-bar.txt")
                try? text.write(to: url, atomically: true, encoding: .utf8)
                MacShots.post(url)
            }
        }
        #endif
    }


    func sceneDidDisconnect(_ scene: UIScene) {
        AppLog.note("mac", "settings window: closed")
    }
}
#endif

#if targetEnvironment(macCatalyst)
private extension UIView {
    /// The Settings page's list (SwiftUI's own scroll view, made a moment after the page).
    var settingsScroll: UIScrollView? {
        if let scroll = self as? UIScrollView { return scroll }
        for sub in subviews { if let found = sub.settingsScroll { return found } }
        return nil
    }
}
#endif
