// The hooks the m2 streams left for integration (docs/m2-stream-reports.md, "Hooks to wire"), set once at launch before
// the first screen. Each stream exposes a seam and doesn't know the others; this file joins them.

import SwiftUI
import UIKit

@MainActor enum M2Wiring {
    private static var installed = false
    /// The newest main window's model. The hooks are joined once, but a window closed and opened again from the Dock
    /// makes a new model, so they read this when they run: held from the first window, More's Gateway, Settings,
    /// Capabilities, Marketplace and Connectors rows went with it (Mac polish #3).
    private(set) static weak var model: AppModel?

    static func install(model: AppModel) {
        self.model = model
        // [groups] New Group Chat in Compose, Add to Group Chat… in a bot's menu, Bot Info's Group Chats (they follow the
        // newest model too).
        GroupActions.install(model: model)
        guard !installed else { return }
        installed = true

        // [activity] → settings: Settings › Chat › Tool Calls (Tool Call Style, After Reply).
        SettingsHooks.toolCallsScreen = { ToolCallSettings.makeScreen() }
        SettingsHooks.toolCallsTitle = "Tool Calls"
        SettingsHooks.toolCallsSummary = { ToolCallSettings.summary }

        // [pages] → settings: the Kanban Tab picker (Appearance › Tabs) shows once the gateway answered and has the Kanban API.
        SettingsHooks.kanbanAvailability = { account in PagesTabs.probedKanbanAvailability(account) }

        // [settings] → pages: the gateway card heads More (spec 1x-pages §1.2, `S/ui-nav/more-account.tsx`): the gateway's
        // name and "● Connected · 9 Bots · Hermes 0.21.5"; it opens Settings › Gateway on More's own stack.
        PagesTabs.registerMoreSection(MoreSection(id: "account", header: nil) {
            guard let model = M2Wiring.model, model.account != nil else { return [] }
            return [MoreRow(id: "gateway", title: "Gateway", symbol: nil, image: nil, tile: .clear, make: { [weak model] in
                guard let model else { return nil }
                return GatewayPageController(services: model, router: SettingsRouter(services: model, navigation: nil))
            }, card: { [weak model] in
                guard let model else { return UIListContentConfiguration.cell().hqScaled() }
                let card = SettingsRootModel(services: model)
                return UIHostingConfiguration { GatewayCardView(model: card) }.margins(.vertical, 0)
            })]
        })
        // [settings] → pages: More lists Settings alone, then Bots › Capabilities (S/ui-nav/more-model.ts:12-17; tints
        // and glyphs from S/phone-tab-bar.tsx). Both push on More's own stack, inline titles (owner: headers sit high).
        PagesTabs.registerMoreSection(MoreSection(id: "settings", header: nil) {
            guard let model = M2Wiring.model else { return [] }
            var row = MoreRow(id: "settings", title: "Settings", symbol: "gearshape.fill", image: nil,
                              tile: UIColor(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255, alpha: 1)) { [weak model] in
                guard let model else { return nil }
                #if targetEnvironment(macCatalyst)
                if MacSettingsWindow.open() { return nil }   // [mac-layout] Settings is a window of its own on the Mac
                #endif
                let page = SettingsScreens.makeSettings(services: model)
                page.navigationItem.largeTitleDisplayMode = .never
                return page
            }
            // [addon-reminder] A red 1 while the add-on needs an update the person hasn't made.
            // [plugin-updates] And one for each plugin with an update.
            row.badge = {
                let addOn = AddOnReminder.shared.spoken, plugins = PluginUpdateReminder.shared
                let count = (addOn == nil ? 0 : 1) + plugins.count
                return count > 0 ? (count, [addOn, plugins.spoken].compactMap { $0 }.joined(separator: ", ")) : nil
            }
            return [row]
        })
        PagesTabs.registerMoreSection(MoreSection(id: "bots", header: "Bots") {
            guard let model = M2Wiring.model else { return [] }
            var row = MoreRow(id: "capabilities", title: "Capabilities", symbol: "square.grid.2x2.fill", image: nil,
                              tile: UIColor(red: 0x0A / 255, green: 0x84 / 255, blue: 1, alpha: 1)) { [weak model] in
                guard let model else { return nil }
                // [cap-pages] Owner 2026-11-03: four rows (Skills, Tools, Connectors, Plugins), each its own page. An
                // issue is on the Connectors row too, which then opens on the newest one's bot (3x §8.5).
                return CapabilitiesHubController(services: model)
            }
            row.status = { CapabilitiesIssues.moreStatus() }
            // [marketplace-row] Owner 2026-11-04: the Hermes Marketplace one tap from More, beside Capabilities, and
            // only here ("it's in two places": no row inside Capabilities). It can be a tab, and on the Mac it is one of
            // the sidebar's Tools. The Plugins and Skills pages still link to it for what they list.
            guard model.account != nil else { return [row] }
            let market = MoreRow(id: "marketplace", title: "Marketplace", symbol: "bag.fill", image: nil,
                                 tile: UIColor(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255, alpha: 1)) { [weak model] in
                guard let model else { return nil }
                return MarketplaceController.page(services: model)
            }
            // [directory] More › Connectors: the desktop's Connectors page on its own (Hermes' app catalog, the Nous
            // apps, MCP servers, and Composio with your own key).
            // [cap-pages] The same page as Capabilities › Connectors (one page, two ways in; it can be a tab).
            // [connect-find] Owner 2026-11-11 ("the whole thing is hidden"): beside Marketplace, where what a bot can
            // be given is, not at the foot of More under Integrations (two screens down).
            let connectors = MoreRow(id: "connectors", title: "Connectors", symbol: "powerplug.fill", image: nil,
                                     tile: UIColor(red: 1, green: 0x9F / 255, blue: 0x0A / 255, alpha: 1)) { [weak model] in
                guard let model else { return nil }
                return CapabilitiesPages.page(.connectors, services: model)
            }
            // [passwords-page] Owner 2026-11-11: every password in one organized place, a tap from More (the same page
            // as Settings › Passwords): what the bots fill, password managers, keys, and this device's Keychain.
            let passwords = MoreRow(id: "passwords", title: "Passwords", symbol: "key.fill", image: nil,
                                    tile: UIColor(red: 0x5E / 255, green: 0x5C / 255, blue: 0xE6 / 255, alpha: 1)) { [weak model] in
                guard let model else { return nil }
                return PasswordsPageController(router: SettingsRouter(services: model, navigation: nil))
            }
            return [row, market, connectors, passwords]
        })

        // [morepages] More › Bot Profiles, Messaging, Files, Review, Status & Maintenance, Usage, Spawn Tree, Star Map,
        // Webhooks, Import Sessions (docs/spec/3x-morepages.md §19): each lists only while its page exists and its route answers.
        MorePages.install()
        // [plugin-pages-more] More › Plugin Pages: each page the bots' plugins add (Memory Wiki…), a place of its own.
        PluginPagesMore.install()

        // Bots extras (parity §3): the row menu's New Chat, Mute, Duplicate and Delete Bot.
        BotExtras.install()

        // VOICE → bots: the row menu's Memo tile opens the chat on the locked (hands-free) recorder (spec 1x-voice:
        // `beginMemo(handsFree:)` is the seam for entry points beyond the mic).
        BotMenuHooks.providers[.memo] = { bot, host in
            .action("Memo", "mic") { [weak host] in
                guard let bots = host as? BotsViewController else { return }
                bots.open(bot.id)
                whenChatSettles(on: bots.navigationController, attempts: 30) { $0.beginMemo(handsFree: true) }
            }
        }
    }

    /// Runs `work` on the chat at the top of `navigation` once its push has finished (≤ 3 s).
    private static func whenChatSettles(on navigation: UINavigationController?, attempts: Int, _ work: @escaping (ChatViewController) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let navigation else { return }
            if let chat = navigation.paneChat, chat.view.window != nil,
               navigation.transitionCoordinator == nil {
                work(chat)
            } else if attempts > 0 {
                whenChatSettles(on: navigation, attempts: attempts - 1, work)
            }
        }
    }
}
