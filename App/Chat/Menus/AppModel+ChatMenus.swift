import UIKit

// MENUS (parity 240 §8): the app's side of the chat's ⋯ list actions. A bot's own chat pins its bot (the Bots list's pin,
// as its row and Bot Info do) and its dot is the Bots row's (device-local); another chat writes its session row
// (`PATCH /api/sessions/<id>` {pinned|unread}) and the Sessions list follows at once.

extension AppModel: ChatMenuHosting {
    private func isBotChat(_ chat: any ChatSessionModel) -> Bool { (chat as? LiveChatSession)?.isBotChat ?? false }

    private func storedId(_ chat: any ChatSessionModel) -> String? { (chat as? ChatSessionMoreActions)?.actionsStoredId }

    /// Any chat with a bot the Bots list knows (as the header opens it in a bot's own chat).
    func botInfo(for chat: any ChatSessionModel, over screen: UIViewController) -> (name: String, open: () -> Void)? {
        guard botEditing != nil, let bot = botStore?.bot(named: chat.profile) else { return nil }
        return (bot.name, { [weak self, weak screen] in
            guard let self, let screen, screen.presentedViewController == nil else { return }
            BotInfoSheet.present(bot: self.botStore?.bot(named: bot.id) ?? bot, from: screen, services: self)
        })
    }

    /// [context-window] The chat's bot's Context Window, a sheet over the chat (the model panel's Context fact).
    func contextWindow(for chat: any ChatSessionModel, over screen: UIViewController) -> (() -> Void)? {
        guard let bot = botStore?.bot(named: chat.profile), BotModelPages.available(self) else { return nil }
        return { [weak self, weak screen] in
            guard let self, let screen,
                  let sheet = BotModelPages.contextWindowSheet(self.botStore?.bot(named: bot.id) ?? bot, services: self) else { return }
            MenusSheet.top(screen)?.present(sheet, animated: true)
        }
    }

    func menuState(for chat: any ChatSessionModel) -> ChatMenuState {
        var state = ChatMenuState()
        if isBotChat(chat) {
            if let bot = botStore?.bot(named: chat.profile) {
                state.pinned = bot.pinned
                state.unread = bot.unread
            }
        } else if let id = storedId(chat), let row = sessionStore?.row(for: id) {
            state.pinned = row.pinned == true
            state.unread = row.unread == true
            state.archived = row.archived == true
        }
        if let id = storedId(chat) { state.owner = sessionStore?.row(for: id)?.userId }
        return state
    }

    func setPinned(_ pinned: Bool, chat: any ChatSessionModel) async throws {
        if isBotChat(chat) {
            guard let botStore, let bot = botStore.bot(named: chat.profile) else { throw MenusError("This bot isn’t in the list yet.") }
            try await botStore.setPinned(name: bot.id, display: bot.name, pinned)
            return
        }
        guard let actions = chat as? ChatSessionMoreActions, let id = actions.actionsStoredId else { throw MenusError.loading }
        let before = sessionStore?.row(for: id)?.pinned
        sessionStore?.updateRow(id: id, profile: chat.profile) { $0.pinned = pinned }
        do {
            try await actions.setPinned(pinned)
        } catch let error as HTTPError where SessionWrite.isMaintenanceRefusal(error) {
            sessionStore?.keepPinOnDevice(pinned, id: id, profile: chat.profile)   // Hermes before 0.22.3 (SessionWrite)
        } catch {
            sessionStore?.updateRow(id: id, profile: chat.profile) { $0.pinned = before }
            throw error
        }
    }

    func setUnread(_ unread: Bool, chat: any ChatSessionModel) async throws {
        if isBotChat(chat) {
            guard let botStore, let bot = botStore.bot(named: chat.profile) else { return }
            if unread { botStore.markUnread(bot) } else { botStore.markRead(bot) }
            return
        }
        guard let actions = chat as? ChatSessionMoreActions, let id = actions.actionsStoredId else { throw MenusError.loading }
        let before = sessionStore?.row(for: id)?.unread
        sessionStore?.updateRow(id: id, profile: chat.profile, forgetsRead: false) { $0.unread = unread }      // [sessions-m9] §11.2
        do {
            try await actions.setUnread(unread)
        } catch let error as HTTPError where SessionWrite.isMaintenanceRefusal(error) {
            sessionStore?.keepUnreadOnDevice(unread, id: id, profile: chat.profile)   // Hermes before 0.22.3 (SessionWrite)
        } catch {
            sessionStore?.updateRow(id: id, profile: chat.profile, forgetsRead: false) { $0.unread = before }      // [sessions-m9] §11.2
            throw error
        }
    }

    func chatArchived(_ chat: any ChatSessionModel) {
        if let id = storedId(chat) { sessionStore?.forget(id: id, profile: chat.profile) }
        refreshSessions()
    }

    func chatUnarchived(_ chat: any ChatSessionModel) {
        refreshSessions()
    }

    func chatDeleted(_ chat: any ChatSessionModel) {
        if let id = storedId(chat) { sessionStore?.forget(id: id, profile: chat.profile) }
        refreshSessions()
    }

    func openBranch(_ result: ChatBranchResult, of chat: any ChatSessionModel, replacing screen: UIViewController) {
        let parent = chat.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = SessionSummary(id: result.storedId, profile: chat.profile, title: parent.isEmpty ? "Branch" : "Branch of \(parent)",
                                     preview: nil, lastActive: Date(), source: nil, unread: false, isRunning: false)
        // The chat opens as any listed chat does (its resume binds the runtime the branch already started).
        let model = self.chat(for: summary)
        let next = makeChatScreen(model)
        next.hidesBottomBarWhenPushed = true
        next.navigationItem.largeTitleDisplayMode = .never
        guard let navigation = screen.navigationController else { return }
        var stack = navigation.viewControllers
        if let index = stack.firstIndex(where: { $0 === screen }) { stack.remove(at: index) }
        stack.append(next)
        navigation.setViewControllers(stack, animated: true)
        (next as? ChatViewController)?.showNotice("Branched into a new chat.")
        refreshSessions()
    }

    /// `/new` (docs/spec/3x-composer.md §8.2): the chat Bots › New Chat starts (`newChat(for:)`, made on the gateway as
    /// it opens), put where this one was, as /resume and Branch put theirs (Back returns to the list it came from).
    func openNewChat(like chat: any ChatSessionModel, draft: String, replacing screen: UIViewController) -> Bool {
        guard let bot = botStore?.bot(named: chat.profile) ?? bots.first(where: { $0.id == chat.profile }),
              let navigation = screen.navigationController else {
            AppLog.note("chat", "/new: no bot or no stack for \(AppLog.tag(chat.profile)); nothing opened")
            return false
        }
        Haptics.play(.soft)
        let next = makeChatScreen(newChat(for: bot))
        next.hidesBottomBarWhenPushed = true
        next.navigationItem.largeTitleDisplayMode = .never
        var stack = navigation.viewControllers
        if let index = stack.firstIndex(where: { $0 === screen }) { stack.remove(at: index) }
        stack.append(next)
        navigation.setViewControllers(stack, animated: true)
        let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty, let chatScreen = next as? ChatViewController {
            chatScreen.loadViewIfNeeded()
            chatScreen.composer.text = words
        }
        AppLog.trace("chat", "/new: a new chat with \(AppLog.tag(bot.id)) opened in place\(words.isEmpty ? "" : ", \(words.count) chars in its field")")
        return true
    }
}
