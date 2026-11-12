// desktoplook: DEBUG launch hooks for UI tests and the screenshot tour (spec 3x-desktoplook §11.3). They write the
// stored theme state before the first frame, exactly as the Theme page would.
//
// - `-HQDebugSkin <id>`             the skin (as if picked)
// - `-HQDebugDesktopLook YES|NO`    Desktop Look
// - `-HQDebugHighContrast YES|NO`   High Contrast
// - `-HQDebugUIScale <percent>`     UI Scale
// - `-HQDebugDensity standard|compact`   [density] Density (the iOS look)
// - `-HQDebugThemeDensity YES`      [density] with -HQDebugOpenTheme, scrolled to Density and UI Scale (screenshots)
// - `-HQDebugBubbleCorners <pt>`    Bubble Corners (the iOS look's chat bubbles)
// - `-HQDebugDesktopCorners <pt>`   [desktop-corners] the Desktop Look's own Corners
// - `-HQDebugDesktopComposer glass|box`   [desktop-composer] the Desktop Look's Text Box
// - `-HQDebugGlassBubbles YES|NO`   [glass-bubbles] Chat Bubbles › Glass
// - `-HQDebugBubbleStyle solid|glass|tinted`   [tinted-bubbles] Chat Bubbles › Style
// - `-HQDebugMessageColour <name | #RRGGBB | theme>`   [message-colour] Chat Bubbles › Colour
// - `-HQDebugBotMessageColour <bot>=<face | name | #RRGGBB>[,…]`   [bot-colour] Bot Info › Settings › Colour, by bot
// - `-HQDebugResetTheme YES`        forget all the `hqn.theme.*` keys first (`-HQDebugResetAccounts YES` does too),
//                                   and both backgrounds
// - `-HQDebugChatBackground <path | id>` [backdrop] Theme › Chat Background set to that photo (read as a pick reads it)
//                                   or one of the app's own pictures (`BackdropPreset` id: aurora, sunset…)
// - `-HQDebugAppBackground <path | id>` the same for Theme › App Background (`none` for either: as never chosen)
// - `-HQDebugChatBackgroundDim <percent>`, `-HQDebugChatBackgroundBlur YES|NO`  its Dim and Blur (and `…AppBackground…`)
// - `-HQDebugChatBackgroundSame YES|NO` Chat Background's Use App Background
// - `-HQDebugAppBackgroundCards YES|NO` [backdrop-cards] App Background's Soft Cards
// - `-HQDebugFlipCardsAt <seconds>`  [backdrop-cards] Soft Cards flips that long after launch (live relayout)
// - `-HQDebugChatBackgroundPick <path>` Your Own Photo takes that file instead of opening a system picker (UI tests)
// - `-HQDebugThemeBackground YES`   with -HQDebugOpenTheme, Backgrounds opens instead ([theme-pages] its own page)
// - `-HQDebugNoThemeFile YES`       the installer behaves as if the bundled theme file were missing (stress item 11)
// - `-HQDebugOpenTheme YES`         open Settings › Theme once the app is up (screenshots)
// - `-HQDebugThemeBubbles YES`      with it, Chat Bubbles opens instead ([theme-pages] its own page)
// - `-HQDebugThemeChats YES`        with it in the Desktop Look, Theme scrolled to Corners and Text Box
// - `-HQDebugThemeTab chats|backgrounds`   with it, Chat Bubbles or Backgrounds opens instead (they were Theme's tabs)
// - `-HQDebugOpenBackground app|chats`   with Backgrounds open, that background's page pushed over it
// - `-HQDebugThemeShot <path>`     [mac] with -HQDebugOwnerPath: the window as a PNG once Theme is up, POSTed to <url>
// - `-HQDebugCycleScale YES`        with -HQDebugCycleSkins: step UI Scale instead of the skin
// - `-HQDebugFlipLook YES`          with -HQDebugCycleSkins: flip Desktop Look as its switch does instead
// - `-HQDebugCycleSkins YES`        with it, pick the next skin every 1.5 s, as a click on the grid does (Mac 479 crash)
// - `-HQDebugOpenMore YES`         show the More tab once the app is up (screenshots: its cards on a skin)
// - `-HQDebugOpenTab <key>`         show that tab (bots, sessions, jobs, workspace, more)
// - `-HQDebugOpenSettings YES`      More › Settings pushed once the app is up
// - `-HQDebugOpenDeviceAccess health[.<group>]`   [health-all-types] with -HQDemoLists and -HQDebugOpenSettings:
//                                   Device Access › Health (and that group's page) pushed over Settings (screenshots);
//                                   `-HQDebugHealthOn <group or type key>,…` switches those on first, without asking iOS
// - `-HQDebugOpenNotifications YES` open Settings › Notifications once the app is up (screenshots)
// - `-HQDebugOpenVoice conversation|speech|transcription`   [voice picker] open that Settings › Voice page (screenshots)
// - `-HQDebugOwnerPath <w>`         [mac] a window <w> wide (screen points), the sidebar opened and folded, then
//                                   More › Settings › Appearance pushed, as the Mac download 447 crash was reached

#if DEBUG
import UIKit

enum ThemeDebugHooks {
    static func applyBeforeLaunch() {
        let defaults = UserDefaults.standard
        let store = ThemeStore()
        // Hosting the unit tests: they start from the standard look whatever a UI test left stored on this simulator
        // (repair round 1: a stored Midnight made settledCodeIsHighlightedWithTheGitHubColours read Midnight's ink).
        let hostsUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if hostsUnitTests || defaults.bool(forKey: "HQDebugResetTheme") || defaults.bool(forKey: "HQDebugResetAccounts") { store.reset() }
        if let skin = defaults.string(forKey: "HQDebugSkin"), !skin.isEmpty { store.pick(skin: skin) }
        if defaults.object(forKey: "HQDebugDesktopLook") != nil { store.setDesktopLook(defaults.bool(forKey: "HQDebugDesktopLook")) }
        if defaults.object(forKey: "HQDebugHighContrast") != nil { store.setHighContrast(defaults.bool(forKey: "HQDebugHighContrast")) }
        if defaults.object(forKey: "HQDebugUIScale") != nil { store.setUIScale(defaults.integer(forKey: "HQDebugUIScale")) }
        if let density = defaults.string(forKey: "HQDebugDensity").flatMap(ListDensity.init(rawValue:)) { store.setDensity(density) }
        if defaults.object(forKey: "HQDebugBubbleCorners") != nil { store.setBubbleCorners(defaults.integer(forKey: "HQDebugBubbleCorners")) }
        if defaults.object(forKey: "HQDebugDesktopCorners") != nil { store.setBubbleCorners(defaults.integer(forKey: "HQDebugDesktopCorners"), desktop: true) }
        if let composer = defaults.string(forKey: "HQDebugDesktopComposer").flatMap(DesktopComposer.init(rawValue:)) { store.setDesktopComposer(composer) }
        if defaults.object(forKey: "HQDebugGlassBubbles") != nil { store.setGlassBubbles(defaults.bool(forKey: "HQDebugGlassBubbles")) }
        if let style = defaults.string(forKey: "HQDebugBubbleStyle").flatMap(BubbleStyle.init(rawValue:)) { store.setBubbleStyle(style) }
        if let colour = defaults.string(forKey: "HQDebugMessageColour") { store.setMessageColour(MessageColour(stored: colour)) }
        // [bot-colour] -HQDebugBotMessageColour sam=face,default=green
        if let picks = defaults.string(forKey: "HQDebugBotMessageColour") {
            for pick in picks.split(separator: ",") {
                let parts = pick.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { BotMessageColour.debugChoices[parts[0]] = BotMessageColour.Choice(stored: parts[1]) }
            }
        }
        applyChatBackground(defaults, reset: hostsUnitTests || defaults.bool(forKey: "HQDebugResetTheme") || defaults.bool(forKey: "HQDebugResetAccounts"))
    }

    /// [backdrop] Before `Backdrop.app` and `Backdrop.chats` first read their keys.
    private static func applyChatBackground(_ defaults: UserDefaults, reset: Bool) {
        for (place, name) in [(Backdrop.Place.app, "AppBackground"), (.chats, "ChatBackground")] {
            let keys = Backdrop.keys(place)
            if reset { keys.all.forEach(defaults.removeObject(forKey:)) }
            if defaults.string(forKey: "HQDebug" + name) == "none" {   // put back as nothing was ever chosen
                keys.all.forEach(defaults.removeObject(forKey:))
                continue
            }
            if let value = defaults.string(forKey: "HQDebug" + name), !value.isEmpty {
                if let preset = BackdropPreset(rawValue: value) {
                    defaults.set(preset.rawValue, forKey: keys.preset)
                    defaults.removeObject(forKey: keys.photo)
                } else {
                    switch PhotoLoad.read(URL(fileURLWithPath: value), maxPixel: Backdrop.maxPixel) {
                    case .success(let photo):
                        if let file = try? Backdrop.write(photo.image, into: Backdrop.defaultFolder(place)) {
                            defaults.set(file, forKey: keys.photo)
                            defaults.removeObject(forKey: keys.preset)
                        }
                    case .failure(let error): print("[backdrop] -HQDebug\(name) \(value): \(error)")
                    }
                }
                if place == .chats { defaults.set(false, forKey: keys.sameAsApp) }
            }
            if defaults.object(forKey: "HQDebug\(name)Dim") != nil { defaults.set(defaults.integer(forKey: "HQDebug\(name)Dim"), forKey: keys.dim) }
            if defaults.object(forKey: "HQDebug\(name)Blur") != nil { defaults.set(defaults.bool(forKey: "HQDebug\(name)Blur"), forKey: keys.blur) }
            // [backdrop-cards] `-HQDebugAppBackgroundCards YES|NO`: Soft Cards.
            if defaults.object(forKey: "HQDebug\(name)Cards") != nil { defaults.set(defaults.bool(forKey: "HQDebug\(name)Cards"), forKey: keys.cards) }
        }
        if defaults.object(forKey: "HQDebugChatBackgroundSame") != nil {
            defaults.set(defaults.bool(forKey: "HQDebugChatBackgroundSame"), forKey: Backdrop.keys(.chats).sameAsApp)
        }
    }

    static func applyAfterLaunch(_ root: MainTabController) {
        #if targetEnvironment(macCatalyst)
        let width = UserDefaults.standard.integer(forKey: "HQDebugOwnerPath")
        if width > 0 { ownerPath(root, width: CGFloat(width)); return }
        #endif
        if UserDefaults.standard.bool(forKey: "HQDebugOpenMore") { DispatchQueue.main.async { root.select(.more) } }
        if let key = UserDefaults.standard.string(forKey: "HQDebugOpenTab"), let tab = HQTab(key: key) {
            DispatchQueue.main.async { root.select(tab) }
        }
        if UserDefaults.standard.bool(forKey: "HQDebugOpenSettings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                root.select(.more)
                root.listStack(.more)?.pushViewController(SettingsRootController(services: root.services), animated: false)
            }
        }
        if let id = UserDefaults.standard.string(forKey: "HQDebugOpenVoice"), let page = ConfigCatalog.page("voice.\(id)") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                SettingsScreens.presentSettings(from: root, services: root.services) { navigation in
                    guard let settings = navigation.viewControllers.first as? SettingsRootController else { return }
                    let router = settings.router
                    router.push([VoiceSettingsScreens.makeSection(router: router)] + [VoiceSettingsScreens.makePage(page, router: router)].compactMap { $0 })
                }
            }
            return
        }
        // [backdrop-cards] `-HQDebugFlipCardsAt <seconds>`: Soft Cards flips then, as its switch does (pages update live).
        let flipAt = UserDefaults.standard.double(forKey: "HQDebugFlipCardsAt")
        if flipAt > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + flipAt) { Backdrop.app.setCards(!Backdrop.app.cards) } }
        let notifications = UserDefaults.standard.bool(forKey: "HQDebugOpenNotifications")
        guard notifications || UserDefaults.standard.bool(forKey: "HQDebugOpenTheme") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (notifications ? 4.0 : 1.0)) {
            let page: UIViewController = notifications ? NotificationsSettingsController(app: root.services as? AppModel)
                : themePage(services: root.services)
            let navigation = UINavigationController(rootViewController: page)
            page.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak navigation] _ in
                navigation?.dismiss(animated: true)
            })
            root.present(navigation, animated: false)
            if UserDefaults.standard.bool(forKey: "HQDebugCycleSkins") { cycleSkins(from: 0) }
        }
    }

    /// [health-all-types] `-HQDebugOpenDeviceAccess health[.<group>]`: Device Access, then Health (and a group's page).
    private static func openDeviceAccess(on stack: UINavigationController?) {
        guard let stack, let target = UserDefaults.standard.string(forKey: "HQDebugOpenDeviceAccess"),
              let kind = DeviceAccess.Kind(rawValue: String(target.split(separator: ".").first ?? "")) else { return }
        for name in (UserDefaults.standard.string(forKey: "HQDebugHealthOn") ?? "").split(separator: ",").map(String.init) {
            let keys = HealthCatalog.Category(rawValue: name).map(DeviceAccess.Settings.healthKeys) ?? [name]
            DeviceAccessCenter.shared.set(.health, Set(keys), on: true)
        }
        let access = DeviceAccessSettingsController()
        stack.pushViewController(access, animated: false)
        stack.pushViewController(DeviceAccessKindController(kind: kind, model: access.model), animated: false)
        let group = target.split(separator: ".").dropFirst().first.flatMap { HealthCatalog.Category(rawValue: String($0)) }
        if kind == .health, let group {
            stack.pushViewController(DeviceAccessHealthCategoryController(category: group, model: access.model), animated: false)
        }
    }

    /// [backdrop] `-HQDemoChat` with `-HQDebugOpenTheme YES`: the Theme page over the demo list, so its chat options
    /// (Chat Bubbles, Chat Background) can be checked on a simulator that isn't signed in.
    /// With `-HQDemoLists` it's pushed on the Bots tab's stack instead, as Settings sits on More's: the app's
    /// background shows behind it there (sheets keep their own look).
    static func openThemeOverDemo(_ root: UIViewController?) {
        // [settings-lines] `-HQDebugOpenSettings YES` over the demo lists: Settings' root page on the Bots stack.
        if let root, UserDefaults.standard.bool(forKey: "HQDebugOpenSettings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                func tabs(in controller: UIViewController) -> MainTabController? {
                    if let tabs = controller as? MainTabController { return tabs }
                    return controller.children.lazy.compactMap(tabs(in:)).first
                }
                guard let tabs = tabs(in: root) else { return }
                tabs.botsViewController.navigationController?.pushViewController(SettingsRootController(services: tabs.services), animated: false)
                openDeviceAccess(on: tabs.botsViewController.navigationController)
            }
        }
        guard let root, UserDefaults.standard.bool(forKey: "HQDebugOpenTheme") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if let tabs = root as? MainTabController, let stack = tabs.botsViewController.navigationController {
                let page = themePage(services: tabs.services)
                page.navigationItem.largeTitleDisplayMode = .never
                stack.pushViewController(page, animated: false)
                return
            }
            let navigation = UINavigationController(rootViewController: themePage(services: nil))
            navigation.topViewController?.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak navigation] _ in
                navigation?.dismiss(animated: true)
            })
            root.present(navigation, animated: false)
        }
    }

    /// [theme-pages] The page `-HQDebugOpenTheme` opens: Theme, or Chat Bubbles or Backgrounds where an argument asks
    /// for them (`name`: a tour's item, "chats" or "backgrounds").
    static func themePage(services: (any AppServices)?, name: String? = nil) -> UIViewController {
        let defaults = UserDefaults.standard
        let name = name ?? defaults.string(forKey: "HQDebugThemeTab")
        if name == "chats" || defaults.bool(forKey: "HQDebugThemeBubbles") { return ChatBubblesSettings.make() }
        if name == "backgrounds" || defaults.bool(forKey: "HQDebugThemeBackground")
            || defaults.string(forKey: "HQDebugOpenBackground") != nil { return BackgroundsSettings.make() }
        return ThemeSettingsController(services: services)
    }

    /// Mac 479 crash (2026-10-30): a skin picked on the open Theme page sent its List into a layout loop.
    private static func cycleSkins(from index: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let all = SkinCatalog.all
            let skin = all[index % all.count]
            if UserDefaults.standard.bool(forKey: "HQDebugCycleScale") {
                let presets = ThemeState.scalePresets
                let percent = presets[index % presets.count]
                print("[cycle-skins] \(index): UI Scale \(percent)")
                Theme.shared.setUIScale(percent)
            } else if UserDefaults.standard.bool(forKey: "HQDebugFlipLook") {
                print("[cycle-skins] \(index): flip look (was \(Theme.shared.state.desktopLook))")
                NotificationCenter.default.post(name: .init("HQDebugFlipLook"), object: nil)
            } else {
                print("[cycle-skins] \(index): \(skin.id)")
                Theme.shared.pick(skin: skin.id)
            }
            cycleSkins(from: index + 1)
        }
    }

    #if targetEnvironment(macCatalyst)
    private static func ownerPath(_ root: MainTabController, width: CGFloat) {
        Task { @MainActor in
            guard let window = root.view.window else { return }
            window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 40, y: 40, width: width, height: width * 0.548))) { _ in }
            try? await Task.sleep(for: .seconds(6))
            UIApplication.shared.sendAction(KeyCommands.toggleSidebar, to: UIApplication.shared.delegate, from: nil, for: nil)
            try? await Task.sleep(for: .seconds(3))
            UIApplication.shared.sendAction(KeyCommands.toggleSidebar, to: UIApplication.shared.delegate, from: nil, for: nil)
            try? await Task.sleep(for: .seconds(1))
            let names = (root.viewControllers ?? []).map { $0.tabBarItem.title ?? "?" }
            guard let index = names.firstIndex(of: "More"), let nav = root.viewControllers?[index] as? UINavigationController,
                  let more = nav.viewControllers.first as? MoreViewController else { return }
            root.selectedIndex = index
            try? await Task.sleep(for: .seconds(1))
            more.open(rowId: "settings")
            try? await Task.sleep(for: .seconds(2))
            func find(_ vc: UIViewController?) -> SettingsRootController? {
                guard let vc else { return nil }
                if let hit = vc as? SettingsRootController { return hit }
                for child in vc.children + [vc.presentedViewController].compactMap({ $0 }) { if let hit = find(child) { return hit } }
                return nil
            }
            guard let settings = find(window.rootViewController) else { NSLog("HQOwnerPath: no settings"); return }
            SettingsNavigator.openRoot("theme", router: settings.router)
            NSLog("HQOwnerPath: theme pushed")
            if UserDefaults.standard.bool(forKey: "HQDebugCycleSkins") { try? await Task.sleep(for: .seconds(2)); cycleSkins(from: 0) }
            if let path = UserDefaults.standard.string(forKey: "HQDebugThemeShot") {
                try? await Task.sleep(for: .seconds(2))
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                // The app is sandboxed: the picture goes to a local listener (`http://127.0.0.1:<port>/<name>.png`).
                guard let url = URL(string: path), let data = image.pngData() else { return }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                _ = try? await URLSession.shared.upload(for: request, from: data)
                NSLog("HQThemeShot: sent \(data.count) bytes")
            }
        }
    }
    #endif
}
#endif
