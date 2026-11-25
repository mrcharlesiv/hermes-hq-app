import UIKit

/// [threads] A bot chat screen's link to the account's threads (docs/spec/3x-threads.md §4).
@MainActor
final class BotChatThreads: ChatThreadsHost {
    private weak var model: AppModel?
    private weak var chat: LiveChatSession?
    var onChange: (() -> Void)?

    init(model: AppModel, chat: LiveChatSession) {
        self.model = model
        self.chat = chat
        model.threadStore.observe(profile: chat.profile, owner: self) { [weak self] in
            self?.onChange?()
            self?.model?.threadPanelRenamed()
        }
    }

    /// Every id this parent chat goes by: the one it was opened with, the one the gateway resolved it to (its newest
    /// part after a compression), and (for bot chats only) the roster's canonical session id.
    private var parentIds: Set<String> {
        guard let chat, let model else { return [] }
        return model.threadStore.parentIds(for: chat)
    }

    func threads() -> [ChatThread] {
        guard let chat, let model else { return [] }
        return model.threadStore.threads(profile: chat.profile, parentIds: parentIds, isBotChat: chat.menus.isBotChat)
    }

    func start(text: String, under anchor: ChatMessage?) -> String? {
        start(text: text, memo: nil, under: anchor)
    }

    func start(text: String, memo: MemoFile?, under anchor: ChatMessage?) -> String? {
        guard let chat, let model, let bot = model.botStore?.bot(named: chat.profile) else { return nil }
        return model.threadStore.start(text: text, memo: memo, in: chat, bot: bot, anchor: anchor)
    }

    func open(_ key: String, from screen: ChatViewController) {
        model?.openThread(key, from: screen)
    }

    func markSeen(_ keys: [String]) {
        model?.threadStore.markSeen(keys)
    }

    func busyRoutingBanner() -> ThreadBusyBanner? {
        guard let chat, let model else { return nil }
        return model.threadStore.busyBanner(for: chat, botName: chat.botName)
    }

    func optOutBusyRouting() {
        guard let chat else { return }
        model?.threadStore.optOutBusyRouting(for: chat)
    }

    var tint: ThreadTint {
        guard let chat else { return .label2 }
        let color = Head.resolve(chat.head, profile: chat.profile).color
        // Ink and paper faces are drawn black or white (as the page asks), not in their accent (`Bot.chatsTint`).
        if color == .ink { return .label }
        if color == .paper { return .label2 }
        let rgb = HeadTones.accent(color)
        return .accent(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

extension AppModel {
    /// Opens a thread's own chat from the bot chat showing it. On the Mac it fills the pane beside the chat (where
    /// Info, Steps, Files and Helpers live), so the main chat stays in view; where that pane has no room, and on the
    /// iPhone and iPad, it is pushed over the chat and Back returns to it.
    func openThread(_ key: String, from screen: ChatViewController) {
        guard let model = threadStore.chatModel(for: key) else {
            screen.showNotice("This thread is still starting. Try again in a moment.")
            return
        }
        let next = makeChatScreen(model)
        #if targetEnvironment(macCatalyst)
        if let inspector = MacInspector.beside(screen), let chat = next as? ChatViewController {
            // The same thread again: it is already there.
            if threadPanel?.key == key, inspector.shownThread != nil, inspector.isVisible { return }
            inspector.onThreadClosed = { [weak self] in
                // The pane's chat is gone with its screen (`chatLeft` gives the focus back to the bot chat).
                if self?.focusedChat == nil { self?.threadPanel = nil }
            }
            inspector.showThread(chat, name: threadTitle(key))
            if inspector.isVisible {
                if let parent = screen.session as? LiveChatSession { threadPanel = (key, WeakBox(parent), WeakBox(inspector)) }
                return
            }
            inspector.closeThread()     // a window too narrow for the pane: over the chat instead
        }
        #endif
        guard let navigation = screen.navigationController else { return }
        next.hidesBottomBarWhenPushed = true
        next.navigationItem.largeTitleDisplayMode = .never
        ChatViewController.push(next, on: navigation) {}
    }

    /// "Thread", or the thread's own short title once it has one.
    func threadTitle(_ key: String) -> String {
        threadStore.name(for: key) ?? ThreadRules.defaultTitle
    }

    /// A thread got its title: the Mac's pane shows it.
    func threadPanelRenamed() {
        #if targetEnvironment(macCatalyst)
        guard let panel = threadPanel, let inspector = panel.pane.value as? MacInspector else { return }
        inspector.renameThread(threadTitle(panel.key))
        #endif
    }
}
