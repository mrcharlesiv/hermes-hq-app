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

        // Owner 2026-11-23: the Hermes HQ Discord card over the gateway card, until it's closed.
        HQCommunity.registerMoreCard()
        // [settings] → pages: the gateway card and Settings share the top card on More (on the Mac, MoreViewController
        // filters out Settings since it has its own window).
        func makeSettingsRow(_ model: AppModel) -> MoreRow {
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
            return row
        }
        PagesTabs.registerMoreSection(MoreSection(id: "account", header: nil) {
            guard let model = M2Wiring.model else { return [] }
            let settings = makeSettingsRow(model)
            guard model.account != nil else { return [settings] }
            let gateway = MoreRow(id: "gateway", title: "Gateway", symbol: nil, image: nil, tile: .clear, make: { [weak model] in
                guard let model else { return nil }
                return GatewayPageController(services: model, router: SettingsRouter(services: model, navigation: nil))
            }, card: { [weak model] in
                guard let model else { return UIListContentConfiguration.cell().hqScaled() }
                let card = SettingsRootModel(services: model)
                return UIHostingConfiguration { GatewayCardView(model: card) }.margins(.vertical, 0)
            })
            return [gateway, settings]
        })
        // Apps & Extensions: Marketplace, Capabilities, Connectors, Composio (plus Messaging & Webhooks appended by MorePages).
        PagesTabs.registerMoreSection(MoreSection(id: "apps", header: "Apps & Extensions") {
            guard let model = M2Wiring.model else { return [] }
            var capabilities = MoreRow(id: "capabilities", title: "Capabilities", symbol: "square.grid.2x2.fill", image: nil,
                                       tile: UIColor(red: 0x0A / 255, green: 0x84 / 255, blue: 1, alpha: 1)) { [weak model] in
                guard let model else { return nil }
                return CapabilitiesHubController(services: model)
            }
            capabilities.status = { CapabilitiesIssues.moreStatus() }
            guard model.account != nil else { return [capabilities] }
            let market = MoreRow(id: "marketplace", title: "Marketplace", symbol: "bag.fill", image: nil,
                                 tile: UIColor(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255, alpha: 1)) { [weak model] in
                guard let model else { return nil }
                return MarketplaceController.page(services: model)
            }
            let connectors = MoreRow(id: "connectors", title: "Connectors", symbol: "powerplug.fill", image: nil,
                                     tile: UIColor(red: 1, green: 0x9F / 255, blue: 0x0A / 255, alpha: 1)) { [weak model] in
                guard let model else { return nil }
                return CapabilitiesPages.page(.connectors, services: model)
            }
            let composio = MoreRow(id: ComposioRow.id, title: ComposioRow.title, symbol: ComposioRow.symbol, image: nil,
                                   tile: UIColor(red: 0x30 / 255, green: 0xB0 / 255, blue: 0xC7 / 255, alpha: 1)) { [weak model] in
                guard let model else { return nil }
                return ConnectAppsScreens.makeRoot(services: model)
            }
            return [market, capabilities, connectors] + (ConnectAppsFeature.isOn ? [composio] : [])
        })
        // System: admin, secrets & bot management (Bot Profiles, Passwords, Status & Maintenance, Import Sessions).
        PagesTabs.registerMoreSection(MoreSection(id: "system", header: "System") {
            guard let model = M2Wiring.model, model.account != nil else { return [] }
            let passwords = MoreRow(id: "passwords", title: "Passwords", symbol: "key.fill", image: nil,
                                    tile: UIColor(red: 0x5E / 255, green: 0x5C / 255, blue: 0xE6 / 255, alpha: 1)) { [weak model] in
                guard let model else { return nil }
                return PasswordsPageController(router: SettingsRouter(services: model, navigation: nil))
            }
            return [passwords]
        })

        // [morepages] More › Bot Profiles, Messaging, Files, Review, Status & Maintenance, Usage, Spawn Tree, Star Map,
        // Webhooks, Import Sessions (docs/spec/3x-morepages.md §19): each lists only while its page exists and its route answers.
        MorePages.install()
        // [plugin-pages-more] More › Plugin Pages: each page the bots' plugins add (Memory Wiki…), a place of its own.
        PluginPagesMore.install()
        CapabilitiesModel.installMemoryTrim()

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
