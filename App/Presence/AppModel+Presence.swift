import SwiftUI
import UIKit

// [presence] The presence centre's hooks into the app (docs/spec/3x-presence.md §3.3, §6.2, §8.4): made with the
// account, fed the gateway's events and the Bots list's visibility, and given the two Watch actions. Bot Info's Computer
// group is registered here too.

extension AppModel {
    /// Signed in: a centre for this account. Called from `activate` right after `registerBrowserMenu()`.
    func startPresence() {
        presence?.shutdown()
        // The browser plugin's request is one fixed prompt: its bubble shows the short title wherever the chat reads it
        // (after a relaunch and from another device too), never the stored prompt, which names the plugin's old wire
        // name. Noting the same pair again changes nothing.
        LiveChatSession.sentTitles.note(text: BrowserSetupPrompt.text, title: MainBotRequest.browserTitle)
        LiveChatSession.sentTitles.note(text: BrowserSetupPrompt.update, title: MainBotRequest.browserUpdateTitle)
        LiveChatSession.sentTitles.note(text: PushSetupOffer.prompt, title: PushSetupOffer.queueTitle)   // [settings]
        let center = PresenceCenter(browser: browser, context: PresenceCenter.Context(
            owner: { [weak self] runtimeId in self?.presenceOwner(ofRuntime: runtimeId) },
            bots: { [weak self] in self?.bots ?? [] },
            noticeOn: { [weak self] profile in self?.botStore?.screenNoticeOn(profile) ?? false },
            visibleChatProfile: { [weak self] in self?.presenceVisibleChatProfile },
            face: { [weak self] profile in self?.peekFace(profile) },
            window: { AppModel.presenceWindow() },
            openBrowser: { [weak self] scope, gaveUp in self?.watchBrowser(scope, gaveUp: gaveUp) },
            openScreen: { [weak self] bot, gaveUp in self?.watchScreen(bot, gaveUp: gaveUp) },
            publish: { [weak self] map in self?.botStore?.setPresence(map) },
            ownChats: { [weak self] profile in self?.botStore?.ownChatIds(profile) }))
        presenceSet(center)
        PresenceHooks.botsListShown = { [weak self] list, shown in self?.botsListShown(list, shown) }
        // A gateway switch keeps the Bots list's place on screen: the new centre starts from what is showing.
        if let list = Self.shownBotsList, list.viewIfLoaded?.window != nil { center.setBotsListShown(true) }
        // UX study #135: on Sessions and More the centre opens the plugin's list itself, so an ask is heard there too.
        PresenceHooks.askTabShown = { [weak self] shown in self?.presence?.setAsksHeard(shown) }
        if MainTabController.current?.showsAskTab == true { center.setAsksHeard(true) }
        installPresenceDebugHooks()
    }

    /// The app's window, for the notice. Under a full-screen cover (the browser viewer) the tabs' own view is out of the
    /// window, so what is on top is asked instead: a notice still shows over a viewer (spec §8.4, E5).
    static func presenceWindow() -> UIWindow? {
        let tabs = MainTabController.current
        return tabs?.view.window ?? FailureAlert.topmost(tabs)?.view.window ?? tabs?.presentedViewController?.view.window
    }

    private static weak var shownBotsList: UIViewController?

    /// The Bots list came on screen or left it. A list that went away with its gateway (the tabs are made again on a
    /// switch) cannot switch off the one that replaced it.
    private func botsListShown(_ list: UIViewController, _ shown: Bool) {
        if shown {
            Self.shownBotsList = list
            presence?.setBotsListShown(true)
        } else if Self.shownBotsList === list || Self.shownBotsList == nil {
            Self.shownBotsList = nil
            presence?.setBotsListShown(false)
        }
    }

    /// The notice's Watch for a browser (§8.4): over whatever is on screen. An alert on top is waited for first, and only
    /// then does a viewer for another bot close (it hands a held browser back), so Watch never does nothing (DECISION
    /// D9) and never answers an alert for the person (D22). `gaveUp` runs when the wait ran out.
    func watchBrowser(_ scope: BrowserScope, gaveUp: @escaping () -> Void = {}) {
        AppLog.note("presence", "watch browser")
        presentOverTop(gaveUp: gaveUp) { model, top in
            guard BrowserViewerController.isUp, !BrowserViewerController.isWatching(profile: scope.profile) else {
                model.openBrowser(scope, from: top)
                return
            }
            BrowserViewerController.closeCurrent {
                model.presentOverTop(gaveUp: gaveUp) { model, top in model.openBrowser(scope, from: top) }
            }
        }
    }

    /// The notice's Watch for a screen: the screen stream's viewer.
    func watchScreen(_ bot: Bot, gaveUp: @escaping () -> Void = {}) {
        AppLog.note("presence", "watch screen")
        presentOverTop(gaveUp: gaveUp) { _, top in BotComputerHooks.openScreen?(bot, top) }
    }

    /// How long Watch waits for an alert or a transition on top: 20 looks, a quarter of a second apart.
    nonisolated static let watchWaitTries = 20

    /// What is on top of everything, and whether it can take a presentation now. An alert is the person's to answer,
    /// and nothing can be presented while any page in the stack is still arriving or leaving (UIKit drops it).
    static func presenceTop() -> (top: UIViewController, busy: Bool)? {
        guard let tabs = MainTabController.current else { return nil }
        var top: UIViewController = tabs.view.window?.rootViewController ?? tabs
        var busy = top.isBeingPresented || top.isBeingDismissed
        while let next = top.presentedViewController {
            if next.isBeingPresented || next.isBeingDismissed { busy = true }
            top = next
        }
        if top is UIAlertController { busy = true }
        return (top, busy)
    }

    /// Runs `present` with the topmost controller once it can take a presentation. It waits for an alert or a
    /// transition for about 5 s, never dismissing the alert for the person; a wait that runs out is not dropped
    /// silently: `gaveUp` puts Watch on offer again (DECISION D22).
    private func presentOverTop(tries: Int = AppModel.watchWaitTries, gaveUp: @escaping () -> Void = {},
                                _ present: @escaping (AppModel, UIViewController) -> Void) {
        guard let (top, busy) = Self.presenceTop() else { return }
        if busy {
            guard tries > 0 else {
                AppLog.note("presence", "watch: gave up waiting")
                gaveUp()
                return
            }
            if tries == AppModel.watchWaitTries { AppLog.note("presence", "watch: waiting for what is on top (\(type(of: top)))") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.presentOverTop(tries: tries - 1, gaveUp: gaveUp, present)
            }
            return
        }
        AppLog.note("presence", "watch: over \(type(of: top))")
        present(self, top)
    }

    /// Bot Info's Computer group (it replaces the browser stream's "Browser" group).
    func computerInfoSection(_ bot: Bot, host: UIViewController) -> AnyView? {
        guard let browser else { return nil }
        let name = bot.id
        return AnyView(ComputerInfoSection(
            bot: bot, service: browser, host: host,
            online: { [weak self] in self?.connection == .ready },
            alertOn: { [weak self] in self?.botStore?.screenNoticeOn(name) ?? true },
            setAlert: { [weak self] on in
                guard let store = self?.botStore else { throw BotWriteError(title: "Couldn’t Change the Alert", reason: BotWriteError.notSavedReason) }
                try await store.setScreenNotice(name: name, on)
            },
            open: { [weak self] scope, presenter in self?.openBrowser(scope, from: presenter) }))
    }

    /// "Ask Hermes to Install It" (§10): what can be known without leaving the viewer. Is there a main bot to ask, and
    /// can what is open under the viewer be closed to show its chat (a sheet with unsaved edits is never thrown away)?
    func canAskMainBot() throws {
        _ = try MainBotRequest.mainBot(bots)
        try MainBotRequest.checkCanLeave(MainTabController.current)
    }

    private func installPresenceDebugHooks() {
        #if DEBUG
        // UI tests (`-HQDebugScreenRow YES`): a stand-in for the screen stream's hooks, so the Computer group's first row
        // and the "is using its screen" notice can be seen before that stream lands.
        guard UserDefaults.standard.bool(forKey: "HQDebugScreenRow"), BotComputerHooks.screenRow == nil else { return }
        BotComputerHooks.screenRow = { bot, host in
            AnyView(Button {
                BotComputerHooks.openScreen?(bot, host)
            } label: {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Watch Screen").foregroundStyle(Color.hqLabel)
                            Text("See its desktop live").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                        }
                    } icon: {
                        Image(systemName: "display").foregroundStyle(Color.hqLabel)
                    }
                    Spacer(minLength: 8)
                    SettingsChevron()
                }
            }
            .accessibilityIdentifier("bot-info.computer.screen"))
        }
        BotComputerHooks.openScreen = { bot, host in
            let alert = UIAlertController(title: "Screen", message: "\(bot.name)’s screen would open here.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            host.present(alert, animated: true)
        }
        BotComputerHooks.screenIsOpen = { false }
        #endif
    }
}
