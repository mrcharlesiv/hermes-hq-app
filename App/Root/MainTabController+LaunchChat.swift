// [restore] Reopening the last chat on a cold launch (HermesKit/Store/LaunchChatMemory.swift says what is remembered
// and when it is not reopened). The chat goes back over the list (or page) it was opened from before the first frame,
// without a push, so Back returns there as it did; its rows paint from the transcript cache as a tapped open's do. When
// the lists it is checked against have nothing cached yet, the check waits for their first answer (at most 8 s, the
// web's settle limit) and the chat is put back then only if nothing else was opened meanwhile. A chat reopened from
// cache that the gateway's first fresh answer no longer has (deleted, archived, its bot removed) goes back to its list
// quietly. A launch from a tapped alert or a link opens that instead.

import UIKit

/// What the launch restore still waits for.
enum LaunchChatWatch {
    /// The lists had nothing cached: decide on their first answer.
    case awaiting(RememberedChat, until: Date)
    /// Reopened from cached lists: confirm against the first fresh answer.
    case verifying(RememberedChat, screen: WeakBox<UIViewController>, until: Date)
}

extension MainTabController {
    /// Set by the scene for its cold launch only: a sign-in, the next saved account after a sign-out and a gateway switch
    /// never reopen a chat.
    static var launchRestorePending = false

    /// Called once from `init`, after the tabs (and the last tab) are in place.
    func restoreLaunchChat() {
        defer {
            launchChatSettled = true
            noteLaunchScreen()
        }
        guard Self.launchRestorePending else { return }
        Self.launchRestorePending = false
        guard let model = services as? AppModel, let account = model.account?.id else { return }
        let memory = LaunchChatMemory.shared
        guard let chat = memory.recall(account: account) else {
            if memory.crashed(account: account) { AppLog.note("restore", "skipped: \(LaunchChatDecision.Reason.crashed.rawValue)") }
            return
        }
        guard memory.resume(account: account) else {
            AppLog.note("restore", "skipped: \(LaunchChatDecision.Reason.resumeOff.rawValue)")
            return
        }
        // Nothing to check it against yet (a first launch after an update, caches cleared): the lists' first answer.
        guard chat.botChat ? !model.bots.isEmpty : model.launchSessionsCached else {
            AppLog.note("restore", "waiting for the lists")
            watchLaunchLists(model)
            launchChatWatch = .awaiting(chat, until: Date().addingTimeInterval(8))
            return
        }
        switch decideLaunchChat(chat, model: model) {
        case .skip(let reason):
            AppLog.note("restore", "skipped: \(reason.rawValue)")
        case .reopen(let chat):
            guard let screen = placeLaunchChat(chat, model: model) else { return }
            AppLog.note("restore", "reopened the last chat (\(chat.origin.rawValue))")
            watchLaunchLists(model)
            launchChatWatch = .verifying(chat, screen: WeakBox(screen), until: Date().addingTimeInterval(30))
        }
    }

    /// The screen on show is what the next cold launch reopens: kept current on every tab change and navigation, and
    /// written again as the app leaves the foreground (SceneDelegate).
    func noteLaunchScreen() {
        guard launchChatSettled, let account = services.account?.id else { return }
        if let live = paneChatOnShow?.chat.session as? LiveChatSession { MoreChatFolder.note(live, account: account) }   // [morepages] Files' "last chat" folder
        LaunchChatMemory.shared.remember(rememberedChatOnShow(), account: account,
                                         foreground: UIApplication.shared.applicationState != .background)
    }

    /// The chat on top of the selected tab, and where it was opened from.
    private func rememberedChatOnShow() -> RememberedChat? {
        // [m9/ipad] In two panes the chat is in the right pane; its origin is the list it was opened from.
        guard let (screen, navigation, tab) = paneChatOnShow,
              let live = screen.session as? LiveChatSession else { return nil }
        let origin: RememberedChat.Origin = tab == .bots ? .bots : tab == .sessions ? .sessions : .page
        let kind = navigation.tabBarItem.accessibilityIdentifier
        if origin == .page && kind == nil { return nil }
        return RememberedChat(origin: origin, profile: live.profile, storedId: live.storedSessionId ?? live.resolvedStoredId,
                              botChat: live.menus.isBotChat, pageTab: origin == .page ? tab?.rawValue : nil,
                              pageKind: origin == .page ? kind : nil)
    }

    private func decideLaunchChat(_ chat: RememberedChat, model: AppModel) -> LaunchChatDecision {
        LaunchChatDecision.decide(chat, crashed: false, resume: true,
                                  bot: { id in model.bots.contains { $0.id == id } },
                                  listed: { profile, id in model.launchListedSession(profile: profile, id: id) != nil },
                                  page: { [weak self] tab, kind in self?.pageNavigation(tab, kind: kind) != nil })
    }

    /// [taborder] `tab` is the page tab's tag (`HQTab`), which is also the place it had when older builds saved it.
    private func pageNavigation(_ tab: Int, kind: String) -> UINavigationController? {
        guard tab >= HQTab.jobs.rawValue, let page = HQTab(rawValue: tab),
              let navigation = controller(for: page) as? UINavigationController,
              navigation.tabBarItem.accessibilityIdentifier == kind else { return nil }
        return navigation
    }

    /// Puts the chat over its tab's root, with no push: [list, chat], Back pops to the list.
    private func placeLaunchChat(_ chat: RememberedChat, model: AppModel) -> UIViewController? {
        let navigation: UINavigationController?
        switch chat.origin {
        case .bots: navigation = listStack(.bots)            // [customtabs] the other list's while Bots is hidden
        case .sessions: navigation = listStack(.sessions)
        case .page: navigation = chat.pageKind.flatMap { pageNavigation(chat.pageTab ?? -1, kind: $0) }
        }
        guard let navigation, let root = navigation.viewControllers.first else { return nil }
        let session: ChatSessionModel
        if chat.botChat, let bot = model.bots.first(where: { $0.id == chat.profile }) {
            session = model.chat(for: bot)
        } else if let id = chat.storedId, let summary = model.launchListedSession(profile: chat.profile, id: id) {
            session = model.chat(for: summary)
        } else {
            return nil
        }
        let screen = makeChat(session)
        screen.hidesBottomBarWhenPushed = true
        screen.navigationItem.largeTitleDisplayMode = .never
        if let tab = viewControllers?.firstIndex(where: { $0 === navigation }), selectedIndex != tab { selectedIndex = tab }
        navigation.setViewControllers([root, screen], animated: false)
        return screen
    }

    private func watchLaunchLists(_ model: AppModel) {
        model.onLaunchListsChange = { [weak self, weak model] in
            guard let self, let model else { return }
            self.launchListsChanged(model)
        }
    }

    /// The roster or the Sessions list changed: settle what the launch restore waits for.
    private func launchListsChanged(_ model: AppModel) {
        guard let watch = launchChatWatch else { model.onLaunchListsChange = nil; return }
        let done = { [weak self] in
            self?.launchChatWatch = nil
            model.onLaunchListsChange = nil
        }
        switch watch {
        case .awaiting(let chat, let until):
            guard Date() < until else { return done() }
            guard chat.botChat ? model.botsLoaded : model.launchSessionsCached else { return }
            done()
            // Only onto the list the launch showed, untouched: anything opened meanwhile stands.
            guard presentedViewController == nil, nothingOpen else { return }   // [m9/ipad] `nothingOpen` covers the right pane
            switch decideLaunchChat(chat, model: model) {
            case .skip(let reason):
                AppLog.note("restore", "skipped: \(reason.rawValue)")
            case .reopen(let chat):
                if placeLaunchChat(chat, model: model) != nil {
                    AppLog.note("restore", "reopened the last chat (\(chat.origin.rawValue)) after the lists loaded")
                    noteLaunchScreen()
                }
            }
        case .verifying(let chat, let screen, let until):
            guard Date() < until, let shown = screen.value, let navigation = shown.navigationController,
                  navigation.topViewController === shown else { return done() }
            guard chat.botChat ? model.launchBotsFresh : model.launchSessionsFresh else { return }
            done()
            guard case .skip(let reason) = decideLaunchChat(chat, model: model) else { return }
            AppLog.note("restore", "closed the reopened chat: \(reason.rawValue)")
            // [m9/ipad] Two panes: the right pane goes back to its placeholder.
            if split?.isDouble == true { leave(shown, animated: true) } else { navigation.popToRootViewController(animated: true) }
        }
    }
}

extension AppModel {
    /// A listed chat of `profile` (Sessions recents, scheduled runs, messaging threads), as the lists hold it now.
    func launchListedSession(profile: String, id: String) -> SessionSummary? {
        guard let store = sessionStore else { return nil }
        return (store.sessions + store.cronSessions + store.messagingSessions).first { $0.id == id && $0.profile == profile }
    }

    /// The Sessions list has rows from its cache or a read.
    var launchSessionsCached: Bool { sessionStore?.lastUpdated != nil }
    /// The roster answered since launch (not only painted from cache).
    var launchBotsFresh: Bool { (botStore?.phase ?? .none) >= .slim }
    /// The Sessions list answered since launch.
    var launchSessionsFresh: Bool { sessionStore?.loadState == .ready }

    /// `display.resume_last_session` from the gateway's config, once per sign-in, a moment after the link is first
    /// ready (the gateway reads its whole config under one lock; the launch's own reads go first). Kept for the next
    /// cold launch; a failed read keeps the last answer.
    func readResumePreference() {
        guard !resumePreferenceRead, let client, let account else { return }
        resumePreferenceRead = true
        let accountId = account.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let on = await Self.readResume(client), let self, self.account?.id == accountId else { return }
            if LaunchChatMemory.shared.resume(account: accountId) != on { AppLog.note("restore", "reopen last chat: \(on ? "on" : "off")") }
            LaunchChatMemory.shared.setResume(on, account: accountId)
        }
    }

    @concurrent private static func readResume(_ client: any GatewayClient) async -> Bool? {
        guard let data = try? await client.configData([]),   // [load-cache] shared with the launch's other readers
              let json = try? JSONValue.parse(data) else { return nil }
        return LaunchChatMemory.resume(config: json)
    }
}
