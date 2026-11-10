// [tasks] A task's page is the task's own chat (owner 2026-11-05, "Yes" to: the task's chat on the task page itself,
// not sliding over it). Owner 2026-11-07 (Pinned Task, step 3): the task's brief (TodoSheetView) is pinned under the
// bar on its own panel, outside the chat's scroll, and the chat starts right under it. When you take up the
// conversation (drag the chat, write, send, find) it rolls up to a slim bar that keeps where the task stands, your next
// step and its one move; the bar or the title brings the brief back. The chat's own bar sends (memos, pictures, the
// model). A task with no chat yet makes it with its first message (`LiveChatSession.opensOnFirstSend`).

import SwiftUI
import UIKit

/// The pinned task: the brief, or its bar once rolled up. No safe area of its own (it stands under the chat's bar).
final class TaskBriefHost: UIHostingController<HQScaledRoot<TaskBriefRoot>> {
    let model: TodoSheetModel
    /// The keys moved: the page caps the brief again.
    var onKeysChanged: (() -> Void)?

    init(model: TodoSheetModel) {
        self.model = model
        super.init(rootView: HQScaledRoot(TaskBriefRoot(model: model)))
        safeAreaRegions = []
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Writing in the chat's field rolls the brief up; the keys going away with nothing sent bring it back.
    func watch(field: UITextView) {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(fieldBegan), name: UITextView.textDidBeginEditingNotification, object: field)
        center.addObserver(self, selector: #selector(keysHiding), name: UIResponder.keyboardWillHideNotification, object: nil)
        center.addObserver(self, selector: #selector(keysChanged), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
    }

    @objc private func fieldBegan() { model.tuck(.focus) }
    @objc private func keysHiding() { if model.tuckReason == .focus { model.untuck() } }
    @objc private func keysChanged() { onKeysChanged?() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "task.sheet"
        view.clipsToBounds = false   // the panel's fill runs up behind the chat's bar
    }

    /// The page says how tall it is as soon as it is drawn, which can be before the chat is on screen (its composer not
    /// yet placed, so the room down to it read as a few points and the panel stayed that short). Once the chat is on,
    /// and whenever its width changes, the page caps the task's view again.
    private var laidWidth: CGFloat = 0

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onKeysChanged?()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard abs(view.bounds.width - laidWidth) > 0.5 else { return }
        laidWidth = view.bounds.width
        DispatchQueue.main.async { [weak self] in self?.onKeysChanged?() }
    }
}

/// The brief or its bar.
struct TaskBriefRoot: View {
    @Bindable var model: TodoSheetModel
    var body: some View {
        if model.tucked, let task = model.task {
            // Its own height, at the top (it reports what it needs, not the room the brief had).
            TaskBarView(model: model, task: task)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
        } else {
            TodoSheetView(model: model)
                .transition(.opacity)
        }
    }
}

@MainActor
enum TaskPage {
    /// The task's chat with its details on top; nil before the task is read or with no bots (the page stands alone).
    static func make(model sheet: TodoSheetModel) -> ChatViewController? {
        let store = sheet.store, context = sheet.context
        guard let task = store.task(sheet.taskID) else { return nil }
        guard let chatModel = chatModel(task, store: store, context: context),
              let chat = context.makeChat(chatModel) as? ChatViewController else { return nil }
        sheet.embedded = true
        sheet.chat = chat
        sheet.controller = chat
        let brief = TaskBriefHost(model: sheet)
        chat.setTopAccessory(brief)
        // A start to measure in (a list in no room draws no rows, so it never says how tall it is); it settles at once.
        chat.setTopAccessoryHeight(360, animated: false)
        // The brief takes what it draws, leaving the chat at least 160 pt above the composer (a long one scrolls in its
        // panel, its first lines and its one move staying in sight); the bar takes its own height.
        var drawn: CGFloat = 0
        var untight: CGFloat = 0   // what the brief drew before it folded (it loosens only once that fits with room to spare)
        let apply: (Bool) -> Void = { [weak chat, weak sheet] animated in
            guard let chat, let sheet else { return }
            // Owner 2026-11-08 ("I like A, but … the buttons you need to click stay above the fold"): never half and
            // half. The task's view covers the chat down to its composer, its move and the chat's line at its foot;
            // the chat's view is the whole chat under the task's bar.
            let cap = max(120, chat.roomToComposer)
            if !sheet.tucked {
                if !sheet.briefTight, drawn > cap + 0.5 {
                    untight = drawn
                    sheet.briefTight = true   // it draws again, shorter, and says so
                } else if sheet.briefTight, untight + 24 < cap {
                    sheet.briefTight = false
                }
            }
            sheet.briefScrolls = !sheet.tucked && drawn > cap + 0.5
            chat.transcriptCovered = !sheet.tucked
            // The bar names the bot over the task's view (its title is right under it), the task over its chat.
            chat.titleOverride = sheet.tucked ? nil : sheet.store.task(sheet.taskID).map { sheet.botName(sheet.chatBot($0)) }
            if sheet.tucked {
                chat.setTopAccessoryHeight(drawn, insets: true, animated: animated)
            } else {
                chat.setTopAccessoryHeight(cap, insets: false, animated: animated)
            }
        }
        sheet.onLeadHeight = { height in
            // A list's first answer can come before its rows (0, or its margins alone): taking it laid the panel
            // away, and a list in no room never says how tall it is again.
            guard height > 40 else { return }
            drawn = height
            apply(true)
        }
        sheet.onBriefLayoutChange = { apply(true) }
        sheet.onTuckChange = { apply(true) }
        chat.suppressesTalkTip = true
        chat.onEngage = { [weak sheet] engagement in
            switch engagement {
            case .drag: sheet?.tuck(.drag)
            case .send: sheet?.tuck(.send)
            case .find: sheet?.tuck(.find)
            }
        }
        // The title opens the task (it had opened the chat's technical Info, which is in ⋯ › Chat).
        chat.onTitleTap = { [weak sheet] in sheet?.untuck() }
        brief.onKeysChanged = { apply(false) }
        brief.watch(field: chat.composer.textView)
        chat.view.accessibilityIdentifier = "task.page"
        // ⋯: the task's own rows first, then the chat's (Share, Find, Info, Model…) under Chat, then Delete Task….
        let chatMenu = chat.moreMenu
        chat.moreMenu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak sheet] completion in
                MainActor.assumeIsolated {
                    guard let sheet, let task = sheet.task else { completion([]); return }
                    completion(TodoSheetHost.menu(task, model: sheet))
                }
            },
        ] + (chatMenu.map { [UIMenu(title: "Chat", image: UIImage(systemName: "bubble.left.and.bubble.right"), children: $0.children)] } ?? []) + [
            UIDeferredMenuElement.uncached { [weak sheet] completion in
                MainActor.assumeIsolated {
                    guard let sheet, sheet.task != nil else { completion([]); return }
                    completion([UIMenu(options: .displayInline, children: TodoSheetHost.deleteMenu(model: sheet))])
                }
            },
        ])
        // [tasks] Owner 2026-11-07 (Pinned Task step 2): the ⋯'s Chat ▸ leaves out Pin, Mark as Read, Rename, Branch,
        // Archive and Delete Chat, and /new keeps the task's one chat (it had opened a bare chat in the task's place).
        // The chat is made by the first message (`LiveChatSession.send`), not the first letter, and the composer keeps
        // its own draft saver (this page had taken its place, so words typed on a new task were never kept).
        chat.menus?.isTaskChat = true
        if let live = chatModel as? LiveChatSession {
            live.slashHooks.newChat = { [weak chat] _ in
                chat?.showNotice("A task keeps its one chat. Ask here, or start a new chat from Sessions.", duration: 4, spinner: false)
                return true
            }
        }
        AppLog.note("tasks", "task page opened: chat \(TaskChatLinks.link(task, account: context.account) == nil ? "not made yet" : "linked") for \(AppLog.tag(chatModel.profile))")
        return chat
    }

    /// The task's chat: the one it has, else a new hidden one with the bot that knows the task, made on the first
    /// message. Typed words go out with the task's details the first time (your bubble keeps your words).
    static func chatModel(_ task: TodoTask, store: TasksStore, context: MorePages.Context) -> (any ChatSessionModel)? {
        let account = context.account
        let model: any ChatSessionModel
        let link = TaskChatLinks.link(task, account: account)
        if let link {
            model = context.pages.chat(for: SessionSummary(id: link.sessionId, profile: link.profile, title: task.title, preview: nil,
                                                           lastActive: nil, source: nil, unread: false, isRunning: false))
        } else {
            guard let bot = TaskChatLinks.bot(for: task, bots: context.bots) else { return nil }
            let id = task.id
            model = context.pages.taskChat(for: bot, sessionTitle: TaskChatLinks.sessionTitle(task), shownTitle: task.title) { stored in
                let made = TodoChat(profile: bot.id, sessionId: stored)
                TaskChatLinks.remember(made, task: id, account: account)
                Task { _ = await store.patch(id, ["chat": made.json]) }
            }
        }
        if let live = model as? LiveChatSession {
            if link == nil { live.pendingScope = "task." + task.id }   // its draft is this task's, not the bot's
            // The chat is made by its first message, so "first" is this chat's first message, not "no link yet".
            var first = link == nil
            let id = task.id
            live.wrapsSend = { [weak store] typed in
                guard let task = store?.task(id) else { return nil }
                let out = outgoing(typed, task: task, first: first)
                if !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { first = false }
                return out
            }
        }
        return model
    }

    /// What a message about the task carries and shows: the task's details with the chat's first message; Ask to
    /// Help's question shows as "Help me with …". Nil: as typed.
    static func outgoing(_ typed: String, task: TodoTask, first: Bool) -> (text: String, display: String)? {
        let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        let shown = words == TodoWords.helpQuestion ? "Help me with “\(task.title)”" : words
        if first { return (TodoWords.askMessage(words, task: task), shown) }
        return shown == words ? nil : (words, shown)
    }
}

/// [tasks] Trial 2026-11-05 (owner: the chat "feels like it's too blended" with the task): the task's details stand in
/// one panel a step up from the chat's page, with a rounded foot, and the chat starts under it.
enum TaskPanel {
    /// The task's view stands on the chat's own page (owner 2026-11-09, the plain task view: no panel, no cards); it had
    /// been the chat's card fill laid on the page (#F5F5F6 light, #202228 dark in the Nous look).
    static let fill = UIColor { traits in ChatPalette.page.resolvedColor(with: traits) }
    /// The band between two sections of the task's view (Todoist's): the chat's card fill laid on the page (#F5F5F6
    /// light, #202228 dark in the Nous look); the look's grouped page in the Desktop Look in dark.
    static let band = UIColor { traits in
        if ThemeTable.desktopLook, traits.userInterfaceStyle == .dark { return HQPalette.groupedPage.resolvedColor(with: traits) }
        return over(ChatPalette.fill4.resolvedColor(with: traits), ChatPalette.page.resolvedColor(with: traits))
    }
    /// The cards on the panel: the chat's page in light (white on grey); one more card fill over the panel in dark.
    /// In the Desktop Look, the look's grouped card (as its boxed rows).
    static let card = UIColor { traits in
        if ThemeTable.desktopLook { return HQPalette.groupedCard.resolvedColor(with: traits) }
        return traits.userInterfaceStyle == .dark
            ? over(ChatPalette.fill4.resolvedColor(with: traits), fill.resolvedColor(with: traits))
            : ChatPalette.page.resolvedColor(with: traits)
    }
    static let edge = ChatPalette.separator

    /// A see-through fill as it shows on the colour under it.
    private static func over(_ top: UIColor, _ base: UIColor) -> UIColor {
        var (r1, g1, b1, a1, r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0, 0, 0, 0, 0)
        top.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        base.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r2 + (r1 - r2) * a1, green: g2 + (g1 - g2) * a1, blue: b2 + (b1 - b2) * a1, alpha: 1)
    }
}
