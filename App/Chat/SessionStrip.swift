import UIKit

// [session-strip] Owner 2026-11-17: "Is there any way to have active Sessions shown along the top bar on a Bot chat so
// that you can easily move between them?" Three switchers were built and run on his real chats (a pill strip, the
// title's menu, a sideways swipe); he picked the strip. Under the bar of any chat with a bot: that bot's own chat first
// (the tab bar's robot), then its active chats newest first, the one on screen lit. A green dot is a chat at work, a
// blue one a reply not read yet. One tap opens that chat in this one's place, the bar staying put. The strip is drawn
// only when Settings › Chat › Other Chats at the Top is on, together with the New Chat button. Not in a group room or
// a task's page.
// [bot-chat-sessions] Owner 2026-11-18 ("I need some way to show sessions owned by a bot ON the bot chat for the Mac
// app"; of four mock-ups he picked the strip and the right panel together): the Mac draws it too, on unless turned
// off, and slimmer. There it holds only what is live (working, unread, pinned, the chat on screen, the ones gone
// through this run), and "All N" at its end opens the inspector's Chats tab (`BotChatsPanel`), which lists every one.
// The Mac draws them as tabs, not pills (owner 2026-11-18, picking "A · Underline tabs" of four designs: the pills
// read as a second row of buttons): plain words on the bar's own ground, the chat on screen in the label colour with
// a line of the tint under it, the rest grey, a hairline under the row.
// [bot-tabs-ux] Owner 2026-11-18, on the built tabs ("I don't want these to show on every session. Only on a bot chat
// … same direction, [just] better. The UX needs improvement"): on the Mac the row is drawn on a bot's own chat only,
// which makes it that bot's doorway to its live chats. A tab is a whole target (it lights under the pointer, no dead
// gaps between tabs), a short rule parts Bot Chat from the chats, the tabs keep their places as chats work (a new one
// comes in first; nothing is re-sorted under the pointer), a tab's tip gives its whole title and last line, and a
// right-click offers Mark as Read, Pin, Archive and Remove from Tabs.

// [typing-header] Owner 2026-11-20 ("Is there any way to reduce the height of that whole top section? … with the
// keyboard up, there's really not much screen real estate left for the actual chat"; of the drawn study he said
// "That works!!!"): on the iPhone the row folds away while the software keyboard covers the chat and comes back as
// it goes. Only the row's height changes (`setKeyboardOccludesChat`): Back, the title and ⋯ stay as they are, ⋯ ›
// Chats with the bot still lists every chat, and the pills, their scroll place and the draft are kept.

/// Settings › Chat › Other Chats at the Top (opt-in).
enum SessionStripPref {
    static let key = "hqn.sessionStrip"
    static let didChange = Notification.Name("hqn.sessionStrip.changed")

    /// Until it is chosen: off on the iPhone and iPad (opt-in), on on the Mac ([bot-chat-sessions]).
    static var standard: Bool { DeviceWord.isMac }

    static var isOn: Bool {
        // `bool(forKey:)` also reads a launch argument's "NO" (a string in the argument domain).
        get { UserDefaults.standard.object(forKey: key) == nil ? standard : UserDefaults.standard.bool(forKey: key) }
        set {
            guard newValue != isOn else { return }
            if newValue == standard { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(newValue, forKey: key) }
            AppLog.note("settings", "Other Chats at the Top set to \(newValue)")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

/// One pill.
nonisolated struct SessionStripEntry: Equatable, Sendable {
    var id: String          // the stored session id ("" for a bot chat the roster hasn't named yet)
    var title: String
    var isBotChat: Bool
    var working: Bool
    var unread: Bool
    var current: Bool
    /// The Mac's tip: what was last said (or the step at work).
    var detail: String = ""
    var pinned: Bool = false
}

nonisolated enum SessionStripRules {
    /// A chat touched this recently counts as active.
    static let activeFor: TimeInterval = 24 * 3600
    /// The most pills (the chat on screen is always among them).
    static let most = 8
    /// Fewer than this and the strip is not drawn.
    static let fewest = 2

    static func sameBot(_ a: String, _ b: String) -> Bool { (a.isEmpty ? "default" : a) == (b.isEmpty ? "default" : b) }

    /// The phone's list and count share this membership, independent of the Mac's existing list.
    static func phoneChats(bot: Bot?, sessions: [SessionSummary], profile: String, hidden: Set<String>) -> [SessionSummary] {
        sessions.filter {
            sameBot($0.profile, profile) && !$0.archived && $0.id != bot?.canonicalSessionId
                && SessionList.isVisible($0) && !$0.title.hasPrefix("Task: ") && !hidden.contains($0.id)
        }.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    /// Select by work, unread, then pinned; preserve the positions of surviving names.
    static func phoneEntries(_ chats: [SessionSummary], order: [String], now: Date = Date()) -> [SessionStripEntry] {
        func rank(_ chat: SessionSummary) -> Int {
            chat.isRunning || chat.status == .working ? 0 : chat.unread ? 1 : chat.pinned ? 2 : 3
        }
        let previous = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let candidates = chats.enumerated().filter { _, chat in
            rank(chat) < 3
        }.sorted { a, b in
            let ar = rank(a.element), br = rank(b.element)
            if ar != br { return ar < br }
            let ap = previous[a.element.id] ?? Int.max, bp = previous[b.element.id] ?? Int.max
            return ap != bp ? ap < bp : a.offset < b.offset
        }
        let selected = Array(candidates.prefix(2))
        let placed = selected.enumerated().sorted { a, b in
            let ap = previous[a.element.element.id] ?? Int.max, bp = previous[b.element.element.id] ?? Int.max
            return ap != bp ? ap < bp : a.offset < b.offset
        }.map(\.element)
        return placed.map { _, chat in
            SessionStripEntry(id: chat.id, title: chat.title, isBotChat: false,
                              working: chat.isRunning || chat.status == .working, unread: chat.unread,
                              current: false, pinned: chat.pinned)
        }
    }

    /// Every chat of the bot's a person would call one (never archived, a job's run, a tool's, nor its own Bot Chat),
    /// newest first: what the strip picks from, and what the Mac's Chats tab lists.
    static func chats(bot: Bot?, sessions: [SessionSummary], profile: String) -> [SessionSummary] {
        sessions
            .filter { sameBot($0.profile, profile) && !$0.archived && $0.source != "cron" && $0.source != "tool"
                && $0.id != bot?.canonicalSessionId }
            .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    /// The bot's own chat, then its active chats (working, unread, pinned, the one on screen, touched in the last day,
    /// or `kept`: already a pill this run, so a chat you just went through doesn't drop out as you move on; never
    /// archived, a job's run or a tool's), newest first. `recent` false (the Mac, whose Chats tab lists the rest):
    /// a chat only touched in the last day is not one of them.
    static func entries(bot: Bot?, sessions: [SessionSummary], profile: String, currentId: String?, onBotChat: Bool,
                        kept: Set<String> = [], recent: Bool = true, now: Date = Date()) -> [SessionStripEntry] {
        var out: [SessionStripEntry] = []
        if let bot {
            out.append(SessionStripEntry(id: bot.canonicalSessionId ?? "", title: bot.name, isBotChat: true,
                                         working: bot.isWorking, unread: bot.unread && !onBotChat, current: onBotChat))
        }
        let chats = chats(bot: bot, sessions: sessions, profile: profile)
            .filter { $0.id == currentId || kept.contains($0.id) || $0.isRunning || $0.status == .working || $0.unread || $0.pinned
                || (recent && now.timeIntervalSince($0.lastActive ?? .distantPast) < activeFor) }
        for chat in chats {
            let isCurrent = !onBotChat && chat.id == currentId
            guard isCurrent || out.count < most else { continue }
            let working = chat.isRunning || chat.status == .working
            let said = (chat.preview ?? "").split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            out.append(SessionStripEntry(id: chat.id, title: chat.title, isBotChat: false, working: working,
                                         unread: chat.unread && !isCurrent, current: isCurrent,
                                         detail: working ? (chat.step ?? "Working…") : said, pinned: chat.pinned))
        }
        return out
    }

    /// [bot-tabs-ux] The Mac's tabs keep their places: the bot's own chat, then chats not shown before (in the order
    /// given, newest first), then the ones already shown in the order they had. Returns that order to keep.
    static func settled(_ entries: [SessionStripEntry], order: [String]) -> (entries: [SessionStripEntry], order: [String]) {
        let chats = entries.filter { !$0.isBotChat }
        let known = Set(order)
        // Among the ones coming in, what wants the eye leads: at work, then a reply not read, then the rest.
        func rank(_ entry: SessionStripEntry) -> Int { entry.working ? 0 : entry.unread ? 1 : 2 }
        let fresh = chats.filter { !known.contains($0.id) }.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        let byId = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let old = order.compactMap { byId[$0] }
        let placed = fresh + old
        return (entries.filter(\.isBotChat) + placed, placed.map(\.id))
    }
    /// [bot-tabs-seamless] The Mac's strip draws only the bot's other chats (never its own Bot Chat: the header right
    /// above already names the bot and the strip only lives on Bot Chat).
    static func macEntries(_ entries: [SessionStripEntry]) -> [SessionStripEntry] {
        entries.filter { !$0.isBotChat }
    }
}

/// [bot-chat-sessions] One group of the Mac's Chats tab.
nonisolated struct BotChatGroup: Equatable, Sendable {
    var title: String
    var chats: [SessionSummary]
}

extension SessionStripRules {
    /// The Chats tab's groups, each chat in the first that fits: Active (at work, then a reply not read), Pinned, Today,
    /// Earlier. Within a group the chats keep the order they came in (newest first); an empty group is left out.
    static func groups(_ chats: [SessionSummary], now: Date = Date(), calendar: Calendar = .current) -> [BotChatGroup] {
        let titles = ["Active", "Pinned", "Today", "Earlier"]
        var held: [[SessionSummary]] = Array(repeating: [], count: titles.count)
        let today = calendar.startOfDay(for: now)
        var working: [SessionSummary] = []
        for chat in chats {
            if chat.isRunning || chat.status == .working { working.append(chat); continue }
            let index = chat.unread ? 0 : chat.pinned ? 1 : (chat.lastActive ?? .distantPast) >= today ? 2 : 3
            held[index].append(chat)
        }
        held[0] = working + held[0]
        return zip(titles, held).filter { !$0.1.isEmpty }.map { BotChatGroup(title: $0.0, chats: $0.1) }
    }
}

@MainActor enum SessionStrip {
    /// Posted when the chats or the bots change (AppModel): every strip on screen reads its pills again.
    static let listChanged = Notification.Name("hq.sessionStrip.listChanged")

    /// Offers the strip to a chat screen as it is made (`AppModel.makeChatScreen`). It takes the slot under the bar
    /// when the chat first appears, so a task's page, which puts its own panel there, keeps it.
    static func offer(to screen: ChatViewController, model: any ChatSessionModel, app: AppModel) {
        guard let live = model as? LiveChatSession, !(model is ChatRoomSurface) else { return }
        // Both platforms use the bot's canonical chat as the doorway; child and group chats have no row.
        let wanted = live.isBotChat
        if wanted { screen.makeTopStrip = { [weak screen, weak app] in
            // A task keeps its one chat: none over the Mac's task pane either (a chat with no panel of the task's on it).
            guard let screen, let app, screen.menus?.isTaskChat != true else { return nil }
            return SessionStripController(screen: screen, app: app)
        } }
        #if targetEnvironment(macCatalyst)
        // [bot-chat-sessions] The inspector's Chats tab beside this chat: every chat of its bot's.
        screen.makeChatsPanel = { [weak screen, weak app] in
            guard let screen, let app else { return nil }
            return BotChatsPanel(screen: screen, app: app)
        }
        #endif
    }

    /// How many chats the bot has besides its own ("All N", and whether the Mac draws the strip at all).
    static func count(app: AppModel, model: any ChatSessionModel) -> Int {
        if !DeviceWord.isMac { return phoneChats(app: app, model: model).count }
        let profile = model.profile.isEmpty ? "default" : model.profile
        let current = (model as? LiveChatSession)?.storedSessionId
        return SessionStripRules.chats(bot: app.botStore?.bot(named: profile), sessions: app.sessionsOutsideKeptProjects(keeping: current),
                                       profile: profile).count
    }

    /// The sheet and its All count must use exactly the same membership as the phone strip.
    static func phoneChats(app: AppModel, model: any ChatSessionModel) -> [SessionSummary] {
        let profile = model.profile.isEmpty ? "default" : model.profile
        let current = (model as? LiveChatSession)?.storedSessionId
        return SessionStripRules.phoneChats(bot: app.botStore?.bot(named: profile), sessions: app.sessionsOutsideKeptProjects(keeping: current),
                                            profile: profile, hidden: phoneHiddenChats(app: app))
    }

    private static func phoneHiddenChats(app: AppModel) -> Set<String> {
        var hidden: Set<String> = []
        for bot in app.bots { if let id = bot.canonicalSessionId, !id.isEmpty { hidden.insert(id) } }
        if let account = app.account?.id {
            hidden.formUnion(TileMaker.chatIDs(account: account))
            for maker in TileMaker.active where maker.accountId == account {
                if let id = (maker.chat as? LiveChatSession)?.storedSessionId, !id.isEmpty { hidden.insert(id) }
            }
            for pin in ArtifactPins.of(accountId: account).pins where pin.isPage && !pin.sessionId.isEmpty {
                hidden.insert(pin.sessionId)
            }
            if let store = TasksHub.current, store.account.id == account, store.hasList {
                for task in store.tasks {
                    if let id = TaskChatLinks.link(task, account: store.account)?.sessionId { hidden.insert(id) }
                }
            }
        }
        return hidden
    }

    /// Chats that have been a pill this run, by bot (kept in memory only).
    private static var shownBefore: [String: Set<String>] = [:]

    static func entries(app: AppModel, model: any ChatSessionModel) -> [SessionStripEntry] {
        if !DeviceWord.isMac {
            let key = (app.account?.id ?? "") + "\u{1F}" + (model.profile.isEmpty ? "default" : model.profile)
            let result = SessionStripRules.phoneEntries(phoneChats(app: app, model: model), order: phoneOrder[key] ?? [])
            phoneOrder[key] = result.map(\.id)
            return result
        }
        let live = model as? LiveChatSession
        let profile = model.profile.isEmpty ? "default" : model.profile
        let entries = SessionStripRules.entries(bot: app.botStore?.bot(named: profile),
                                                sessions: app.sessionsOutsideKeptProjects(keeping: live?.storedSessionId), profile: profile,
                                                currentId: live?.storedSessionId, onBotChat: live?.isBotChat == true,
                                                kept: shownBefore[profile] ?? [], recent: !DeviceWord.isMac)
        shownBefore[profile, default: []].formUnion(entries.filter { !$0.isBotChat }.map(\.id))
        guard DeviceWord.isMac else { return entries }
        let settled = SessionStripRules.settled(entries, order: tabOrder[profile] ?? [])
        tabOrder[profile] = settled.order
        return settled.entries
    }

    /// [bot-tabs-ux] The Mac's tabs in the places they have, by bot (kept in memory only).
    private static var tabOrder: [String: [String]] = [:]
    private static var phoneOrder: [String: [String]] = [:]

    /// Remove from Tabs: a chat kept in the row only because it was shown before leaves it.
    static func forget(_ id: String, profile: String) {
        shownBefore[profile]?.remove(id)
        NotificationCenter.default.post(name: listChanged, object: nil)
    }

    /// [spring-drop] The chat an entry opens from `screen`, for files let go on its tab or row: the one on show is the
    /// screen itself.
    static func dropChat(_ entry: SessionStripEntry, screen: ChatViewController) -> DroppedFilesHandOff.Chat {
        if entry.current { return .screen(ObjectIdentifier(screen)) }
        let profile = screen.session.profile.isEmpty ? "default" : screen.session.profile
        return entry.isBotChat ? .botChat(profile: profile) : .session(profile: "", id: entry.id)
    }

    /// That chat opens in this one's place: a quick fade, the bar and the strip staying where they are.
    static func open(_ entry: SessionStripEntry, from screen: ChatViewController, app: AppModel) {
        guard !entry.current, let navigation = screen.navigationController else { return }
        let profile = screen.session.profile.isEmpty ? "default" : screen.session.profile
        let model: any ChatSessionModel
        if entry.isBotChat {
            guard let bot = app.botStore?.bot(named: profile) else { return }
            model = app.chat(for: bot)
        } else {
            guard let summary = app.sessions.first(where: { $0.id == entry.id }) else { return }
            model = app.chat(for: summary)
        }
        // Keep the canonical chat (and its composer draft) underneath on iPhone and iPad.
        if !DeviceWord.isMac, !entry.isBotChat, (screen.session as? LiveChatSession)?.isBotChat == true {
            guard navigation.topViewController === screen else { return }
            let next = app.makeChatScreen(model)
            next.hidesBottomBarWhenPushed = true
            next.navigationItem.largeTitleDisplayMode = .never
            navigation.pushViewController(next, animated: !HQMotion.reduced)
            AppModel.markPane(navigation)
            return
        }
        let next = app.makeChatScreen(model)
        next.hidesBottomBarWhenPushed = true
        next.navigationItem.largeTitleDisplayMode = .never
        if !entry.isBotChat { carryBack(from: screen, to: next, app: app) }
        var stack = navigation.viewControllers
        if let index = stack.firstIndex(where: { $0 === screen }) { stack.remove(at: index) }
        stack.append(next)
        if !HQMotion.reduced {
            let fade = CATransition()
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.type = .fade
            navigation.view.layer.add(fade, forKey: "hq.sessionStrip")
        }
        navigation.setViewControllers(stack, animated: false)
        // In two panes the lists' marks and the Mac's inspector follow the chat now beside them.
        AppModel.markPane(navigation)
        AppLog.note("chat", "strip: opened \(entry.isBotChat ? "the bot's chat" : "chat \(AppLog.tag(entry.id))")")
    }

    /// [bot-chat-back] The Mac: a chat opened from a bot's own chat (or from a chat that was) gets a Back to that bot's
    /// chat at the start of its bar. Nothing for a chat opened from a list.
    static func carryBack(from screen: UIViewController, to next: UIViewController, app: AppModel) {
        #if targetEnvironment(macCatalyst)
        guard let from = screen as? ChatViewController, let next = next as? ChatViewController,
              let live = from.session as? LiveChatSession, live.isBotChat || from.backToBotChat != nil else { return }
        let profile = live.profile.isEmpty ? "default" : live.profile
        next.backToBotChat = { [weak next, weak app] in
            guard let next, let app, let bot = app.botStore?.bot(named: profile) else { return }
            AppLog.note("chat", "back to the bot's chat")
            open(SessionStripEntry(id: bot.canonicalSessionId ?? "", title: bot.name, isBotChat: true, working: false, unread: false,
                                   current: false), from: next, app: app)
        }
        #endif
    }

    static let workingColor = UIColor.systemGreen
    static let unreadColor = UIColor.systemBlue

    static func dot(_ color: UIColor, side: CGFloat = 7) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }

    /// The tab bar's robot, at a pill's size.
    static func robot(side: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            TabIcons.bot.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }.withRenderingMode(.alwaysTemplate)
    }
}

/// The row of pills under the bar; 0 tall (and nothing drawn) while it is off or the bot has one chat to show.
/// [compact-strip] The iPhone row is drawn slimmer than a finger: a touch up to `reach` below it still lands on the name
/// above, so every name keeps a 44 pt tall target while the row gives that room back to the chat.
private final class StripView: UIView {
    var reach: CGFloat = 0
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.inset(by: UIEdgeInsets(top: 0, left: 0, bottom: -reach, right: 0)).contains(point)
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, isUserInteractionEnabled, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        return super.hitTest(CGPoint(x: point.x, y: min(point.y, bounds.maxY - 1)), with: event)
    }
}

final class SessionStripController: UIViewController, UIScrollViewDelegate {
    private weak var screen: ChatViewController?
    private weak var app: AppModel?
    /// [bot-tabs-seamless] The Mac's strip shares the top bar's exact surface: Desktop Look's 94 % page frost
    /// (`DesktopFrostView`), and in the iOS look `ChatViewController.barBand`'s `systemUltraThinMaterial` + `popupVeil`
    /// while messages scroll under it (clear at rest).
    private let macDesktopFrost = DesktopFrostView()
    private let macIOSBand = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let macIOSVeil = UIView()
    private var topBandShown = false
    /// [bot-tabs-seamless] On iPhone and iPad in Normal Theming (Liquid Glass), a single slim floating glass capsule
    /// tucked below the nav bar's pills (Option A). Hidden in Desktop Look, where `ChatViewController.edgeStandIn`
    /// already extends seamlessly behind the strip down to its bottom hairline.
    private let iosGlassBar: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        view.cornerConfiguration = .capsule()
        view.isUserInteractionEnabled = false
        view.accessibilityIdentifier = "chat.strip.glass"
        return view
    }()
    private let scroller = UIScrollView()
    private let row = UIStackView()
    private let newChat = UIButton(configuration: .glass())
    /// [bot-chat-sessions] The Mac's "All N": every chat of the bot's, in the inspector's Chats tab.
    private let allChats = UIButton(configuration: .glass())
    /// [bot-tabs-seamless] Subtle vertical tick between `All N ›` and `+` on the Mac.
    private let rightRule = UIView()
    private var allCount = -1
    private lazy var scrollerToNew = scroller.trailingAnchor.constraint(equalTo: newChat.leadingAnchor, constant: -6)
    private lazy var scrollerToAll = scroller.trailingAnchor.constraint(equalTo: allChats.leadingAnchor, constant: tabs ? -6 : -4)
    private var phoneScrollerLeading: NSLayoutConstraint?
    private var phoneScrollerTop: NSLayoutConstraint?
    private var phoneScrollerBottom: NSLayoutConstraint?
    private var phoneAllTrailing: NSLayoutConstraint?
    private var newChatHeight: NSLayoutConstraint?
    private var newChatWidth: NSLayoutConstraint?
    private var allChatsHeight: NSLayoutConstraint?
    private var shown: [SessionStripEntry] = []
    private var watches: [NSObjectProtocol] = []
    private var availableHeight: CGFloat = 0
    private var keyboardOccludesChat = false
    /// The pill of the chat on screen is kept in view as the pills change, until the person scrolls the strip.
    private var personScrolled = false
    private var placedCurrent = false
    /// [spring-drop] Each drawn tab or pill's chat, for a file drag held over it.
    private var pillEntries: [ObjectIdentifier: SessionStripEntry] = [:]
    /// [spring-drop] Files dragged in from outside the app: a tab held under them opens its chat in this one's place.
    private lazy var fileDrop: SessionFileDrop = {
        let drop = SessionFileDrop(list: view)
        drop.target = { [weak self] point in self?.fileDropTarget(at: point) }
        return drop
    }()
    private lazy var fileDropInteraction = SessionFileDropInteraction(drop: fileDrop)

    private func fileDropTarget(at point: CGPoint) -> SessionFileDrop.Target? {
        guard let screen, let app else { return nil }
        for pill in row.arrangedSubviews where !pill.isHidden {
            guard let entry = pillEntries[ObjectIdentifier(pill)], pill.convert(pill.bounds, to: view).contains(point) else { continue }
            return SessionFileDrop.Target(key: entry.isBotChat ? "bot" : entry.id, view: pill, cornerRadius: tabs ? 6 : pill.bounds.height / 2,
                                          chat: SessionStrip.dropChat(entry, screen: screen),
                                          open: { [weak screen, weak app] in
                                              guard let screen, let app else { return }
                                              SessionStrip.open(entry, from: screen, app: app)
                                          })
        }
        return nil
    }

    init(screen: ChatViewController, app: AppModel) {
        self.screen = screen
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        watches.forEach { NotificationCenter.default.removeObserver($0) }
        app?.setChatList(self, shown: false)
    }

    /// [bot-chat-sessions] On screen (the Mac reads the chats at the on-screen pace while its strip is drawn).
    private var appeared = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        reload()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        appeared = false
        app?.setChatList(self, shown: false)
    }

    /// Compact iPhone/iPad strip type: subordinate to the chat title above, scaling with Dynamic Type up to 18 pt.
    private func phoneFont(weight: UIFont.Weight) -> UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(for: HQFont.system(ofSize: 13, weight: weight), maximumPointSize: 18)
    }
    /// [bot-tabs-seamless] Compact Mac strip type: ~12 pt on screen at 100 % UI Scale (subordinate to the bot's name
    /// and model above), floored at `HQFont.macSmallest` and following UI Scale.
    private func macFont(weight: UIFont.Weight) -> UIFont {
        let grow = max(1, ChatTitleView.macChrome)
        let raw = HQFont.system(ofSize: HQFont.legibleLiteral(12), weight: weight)
        let cap = 20 * grow
        return raw.pointSize > cap ? raw.withSize(cap) : raw
    }
    /// [bot-chat-sessions] The Mac's look: seamless plain words on the top bar's own ground (floating glass capsule /
    /// seamless Desktop Look bar elsewhere).
    private var tabs: Bool { DeviceWord.isMac }
    private let rule = UIView()
    /// The tabs fade out at an edge they run past (words cut square at the row's end read as a fault); none at an
    /// edge with nothing beyond it.
    private let fade = CAGradientLayer()

    /// [bot-tabs-seamless] Solid bottom hairline: composites the pane divider over `ChatPalette.page` so messages
    /// scrolling underneath never tint it, matching `ChatViewController.barBand` and `MacInspector.rule`.
    private static var ruleColor: UIColor {
        UIColor { traits in
            #if targetEnvironment(macCatalyst)
            let line = HQPalette.paneLine.resolvedColor(with: traits)
            #else
            let line = ChatPalette.separator.resolvedColor(with: traits)
            #endif
            let page = ChatPalette.page.resolvedColor(with: traits)
            var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
            var pr: CGFloat = 0, pg: CGFloat = 0, pb: CGFloat = 0, pa: CGFloat = 0
            guard line.getRed(&lr, green: &lg, blue: &lb, alpha: &la),
                  page.getRed(&pr, green: &pg, blue: &pb, alpha: &pa) else { return line }
            return UIColor(red: lr * la + pr * (1 - la), green: lg * la + pg * (1 - la), blue: lb * la + pb * (1 - la), alpha: 1)
        }
    }

    private func placeFade() {
        guard tabs else { return }
        let width = scroller.bounds.width
        guard width > 0 else { return }
        let reach: CGFloat = 22
        let before = scroller.contentOffset.x > 1
        let after = scroller.contentOffset.x < scroller.contentSize.width - width - 1
        let clear = UIColor.clear.cgColor, solid = UIColor.black.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = scroller.bounds   // the mask moves with the scrolled content: kept over what shows
        fade.colors = [before ? clear : solid, solid, solid, after ? clear : solid]
        fade.locations = [0, NSNumber(value: Double(reach / width)), NSNumber(value: Double(1 - reach / width)), 1]
        CATransaction.commit()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { placeFade() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !tabs { (view as? StripView)?.reach = max(0, 44 - stripHeight) }   // follows Dynamic Type
        fitTabs()
        placeFade()
    }

    /// [bot-tabs-ux] The chats' tabs share the row: each shows its whole title while they all fit, and when they don't
    /// the longest give way first, evenly, down to `narrowestTab` (then the row scrolls). A fixed cap cut titles in a
    /// half-empty row.
    private static let widestTab: CGFloat = 300
    private static let narrowestTab: CGFloat = 110
    private var tabCaps: [(tab: UIButton, cap: NSLayoutConstraint)] = []
    private var fittedFor: CGFloat = -1

    private func fitTabs() {
        if !tabs {
            let names = row.arrangedSubviews.compactMap { $0 as? UIButton }
            let dots = row.arrangedSubviews.compactMap { $0 as? UILabel }
            let room = scroller.bounds.width - 16
            guard room > 0, !names.isEmpty else { return }
            if names.count == 2 {
                let wants = names.map { max(44, ceil($0.intrinsicContentSize.width)) }
                let dotWidth = dots.first.map { ceil($0.intrinsicContentSize.width) } ?? 0
                let hideSecond = wants.reduce(0, +) + dotWidth + row.spacing * 2 > room
                    || traitCollection.preferredContentSizeCategory.isAccessibilityCategory
                names[1].isHidden = hideSecond
                dots.first?.isHidden = hideSecond
            }
            if let limit = tabCaps.first?.cap, limit.constant != max(44, room) { limit.constant = max(44, room) }
            return
        }
        guard !tabCaps.isEmpty, scroller.bounds.width > 0, scroller.bounds.width != fittedFor else { return }
        fittedFor = scroller.bounds.width
        let wants = tabCaps.map { min(Self.widestTab, ceil($0.tab.intrinsicContentSize.width)) }
        let others = row.arrangedSubviews.filter { view in !tabCaps.contains { $0.tab === view } }
            .reduce(CGFloat(0)) { $0 + $1.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width }
        let room = scroller.bounds.width - 16 - others - row.spacing * CGFloat(max(0, row.arrangedSubviews.count - 1))
        // The largest cap at which the tabs fit (a tab narrower than the cap takes only what it needs).
        var cap = Self.widestTab
        if wants.reduce(0, +) > room {
            var left = room, count = CGFloat(wants.count)
            cap = Self.narrowestTab
            for want in wants.sorted() {
                if want * count <= left { left -= want; count -= 1 } else { cap = max(Self.narrowestTab, floor(left / count)); break }
            }
        }
        for item in tabCaps where item.cap.constant != cap { item.cap.constant = cap }
    }
    /// [compact-strip] Owner 2026-11-21 ("Entire little strip for the sessions is still too tall … taking up way too much
    /// screen space"): the iPhone's row is slim; `StripView` keeps each name a 44 pt tap.
    /// [bot-tabs-seamless] On the Mac, a compact ~27 pt item inside a ~33 pt sub-row; on iPhone/iPad, a ~32 pt
    /// floating Liquid Glass capsule in Normal Theming or a snug ~34 pt seamless sub-row in Desktop Look.
    private var pillHeight: CGFloat {
        tabs ? max(26, ceil(macFont(weight: .medium).lineHeight) + 8)
             : max(32, ceil(phoneFont(weight: .medium).lineHeight) + 14)
    }
    private var stripHeight: CGFloat {
        if tabs { return pillHeight + 6 }
        return Theme.isDesktop ? pillHeight + 2 : pillHeight + 8
    }

    override func loadView() {
        let strip = StripView()
        if !tabs { strip.reach = max(0, 44 - stripHeight) }
        view = strip
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "chat.strip"
        view.addInteraction(UIDropInteraction(delegate: fileDropInteraction))   // [spring-drop]
        // On the Mac, exact parity with the navigation bar's surface; on iPhone/iPad, a floating Liquid Glass capsule
        // in Normal Theming and transparent over `ChatViewController.edgeStandIn` in Desktop Look.
        if tabs {
            macDesktopFrost.translatesAutoresizingMaskIntoConstraints = false
            macDesktopFrost.fade = .none
            view.addSubview(macDesktopFrost)
            macIOSBand.isUserInteractionEnabled = false
            macIOSBand.translatesAutoresizingMaskIntoConstraints = false
            macIOSVeil.isUserInteractionEnabled = false
            macIOSVeil.backgroundColor = ChatPalette.popupVeil
            macIOSVeil.frame = macIOSBand.contentView.bounds
            macIOSVeil.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            macIOSBand.contentView.addSubview(macIOSVeil)
            view.addSubview(macIOSBand)
        } else {
            iosGlassBar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(iosGlassBar)
        }
        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceHorizontal = tabs
        scroller.clipsToBounds = true
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.panGestureRecognizer.addTarget(self, action: #selector(scrolledByPerson))
        if tabs {
            scroller.delegate = self
            fade.startPoint = CGPoint(x: 0, y: 0.5)
            fade.endPoint = CGPoint(x: 1, y: 0.5)
            scroller.layer.mask = fade
        }
        view.addSubview(scroller)
        configureNewChat()
        newChat.isHidden = !tabs
        newChat.isPointerInteractionEnabled = true
        newChat.translatesAutoresizingMaskIntoConstraints = false
        newChat.accessibilityIdentifier = "chat.strip.new"
        newChat.accessibilityLabel = "New Chat"
        if tabs {
            newChat.toolTip = "New Chat"
            PointerEffects.surface(newChat, pill: true)
        }
        newChat.addAction(UIAction { [weak self] _ in
            guard let self, let screen = self.screen, let app = self.app, let navigation = screen.navigationController else { return }
            guard app.openNewChat(like: screen.session, draft: "", replacing: screen) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                (navigation.topViewController as? ChatViewController)?.focusComposer()
            }
        }, for: .primaryActionTriggered)
        view.addSubview(newChat)
        rightRule.backgroundColor = Self.ruleColor
        rightRule.isUserInteractionEnabled = false
        rightRule.isHidden = true
        rightRule.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rightRule)
        allChats.translatesAutoresizingMaskIntoConstraints = false
        allChats.accessibilityIdentifier = tabs ? "chat.strip.all" : "session-strip.all"
        allChats.isHidden = true
        allChats.isPointerInteractionEnabled = true
        allChats.setContentCompressionResistancePriority(.required, for: .horizontal)
        allChats.setContentHuggingPriority(.required, for: .horizontal)
        let allH = allChats.heightAnchor.constraint(equalToConstant: pillHeight)
        allChatsHeight = allH
        allH.isActive = true
        if tabs {
            PointerEffects.surface(allChats, pill: true)
        } else {
            allChats.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        allChats.addAction(UIAction { [weak self] _ in self?.showAll() }, for: .primaryActionTriggered)
        view.addSubview(allChats)
        row.axis = .horizontal
        row.spacing = 2
        rule.backgroundColor = Self.ruleColor
        rule.isUserInteractionEnabled = false
        rule.isHidden = !tabs && !Theme.isDesktop
        rule.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rule)
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(row)
        let pixel = HQShape.pixel(traitCollection.displayScale)
        let newH = newChat.heightAnchor.constraint(equalToConstant: tabs ? pillHeight : 44)
        newChatHeight = newH
        let newW = newChat.widthAnchor.constraint(equalToConstant: tabs ? max(28, pillHeight) : 44)
        newChatWidth = newW
        let scrollerLeading = scroller.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        let scrollerTop = scroller.topAnchor.constraint(equalTo: view.topAnchor)
        let scrollerBottom = scroller.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: tabs ? -4 : -4)
        let allTrailing = tabs ? allChats.trailingAnchor.constraint(equalTo: rightRule.leadingAnchor, constant: -6)
            : allChats.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18)
        if !tabs {
            phoneScrollerLeading = scrollerLeading
            phoneScrollerTop = scrollerTop
            phoneScrollerBottom = scrollerBottom
            phoneAllTrailing = allTrailing
        }
        var constraints: [NSLayoutConstraint] = [
            scrollerLeading,
            tabs ? scrollerToNew : scrollerToAll,
            allTrailing,
            allChats.centerYAnchor.constraint(equalTo: scroller.centerYAnchor),
            rightRule.trailingAnchor.constraint(equalTo: newChat.leadingAnchor, constant: -6),
            rightRule.centerYAnchor.constraint(equalTo: scroller.centerYAnchor),
            rightRule.widthAnchor.constraint(equalToConstant: pixel),
            rightRule.heightAnchor.constraint(equalToConstant: 12),
            scrollerTop,
            scrollerBottom,
            newChat.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: tabs ? -10 : -14),
            tabs ? newChat.centerYAnchor.constraint(equalTo: scroller.centerYAnchor)
                : newChat.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -1),
            newW,
            rule.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: pixel),
            newH,
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.centerYAnchor.constraint(equalTo: scroller.frameLayoutGuide.centerYAnchor),
        ]
        if tabs {
            constraints += [
                macDesktopFrost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                macDesktopFrost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                macDesktopFrost.topAnchor.constraint(equalTo: view.topAnchor),
                macDesktopFrost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                macIOSBand.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                macIOSBand.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                macIOSBand.topAnchor.constraint(equalTo: view.topAnchor),
                macIOSBand.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ]
        } else {
            constraints += [
                iosGlassBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                iosGlassBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                iosGlassBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
                iosGlassBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        applyLook()
        let center = NotificationCenter.default
        for name in [SessionStrip.listChanged, SessionStripPref.didChange, TileMaker.changed, ArtifactPins.didChange] {
            watches.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
        watches.append(center.addObserver(forName: HQAccessibility.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyLook() }
        })
        watches.append(center.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyLook()
                self.configureNewChat()
                self.allChatsHeight?.constant = self.pillHeight
                if self.tabs {
                    self.newChatHeight?.constant = self.pillHeight
                    self.newChatWidth?.constant = max(28, self.pillHeight)
                }
                self.shown = []      // the pills again, in the look's colours
                self.allCount = -1
                self.reload()
            }
        })
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (strip: SessionStripController, _) in
            strip.configureNewChat()
            strip.allChatsHeight?.constant = strip.pillHeight
            if strip.tabs {
                strip.newChatHeight?.constant = strip.pillHeight
                strip.newChatWidth?.constant = max(28, strip.pillHeight)
            }
            strip.shown = []
            strip.allCount = -1
            strip.reload()
        }
        reload()
    }

    private func configureNewChat() {
        var newConfig = UIButton.Configuration.hqGlass()
        newConfig.cornerStyle = .capsule
        newConfig.image = UIImage(systemName: "plus")
        newConfig.baseForegroundColor = ChatPalette.label
        newConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        if tabs {
            let size = (12 * max(1, ChatTitleView.macChrome)).rounded()
            newConfig = .plain()
            newConfig.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .medium))
            newConfig.baseForegroundColor = ChatPalette.label2
            newConfig.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 5, bottom: 3, trailing: 5)
        }
        newChat.configuration = newConfig
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    /// [bot-tabs-seamless] The Mac's iOS look bar switches between clear and frosted (`ChatViewController.updateTopBand`):
    /// the strip's backing follows in lockstep so both read as one continuous surface.
    func setTopBandShown(_ shown: Bool) {
        guard tabs, topBandShown != shown else { return }
        topBandShown = shown
        if isViewLoaded { applyLook() }
    }

    /// Desktop Look: exact match to `ThemeChrome.solidBar(frosted: true)` on Mac, and transparent over
    /// `ChatViewController.edgeStandIn` on iPhone/iPad (zero seam).
    /// iOS Look: `ChatViewController.barBand` / `barClear` on Mac; floating Liquid Glass capsule on iPhone/iPad.
    private func applyLook() {
        let desktop = Theme.isDesktop
        let solid = HQAccessibility.reduceTransparency
        if tabs {
            macDesktopFrost.isHidden = !desktop
            macDesktopFrost.effectView.isHidden = solid
            macDesktopFrost.color = ChatPalette.page
            macDesktopFrost.tintAlpha = solid ? 1 : DesktopFrost.barTintAlpha
            macIOSBand.isHidden = desktop
            macIOSBand.effect = solid ? nil : UIBlurEffect(style: .systemUltraThinMaterial)
            macIOSVeil.backgroundColor = solid ? ChatPalette.page : ChatPalette.popupVeil
            macIOSBand.alpha = topBandShown ? 1 : 0
            rule.backgroundColor = Self.ruleColor
            rightRule.backgroundColor = Self.ruleColor
            return
        }
        iosGlassBar.isHidden = desktop
        rule.isHidden = !desktop
        rule.backgroundColor = Self.ruleColor
        phoneScrollerLeading?.constant = desktop ? 2 : 18
        phoneScrollerTop?.constant = desktop ? 0 : 4
        phoneScrollerBottom?.constant = desktop ? -2 : -4
        phoneAllTrailing?.constant = desktop ? -10 : -22
        if !desktop, !Theme.solidChrome {
            if solid {
                iosGlassBar.effect = nil
                iosGlassBar.backgroundColor = ChatPalette.botBubble
                iosGlassBar.layer.borderWidth = HQShape.hairline
                iosGlassBar.layer.borderColor = ChatPalette.strokeSecondary.resolvedColor(with: traitCollection).cgColor
                iosGlassBar.cornerConfiguration = .capsule()
            } else if !(iosGlassBar.effect is UIGlassEffect) {
                iosGlassBar.effect = UIGlassEffect(style: .regular)
                iosGlassBar.backgroundColor = nil
                iosGlassBar.layer.borderWidth = 0
                iosGlassBar.layer.borderColor = nil
                iosGlassBar.cornerConfiguration = .capsule()
            }
        }
    }

    @objc private func scrolledByPerson() { personScrolled = true }

    /// The keyboard guide follows actual occlusion, including interactive dismissal; focus alone is not enough.
    /// Only change the height here: the existing pills and their scroll position remain untouched.
    func setKeyboardOccludesChat(_ occludes: Bool) {
        guard keyboardOccludesChat != occludes else { return }
        keyboardOccludesChat = occludes
        updateHeight(animated: false)
    }

    private func updateHeight(animated: Bool) {
        let height = keyboardOccludesChat ? 0 : availableHeight
        view.isHidden = height == 0
        screen?.setTopAccessoryHeight(height, insets: true, animated: animated)
    }

    private func reload() {
        guard let app, let screen else { return }
        let raw = SessionStripPref.isOn ? SessionStrip.entries(app: app, model: screen.session) : []
        // [bot-tabs-seamless] On the Mac, omit the redundant Bot Chat tab; the header right above names the bot.
        let entries = tabs ? SessionStripRules.macEntries(raw) : raw
        // The Mac: only for a bot with a chat besides its own (its sidebar already says whose chat this is).
        let others = SessionStripPref.isOn ? SessionStrip.count(app: app, model: screen.session) : 0
        let drawn = DeviceWord.isMac ? others > 0 || !entries.isEmpty : !entries.isEmpty
        let height: CGFloat = SessionStripPref.isOn && drawn ? stripHeight : 0
        showAllCount(height > 0 ? others : 0)
        app.setChatList(self, shown: appeared && (DeviceWord.isMac ? height > 0 : SessionStripPref.isOn))
        availableHeight = height
        updateHeight(animated: view.window != nil && !HQMotion.reduced)
        guard entries != shown else { return }
        shown = entries
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tabCaps = []
        fittedFor = -1
        pillEntries = [:]
        for (index, entry) in entries.enumerated() {
            if index > 0 { row.addArrangedSubview(middot()) }
            let pill = pill(entry, index: index)
            pillEntries[ObjectIdentifier(pill)] = entry
            row.addArrangedSubview(pill)
        }
        if tabs { DispatchQueue.main.async { [weak self] in self?.view.setNeedsLayout(); self?.view.layoutIfNeeded(); self?.placeFade() } }
        if height > 0, !placedCurrent || !personScrolled {
            placedCurrent = true
            DispatchQueue.main.async { [weak self] in self?.showCurrent() }
        }
    }

    /// [bot-chat-sessions] "All 14" at the strip's end, on the Mac, while the bot has chats besides its own.
    private func showAllCount(_ count: Int) {
        guard count != allCount else { return }
        allCount = count
        let shows = count > 0
        allChats.isHidden = !shows
        rightRule.isHidden = !tabs || !shows
        if tabs {
            scrollerToNew.isActive = !shows
            scrollerToAll.isActive = shows
        }
        guard shows else { return }
        var config: UIButton.Configuration = .plain()
        config.cornerStyle = .capsule
        config.contentInsets = tabs ? NSDirectionalEdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 6)
            : NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        config.attributedTitle = AttributedString("All \(count)", attributes: AttributeContainer([.font: tabs ? macFont(weight: .medium) : phoneFont(weight: .medium)]))
        let chevronSize: CGFloat = tabs ? (9.5 * max(1, ChatTitleView.macChrome)).rounded() : 9.5
        config.image = UIImage(systemName: "chevron.right",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: chevronSize, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 3
        config.baseForegroundColor = ChatPalette.label2
        allChats.configuration = config
        allChats.accessibilityLabel = "All chats, \(count)"
        allChats.toolTip = "All Chats"
    }

    private func showAll() {
        guard let screen, let app else { return }
        if !DeviceWord.isMac {
            PhoneBotChats.present(from: screen, app: app)
            return
        }
        #if targetEnvironment(macCatalyst)
        if let inspector = MacInspector.beside(screen) {
            inspector.show(.chats)
            AppLog.note("chat", "strip: All opened the Chats tab")
            return
        }
        #endif
        // No panel beside the chat (a window too small for two panes): Sessions, with this bot's chip picked.
        guard let root = MainTabController.current else { return }
        let profile = screen.session.profile.isEmpty ? "default" : screen.session.profile
        root.select(.sessions)
        let list = root.sessionsViewController
        list.navigationController?.popToRootViewController(animated: false)
        list.pickBot(profile)
    }

    /// The chat on screen sits a little in from the leading edge, the pill before it peeking (there is more that way).
    private func showCurrent() {
        view.layoutIfNeeded()
        guard let index = shown.firstIndex(where: \.current), index > 0,
              !scroller.isTracking, !scroller.isDecelerating else { return }
        let targetEntry = shown[index]
        guard let pillView = row.arrangedSubviews.first(where: { pillEntries[ObjectIdentifier($0)] == targetEntry }) else { return }
        let pill = row.convert(pillView.frame, to: scroller)
        let most = max(0, scroller.contentSize.width - scroller.bounds.width)
        let leading = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? max(0, most - (scroller.contentSize.width - pill.maxX - 56)) : pill.minX - 56
        scroller.setContentOffset(CGPoint(x: min(most, max(0, leading)), y: 0), animated: false)
    }

    /// [bot-tabs-seamless] The Mac's seamless plain-text item: borderless at rest on the top bar's own ground, a 6 pt
    /// dot before a chat at work or with a reply not read, and a soft hover fill under the pointer (`pill: true`:
    /// crisp 4 pt box in Desktop Look, capsule in iOS Look).
    private func tab(_ entry: SessionStripEntry) -> UIButton {
        let inset: CGFloat = 8
        let live = entry.working || entry.unread
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: inset, bottom: 3, trailing: inset)
        config.imagePadding = 6
        config.titleLineBreakMode = .byTruncatingTail
        let face = macFont(weight: live ? .medium : .regular)
        config.attributedTitle = AttributedString(entry.title, attributes: AttributeContainer([.font: face]))
        if entry.working {
            config.image = SessionStrip.dot(SessionStrip.workingColor, side: 6)
        } else if entry.unread {
            config.image = SessionStrip.dot(SessionStrip.unreadColor, side: 6)
        }
        config.baseForegroundColor = live ? ChatPalette.label : ChatPalette.label2
        let button = UIButton(configuration: config)
        button.isPointerInteractionEnabled = true
        button.heightAnchor.constraint(equalToConstant: pillHeight).isActive = true
        // Its width is shared out with the other tabs once the row is laid out (`fitTabs`).
        let cap = button.widthAnchor.constraint(lessThanOrEqualToConstant: Self.widestTab)
        cap.isActive = true
        tabCaps.append((button, cap))
        PointerEffects.surface(button, pill: true)
        button.toolTip = entry.detail.isEmpty ? entry.title : entry.title + "\n" + entry.detail
        if !entry.isBotChat { button.menu = tabMenu(entry) }
        return button
    }

    /// Subtle middot separating plain-text chat titles so multi-word names stay distinct without boxes.
    private func middot() -> UILabel {
        let dot = UILabel()
        dot.text = "·"
        dot.font = tabs ? macFont(weight: .semibold) : phoneFont(weight: .semibold)
        dot.textColor = ChatPalette.label3
        dot.isUserInteractionEnabled = false
        dot.isAccessibilityElement = false
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.setContentCompressionResistancePriority(.required, for: .horizontal)
        return dot
    }

    /// A right-click on a chat's tab: what the Sessions list's row offers that fits a tab.
    private func tabMenu(_ entry: SessionStripEntry) -> UIMenu {
        var items: [UIMenuElement] = [
            UIAction(title: "Open", image: UIImage(systemName: "bubble.left")) { [weak self] _ in
                guard let self, let screen = self.screen, let app = self.app else { return }
                SessionStrip.open(entry, from: screen, app: app)
            },
        ]
        if entry.unread {
            items.append(UIAction(title: "Mark as Read", image: UIImage(systemName: "envelope.open")) { [weak self] _ in
                self?.act(entry, failed: "") { store, chat in store.setUnread(chat, false) }
            })
        }
        items.append(UIAction(title: entry.pinned ? "Unpin" : "Pin", image: UIImage(systemName: entry.pinned ? "pin.slash" : "pin")) { [weak self] _ in
            self?.act(entry, failed: entry.pinned ? "Couldn’t unpin that chat." : "Couldn’t pin that chat.") { store, chat in
                try await store.setPinned(chat, !entry.pinned)
            }
        })
        var tail: [UIMenuElement] = []
        if !entry.working, !entry.unread, !entry.pinned {
            tail.append(UIAction(title: "Remove from Tabs", image: UIImage(systemName: "xmark")) { [weak self] _ in
                guard let screen = self?.screen else { return }
                SessionStrip.forget(entry.id, profile: screen.session.profile.isEmpty ? "default" : screen.session.profile)
            })
        }
        tail.append(UIAction(title: "Archive", image: UIImage(systemName: "archivebox")) { [weak self] _ in
            self?.act(entry, failed: "Couldn’t archive that chat.") { store, chat in try await store.setArchived(chat, true) }
        })
        items.append(UIMenu(options: .displayInline, children: tail))
        return UIMenu(children: items)
    }

    private func act(_ entry: SessionStripEntry, failed: String, _ work: @escaping @MainActor (SessionStore, SessionSummary) async throws -> Void) {
        guard let app, let store = app.sessionStore, let chat = app.sessions.first(where: { $0.id == entry.id }) else { return }
        Task { @MainActor [weak self] in
            do { try await work(store, chat) } catch {
                AppLog.note("chat", "strip: a tab's action failed, \(error.localizedDescription)")
                if !failed.isEmpty { self?.screen?.showNotice(failed) }
            }
        }
    }

    private func pill(_ entry: SessionStripEntry, index: Int) -> UIButton {
        let button = tabs ? tab(entry) : phoneTab(entry)
        button.accessibilityIdentifier = tabs ? "chat.strip.pill.\(index)" : "strip.session.\(entry.id)"
        button.accessibilityLabel = [entry.title, entry.isBotChat ? "Bot Chat" : nil, entry.working ? "Working" : nil,
                                     entry.unread ? "New reply" : nil].compactMap { $0 }.joined(separator: ", ")
        if entry.current { button.accessibilityTraits.insert(.selected) }
        button.addAction(UIAction { [weak self] _ in
            guard let self, let screen = self.screen, let app = self.app else { return }
            Haptics.play(.selection)
            SessionStrip.open(entry, from: screen, app: app)
        }, for: .primaryActionTriggered)
        return button
    }

    private func phoneTab(_ entry: SessionStripEntry) -> UIButton {
        let live = entry.working || entry.unread
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        config.titleLineBreakMode = .byTruncatingTail
        config.attributedTitle = AttributedString(entry.title, attributes: AttributeContainer([.font: phoneFont(weight: live ? .medium : .regular)]))
        config.baseForegroundColor = live ? ChatPalette.label : ChatPalette.label2
        if entry.working { config.image = SessionStrip.dot(SessionStrip.workingColor, side: 6) }
        else if entry.unread { config.image = SessionStrip.dot(SessionStrip.unreadColor, side: 6) }
        config.imagePadding = 6
        let button = UIButton(configuration: config)
        button.heightAnchor.constraint(equalToConstant: pillHeight).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let limit = button.widthAnchor.constraint(lessThanOrEqualToConstant: 300)
        limit.isActive = true
        tabCaps.append((button, limit))
        return button
    }


}
