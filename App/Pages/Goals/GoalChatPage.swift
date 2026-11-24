// [goals step 3] A goal with a lead is a goal's page with a teammate on it, exactly as a task with a bot (docs/tasks.md
// step 2, `TaskPage`): the goal's own chat with the goal laid over it. The goal covers the chat down to a one-line
// "Message Hermes" box at its foot (`TaskMessageLine`); a tap there, writing, sending, dragging the chat or Find gives
// the chat the screen under the goal's slim bar, and the bar or the title brings the goal back. The chat is hidden from
// Sessions, made on its first message, titled "Goal: <title> · <id prefix>", and its link is saved on the goal
// (`PATCH chat`) and on this device. On the Mac the chat is the window's right-hand pane instead (`makeBeside`).

import SwiftUI
import UIKit

/// Which chat is a goal's own: the goal's `chat` with its lead, else the one this device made for it, else none yet.
@MainActor
enum GoalChats {
    private static func key(_ account: GatewayAccount) -> String { "goals.chats.\(account.id)" }

    static func link(_ goal: Goal, account: GatewayAccount) -> TodoChat? {
        if let chat = goal.chat, chat.profile == goal.lead { return chat }
        guard let saved = UserDefaults.standard.dictionary(forKey: key(account))?[goal.id] as? [String: String],
              let profile = saved["profile"], let session = saved["session_id"], !profile.isEmpty, !session.isEmpty,
              profile == goal.lead else { return nil }
        return TodoChat(profile: profile, sessionId: session)
    }

    static func remember(_ chat: TodoChat, goal: String, account: GatewayAccount) {
        var all = UserDefaults.standard.dictionary(forKey: key(account)) ?? [:]
        all[goal] = ["profile": chat.profile, "session_id": chat.sessionId]
        UserDefaults.standard.set(all, forKey: key(account))
    }

    nonisolated static func sessionTitle(_ goal: Goal) -> String { GoalBots.sessionTitle(goal) }

    /// The goal's chat: the one it has, else a new hidden one with its lead, made on the first message. The first
    /// message carries the goal's details (your bubble keeps your words).
    static func chatModel(_ goal: Goal, store: TasksStore, context: MorePages.Context) -> (any ChatSessionModel)? {
        guard let lead = goal.lead, let bot = context.bots.first(where: { $0.id == lead }) else { return nil }
        let account = context.account
        let model: any ChatSessionModel
        let link = link(goal, account: account)
        if let link {
            model = context.pages.chat(for: SessionSummary(id: link.sessionId, profile: link.profile, title: goal.title, preview: nil,
                                                           lastActive: nil, source: nil, unread: false, isRunning: false))
        } else {
            let id = goal.id
            model = context.pages.taskChat(for: bot, sessionTitle: sessionTitle(goal), shownTitle: goal.title) { stored in
                let made = TodoChat(profile: bot.id, sessionId: stored)
                remember(made, goal: id, account: account)
                Task { _ = await store.patchGoal(id, ["chat": made.json]) }
            }
        }
        if let live = model as? LiveChatSession {
            if link == nil { live.pendingScope = "goal." + goal.id }
            var first = link == nil
            let id = goal.id
            live.wrapsSend = { [weak store] typed in
                guard let goal = store?.goal(id) else { return nil }
                let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !words.isEmpty else { return nil }
                defer { first = false }
                // The bot reads the goal with the chat's first message; a plan request already carries it.
                guard first, !words.hasPrefix(GoalBots.planRequestStart) else { return nil }
                return (words + "\n\n" + GoalBots.details(goal, now: Date()), words)
            }
            live.slashHooks.newChat = { _ in false }
        }
        return model
    }
}

/// [goals set-up] You took a lead's plan (on the goal's page, in its chat, or on Today): the lead hears it once, as a
/// hidden turn in the goal's chat (`GoalBots.planTakenRequest`). Once per offer on this device, kept over relaunches
/// (`GoalPlanTold`); another device's accept is a 409 there, so only the device whose tap the gateway took sends it.
/// With the goal's page open the turn goes through its chat, so the lead's reply shows as it comes; else through a
/// chat of its own kept until the reply has had time to come.
@MainActor
enum GoalPlanTaken {
    private final class Open { weak var page: GoalPageModel?; init(_ page: GoalPageModel) { self.page = page } }
    private static var open: [Open] = []
    /// Background chats, kept a while so the turn goes out and its reply is read.
    private static var kept: [(model: any ChatSessionModel, until: Date)] = []
    private static func key(_ account: GatewayAccount) -> String { "goals.plan-told.\(account.id)" }

    /// A goal's page with its chat (GoalChatPage) is open: plan-taken turns for its goal go through it.
    static func noteOpen(_ page: GoalPageModel) {
        open.removeAll { $0.page == nil || $0.page === page }
        open.append(Open(page))
    }

    static func tell(_ offer: TodoOffer, store: TasksStore) {
        guard let context = MorePages.context, context.account.id == store.account.id else { return }
        let goal = offer.goal.flatMap { store.goal($0) }
        var told = GoalPlanTold.read(UserDefaults.standard.string(forKey: key(context.account)))
        guard told.shouldTell(action: .accept, answer: offer, goal: goal), let goal,
              told.mark(offer.id, now: Date()) else { return }
        UserDefaults.standard.set(told.stored, forKey: key(context.account))
        let prompt = GoalBots.planTakenRequest(goal, offer: offer)
        if let page = open.lazy.compactMap(\.page).first(where: { $0.goalID == goal.id && !$0.gone }), let chat = page.chat {
            page.sendHidden(prompt, display: nil, in: chat)
            AppLog.note("goals", "plan taken: lead told in the open goal's chat")
            return
        }
        guard let model = GoalChats.chatModel(goal, store: store, context: context),
              let provider = model as? ChatActivityProviding else {
            AppLog.note("goals", "plan taken: no chat with the lead to tell")
            return
        }
        provider.sendHidden(prompt, display: nil)
        let now = Date()
        kept.removeAll { $0.until < now }
        kept.append((model, now.addingTimeInterval(600)))
        AppLog.note("goals", "plan taken: lead told in the goal's chat (page closed)")
    }
}

@MainActor
enum GoalChatPage {
    /// The goal's chat with the goal over it; nil without the add-on's bots, with no lead, or a lead that isn't one of
    /// your bots (the page stands alone, as steps 1 and 2).
    static func make(model page: GoalPageModel) -> ChatViewController? {
        let store = page.store, context = page.context
        guard store.goalBotsSupported, let goal = store.goal(page.goalID), goal.lead != nil,
              let chatModel = GoalChats.chatModel(goal, store: store, context: context),
              let chat = context.makeChat(chatModel) as? ChatViewController else { return nil }
        page.embedded = true
        page.chat = chat
        page.controller = chat
        GoalPlanTaken.noteOpen(page)
        chat.goalChatID = goal.id
        page.syncChatName()
        let host = GoalLeadHost(model: page)
        chat.setTopAccessory(host)
        chat.setTopAccessoryHeight(360, animated: false)
        // The goal's bar over the chat: "◉ Goal" over the goal's view; the chat's own title (its bot) over the chat.
        let face = chat.titleAccessoryView
        let mark = UIImageView(image: UIImage(systemName: "smallcircle.filled.circle",
                                              withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)))
        mark.contentMode = .scaleAspectFit
        mark.isAccessibilityElement = false
        let apply: (Bool) -> Void = { [weak chat, weak page] animated in
            guard let chat, let page else { return }
            mark.tintColor = UIColor((page.goal?.tint ?? .blue).ink)
            chat.coverFootHeight = page.goal?.lead == nil ? 0 : TaskMessageLine.height
            chat.transcriptCovered = !page.tucked
            chat.titleOverride = page.tucked ? nil : "Goal"
            chat.titleAccessoryView = page.tucked ? face : mark
            if page.tucked {
                chat.setTopAccessoryHeight(host.barHeight, insets: true, animated: animated)
            } else {
                chat.setTopAccessoryHeight(max(120, chat.roomToComposerFoot), insets: false, animated: animated)
            }
        }
        page.onTuckChange = { apply(true) }
        chat.onShelfRoom = { [weak page] room in page?.shelfRoom = room }
        host.onKeysChanged = { apply(false) }
        host.onBarHeight = { if page.tucked { apply(true) } }
        chat.suppressesTalkTip = true
        chat.onEngage = { [weak page] engagement in
            switch engagement {
            case .drag: page?.tuck(.drag)
            case .send: page?.tuck(.send)
            case .find: page?.tuck(.find)
            }
        }
        chat.onTitleTap = { [weak page] in page?.untuck() }
        host.watch(field: chat.composer.textView)
        page.syncComposer(animated: false)
        apply(false)
        chat.view.accessibilityIdentifier = "goal.page"
        let chatMenu = chat.moreMenu
        chat.moreMenu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak page, weak chat] completion in
                MainActor.assumeIsolated {
                    guard let page, let chat, !page.gone, !page.readOnly else { completion([]); return }
                    completion(GoalMenu.leadItems(model: page) + GoalMenu.items(goalID: page.goalID, store: page.store, from: chat, source: nil))
                }
            },
        ] + (chatMenu.map { [UIMenu(title: "Chat", image: UIImage(systemName: "bubble.left.and.bubble.right"), children: $0.children)] } ?? []))
        chat.menus?.isTaskChat = true
        if let live = chatModel as? LiveChatSession {
            live.slashHooks.newChat = { [weak chat] _ in
                chat?.showNotice("A goal keeps its one chat. Ask here, or start a new chat from Sessions.", duration: 4, spinner: false)
                return true
            }
        }
        AppLog.note("goals", "goal page opened with its chat (\(GoalChats.link(goal, account: context.account) == nil ? "not made yet" : "linked"))")
        return chat
    }

    /// The Mac: the goal's chat for the pane beside its page (`page.split`).
    static func makeBeside(model page: GoalPageModel) -> ChatViewController? {
        let store = page.store, context = page.context
        guard store.goalBotsSupported, let goal = store.goal(page.goalID), goal.lead != nil,
              let chatModel = GoalChats.chatModel(goal, store: store, context: context),
              let chat = context.makeChat(chatModel) as? ChatViewController else { return nil }
        page.split = true
        page.chat = chat
        page.keptChat = chat
        GoalPlanTaken.noteOpen(page)
        chat.goalChatID = goal.id
        page.syncChatName()
        chat.suppressesTalkTip = true
        chat.view.accessibilityIdentifier = "goal.chat-pane"
        chat.menus?.isTaskChat = true
        if let live = chatModel as? LiveChatSession {
            live.slashHooks.newChat = { [weak chat] _ in
                chat?.showNotice("A goal keeps its one chat. Ask here, or start a new chat from Sessions.", duration: 4, spinner: false)
                return true
            }
        }
        AppLog.note("goals", "goal page opened beside its chat")
        return chat
    }
}

/// The goal over its chat: the goal's page, or its bar once rolled up.
final class GoalLeadHost: UIHostingController<HQScaledRoot<GoalLeadRoot>> {
    let model: GoalPageModel
    var onKeysChanged: (() -> Void)?
    var onBarHeight: (() -> Void)?
    private(set) var barHeight: CGFloat = 56
    private weak var field: UITextView?

    init(model: GoalPageModel) {
        self.model = model
        super.init(rootView: HQScaledRoot(GoalLeadRoot(model: model, onBarHeight: { _ in })))
        rootView = HQScaledRoot(GoalLeadRoot(model: model, onBarHeight: { [weak self] height in
            guard let self, height > 20, abs(height - self.barHeight) > 0.5 else { return }
            self.barHeight = height
            self.onBarHeight?()
        }))
        safeAreaRegions = []
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func watch(field: UITextView) {
        self.field = field
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(fieldBegan), name: UITextView.textDidBeginEditingNotification, object: field)
        center.addObserver(self, selector: #selector(keysHiding), name: UIResponder.keyboardWillHideNotification, object: nil)
        center.addObserver(self, selector: #selector(keysChanged), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
    }

    @objc private func fieldBegan() { model.tuck(.focus) }
    @objc private func keysHiding() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.tuckReason == .focus, self.field?.isFirstResponder != true else { return }
            self.model.untuck()
        }
    }
    @objc private func keysChanged() { onKeysChanged?() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "goal.sheet"
        view.clipsToBounds = false
    }

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

struct GoalLeadRoot: View {
    @Bindable var model: GoalPageModel
    var onBarHeight: (CGFloat) -> Void

    var body: some View {
        // [goals set-up] The chat's bar names the goal as it is now (rolled up or not, a rename shows at once).
        content.onChange(of: model.goal?.title) { model.syncChatName() }
    }

    @ViewBuilder private var content: some View {
        if model.tucked, let goal = model.goal {
            GoalBarView(model: model, goal: goal)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onBarHeight($0) }
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
        } else {
            GoalPlainView(model: model)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let lead = model.goal?.lead {
                        TaskMessageLine(name: model.botName(lead), draft: model.draft) { model.writeMessage() }
                    }
                }
                .transition(.opacity)
        }
    }
}

/// The goal rolled up over its chat: its ring, its name, and where it stands in one line. A tap brings it back.
struct GoalBarView: View {
    @Bindable var model: GoalPageModel
    var goal: Goal

    var body: some View {
        let fraction = GoalViews.fraction(goal, tasks: model.tasks)
        Button { model.untuck() } label: {
            HStack(spacing: 10) {
                GoalRing(fraction: fraction, color: goal.tint, size: 20, quiet: goal.state != .active)
                VStack(alignment: .leading, spacing: 1) {
                    Text(goal.title.isEmpty ? "Untitled Goal" : goal.title)
                        .font(Font.hq(.subheadline).weight(.semibold))
                        .foregroundStyle(Color.hqLabel)
                        .lineLimit(1)
                    let line = GoalViews.line(goal, tasks: model.tasks, now: Date())
                    if !line.isEmpty {
                        Text(line).font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(Font.hq(.footnote).weight(.semibold))
                    .foregroundStyle(Color.hqLabel3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: TaskPanel.fill))
            .overlay(alignment: .bottom) { Rectangle().fill(Color(uiColor: TaskPanel.edge)).frame(height: HQShape.hairline) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(goal.title)
        .accessibilityHint("Shows the goal")
        .accessibilityIdentifier("goal.tucked-bar")
    }
}
