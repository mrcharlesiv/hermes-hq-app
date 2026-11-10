// The running app as `IntentsRuntime` sees it (docs/spec/3x-intents.md §3.4): the signed-in account and its roster
// from `AppModel`, the screens from `MainTabController`, the recorder from `MemoController`.

import UIKit

@MainActor final class LiveIntentsHost: IntentsHost {
    private weak var model: AppModel?

    init(model: AppModel) { self.model = model }

    private var root: MainTabController? { MainTabController.current }

    // MARK: Account and roster

    var account: String? { model?.intentsAccount }

    var isActive: Bool { UIApplication.shared.applicationState == .active }

    var isForeground: Bool {
        UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
    }

    func cancelLaunchRestore() {
        var event: String?
        if MainTabController.launchRestorePending {
            MainTabController.launchRestorePending = false
            event = "launch restore canceled"
        }
        // A restore already in flight stops: one still waiting for the lists never shows its chat; one that has put
        // its chat back is no longer checked (the shortcut's chat takes its place).
        if let root, let watch = root.launchChatWatch {
            root.launchChatWatch = nil
            if case .awaiting = watch { event = "launch restore canceled" } else { event = event ?? "launch restore replaced" }
        }
        guard let event else { return }
        AppLog.note("intents", event)
        IntentsEvents.note(event)
    }

    var isReady: Bool { model?.account != nil && root?.view.window != nil }

    var rosterLoaded: Bool { model?.botsLoaded ?? false }

    func bot(forKey key: String) -> Bot? {
        guard let profile = VoiceBotCatalog.profile(key: key) else { return nil }
        return model?.bots.first { $0.id == profile }
    }

    func refreshRoster() async {
        AppLog.note("intents", "roster read")
        await model?.botStore?.refresh()
    }

    func syncCatalog() { model?.intentsListsChanged() }

    // MARK: The bot's chat

    func openBotChat(_ bot: Bot) async throws -> (any IntentsChat)? {
        guard let root else { return nil }
        if let top = topChat(of: root), LiveIntentsChat.botProfile(top) == bot.id, settled(top) {
            return LiveIntentsChat(screen: top)
        }
        // As a tapped alert does (`openNotifiedChat`): whatever is presented goes, the Bots tab shows its list. A sheet
        // holding unsaved edits asks first (UX study #263); kept, the chat doesn't open and nothing is said.
        guard await root.clearForRoute() else { throw IntentsKept() }
        root.select(.bots)
        let bots = root.botsViewController
        bots.navigationController?.popToRootViewController(animated: false)
        bots.open(bot.id)
        // ≤ 3 s for the chat to be on top with its push finished. On a cold launch the list may not have its rows
        // yet, and `open` ignores a call while its own push waits: ask again every 300 ms while no chat is on top.
        for step in 1...30 {
            try? await Task.sleep(for: .milliseconds(100))
            guard let navigation = bots.navigationController, root.shownTab == .bots else { continue }
            if let chat = navigation.paneChat {
                // Whatever chat it is: the runtime refuses one that is not this bot's ("…changed before recording could start").
                if settled(chat) { return LiveIntentsChat(screen: chat) }
            } else if step % 3 == 0 {
                bots.open(bot.id)
            }
        }
        return nil
    }

    private func topChat(of root: MainTabController) -> ChatViewController? {
        root.chatOnShow
    }

    /// In a window with no transition running (the rule of `M2Wiring.whenChatSettles`).
    private func settled(_ chat: ChatViewController) -> Bool {
        chat.viewIfLoaded?.window != nil && chat.navigationController?.transitionCoordinator == nil
    }

    var takeInProgress: (key: String?, active: Bool) {
        let controller = MemoController.shared
        guard controller.state.phase != .idle else { return (nil, false) }
        let live = controller.target?.session as? LiveChatSession
        return (live.flatMap { $0.menus.isBotChat ? VoiceBotCatalog.key(profile: $0.profile) : nil }, true)
    }

    func now() -> Double { Date().timeIntervalSince1970 * 1000 }

    func sleep(ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    // MARK: Alerts

    func show(_ notice: IntentsNoticeContent) { IntentsNotice.shared.show(notice) }
    func dismissNotice() { IntentsNotice.shared.dismiss() }
    func isShowing(_ notice: IntentsNoticeContent) -> Bool { IntentsNotice.shared.isShowing(notice) }

    // MARK: The saved older-build note

    func noteFile(_ path: String) -> URL? { LegacyNoteFile.resolve(path) }

    func importNote(_ file: URL) async -> MemoFile? {
        guard let key = MemoAccountStores.shared.key else { return nil }
        let wav = file.pathExtension.lowercased() == "wav"
        let destination = MemoPaths.newRecording(key, ext: wav ? "wav" : "m4a")
        return await Task.detached(priority: .userInitiated) { () -> MemoFile? in
            let files = FileManager.default
            do {
                MemoPaths.ensure(destination.deletingLastPathComponent())
                try files.copyItem(at: file, to: destination)
                let shape = try MemoWaveform.compute(destination)
                return MemoFile(path: destination.path, seconds: (shape.seconds * 100).rounded() / 100, peaks: shape.peaks,
                                mime: wav ? "audio/wav" : "audio/x-m4a")
            } catch {
                try? files.removeItem(at: destination.deletingLastPathComponent())
                return nil
            }
        }.value
    }

    func setDraft(_ memo: MemoFile, scope: String) -> Bool {
        guard let drafts = MemoAccountStores.shared.drafts else { return false }
        drafts.set(memo, for: scope)
        guard drafts.draft(for: scope)?.path == memo.path else { return false }
        MemoAccountStores.shared.shapes?.remember(memo.path, peaks: memo.peaks, seconds: memo.seconds)
        return true
    }

    func discard(_ memo: MemoFile) { MemoPaths.remove(memo.path) }

    func delete(_ file: URL) { LegacyNoteFile.remove(file) }

    // MARK: Quick actions

    func sessionProfile(_ stored: String) -> String? { model?.sessions.first { $0.id == stored }?.profile }

    func openSessionChat(stored: String, profile: String) async -> IntentsSessionOpen {
        guard let model, let root else { return .failed }
        // A sheet holding unsaved edits asks first (UX study #263), before the 3 s below start; kept, nothing opens.
        // Not when the chat is already on top: `openNotifiedChat` only reads its tail then.
        let onTop = topChat(of: root).flatMap { $0.session as? LiveChatSession }
            .map { $0.storedSessionId == stored || $0.resolvedStoredId == stored } ?? false
        if !onTop, !(await root.clearForRoute()) { return .kept }
        model.openNotifiedChat(stored: stored, profile: profile)
        var screen: ChatViewController?
        for _ in 0..<30 where screen == nil {
            try? await Task.sleep(for: .milliseconds(100))
            if let top = topChat(of: root), settled(top), let live = top.session as? LiveChatSession,
               live.storedSessionId == stored || live.resolvedStoredId == stored { screen = top }
        }
        guard let screen, let live = screen.session as? LiveChatSession else { return .failed }
        // The Home Screen item may be older than the chat: when the gateway answers (quickly) that it no longer has it,
        // the screen, painted from the cache or empty, is closed again and the owner is told. A slow gateway is not
        // waited for: the chat stays, as when its row is tapped.
        for _ in 0..<40 where !live.openFinished && !live.chatGone { try? await Task.sleep(for: .milliseconds(100)) }
        guard live.chatGone else { return .opened }
        if let navigation = screen.navigationController, navigation.topViewController === screen {
            navigation.popViewController(animated: false)
        }
        AppLog.note("intents", "the chat is gone")
        return .gone
    }

    func openRoom(_ key: String) async -> IntentsSessionOpen {
        guard let model, let root, model.groupStore?.room(key) != nil else { return .gone }
        guard await root.clearForRoute() else { return .kept }
        root.select(.bots)
        root.botsViewController.navigationController?.popToRootViewController(animated: false)
        model.openRoom(key, from: nil)
        return .opened
    }

    func openSearch() {
        guard let root else { return }
        let open = { [weak self] in
            guard let self, let root = self.root else { return }
            root.select(.sessions)
            let sessions = root.sessionsViewController
            sessions.navigationController?.popToRootViewController(animated: false)
            sessions.search("")                              // the field open and empty (§9.5)
            self.focusSearch(of: sessions, tries: 100)
        }
        // An alert that is up remembers the keyboard as it was (none) and puts that back once it has gone. A field
        // focused before then is left open with no keyboard (seen with another stream's alert up when the Home
        // Screen item arrived), so the search opens only when the alert has finished going.
        if root.presentedViewController != nil { root.dismiss(animated: false, completion: open) } else { open() }
    }

    /// The keyboard for the search field. A quick action arrives while the app is still coming forward, so this
    /// looks every 0.1 s, for 10 s at most, until the scene is active and the field has the keyboard. It stops as
    /// soon as the owner went elsewhere: another tab, another screen on top, or the search closed.
    private func focusSearch(of sessions: SessionsViewController, tries: Int) {
        guard tries > 0, let root, root.shownTab == .sessions, sessions.navigationController?.topViewController === sessions,
              let search = sessions.navigationItem.searchController,
              root.presentedViewController == nil || root.presentedViewController === search else { return }
        if !search.isActive, tries < 95 { return }          // closed again (the first half second is its opening)
        let field = search.searchBar.searchTextField
        if field.isFirstResponder { return }
        if field.window?.windowScene?.activationState == .foregroundActive {
            field.becomeFirstResponder()
            if field.isFirstResponder { return }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak sessions] in
            guard let self, let sessions else { return }
            self.focusSearch(of: sessions, tries: tries - 1)
        }
    }
}

/// A chat screen, as the runtime may use it.
@MainActor final class LiveIntentsChat: IntentsChat {
    private weak var screen: ChatViewController?

    init(screen: ChatViewController) { self.screen = screen }

    /// The profile when the screen shows a bot's own chat.
    static func botProfile(_ screen: ChatViewController) -> String? {
        guard let live = screen.session as? LiveChatSession, live.menus.isBotChat else { return nil }
        return live.profile
    }

    var botKey: String? { screen.flatMap(Self.botProfile).map(VoiceBotCatalog.key(profile:)) }

    var isTop: Bool {
        guard let screen, screen.viewIfLoaded?.window != nil, let navigation = screen.navigationController,
              navigation.topViewController === screen else { return false }
        return MainTabController.current?.selectedViewController === navigation
    }

    var composerReady: Bool {
        guard let screen, screen.navigationController?.transitionCoordinator == nil else { return false }
        return screen.voice.isAvailable && screen.voice.canSendMemo
    }

    var scope: String { screen?.voice.scope ?? "" }

    func beginHandsFreeMemo() { screen?.beginMemo(handsFree: true) }
}
