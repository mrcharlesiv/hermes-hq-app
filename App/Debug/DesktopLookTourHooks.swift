// desktoplook2: DEBUG launch hook for the screenshot tour of every screen (scripts/desktoplook2-tour.sh). It only
// navigates, as a person would; nothing is drawn differently.
//
// - `-HQDebugTour <screen>`   bots | sessions | jobs | tab3 | more | settings | theme | chat | room | botinfo | editbot | changeface
//                             | morescrolled | morepage (a row of More pushed: `-HQDebugTourItem "section,item"`, default the first) | sheet (Kanban's New Task)
//                             | task (Kanban's task sheet; `-HQDebugTourTask <id>`, default: the running one)
// - `-HQDebugTourBot <id>`    the bot for chat / botinfo / editbot / changeface (default: the first listed)
// - [page-tabs] `-HQDebugTourItem <tab>` with theme (chats | backgrounds: [theme-pages] Chat Bubbles or Backgrounds, which
//                             were its tabs) or botinfo (about | brain | chats | artifacts | settings): the page opens on that tab
// - [desktop-frost] `kanbanabout` (Kanban's How Kanban Works sheet); `-HQDebugTourScroll <points>` then scrolls the
//                             topmost screen's first list down that far (content under its bar)
// - [improve-24] `chatinfo` | `commands` (a bot's chat, then ⋯ › Info or the ☰ Commands sheet) | `newchat` (Sessions'
//                             compose: the Choose a Bot / New Chat sheet) | `focus` (a bot's chat, the field focused)
// - [glass] `models` | `prompts` | `errordetails` | `selecttext` | `talkinfo` (a bot's chat, then that half-height
//                             sheet: the pop-ups that sit on Liquid Glass over the chat)
// - [glass-design] `promptsheet` (a bot's chat, then a sudo password prompt with its command) | `prompteditor` (⋯ ›
//                             Prompts, then New Prompt) | `screensetup` (a bot's chat, then the Screen Control setup sheet)
//                             | `audiopreview` (a bot's chat, then a 12 s voice memo in its preview sheet)
// - [glass-phone] `glassdock` (a bot's chat with a sample two-question dock in the composer's place) | `glassreply` /
//                             `glassreplyarmed` (a bot's chat, its newest bot bubble held mid Swipe to Reply, short of
//                             the threshold / armed) | `glasstray` (a bot's chat; add `-HQDebugAttach` for tiles);
//                             `-HQDebugGlassScroll <points>` then moves the transcript toward older rows (rows behind)
// - [custom-providers] `settings-providers` (Settings › Providers) | `settings-provider` (a provider’s page; `-HQDebugTourItem
//                             <catalog id>`, default the first; `new`: Add Provider’s empty page; [provider-manager]
//                             `-HQDebugProviderPrompt rename|model:<id>` opens that rename over it) | [provider-add] `settings-providers-add`
//                             (Providers with its Add Provider chooser over it; `-HQDebugTourItem <preset id>`: that preset's page)
// - [glass-audit] `account` (Bots' Account sheet) | `secretkey` (an API key sheet over a list) | `starnode` (a Star Map
//                             star's sheet, made-up text) | `htmlstatus` (a live page with its talk-back pill showing)
// - [plugin-pages] `plugins` with `-HQDebugTourItem page:<plugin name>`: that page plugin's page, opened in HQ;
//                             `installed:<plugin name>`: an installed plugin's own page; `-HQDebugPluginPageClick <words>` presses a page's button

#if DEBUG
import SwiftUI
import UIKit

/// [glass-audit 2026-11-01] A plain list page that opens the key sheet or a Star Map star the way the app does
/// (SwiftUI `.sheet`), so the pictures show their backgrounds as they are.
struct GlassAuditHost: View {
    let star: Bool
    struct Pick: Identifiable { let id = "x" }
    @State private var pick: Pick?
    var body: some View {
        List {
            Section("Toolsets") { ForEach(["Web Search", "Browser", "Image Generation", "Terminal", "GitHub", "Home Assistant", "Spotify", "Weather", "Notion", "Linear", "Gmail", "Calendar"], id: \.self) { Text($0) } }
        }
        .hqGroupedPage()
        .task { try? await Task.sleep(for: .seconds(1.2)); pick = Pick() }
        .sheet(item: $pick) { _ in
            if star, let client = MorePages.context?.client {
                StarMapNodeSheet(node: StarMapNode(id: "skill-deploy", label: "Deploy the website", kind: .skill, category: "devops",
                                                   useCount: 14, state: "active", createdBy: "agent", pinned: true),
                                 client: client, profile: "default")
            } else {
                SecretEntrySheet(title: "Brave Search API Key", name: "BRAVE_API_KEY", isSet: true, placeholder: nil,
                                 save: { _ in true }, remove: {})
            }
        }
    }
}

enum DesktopLookTourHooks {
    /// [glass-design] The prompt sheets focus their first field, which lifts them to full height (off the glass): the
    /// tour drops the keyboard and puts the sheet back at half height, where it opens without a field to type in.
    private static func halfHeightNoKeyboard(_ chat: UIViewController) {
        for delay in [1.5, 3.0] { after(delay) {
            var top: UIViewController = chat
            while let next = top.presentedViewController { top = next }
            top.view.window?.endEditing(true)
            guard let sheet = top.sheetPresentationController, sheet.detents.contains(where: { $0.identifier == .medium }) else { return }
            sheet.animateChanges { sheet.selectedDetentIdentifier = .medium }
        } }   // twice: a slow present can focus the field after the first pass
    }

    static func applyAfterLaunch(_ root: MainTabController) {
        guard let screen = UserDefaults.standard.string(forKey: "HQDebugTour"), !screen.isEmpty else { return }
        let wanted = UserDefaults.standard.string(forKey: "HQDebugTourBot")
        after(1.2) { go(screen, bot: wanted, root: root, attempts: 40) }
        // [backdrop-still] `-HQDebugPopAt <seconds>`: the page on show goes back then (a slide the other way).
        let popAt = UserDefaults.standard.double(forKey: "HQDebugPopAt")
        if popAt > 0 { after(popAt) { (root.selectedViewController as? UINavigationController)?.popViewController(animated: true) } }
        // [glass] `-HQDebugTourDetent large`: the open sheet then grows to full height (glass → solid)
        if UserDefaults.standard.string(forKey: "HQDebugTourDetent") == "large" { after(5.5) { growSheet(root) } }
        let scroll = UserDefaults.standard.double(forKey: "HQDebugTourScroll")
        if scroll != 0 { after(4.0) { scrollTop(root, by: scroll) } }
    }

    private static func growSheet(_ root: UIViewController) {
        var top: UIViewController = root
        while let next = top.presentedViewController { top = next }
        guard let sheet = top.sheetPresentationController else { return }
        sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
    }

    /// The topmost screen's first scroll view (larger than a field), down `points`.
    private static func scrollTop(_ root: UIViewController, by points: Double) {
        var top: UIViewController = root
        while let next = top.presentedViewController { top = next }
        if let tabs = top as? UITabBarController, let selected = tabs.selectedViewController { top = selected }
        if let nav = top as? UINavigationController, let visible = nav.topViewController { top = visible }
        func first(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, !(scroll is UITextView), scroll.bounds.height > 200 { return scroll }
            for child in view.subviews { if let found = first(child) { return found } }
            return nil
        }
        guard let list = first(top.view) else { return }
        list.setContentOffset(CGPoint(x: 0, y: points - list.adjustedContentInset.top), animated: true)
    }

    /// [glass-design] The tour's prompt sheet (its frame holds it only weakly).
    private static var tourKeep: AnyObject?

    private static func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
    }

    private static func go(_ screen: String, bot wanted: String?, root: MainTabController, attempts: Int) {
        let services = root.services
        func retry() { if attempts > 0 { after(0.25) { go(screen, bot: wanted, root: root, attempts: attempts - 1) } } }
        switch screen {
        case "bots": root.select(.bots)
        case "sessions": root.select(.sessions)
        case "jobs": root.select(.jobs)
        case "tab3": root.select(.workspace)
        case "sheet":       // [desktoplook3] a sheet with a segmented choice: Kanban's New Task
            root.select(.workspace)
            after(1.0) {
                guard let nav = root.selectedViewController as? UINavigationController,
                      let kanban = nav.viewControllers.first as? KanbanViewController else { return }
                kanban.newTask()
            }
        case "task":        // a Kanban task sheet: the given task, else the first running one
            root.select(.workspace)
            after(1.0) {
                guard let nav = root.selectedViewController as? UINavigationController,
                      let kanban = nav.viewControllers.first as? KanbanViewController else { return }
                let tasks = kanban.store.board?.columns.flatMap(\.tasks) ?? []
                let id = UserDefaults.standard.string(forKey: "HQDebugTourTask")
                    ?? tasks.first(where: { $0.status == "running" })?.id ?? tasks.first?.id
                if let id { kanban.openTask(id) }
            }
        case "kanbanabout":     // [desktop-frost] the How Kanban Works sheet (static text: no board needed)
            root.present(ChatSheet.wrap(UIHostingController(rootView: KanbanAboutView()), title: "How Kanban Works"), animated: true)
        case "more": root.select(.more)
        case "morescrolled":    // More scrolled down a screen (the collapsed title)
            root.select(.more)
            after(0.8) {
                guard let nav = root.selectedViewController as? UINavigationController,
                      let list = firstCollection(in: nav.topViewController?.view) else { return }
                list.setContentOffset(CGPoint(x: 0, y: 500 - list.adjustedContentInset.top), animated: true)
            }
        case "pluginpage":   // [plugin-pages-more] More › Plugin Pages › `-HQDebugTourItem <plugin name>`, as a tap on its row opens it
            root.select(.more)
            let name = UserDefaults.standard.string(forKey: "HQDebugTourItem") ?? ""
            @MainActor func open(_ tries: Int) {
                guard let nav = root.selectedViewController as? UINavigationController else { return }
                guard let page = PluginPagesMore.open(name, profile: nil) else {
                    if tries > 0 { after(0.3) { open(tries - 1) } }
                    return
                }
                nav.pushViewController(page, animated: false)
            }
            after(0.8) { open(30) }
        case "morepage":
            root.select(.more)
            after(0.8) {
                guard let nav = root.selectedViewController as? UINavigationController,
                      let list = firstCollection(in: nav.topViewController?.view) else { return }
                // `-HQDebugTourItem "section,item"` pushes another row (default the first).
                let pick = (UserDefaults.standard.string(forKey: "HQDebugTourItem") ?? "0,0").split(separator: ",").compactMap { Int($0) }
                let path = IndexPath(item: pick.count > 1 ? pick[1] : 0, section: pick.first ?? 0)
                if list.numberOfSections > path.section, list.numberOfItems(inSection: path.section) > path.item {
                    list.delegate?.collectionView?(list, didSelectItemAt: path)
                }
            }
        case "connectors":   // [connectors-ux] More › Connectors; `-HQDebugTourItem <name>` then opens that connector or app
            root.select(.more)
            after(0.8) {
                guard let nav = root.selectedViewController as? UINavigationController else { return }
                let page = CapabilitiesViewController(services: services, profile: nil, tab: .connectors)
                nav.pushViewController(page, animated: false)
                guard let item = UserDefaults.standard.string(forKey: "HQDebugTourItem"), !item.isEmpty else { return }
                @MainActor func open(_ tries: Int) {
                    let model = page.model
                    let router = page.rootView.router
                    if item == "composio" {   // [connect-find] the Composio page (its key setup while no key is saved)
                        nav.pushViewController(ConnectAppsScreens.makeRoot(services: services), animated: false)
                    } else if item == "allapps", model.catalog != nil {
                        nav.pushViewController(CatalogBrowseController(model: model, router: router), animated: false)
                    } else if let server = model.servers?.first(where: { $0.name == item }) {
                        nav.pushViewController(ConnectorPageController(model: model, server: server, router: router), animated: false)
                    } else if let entry = model.catalog?.first(where: { $0.name == item }) {
                        nav.pushViewController(CatalogAppController(model: model, entry: entry, router: router), animated: false)
                    } else if let app = model.managed?.apps.first(where: { $0.slug == item }) {
                        nav.pushViewController(ManagedAppController(model: model, slug: app.slug, router: router), animated: false)
                    } else if tries > 0 {
                        after(0.3) { open(tries - 1) }
                    }
                }
                after(0.5) { open(20) }
            }
        case "plugins":   // [find-plugins] Settings-style Plugins page; `-HQDebugTourItem find|kind:<shelf>|search:<words>|<catalog name>`
            root.select(.more)
            after(0.8) {
                guard let nav = root.selectedViewController as? UINavigationController else { return }
                let page = CapabilitiesViewController(services: services, profile: nil, tab: .plugins)
                nav.pushViewController(page, animated: false)
                guard let item = UserDefaults.standard.string(forKey: "HQDebugTourItem"), !item.isEmpty else { return }
                @MainActor func open(_ tries: Int) {
                    let model = page.model
                    let router = page.rootView.router
                    if item.hasPrefix("page:") {   // [plugin-pages] a page plugin's page, opened in HQ
                        let name = String(item.dropFirst(5))
                        guard let found = model.dashboardPages?.first(where: { $0.name == name }) else {
                            if tries > 0 { after(0.3) { open(tries - 1) } }
                            return
                        }
                        PluginPagesSection.open(found, model: model, router: router)
                        return
                    }
                    if item.hasPrefix("installed:") {   // [plugin-pages] an installed plugin's own page (with Open when it adds one)
                        let name = String(item.dropFirst(10))
                        guard model.dashboardPages != nil, let plugin = model.plugins?.first(where: { $0.name == name }) else {
                            if tries > 0 { after(0.3) { open(tries - 1) } }
                            return
                        }
                        router.push(PluginPageController(model: model, plugin: plugin, router: router))
                        return
                    }
                    let entries = PluginCatalogStore.shared.entries ?? []
                    if SkillCatalogStore.shared.entries == nil, !SkillCatalogStore.shared.loading { Task { await SkillCatalogStore.shared.load() } }
                    let skillsWait = item.hasPrefix("skill:") && SkillCatalogStore.shared.entries == nil
                    guard !entries.isEmpty, model.plugins != nil, !skillsWait else {
                        if tries > 0 { after(0.3) { open(tries - 1) } }
                        return
                    }
                    if item.hasPrefix("link:"), let url = URL(string: String(item.dropFirst(5))),   // [marketplace] an install link
                       let target = MarketplaceLinks.target(DeepLink.parse(url, scheme: AppIdentity.current.urlScheme)) {
                        MarketplaceLinks.open(target, services: services, from: root)
                    } else if item == "find" || item == "market" {   // [marketplace]
                        nav.pushViewController(MarketplaceController(model: model, router: router, kind: item == "find" ? .plugins : .all), animated: false)
                    } else if item == "market-connectors" {   // [connect-find]
                        nav.pushViewController(MarketplaceController(model: model, router: router, kind: .connectors), animated: false)
                    } else if item == "market-skills" {
                        nav.pushViewController(MarketplaceController(model: model, router: router, kind: .skills), animated: false)
                    } else if item.hasPrefix("skill:"), let skill = SkillCatalogStore.shared.entries?.first(where: { $0.name == String(item.dropFirst(6)) }) {
                        nav.pushViewController(SkillCatalogEntryController(model: model, entry: skill, router: router), animated: false)
                    } else if item.hasPrefix("kind:"), let kind = PluginCatalogCategory(rawValue: String(item.dropFirst(5))) {
                        nav.pushViewController(MarketplaceController(model: model, router: router, kind: .plugins, category: kind.rawValue), animated: false)
                    } else if item.hasPrefix("search:") {
                        model.query = String(item.dropFirst(7))
                    } else if item.hasPrefix("marketsearch:") {   // [marketplace] All, searched: the Plugins and Skills sections
                        nav.pushViewController(MarketplaceController(model: model, router: router, kind: .all, query: String(item.dropFirst(13))), animated: false)
                    } else if item.hasPrefix("findsearch:") {
                        nav.pushViewController(MarketplaceController(model: model, router: router, kind: .plugins, query: String(item.dropFirst(11))), animated: false)
                    } else if let entry = entries.first(where: { $0.name == item }) {
                        nav.pushViewController(PluginCatalogEntryController(model: model, entry: entry, router: router), animated: false)
                    }
                }
                after(0.5) { open(40) }
            }
        case "settings":
            SettingsScreens.presentSettings(from: root, services: services)
        case "settings-model", "settings-context":   // [context-window] Settings › Model, and its Context Window page
            SettingsScreens.presentSettings(from: root, services: services) { navigation in
                guard let router = (navigation.viewControllers.first as? SettingsRootController)?.router,
                      let section = ConfigCatalog.section("model") else { return }
                after(1.0) {
                    ConfigScreens.open(section: section, router: router)
                    guard screen == "settings-context", let page = ConfigCatalog.page("model.context") else { return }
                    after(1.0) { ConfigScreens.open(page: page, router: router) }
                }
            }
        case "settings-providers", "settings-provider":   // [custom-providers] Settings › Providers, and a provider's page
            SettingsScreens.presentSettings(from: root, services: services) { navigation in
                guard let router = (navigation.viewControllers.first as? SettingsRootController)?.router else { return }
                after(1.0) {
                    SettingsNavigator.openRoot("providers", router: router)
                    guard screen == "settings-provider" else { return }
                    let item = UserDefaults.standard.string(forKey: "HQDebugTourItem")
                    if item == "new" {
                        let model = CustomProvidersModel(api: router.gatewaySettings?.settingsAPI,
                                                         readOnly: router.gatewaySettings?.isReadOnlyGateway ?? false,
                                                         account: services.account?.id)
                        CustomProviderPages.open(nil, model: model, router: router)
                        return
                    }
                    // [provider-manager] A provider's page by its catalog id (`custom:together`, `anthropic`), default the
                    // first; `-HQDebugProviderPrompt rename|model:<id>` then opens that prompt over it.
                    let model = ProvidersModel(router: router)
                    Task { @MainActor in
                        await model.load()
                        guard let row = model.rows.first(where: { $0.id == (item ?? $0.id) }) else { return }
                        ProviderPages.open(row.id, model: model, router: router)
                        guard let prompt = UserDefaults.standard.string(forKey: "HQDebugProviderPrompt") else { return }
                        try? await Task.sleep(for: .seconds(1.2))
                        if prompt == "rename" {
                            ProviderPages.rename(row, model: model, router: router)
                        } else if prompt.hasPrefix("model:") {
                            ProviderPages.renameModel(String(prompt.dropFirst(6)), provider: row, model: model, router: router)
                        }
                    }
                }
            }
        case "settings-providers-add":   // [provider-add] the chooser over Providers, or a preset's page
            SettingsScreens.presentSettings(from: root, services: services) { navigation in
                guard let router = (navigation.viewControllers.first as? SettingsRootController)?.router else { return }
                after(1.0) {
                    router.push("Providers", ProvidersPageView(router: router, startAdding: true))
                    guard let id = UserDefaults.standard.string(forKey: "HQDebugTourItem"),
                          let preset = ProviderPreset.all.first(where: { $0.id == id }) else { return }
                    let env = EnvKeysModel(api: router.gatewaySettings?.settingsAPI, readOnly: false)
                    let custom = CustomProvidersModel(api: router.gatewaySettings?.settingsAPI, readOnly: false, account: services.account?.id)
                    Task { @MainActor in
                        await env.load()
                        await custom.load()
                        try? await Task.sleep(for: .seconds(1.5))
                        let page: UIViewController = switch ProviderAdding.route(preset, vars: env.vars) {
                        case .key(let info): SettingsPageController(title: preset.name, EnvKeyEditor(key: info.key, label: preset.name, model: env))
                        case .custom(let draft): SettingsPageController(title: preset.name, CustomProviderEditor(model: custom, router: router, original: draft))
                        }
                        ProviderAdd.replaceChooser(with: page, router: router)
                    }
                }
            }
        case "theme":
            SettingsScreens.presentSettings(from: root, services: services) { navigation in
                _ = navigation.viewControllers.first
                // [theme-pages] `-HQDebugTourItem chats|backgrounds`: Chat Bubbles or Backgrounds, which were its tabs.
                let page = ThemeDebugHooks.themePage(services: services, name: UserDefaults.standard.string(forKey: "HQDebugTourItem") ?? "themes")
                page.navigationItem.largeTitleDisplayMode = .never
                navigation.pushViewController(page, animated: false)
            }
        case "chat", "botinfo", "editbot", "changeface":
            guard let bot = services.bots.first(where: { $0.id == (wanted ?? $0.id) }) else { return retry() }
            if screen == "chat" {
                root.botsViewController.open(bot.id)
            } else {
                // [page-tabs] `-HQDebugTourItem brain|chats|artifacts|settings`: Bot Info on that tab.
                let tab = UserDefaults.standard.string(forKey: "HQDebugTourItem").flatMap(BotInfoTab.init(rawValue:)) ?? .about
                BotInfoSheet.present(bot: bot, from: root, services: services, start: screen == "editbot" ? .editBot : screen == "changeface" ? .face : .info, tab: tab)
            }
        case "chatinfo", "commands", "focus", "models", "prompts", "errordetails", "selecttext", "talkinfo",
             "promptsheet", "prompteditor", "screensetup", "audiopreview":
            guard let bot = services.bots.first(where: { $0.id == (wanted ?? $0.id) }) else { return retry() }
            root.botsViewController.open(bot.id)
            after(2.5) {
                // [mac-audit] On the Mac the chat is in the split beside the tabs, not under them: look from the window.
                guard let chat = findChat(in: root.view.window?.rootViewController ?? root), let menus = chat.menus else { return }
                switch screen {
                case "chatinfo": menus.info()
                case "commands": menus.presentCommandsSheet()
                case "models": menus.presentModelSheet(query: nil)
                case "prompts": menus.presentPrompts()
                case "errordetails":
                    chat.present(ChatErrorDetailsSheet.make(details: "Gateway error 502: the provider closed the stream.\n"
                        + "request id 7f3a91c2, model gpt-5.5, attempt 2 of 3"), animated: true)
                case "selecttext":
                    chat.present(SelectTextViewController.make(text: "A reply to select from: Liquid Glass sits over the chat, "
                        + "and the words stay readable on their own card."), animated: true)
                case "talkinfo": TalkIntroSheet.present(.info, name: "Hermes", from: chat)
                case "promptsheet":
                    // Not the account's store: nothing is answered, and the sheet goes with the app.
                    let prompt = ValuePrompt(id: "tour-sudo", kind: .sudo,
                                             params: ["command": .string("sudo launchctl kickstart -k system/com.hermes.gateway")])
                    let made = PromptSheetController.make(prompt, botName: "Hermes")
                    tourKeep = made.sheet
                    chat.present(made.navigation, animated: true)
                    halfHeightNoKeyboard(chat)
                case "prompteditor":
                    menus.presentPrompts()
                    after(1.2) {
                        var top: UIViewController = chat
                        while let next = top.presentedViewController { top = next }
                        guard let nav = top as? UINavigationController else { return }
                        nav.pushViewController(PromptEditorViewController(prompt: nil) { _, _ in }, animated: false)
                        halfHeightNoKeyboard(chat)
                    }
                case "screensetup":
                    chat.present(ChatSheet.wrap(ScreenSetupSheet(), title: "Screen Control"), animated: true)
                case "audiopreview":
                    // A 12 s tone as a voice memo, in its preview sheet (silent on the Simulator).
                    let folder = FileManager.default.temporaryDirectory.appending(path: "HQNTourAudio", directoryHint: .isDirectory)
                    let file = folder.appending(path: "Voice memo.m4a")
                    Task {
                        let made = await Task.detached { FixtureDictationRecorder.writeTone(file, seconds: 12) }.value
                        guard made else { return }
                        let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
                        AudioPreview.present(.local(file, title: "Voice memo", bytes: bytes, isMemo: true), from: chat)
                    }
                default: chat.focusComposer()
                }
            }
        case "glassdock", "glasstray", "glassreply", "glassreplyarmed":
            guard let bot = services.bots.first(where: { $0.id == (wanted ?? $0.id) }) else { return retry() }
            root.botsViewController.open(bot.id)
            after(3.0) {
                guard let chat = findChat(in: root) else { return }
                if screen == "glassdock" {
                    chat.setDock(sampleDock(), for: .question, animated: false)
                } else if screen != "glasstray" {
                    holdReplySwipe(in: chat.view, pull: screen == "glassreplyarmed" ? 96 : 52)
                }
                // `-HQDebugGlassScroll <points>`: the transcript moves that far toward older rows, so rows sit behind
                // the dock or the tray (the table is flipped: a larger offset is older).
                let shift = UserDefaults.standard.double(forKey: "HQDebugGlassScroll")
                guard shift != 0 else { return }
                after(0.8) {
                    guard let table = firstTable(in: chat.view) else { return }
                    table.setContentOffset(CGPoint(x: 0, y: table.contentOffset.y + shift), animated: false)
                }
            }
        // [glass-audit 2026-11-01] the spots that should be glass and aren't
        case "account":
            root.select(.bots)
            after(1.0) { root.botsViewController.showAccount() }
        case "secretkey", "starnode":
            root.select(.more)
            after(1.0) {
                guard let nav = root.selectedViewController as? UINavigationController else { return }
                let host = UIHostingController(rootView: GlassAuditHost(star: screen == "starnode"))
                host.title = screen == "starnode" ? "Star Map" : "Toolsets"
                nav.pushViewController(host, animated: false)
            }
        case "htmlstatus":
            guard let bot = services.bots.first(where: { $0.id == (wanted ?? $0.id) }) else { return retry() }
            root.botsViewController.open(bot.id)
            after(2.5) {
                guard let chat = findChat(in: root) else { return }
                let url = FileManager.default.temporaryDirectory.appending(path: "dashboard.html")
                let rows = (1...14).map { "<tr><td>Week \($0)</td><td>\(1200 + $0 * 137)</td><td style='color:#2a9d5b'>+\($0 % 7 + 2)%</td></tr>" }.joined()
                let html = "<html><body style='font-family:-apple-system;margin:20px;background:linear-gradient(160deg,#ffd6a5,#bde0fe 55%,#cdb4db)'><h1>Sales Dashboard</h1><div style='display:flex;gap:10px'>" + ["#ff6b6b","#4ecdc4","#ffd93d","#6c5ce7"].map { "<div style='flex:1;height:90px;border-radius:14px;background:\($0)'></div>" }.joined() + "</div><table style='width:100%;font-size:17px;margin-top:16px'>\(rows)</table></body></html>"
                try? html.write(to: url, atomically: true, encoding: .utf8)
                HTMLPageSheet.present(url, from: chat)
            }
        case "newchat":
            root.selectedIndex = 1
            after(1.5) { root.sessionsViewController.organizer?.compose() }
        case "room":
            guard let groups = services as? GroupServices, let key = groups.groupStore?.rows().first?.id else { return retry() }
            groups.openRoom(key, from: root.botsViewController)
        default: break
        }
    }

    /// [glass-phone] A two-question dock as a bot's clarify would bring it (nothing is sent: no delegate).
    private static func sampleDock() -> QuestionDockView {
        let prompt = ClarifyPrompt(id: "tour-dock", questions: [
            ClarifyQuestion(qid: "q0", question: "Which branch should I deploy to staging before the release review?",
                            choices: ["main (Recommended)", "release/2026-11", "feat/glass-phone"], multiSelect: false),
            ClarifyQuestion(qid: "q1", question: "Anything else for the release notes?", choices: nil, multiSelect: false),
        ])
        // `-HQDebugGlassDockPage 1`: open on the second question (Back shows).
        return QuestionDockView(prompt: prompt, draft: ClarifyDraft(page: UserDefaults.standard.integer(forKey: "HQDebugGlassDockPage")))
    }

    /// [glass-phone] The newest visible bot bubble, held mid swipe.
    private static func holdReplySwipe(in view: UIView, pull: CGFloat) {
        func cells(_ v: UIView) -> [ChatBubbleCell] {
            (v as? ChatBubbleCell).map { [$0] } ?? v.subviews.flatMap(cells)
        }
        let bots = cells(view).filter { !$0.debugIsMine && $0.window != nil }
        guard let window = view.window else { return }
        // The table is flipped: the newest row is the lowest on screen.
        let pick = bots.filter { $0.convert($0.bounds, to: window).midY < window.bounds.height * 0.62 }
            .max { $0.convert($0.bounds, to: window).midY < $1.convert($1.bounds, to: window).midY }
        pick?.debugHoldReplySwipe(pull: pull)
    }

    private static func findChat(in controller: UIViewController?) -> ChatViewController? {
        guard let controller else { return nil }
        if let chat = controller as? ChatViewController { return chat }
        // [ipad-polish] Two panes: the chat is in the right pane, which is not under the tabs.
        if let tabs = controller as? MainTabController, let chat = tabs.chatOnShow { return chat }
        if let presented = controller.presentedViewController, let chat = findChat(in: presented) { return chat }
        for child in controller.children { if let found = findChat(in: child) { return found } }
        return nil
    }

    private static func firstTable(in view: UIView?) -> UITableView? {
        guard let view else { return nil }
        if let table = view as? UITableView { return table }
        for child in view.subviews { if let found = firstTable(in: child) { return found } }
        return nil
    }

    private static func firstCollection(in view: UIView?) -> UICollectionView? {
        guard let view else { return nil }
        if let list = view as? UICollectionView { return list }
        for child in view.subviews { if let found = firstCollection(in: child) { return found } }
        return nil
    }
}
#endif
