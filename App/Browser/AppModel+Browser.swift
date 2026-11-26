import SwiftUI
import UIKit

// [browser] Watch Browser's hooks into the app: the account's browser service, the chat's card and ⋯ › Watch Browser,
// the Bots row menu's Watch Browser, and "Ask Hermes to Install It" (the main bot's chat with the request typed).

extension AppModel {
    /// The scope a chat's card and ⋯ item show: a bot's own chat any browser of that bot; another chat only its own.
    /// The card matches the chat's sessions (a Bot Chat's `ownChats`, its earlier ones too) against the chat driving the
    /// browser now (`BrowserScope.drivenRow`); the viewer keeps the wider match.
    func browserScope(for model: any ChatSessionModel) -> BrowserScope {
        let live = model as? LiveChatSession
        let name = live?.botName ?? botStore?.bot(named: model.profile)?.name ?? model.title
        let ids = [live?.storedSessionId, live?.runtimeSessionId].compactMap { $0 }.filter { !$0.isEmpty }
        if live?.menus.isBotChat ?? false {
            let own = botStore?.ownChatIds(model.profile) ?? []
            return BrowserScope(profile: model.profile, title: name, ownChats: Array(Set(ids).union(own)).sorted())
        }
        return BrowserScope(profile: model.profile, sessionIds: ids, title: name, chatOnly: true)
    }

    func openBrowser(_ scope: BrowserScope, from presenter: UIViewController) {
        guard let browser else { return }
        // [presence] Its notice has nothing left to offer once its viewer is up.
        PresenceNotice.shared.dismiss(about: scope.profile)
        // [presence] "Ask Hermes to Install It" queues the request in the main bot's chat (spec 3x-presence §10): sent at
        // once when the bot is free, after its reply otherwise. Nothing is typed for the person to send.
        BrowserViewerController.present(scope: scope, service: browser, from: presenter,
                                        canAsk: { [weak self] in try self?.canAskMainBot() },
                                        askToInstall: { [weak self] prompt in
            try await MainBotRequest.queue(text: prompt, title: prompt == BrowserSetupPrompt.update ? MainBotRequest.browserUpdateTitle : MainBotRequest.browserTitle,
                                           linkReady: { self?.connection == .ready })
        }, openPlugins: { [weak self] in
            self.map { CapabilitiesViewController(services: $0, profile: scope.profile, tab: .plugins) }
        }, helper: (try? MainBotRequest.mainBot(bots))?.name, cloudGateway: CloudGatewayFlow.isCloud(account?.baseURL),
           // [browser-update] "Update the Add-on": the same sheet as Settings' "Add-on Update Available" row.
           updateAddOn: PushRegistrar.available ? { [weak self] in
            guard let self else { return }
            Task { @MainActor in _ = await PushSetupOffer.shared.check(model: self, fromSettings: true, from: nil) }
        } : nil)
    }

    /// The chat screen's browser pieces: one unified Browser (Watch Browser docked beside chat on Mac, full-screen on
    /// iPhone/iPad), the live activity card on the shelf, and silent `desktop_preview` handling if a bot pushes one.
    func installBrowser(on screen: ChatViewController, menus: ChatMenus) {
        previewTabs?.register(screen)   // [preview-tab] silent support when a bot explicitly invokes `desktop_preview`
        guard let browser else { return }
        screen.isInAppBrowserOpen = { [weak screen] in
            guard let screen else { return false }
            #if targetEnvironment(macCatalyst)
            if let inspector = MacInspector.beside(screen), inspector.isVisible, inspector.shownBrowser != nil {
                return true
            }
            #endif
            return BrowserViewerController.isWatching(profile: screen.session.profile)
        }
        screen.onToggleInAppBrowser = { [weak self, weak screen] in
            guard let self, let screen else { return }
            #if targetEnvironment(macCatalyst)
            if let inspector = MacInspector.beside(screen), inspector.isVisible, inspector.shownBrowser != nil {
                inspector.closeBrowser()
                screen.refreshInAppBrowserButton()
                return
            }
            #endif
            self.openBrowser(self.browserScope(for: screen.session), from: screen)
            screen.refreshInAppBrowserButton()
        }
        let model = screen.session
        let fallback = browserScope(for: model)
        // [presence] An ask notice about this bot is old news once its chat (and the card saying the same) is up.
        PresenceNotice.shared.dismissAsk(about: model.profile)
        BrowserChatCard.install(on: screen, service: browser, scope: { [weak self, weak model] in
            guard let self, let model else { return fallback }
            return self.browserScope(for: model)
        }) { [weak self] scope, presenter in
            self?.openBrowser(scope, from: presenter)
        }
        menus.slotItems[.browser] = { [weak self, weak screen, weak menus] in
            guard let self, let screen else { return [] }
            // [presence] Greyed with "Offline" under it while the link is not ready (spec 3x-presence §9); the menu is
            // built again on every open, so the state is fresh.
            let rule = BrowserMenuRule.chatItem(offline: menus?.offline ?? false)
            #if targetEnvironment(macCatalyst)
            let docked = MacInspector.beside(screen).map { $0.isVisible && $0.shownBrowser != nil } ?? false
            let title = docked ? "Hide Browser" : "Browser"
            #else
            let title = BrowserMenuRule.title
            #endif
            let watch = UIAction(title: title, subtitle: rule.subtitle, image: UIImage(systemName: "globe"),
                                 attributes: rule.disabled ? .disabled : []) { [weak self, weak screen] _ in
                guard let self, let screen else { return }
                #if targetEnvironment(macCatalyst)
                if let inspector = MacInspector.beside(screen), inspector.isVisible, inspector.shownBrowser != nil {
                    inspector.closeBrowser()
                    screen.refreshInAppBrowserButton()
                    return
                }
                #endif
                self.openBrowser(self.browserScope(for: screen.session), from: screen)
                screen.refreshInAppBrowserButton()
            }
            watch.accessibilityIdentifier = "chat.more.browser"
            return [watch]
        }
    }

    private static var browserInfoInstalled = false

    /// Bots › a bot's menu › More › Watch Browser, and Bot Info's Computer group ([presence]: Watch Browser, Profile and
    /// Window, the alert switch and the screen stream's row; App/Presence/ComputerInfoSection.swift).
    func registerBrowserMenu() {
        if !Self.browserInfoInstalled {
            Self.browserInfoInstalled = true
            BotInfoHooks.sections.append { [weak self] bot, host in self?.computerInfoSection(bot, host: host) }
        }
        BotMenuHooks.providers[.watchBrowser] = { [weak self] bot, host in
            guard self?.browser != nil else { return nil }
            return .action("Watch Browser", "safari") { [weak self, weak host] in
                guard let self, let host else { return }
                self.openBrowser(BrowserScope(profile: bot.id, title: bot.name), from: host)
            }
        }
    }

}
