import UIKit

/// What the chat's menus ask of the app (AppModel+ChatMenus.swift): the list state behind Pin and Mark as Read/Unread,
/// the writes that keep the Bots and Sessions lists in step, and the navigation after Branch, Archive and Delete.
@MainActor protocol ChatMenuHosting: AnyObject {
    /// Pinned / unread / archived as the lists know them (a bot's own chat: its bot's pin and dot).
    func menuState(for chat: any ChatSessionModel) -> ChatMenuState
    func setPinned(_ pinned: Bool, chat: any ChatSessionModel) async throws
    func setUnread(_ unread: Bool, chat: any ChatSessionModel) async throws
    /// After the gateway took the write: the Sessions list drops the row.
    func chatArchived(_ chat: any ChatSessionModel)
    /// After Undo on the "Archived" pill: the Sessions list takes the row back.
    func chatUnarchived(_ chat: any ChatSessionModel)
    func chatDeleted(_ chat: any ChatSessionModel)
    /// Opens a chat Branch made, in place of `screen` (Back returns to the list it came from).
    func openBranch(_ result: ChatBranchResult, of chat: any ChatSessionModel, replacing screen: UIViewController)
    /// `/new`: a new chat with `chat`'s bot (as Bots › New Chat starts one), in place of `screen`, `draft` in its field.
    /// False when the bot isn't known (nothing opened).
    func openNewChat(like chat: any ChatSessionModel, draft: String, replacing screen: UIViewController) -> Bool
    /// [model-panel] `chat`'s bot by name and a way to open its Bot Info (its default, fallback and auxiliary models)
    /// over `screen`; nil when there is none to open.
    func botInfo(for chat: any ChatSessionModel, over screen: UIViewController) -> (name: String, open: () -> Void)?
    /// [context-window] A way to open `chat`'s bot's Context Window over `screen`; nil where it can't be changed.
    func contextWindow(for chat: any ChatSessionModel, over screen: UIViewController) -> (() -> Void)?
}

extension ChatMenuHosting {
    func botInfo(for chat: any ChatSessionModel, over screen: UIViewController) -> (name: String, open: () -> Void)? { nil }
    func contextWindow(for chat: any ChatSessionModel, over screen: UIViewController) -> (() -> Void)? { nil }
}

extension ChatMenus {
    // MARK: The ⋯'s state

    func menuState() -> ChatMenuState {
        var state = host?.menuState(for: session) ?? ChatMenuState()
        state.botChat = (session as? ChatSessionActions)?.isBotChat ?? true
        state.taskChat = isTaskChat
        state.empty = !session.messages.contains { ($0.role == .user || $0.role == .assistant) && !ChatTranscript.blocks($0).isEmpty }
        state.offline = offline
        return state
    }

    // MARK: List actions (Pin, unread, Files, Changes, Branch, Export, Archive, Delete)

    /// ⌘⌫ (File › Archive Chat) acts when the ⋯ menu would offer Archive (or Unarchive): never in a bot's own chat, nor offline.
    var canArchive: Bool {
        session is ChatSessionMoreActions && ChatMenuModel.danger(menuState()).contains { $0.id == .archive && !$0.disabled }
    }

    /// [mac] ⌘⌫ on the Mac (File › Delete Chat…) acts when the ⋯ menu would offer Delete.
    var canDelete: Bool {
        session is ChatSessionMoreActions && ChatMenuModel.danger(menuState()).contains { $0.id == .delete && !$0.disabled }
    }

    /// [mac] Stress test 2026-10-28 #33: the ⋯ row the menu bar's Chat menu stands for, when the ⋯ offers it now (and
    /// not dimmed); its title follows the state (Pin / Unpin, Mark as Read / Unread).
    func menuBarRow(_ id: ChatMenuItemID) -> ChatMenuRow? {
        let state = menuState()
        let row = ChatMenuModel.all(state).first { $0.id == id }
        switch id {
        case .info, .find, .share: break
        case .rename: guard session is ChatSessionActions else { return nil }
        default: guard session is ChatSessionMoreActions else { return nil }
        }
        return row?.disabled == false ? row : nil
    }

    func performListAction(_ id: ChatMenuItemID) {
        guard let actions = session as? ChatSessionMoreActions else { return }
        let state = menuState()
        switch id {
        case .pin:
            let next = !state.pinned
            write(failed: next ? "Couldn’t Pin Chat" : "Couldn’t Unpin Chat", retry: { [weak self] in self?.performListAction(.pin) }) {
                [weak self] in
                guard let self, let host = self.host else { try await actions.setPinned(next); return }
                try await host.setPinned(next, chat: self.session)
            }
        case .unread:
            let next = !state.unread
            write(failed: next ? "Couldn’t Mark as Unread" : "Couldn’t Mark as Read", retry: { [weak self] in self?.performListAction(.unread) }) {
                [weak self] in
                guard let self, let host = self.host else { try await actions.setUnread(next); return }
                try await host.setUnread(next, chat: self.session)
            }
        case .files: presentWorkspace(.files)
        case .changes: presentWorkspace(.changes)
        case .branch: branch(fromMessage: nil)
        case .export: exportChat(actions)
        case .archive: archive(actions, archived: !state.archived)
        case .delete: confirmDelete(actions)
        default: break
        }
    }

    /// A write with its failure alert (the reason, Show Details, Try Again).
    private func write(failed title: String, retry: @escaping () -> Void, _ body: @escaping () async throws -> Void) {
        Task { [weak self] in
            do {
                try await body()
            } catch {
                Haptics.play(.error)
                self?.failure(title: title, reason: SessionActionText.plain(MenusError.text(error), owner: self?.menuState().owner), retry: retry)
            }
        }
    }

    /// [mac-layout] The inspector's Files: the chat's folder, unwrapped (nil: the chat has none).
    func makeFilesPage() -> UIViewController? {
        guard let actions = session as? ChatSessionMoreActions, actions.workingDirectory?.isEmpty == false else { return nil }
        return WorkspacePage(kind: .files, workspace: actions.workspace, directory: actions.workingDirectory,
                             media: (session as? ChatAttachmentSending)?.mediaContext, panel: true)
    }

    private func presentWorkspace(_ kind: WorkspacePage.Kind, highlight: String? = nil) {
        guard let actions = session as? ChatSessionMoreActions, let screen else { return }
        #if targetEnvironment(macCatalyst)
        if kind == .files, highlight == nil, let inspector = MacInspector.beside(screen) { inspector.show(.files); return }   // [mac-layout]
        #endif
        screen.stowKeys()
        let page = WorkspacePage.make(kind, workspace: actions.workspace, directory: actions.workingDirectory,
                                      media: (session as? ChatAttachmentSending)?.mediaContext, highlight: highlight)
        MenusSheet.top(screen)?.present(page, animated: true)
    }

    /// [transcript] The files card's "Review" and a file row's held "Review in Changes" (§12, n20 F10): the same
    /// Changes page the ⋯ menu's own "Changes" opens, with `path` selected once it has loaded.
    func presentChanges(highlighting path: String?) {
        presentWorkspace(.changes, highlight: path)
    }

    /// Export Chat: every stored row, then the share sheet with the file (Save to Files, AirDrop, another Hermes).
    private func exportChat(_ actions: ChatSessionMoreActions) {
        guard !actionInFlight, let screen else { return }
        actionInFlight = true
        let began = ContinuousClock.now
        screen.showNotice("Preparing export…", duration: nil, spinner: true)
        Task { [weak self] in
            do {
                let (data, name) = try await actions.exportJSON()
                guard let self else { return }
                self.actionInFlight = false
                self.screen?.hideNotice()
                let folder = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appending(path: name)
                try data.write(to: url, options: .completeFileProtection)
                #if DEBUG
                DebugHooks.recordText(String(decoding: data, as: UTF8.self), as: "export.json")
                #endif
                AppLog.trace("chatui", "export chat \(AppLog.tag(self.logScope)) succeeded (\(AppLog.ms(since: began)) ms): \(data.count) bytes")
                guard let screen = self.screen else { return }
                #if targetEnvironment(macCatalyst)
                // [mac] Stress test 2026-10-28 #79: a Mac saves a file with a save panel; the share sheet had no plain
                // Save and put the file nowhere a Mac user looks.
                ExportSaver.present(url, folder: folder, from: screen)
                #else
                let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                share.popoverPresentationController?.sourceItem = screen.moreBarItem
                share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: folder) }
                MenusSheet.top(screen)?.present(share, animated: true)
                #endif
            } catch {
                guard let self else { return }
                self.actionInFlight = false
                self.screen?.hideNotice()
                Haptics.play(.error)
                AppLog.note("chatui", "export chat \(AppLog.tag(self.logScope)) failed (\(AppLog.ms(since: began)) ms)")
                self.failure(title: "Couldn’t Export Chat", reason: MenusError.text(error)) { [weak self] in self?.performListAction(.export) }
            }
        }
    }

    /// Archive: "Archiving…" while the gateway answers; then the chat leaves the lists, the screen goes back to them and
    /// "Archived “title” · Undo" shows there with the way back under it, as a row's Archive does (SessionsOrganizer.archive).
    private func archive(_ actions: ChatSessionMoreActions, archived: Bool) {
        guard !actionInFlight else { return }
        actionInFlight = true
        let began = ContinuousClock.now
        screen?.showNotice(archived ? "Archiving…" : "Unarchiving…", duration: nil, spinner: true)
        Task { [weak self] in
            do {
                try await actions.setArchived(archived)
                guard let self else { return }
                self.actionInFlight = false
                self.screen?.hideNotice()
                Haptics.play(.success)
                AppLog.trace("chatui", "\(archived ? "archive" : "unarchive") chat \(AppLog.tag(self.logScope)) succeeded (\(AppLog.ms(since: began)) ms)")
                if archived {
                    // The list the screen goes back to hosts the pill (UndoPill puts it over the tab bar's controller).
                    let list = self.screen?.tabBarController ?? self.screen?.navigationController
                    let chat = self.session, host = self.host
                    let title = chat.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    host?.chatArchived(chat)
                    self.leave()
                    UndoPill.show(label: "Archived “\(title.isEmpty ? "Untitled Chat" : title)”", wayBack: SessionActionText.archivedWayBack,
                                  showsWayBack: true, in: list) { [weak list, weak host] in
                        Task { [weak list, weak host] in
                            do {
                                try await actions.setArchived(false)
                                host?.chatUnarchived(chat)
                            } catch {
                                FailureAlert.present(title: "Couldn’t Unarchive Chat", reason: MenusError.text(error), from: list)
                            }
                        }
                    }
                }
            } catch {
                guard let self else { return }
                self.actionInFlight = false
                self.screen?.hideNotice()
                Haptics.play(.error)
                AppLog.note("chatui", "\(archived ? "archive" : "unarchive") chat \(AppLog.tag(self.logScope)) failed (\(AppLog.ms(since: began)) ms)")
                self.failure(title: archived ? "Couldn’t Archive Chat" : "Couldn’t Unarchive Chat", reason: SessionActionText.plain(MenusError.text(error), owner: self.menuState().owner)) { [weak self] in
                    self?.archive(actions, archived: archived)
                }
            }
        }
    }

    /// Delete Chat: an action sheet first (S:phone-chat-menu.tsx `confirmDelete`).
    private func confirmDelete(_ actions: ChatSessionMoreActions) {
        guard let screen, !actionInFlight else { return }
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sheet = UIAlertController(title: "Delete “\(title.isEmpty ? "Untitled Chat" : title)”?",
                                      message: "This chat and its messages are deleted from \(HostWord.phrase). This can’t be undone.",
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Delete Chat", style: .destructive) { [weak self] _ in self?.delete(actions) })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceItem = screen.moreBarItem
        sheet.view.accessibilityIdentifier = "chat.delete.confirm"
        MenusSheet.top(screen)?.present(sheet, animated: true)
    }

    private func delete(_ actions: ChatSessionMoreActions) {
        guard !actionInFlight else { return }
        actionInFlight = true
        let began = ContinuousClock.now
        screen?.showNotice("Deleting…", duration: nil, spinner: true)
        Task { [weak self] in
            do {
                try await actions.deleteChat()
                guard let self else { return }
                self.actionInFlight = false
                self.screen?.hideNotice()
                Haptics.play(.success)
                AppLog.trace("chatui", "delete chat \(AppLog.tag(self.logScope)) succeeded (\(AppLog.ms(since: began)) ms)")
                self.host?.chatDeleted(self.session)
                self.leave()
            } catch {
                guard let self else { return }
                self.actionInFlight = false
                self.screen?.hideNotice()
                Haptics.play(.error)
                AppLog.note("chatui", "delete chat \(AppLog.tag(self.logScope)) failed (\(AppLog.ms(since: began)) ms)")
                self.failure(title: "Couldn’t Delete Chat", reason: SessionActionText.plain(MenusError.text(error), owner: self.menuState().owner)) { [weak self] in self?.delete(actions) }
            }
        }
    }

    /// Back to the list the chat was opened from.
    private func leave() {
        guard let screen, let navigation = screen.navigationController else { return }
        // [m9/ipad] Two panes: the right pane goes back to its placeholder.
        if let root = MainTabController.current, root.split?.isDouble == true, navigation.viewControllers.first === screen {
            root.leave(screen, animated: true)
        } else if navigation.topViewController === screen {
            navigation.popViewController(animated: true)
        } else {
            navigation.viewControllers.removeAll { $0 === screen }
        }
    }

    // MARK: Branch

    /// A new chat from the whole chat (nil) or from the start through a reply; it opens in this one's place.
    func branch(fromMessage messageId: String?) {
        guard let actions = session as? ChatSessionMoreActions, !actionInFlight, let screen else { return }
        actionInFlight = true
        let began = ContinuousClock.now
        screen.showNotice("Branching…", duration: nil, spinner: true)
        Task { [weak self] in
            do {
                let result = try await actions.branch(fromMessage: messageId)
                guard let self else { return }
                self.actionInFlight = false
                self.screen?.hideNotice()
                Haptics.play(.success)
                AppLog.trace("chatui", "branch chat \(AppLog.tag(self.logScope)) succeeded (\(AppLog.ms(since: began)) ms)")
                if let screen = self.screen { self.host?.openBranch(result, of: self.session, replacing: screen) }
            } catch {
                guard let self else { return }
                self.actionInFlight = false
                self.screen?.hideNotice()
                Haptics.play(.error)
                AppLog.note("chatui", "branch chat \(AppLog.tag(self.logScope)) failed (\(AppLog.ms(since: began)) ms)")
                self.failure(title: "Couldn’t Branch Chat", reason: MenusError.text(error)) { [weak self] in self?.branch(fromMessage: messageId) }
            }
        }
    }

    // MARK: Message actions (Edit, Regenerate, Branch, Rewind to Here, Send Again, Delete)

    func performMessageAction(_ id: MessageMenuItemID, messageId: String) {
        guard let actions = session as? ChatSessionMoreActions else { return }
        AppLog.trace("chatui", "message action chosen \(AppLog.tag(logScope)): \(id.rawValue)")
        switch id {
        case .edit: beginEdit(messageId)
        case .regenerate: regenerateLatest()
        case .branch: branch(fromMessage: messageId)
        case .rewind: confirmRewind(messageId)
        case .retry:
            Haptics.play(.selection)
            actions.sendAgain(messageId)
        case .delete:
            Haptics.play(.warning)
            actions.deleteUndelivered(messageId)
        default: break
        }
    }

    /// The latest reply's Regenerate (its hold menu and its action row): the prompt runs again in its place.
    func regenerateLatest() {
        guard let actions = session as? ChatSessionMoreActions else { return }
        guard !session.isRunning else { screen?.showNotice("Wait for the reply to finish."); return }
        guard !offline else { screen?.showNotice("Offline"); return }
        screen?.scrollToBottom(animated: true)
        let done = actions.regenerate { [weak self] reason in
            Haptics.play(.error)
            self?.failure(title: "Couldn’t Regenerate", reason: reason, retry: { [weak self] in self?.regenerateLatest() })
        }
        if !done { screen?.showNotice("This reply can’t be regenerated.") }
    }

    /// The action row's Regenerate: a confirm first, as Rewind to Here has (the glyph sits a thumb away from Copy and Read
    /// Aloud, and the reply it replaces can't be brought back). The hold menu's Regenerate stays one step.
    func confirmRegenerate() {
        guard let screen, session is ChatSessionMoreActions else { return }
        guard !session.isRunning else { screen.showNotice("Wait for the reply to finish."); return }
        guard !offline else { screen.showNotice("Offline"); return }
        let alert = UIAlertController(title: "Replace This Reply?",
                                      message: "The prompt runs again, and a new reply takes this one’s place.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Regenerate", style: .default) { [weak self] _ in self?.regenerateLatest() })
        MenusSheet.top(screen)?.present(alert, animated: true)
    }

    /// Whether the latest reply's action row offers Regenerate and More (a live chat).
    var offersReplyActions: Bool { session is ChatSessionMoreActions }

    /// The action row's More: Share, Select Text, Branch in New Chat.
    func replyMoreMenu(rowId: String, source: UIView) -> UIMenu? {
        let messageId = String(rowId.prefix { $0 != "|" })
        guard let message = session.messages.last(where: { $0.id == messageId }) else { return nil }
        let markdown = Self.copyText(message)
        let rows = MessageMenuModel.replyMore(running: session.isRunning, offline: offline)
        return UIMenu(children: rows.map { row in
            let action = UIAction(title: row.title, subtitle: row.subtitle, image: UIImage(systemName: row.symbol),
                                  attributes: row.disabled ? .disabled : []) { [weak self, weak source] _ in
                guard let self else { return }
                switch row.id {
                case .share: self.shareMessage(markdown, from: source)
                case .selectText:
                    MenusSheet.top(self.screen)?.present(SelectTextViewController.make(text: ChatTranscript.readableText(markdown)), animated: true)
                case .branch: self.branch(fromMessage: messageId)
                default: break
                }
            }
            action.accessibilityIdentifier = "reply-more.\(row.id == .selectText ? "select" : row.id.rawValue)"
            return action
        })
    }

    /// Rewind to Here: a confirm first (S:ui-chat/message-actions.ts `REWIND`).
    private func confirmRewind(_ messageId: String) {
        guard let screen else { return }
        let alert = UIAlertController(title: "Rewind to Here?",
                                      message: "Everything after this message is removed from the chat, and it runs again from here.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rewind and Rerun", style: .destructive) { [weak self] _ in
            guard let self, let actions = self.session as? ChatSessionMoreActions else { return }
            self.screen?.scrollToBottom(animated: true)
            let done = actions.rewind(to: messageId) { [weak self] reason in
                Haptics.play(.error)
                self?.failure(title: "Couldn’t Rewind", reason: reason, retry: nil)
            }
            if !done { self.screen?.showNotice("This message can’t be rewound to.") }
        })
        MenusSheet.top(screen)?.present(alert, animated: true)
    }

    // MARK: Edit

    /// Edit: your message's words in the composer with an "Editing Message" banner; the next send goes out as the edit
    /// (the chat is truncated before the message and it runs again), ✕ puts the draft back as it was. An earlier
    /// message says so in the banner, and its send asks first, as Rewind to Here does (editing the latest loses nothing).
    private func beginEdit(_ messageId: String) {
        guard let screen, let message = session.messages.first(where: { $0.id == messageId }) else { return }
        screen.cancelQueueEdit()  // [composer] a queued message's edit gives way (its draft comes back first)
        screen.replyQuote = nil   // Edit takes the banner from a reply
        let original = ChatTranscript.messageText(message)
        let draft = screen.composer.text
        let banner = ComposerEditBanner(removesLater: hasLaterMessages(after: messageId))
        banner.onCancel = { [weak self, weak screen] in
            guard let screen else { return }
            self?.endEdit(on: screen)
            screen.composer.text = draft
        }
        screen.composer.editBanner = banner
        screen.composer.text = original
        screen.sendOverride = { [weak self, weak screen] text in
            guard let self, let screen, self.session is ChatSessionMoreActions else { return false }
            guard self.hasLaterMessages(after: messageId) else {
                self.sendEdit(messageId, text: text, draft: draft, on: screen)
                return true
            }
            let alert = UIAlertController(title: "Send Edit?",
                                          message: "Everything after this message is removed from the chat, and it runs again from your edit.",
                                          preferredStyle: .alert)
            // Cancel keeps editing: the words go back into the field and the banner stays.
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak screen] _ in
                if let screen, screen.composer.text.isEmpty { screen.composer.text = text }
            })
            alert.addAction(UIAlertAction(title: "Send and Rerun", style: .destructive) { [weak self, weak screen] _ in
                guard let self, let screen else { return }
                self.sendEdit(messageId, text: text, draft: draft, on: screen)
            })
            alert.view.accessibilityIdentifier = "chat.edit.confirm"
            MenusSheet.top(screen)?.present(alert, animated: true)
            return true
        }
        screen.focusComposer()
    }

    /// Whether a later message of yours follows this one: its edit removes those turns too (the message's own reply is
    /// answered again, so editing your latest message loses nothing).
    private func hasLaterMessages(after messageId: String) -> Bool {
        guard let index = session.messages.firstIndex(where: { $0.id == messageId }) else { return false }
        return session.messages[(index + 1)...].contains { $0.role == .user }
    }

    private func sendEdit(_ messageId: String, text: String, draft: String, on screen: ChatViewController) {
        guard let actions = session as? ChatSessionMoreActions else { return }
        endEdit(on: screen)
        if !draft.isEmpty && screen.composer.text.isEmpty { screen.composer.text = draft }
        screen.scrollToBottom(animated: true)
        let done = actions.edit(messageId, to: text) { [weak self, weak screen] reason in
            Haptics.play(.error)
            // An edit that didn't go out comes back into the field as typed (S:touch-user-bubble.tsx B-08).
            if let screen, screen.composer.text.isEmpty { screen.composer.text = text }
            self?.failure(title: "Couldn’t Edit Message", reason: reason, retry: nil)
        }
        if !done {
            screen.composer.text = text
            screen.showNotice("This message can’t be edited anymore.")
        }
    }

    // MARK: Reply

    /// Swipe to Reply (or Reply in a reply's hold menu): "Replying to <bot>" over the composer, and the next send goes out
    /// under a quote of the message's opening lines. Hermes has no reply-to, so the quote is what tells the bot which
    /// message you mean. Your draft stays; ✕ drops the quote. An edit in progress is cancelled first.
    func beginReply(_ messageId: String) {
        guard let screen, let message = session.messages.last(where: { $0.id == messageId }), message.role == .assistant else { return }
        let words = ChatTranscript.readableText(Self.copyText(message))
        guard let quote = Self.replyQuote(words) else { return }
        if screen.sendOverride != nil { (screen.composer.editBanner as? ComposerEditBanner)?.onCancel?() }
        let bot = ((session as? ChatSessionDetails)?.botName ?? session.title).trimmingCharacters(in: .whitespaces)
        let banner = ComposerEditBanner.replying(to: bot.isEmpty ? "Hermes" : bot, excerpt: quote.excerpt)
        banner.onCancel = { [weak screen] in
            screen?.replyQuote = nil
            screen?.composer.editBanner = nil
        }
        screen.composer.editBanner = banner
        screen.replyQuote = quote.markdown
        Haptics.play(.selection)
        screen.focusComposer()
    }

    /// The quote a reply goes out under: the message's first two lines, at most 160 characters, each as a `> ` line;
    /// and the one line the banner shows. Nil when the message has no words.
    static func replyQuote(_ readable: String) -> (markdown: String, excerpt: String)? {
        let lines = readable.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        var kept: [String] = []
        var room = 160
        for line in lines.prefix(2) where room > 0 {
            let cut = line.count > room ? String(line.prefix(room)).trimmingCharacters(in: .whitespaces) + "…" : line
            kept.append(cut)
            room -= line.count
        }
        if lines.count > kept.count, let last = kept.last, !last.hasSuffix("…") { kept[kept.count - 1] = last + " …" }
        return (kept.map { "> " + $0 }.joined(separator: "\n"), kept.joined(separator: " "))
    }

    private func endEdit(on screen: ChatViewController) {
        screen.sendOverride = nil
        screen.composer.editBanner = nil
    }
}

/// Edit's banner over the composer row: a glass capsule, "Editing Message" (with "Later messages will be removed" under
/// it when the message isn't the latest), and ✕ to cancel. At least 44 pt tall, the ✕'s tap target; taller when its
/// words need it at the largest text sizes (`ComposerView.editBannerHeight` measures it).
final class ComposerEditBanner: UIView, ComposerFieldWatching {
    var onCancel: (() -> Void)?
    /// [composer] A queued message's edit (spec 3x-composer §15.5) has Cancel and Save in words instead of ✕.
    var onSave: (() -> Void)?
    private var saveButton: UIButton?
    private let glass: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        view.cornerConfiguration = .capsule()
        return view
    }()
    private var capsule = true

    convenience init(removesLater: Bool = false) {
        self.init(title: "Editing Message", symbol: "pencil", note: removesLater ? "Later messages will be removed" : nil,
                  cancelLabel: "Cancel Editing", identifier: "composer.editing")
    }

    /// [composer] Edit on a queued message (spec 3x-composer §15.5): "Editing Queued Message", Cancel and Save (off
    /// while the field is blank).
    static func editingQueued() -> ComposerEditBanner {
        ComposerEditBanner(title: "Editing Queued Message", symbol: "pencil", note: nil, cancelLabel: "Cancel",
                           identifier: "composer.editingQueued", saves: true)
    }

    /// The composer's words changed: Save is off while they are blank.
    func composerTextChanged(_ text: String) {
        saveButton?.isEnabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Swipe to Reply's banner: "Replying to <bot>" over one line of the message.
    static func replying(to sender: String, excerpt: String) -> ComposerEditBanner {
        ComposerEditBanner(title: "Replying to \(sender)", symbol: "arrowshape.turn.up.left", note: excerpt, noteLines: 1,
                           cancelLabel: "Cancel Reply", identifier: "composer.replying")
    }

    init(title: String, symbol: String, note: String?, noteLines: Int = 0, cancelLabel: String, identifier: String, saves: Bool = false) {
        super.init(frame: .zero)
        accessibilityIdentifier = identifier
        addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)))
        icon.tintColor = ChatPalette.tintText
        let label = UILabel()
        label.text = title
        label.font = .menusFont(.footnote, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = ChatPalette.label
        label.numberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let words = UIStackView(arrangedSubviews: [label])
        words.axis = .vertical
        if let note {
            let line = UILabel()
            line.text = note
            line.font = HQFont.preferred(.footnote)
            line.adjustsFontForContentSizeCategory = true
            line.textColor = ChatPalette.label2
            line.numberOfLines = noteLines
            line.lineBreakMode = .byTruncatingTail
            line.accessibilityIdentifier = "\(identifier).note"
            words.addArrangedSubview(line)
        }
        var config = UIButton.Configuration.plain()
        if saves {
            config.title = cancelLabel
            // One line: a configuration's title may wrap, and the row then squeezed the word to 44 pt, a letter or two
            // a line ("Ca / nc / el", tester 2026-11-08). The strip's own words wrap instead.
            config.titleLineBreakMode = .byClipping
            config.baseForegroundColor = ChatPalette.tintText
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming
                out.font = HQFont.preferred(.footnote)
                return out
            }
        } else {
            config.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium))
            config.baseForegroundColor = ChatPalette.label2
        }
        let cancel = UIButton(configuration: config)
        cancel.accessibilityLabel = cancelLabel
        cancel.accessibilityIdentifier = "\(identifier).cancel"
        cancel.addAction(UIAction { [weak self] _ in
            Haptics.play(.selection)
            self?.onCancel?()
        }, for: .primaryActionTriggered)
        cancel.setContentHuggingPriority(.required, for: .horizontal)
        cancel.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        var buttons: [UIView] = [cancel]
        if saves {
            var saveConfig = UIButton.Configuration.plain()
            saveConfig.title = "Save"
            saveConfig.titleLineBreakMode = .byClipping
            saveConfig.baseForegroundColor = ChatPalette.tintText
            saveConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming
                out.font = .menusFont(.footnote, weight: .semibold)
                return out
            }
            let save = UIButton(configuration: saveConfig)
            save.accessibilityIdentifier = "\(identifier).save"
            save.addAction(UIAction { [weak self] _ in self?.onSave?() }, for: .primaryActionTriggered)
            save.setContentHuggingPriority(.required, for: .horizontal)
            save.setContentCompressionResistancePriority(.required, for: .horizontal)
            save.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            save.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            saveButton = save
            buttons.append(save)
        }
        let row = UIStackView(arrangedSubviews: [icon, words, UIView()] + buttons)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            // The words keep 6 pt from the capsule's edges; the ✕ is a full 44 × 44 target.
            words.topAnchor.constraint(greaterThanOrEqualTo: glass.contentView.topAnchor, constant: 6),
            words.bottomAnchor.constraint(lessThanOrEqualTo: glass.contentView.bottomAnchor, constant: -6),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            cancel.topAnchor.constraint(greaterThanOrEqualTo: glass.contentView.topAnchor),
            cancel.bottomAnchor.constraint(lessThanOrEqualTo: glass.contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A capsule while it is one line; a rounded card once its words wrap, so the corners don't cut into them (as ChatFindBar).
    override func layoutSubviews() {
        super.layoutSubviews()
        let isCapsule = bounds.height <= 48
        if isCapsule != capsule {
            capsule = isCapsule
            glass.cornerConfiguration = isCapsule ? .capsule() : .corners(radius: .fixed(22))
        }
    }
}

#if targetEnvironment(macCatalyst)
/// [mac] Stress test 2026-10-28 #79: Export Chat's save panel. Keeps itself alive until the panel closes, then removes
/// the temporary copy and says where the file went.
private final class ExportSaver: NSObject, UIDocumentPickerDelegate {
    private static var open: [ExportSaver] = []
    private let folder: URL
    private weak var screen: ChatViewController?

    private init(folder: URL, screen: ChatViewController) {
        self.folder = folder
        self.screen = screen
    }

    static func present(_ url: URL, folder: URL, from screen: ChatViewController) {
        let saver = ExportSaver(folder: folder, screen: screen)
        let panel = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        panel.delegate = saver
        open.append(saver)
        MenusSheet.top(screen)?.present(panel, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let saved = urls.first { screen?.showNotice("Exported “\(saved.lastPathComponent)”") }
        finish()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish() }

    private func finish() {
        try? FileManager.default.removeItem(at: folder)
        Self.open.removeAll { $0 === self }
    }
}
#endif
