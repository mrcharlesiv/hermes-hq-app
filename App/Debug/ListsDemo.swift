// DEBUG harness for the lists module: fake services with a realistic roster, a fake sign-in driver, and a
// placeholder chat. Launch with -HQDemoLists (Bots/Sessions) or -HQDemoSignIn (sign-in screen).
// Options: -HQDemoAddress <text> prefills the address; -HQDemoStill YES turns the scripted live updates off;
// -HQDemoEmpty YES starts with no bots (skeleton, then the empty state); -HQDemoMatrixHeads YES drops every saved head, so
// each bot wears the dot-matrix head its name picks (screenshots of the new default).

#if DEBUG
import SwiftUI
import UIKit

enum ListsDemo {
    static func makeRoot() -> UIViewController {
        let services = FakeAppServices()
        services.onSignOut = { swapRoot(to: makeSignIn()) }
        var makeChat: ((ChatSessionModel) -> UIViewController)!
        #if targetEnvironment(macCatalyst)
        var tabOrder: [String: [String]] = [:]
        var shownBefore: [String: Set<String>] = [:]
        #endif
        makeChat = { model in
            // [mac-layout] `-HQDemoRealChat`: a real chat screen (generated messages, the bot's face in the title) in
            // place of the placeholder, so the chat's bar can be judged in the Mac's root.
            guard UserDefaults.standard.bool(forKey: "HQDemoRealChat") else { return DemoChatViewController(model: model) }
            let session = UserDefaults.standard.bool(forKey: "HQDemoHelpers")
                ? DemoHelpersSession(count: 24, title: model.title) : FakeChatSession(count: 24, title: model.title)
            session.openedHead = model.head
            let chat = ChatViewController(session: session)
            // `-HQDemoSend <text>` (with -HQDemoHoldStep): a turn running, so the bar's Working… shows.
            if let text = UserDefaults.standard.string(forKey: "HQDemoSend") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { session.send(text) }
            }
            let head = HeadView(side: 34)
            head.configure(raw: model.head, profile: model.profile)
            chat.titleAccessoryView = head
            ChatMenus.install(on: chat, account: nil) {}
            chat.makeInfoContent = { [weak session] in
                session.map { ChatInfoSheet.makeContent(model: $0, account: nil, modelName: "claude-opus-4-5") }
            }
            #if targetEnvironment(macCatalyst)
            if UserDefaults.standard.bool(forKey: "HQDemoSessionTabs") {
                let profile = model.profile.isEmpty ? "default" : model.profile
                let currentId = (model as? FakeChatModel)?.sessionId
                let onBotChat = currentId == nil
                chat.makeTopStrip = { [weak chat] in
                    guard let chat else { return nil }
                    return SessionStripController(screen: chat, demo: .init(
                        entries: {
                            let bot = services.bots.first { $0.id == profile }
                            let raw = SessionStripRules.entries(bot: bot, sessions: services.sessions, profile: profile,
                                                                currentId: currentId, onBotChat: onBotChat,
                                                                kept: shownBefore[profile] ?? [], recent: false)
                            shownBefore[profile, default: []].formUnion(raw.filter { !$0.isBotChat }.map(\.id))
                            let settled = SessionStripRules.settled(raw, order: tabOrder[profile] ?? [])
                            tabOrder[profile] = settled.order
                            return settled.entries
                        },
                        count: {
                            let bot = services.bots.first { $0.id == profile }
                            return SessionStripRules.chats(bot: bot, sessions: services.sessions, profile: profile).count
                        },
                        open: { entry, screen in
                            guard !entry.current, let navigation = screen.navigationController else { return }
                            let nextModel: ChatSessionModel
                            if entry.isBotChat {
                                guard let bot = services.bots.first(where: { $0.id == profile }) else { return }
                                nextModel = services.chat(for: bot)
                            } else {
                                guard let summary = services.sessions.first(where: { $0.id == entry.id }) else { return }
                                nextModel = services.chat(for: summary)
                            }
                            let next = makeChat(nextModel)
                            next.hidesBottomBarWhenPushed = true
                            next.navigationItem.largeTitleDisplayMode = .never
                            var stack = navigation.viewControllers
                            if let index = stack.firstIndex(where: { $0 === screen }) { stack.remove(at: index) }
                            stack.append(next)
                            navigation.setViewControllers(stack, animated: false)
                            AppModel.markPane(navigation)
                        }
                    ))
                }
            }
            #endif
            return chat
        }
        let root = MainTabController(services: services, makeChat: makeChat)
        // Screenshot controls (the simulator can't be tapped from scripts): -HQDemoTab 1, -HQDemoShowHidden YES,
        // -HQDemoSearch <text>, -HQDemoOpen <bot id>, -HQDemoAccount YES, -HQDemoScrollEnd YES,
        // -HQDemoScrollBy <points> (both lists), -HQDemoOfflineAfter <s> / -HQDemoReconnectingAfter <s> (the link drops).
        let defaults = UserDefaults.standard
        for (key, state) in [("HQDemoOfflineAfter", ConnectionState.offline(reason: "")), ("HQDemoReconnectingAfter", .reconnecting(attempt: 1))]
        where defaults.object(forKey: key) != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + defaults.double(forKey: key)) {
                services.connection = state
                services.onConnectionChange?()
            }
        }
        if defaults.object(forKey: "HQDemoScrollBy") != nil {
            let points = CGFloat(defaults.double(forKey: "HQDemoScrollBy"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for list in [root.botsViewController.collectionView!, root.sessionsViewController.collectionView!] {
                    list.setContentOffset(CGPoint(x: 0, y: list.contentOffset.y + points), animated: true)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let bots = root.botsViewController
            if defaults.integer(forKey: "HQDemoTab") == 1 { root.select(.sessions) }
            if defaults.bool(forKey: "HQDemoShowHidden") { bots.setSection(.hidden, collapsed: false) }
            if let text = defaults.string(forKey: "HQDemoSearch") { bots.search(text) }
            if let id = defaults.string(forKey: "HQDemoOpen") { root.select(.bots); bots.open(id) }   // as a click on its sidebar head
            if defaults.bool(forKey: "HQDemoAccount") { bots.showAccount() }
            if defaults.bool(forKey: "HQDemoScrollEnd") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    for list in [bots.collectionView!, root.sessionsViewController.collectionView!] {
                        let section = list.numberOfSections - 1
                        guard section >= 0, list.numberOfItems(inSection: section) > 0 else { continue }
                        let last = IndexPath(item: list.numberOfItems(inSection: section) - 1, section: section)
                        list.scrollToItem(at: last, at: .bottom, animated: false)
                        list.layoutIfNeeded()
                        list.scrollToItem(at: last, at: .bottom, animated: false)
                    }
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        return AppRoot.make(root, window: nil)   // [mac] the demo in the Mac's real two-pane root
        #else
        return root
        #endif
    }

    static func makeSignIn() -> UIViewController {
        let address = UserDefaults.standard.string(forKey: "HQDemoAddress") ?? ""
        return SignInScreen.make(driver: FakeSignInDriver(), initialAddress: address) {
            swapRoot(to: makeRoot())
        }
    }

    private static func swapRoot(to controller: UIViewController) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve) {
            window.rootViewController = controller
        }
    }
}

// MARK: - Fake services

/// [mac] `-HQDemoPages YES`: the demo also gets the real Jobs, Kanban or Artifacts and More tabs, on a gateway nobody
/// answers (their pages show "Can't reach your gateway"), so the whole tab set can be looked at without a fixture.
extension FakeAppServices: PagesServices {
    var gateway: (any GatewayClient)? {
        guard UserDefaults.standard.bool(forKey: "HQDemoPages") else { return nil }
        if let demoGateway { return demoGateway }
        let stored = StoredAccount(url: "http://127.0.0.1:9", username: "demo")
        let client = LiveGatewayClient(stored: stored, transport: HTTPTransport(cookies: true),
                                       vault: AccountVault(service: "ai.hermes.hqnative.demo", signedOutKey: "hqn.demo.signedOut"),
                                       verified: true)
        demoGateway = client
        return client
    }
    var onSignOutPages: (() -> Void)? { get { nil } set {} }
    var readOnlyGateway: Bool { true }
}

final class FakeAppServices: AppServices {
    var account: GatewayAccount? = GatewayAccount(
        id: "nous:user_demo@https://mac-mini.tail1234.ts.net", baseURL: URL(string: "https://mac-mini.tail1234.ts.net")!,
        kind: .nous, username: nil, label: "mac-mini")
    var bots: [Bot]
    var sessions: [SessionSummary]
    var connection: ConnectionState = .ready
    var onBotsChange: (() -> Void)?
    var onSessionsChange: (() -> Void)?
    var onConnectionChange: (() -> Void)?
    var onSignOut: (() -> Void)?
    private var step = 0
    private var timer: Timer?
    fileprivate var demoGateway: LiveGatewayClient?

    init(now: Date = Date()) {
        let empty = UserDefaults.standard.bool(forKey: "HQDemoEmpty")
        bots = empty ? [] : Self.roster(now: now)
        if UserDefaults.standard.bool(forKey: "HQDemoMatrixHeads") { bots = bots.map { var bot = $0; bot.head = nil; return bot } }
        sessions = empty ? [] : Self.sessionList(now: now)
        // [moods] `-HQDemoMoods YES`: every bot's face acts out a mood of its own, in BotMood's order down the list.
        if UserDefaults.standard.bool(forKey: "HQDemoMoods") {
            for (index, bot) in bots.enumerated() { BotMoods.shared.show(BotMood.allCases[index % BotMood.allCases.count], for: bot.id) }
        }
        if empty {
            connection = .connecting
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.connection = .ready
                self?.onConnectionChange?()
                self?.onBotsChange?()
            }
        }
        if !UserDefaults.standard.bool(forKey: "HQDemoStill") && !empty {
            timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.liveStep() }
            }
        }
    }

    func refreshBots() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, let i = self.bots.firstIndex(where: { $0.id == "home" }) else { return }
            self.bots[i].preview = "Front door locked. Porch light on until 11 PM."
            self.bots[i].lastActive = Date()
            self.onBotsChange?()
        }
    }

    func refreshSessions() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.onSessionsChange?() }
    }

    func chat(for bot: Bot) -> ChatSessionModel { FakeChatModel(title: bot.name, profile: bot.id, head: bot.head, sessionId: nil) }

    func chat(for session: SessionSummary) -> ChatSessionModel {
        if let i = sessions.firstIndex(where: { $0.id == session.id }), sessions[i].unread {
            sessions[i].unread = false
            onSessionsChange?()
        }
        return FakeChatModel(title: session.title, profile: session.profile, head: bots.first { $0.id == session.profile }?.head, sessionId: session.id)
    }

    func markRead(_ bot: Bot) {
        guard let i = bots.firstIndex(where: { $0.id == bot.id }), bots[i].unread else { return }
        bots[i].unread = false
        onBotsChange?()
    }

    func signOut() {
        timer?.invalidate()
        onSignOut?()
    }

    /// Scripted activity, so animated updates can be watched: a bot starts working, replies, goes unread.
    private func liveStep() {
        step += 1
        func edit(_ id: String, _ change: (inout Bot) -> Void) {
            if let i = bots.firstIndex(where: { $0.id == id }) { change(&bots[i]) }
        }
        switch step % 4 {
        case 1: edit("wren") { $0.isWorking = true }
        case 2:
            edit("wren") { $0.isWorking = false; $0.unread = true; $0.lastActive = Date()
                $0.preview = "Booked the 9:30 with the dentist and added it to your calendar." }
        case 3: edit("book-club") { $0.isWorking = false; $0.preview = "Three new routines are in the shared folder."; $0.lastActive = Date() }
        default: edit("book-club") { $0.isWorking = true }
        }
        onBotsChange?()
    }

    // MARK: data

    static func head(_ color: String, _ form: String, _ look: String = "slits", seed: Int = 1, v: Int = 6) -> JSONValue {
        ["v": .number(Double(v)), "theme": "shape", "color": .string(color), "form": .string(form), "look": .string(look),
         "seed": .number(Double(seed)), "tile": "none"]
    }

    static func roster(now: Date) -> [Bot] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func bot(_ id: String, _ name: String, preview: String? = nil, role: String? = nil, minutes: Double?,
                 working: Bool = false, unread: Bool = false, pinned: Bool = false, pinOrder: Int? = nil,
                 section: String? = nil, hidden: Bool = false, head: JSONValue? = nil) -> Bot {
            // `-HQDemoNeutralNames YES`: made-up names only, for pictures shared outside (no names like the owner's bots).
            let neutral = ["Inbox": "Mail", "Ivy": "Ava", "Otto": "Writer", "Book Club": "Designer", "App": "Builder",
                           "Wren": "Travel", "Northwind": "Website", "Finance": "Budget", "Bike Shop": "Quotes",
                           "Maple Revenue Operator": "Sales"]
            let name = UserDefaults.standard.bool(forKey: "HQDemoNeutralNames") ? (neutral[name] ?? name) : name
            return Bot(id: id, name: name, role: role, preview: preview, lastActive: minutes.map(ago), isWorking: working,
                unread: unread, pinned: pinned, pinOrder: pinOrder, sectionName: section, hidden: hidden,
                canonicalSessionId: "bot-chat-\(id)", head: head)
        }
        let baseRoster: [Bot] = [
            bot("default", "Hermes", preview: "Here’s today’s summary: three replies need you, the rest is filed.",
                minutes: 4, unread: true, pinned: true, pinOrder: 0,
                head: ["v": 4, "theme": "shape", "color": "ink", "form": "round", "look": "ovals", "mouth": "open", "tile": "color"]),
            bot("inbox", "Inbox", preview: "Sorted 14 new emails into Today and Later.", minutes: 12, working: true,
                pinned: true, pinOrder: 1, head: head("sky", "blob", "ovals", seed: 416723)),
            bot("ivy", "Ivy", preview: "Sounds good — I’ll pick it up after lunch.", minutes: 60 * 26, unread: true, pinned: true),
            bot("otto", "Otto", preview: "The launch post draft is ready for a look. I kept it under 280 characters and added two image ideas.",
                minutes: 35, section: "Marketing", head: head("coral", "square", "dots")),
            bot("book-club", "Book Club", preview: "Rehearsal notes are in the shared folder.", minutes: 60 * 50,
                section: "Marketing", head: head("lilac", "cloud", "ovals")),
            bot("home", "Home", preview: "Thermostat set to 68° for tonight.", minutes: 90, head: head("peach", "triangle")),
            bot("app", "App", preview: "Build 239 passed every check. Ready to ship when you are — release-build239 is tagged.",
                minutes: 60 * 6, section: "Builds", head: head("lilac", "hex")),
            bot("wren", "Wren", preview: "Your flight on Friday is on time.", minutes: 60 * 24 * 3, head: head("butter", "round")),
            bot("northwind", "Northwind", role: "Website and bookings", minutes: nil, head: head("butter", "triangle")),
            bot("finance", "Finance", preview: "Cron · Daily spend report", minutes: 60 * 24 * 9),
            bot("bike-shop", "Bike Shop", preview: "Quote sent to the client.", minutes: 60 * 24 * 20, hidden: true),
            bot("maple-revenue-operator", "Maple Revenue Operator", preview: "Q3 pipeline review is done.", minutes: 60 * 24 * 40,
                hidden: true),
        ]
        // [Mac AAA 2026-11-16] `-HQDemoManyBots <n>`: the roster padded to n bots (some with long names, some working
        // or unread, across three sections), for the sidebar and rail at many bots.
        let many = UserDefaults.standard.integer(forKey: "HQDemoManyBots")
        let words = ["Research", "Quarterly Revenue Reconciliation Assistant", "Notes", "Calendar", "Recipes",
                     "Customer Support Escalations and Follow-Ups", "Garden", "Photos", "Reading List", "Travel Desk"]
        let extra: [Bot] = many > 12 ? (0..<(many - 12)).map { i in
            bot("extra-\(i)", "\(words[i % words.count])\(i >= words.count ? " \(i / words.count + 1)" : "")",
                preview: "Step \(i + 1) of the weekly review is done.", minutes: Double(30 * (i + 1)),
                working: i % 7 == 3, unread: i % 5 == 1, section: ["Work", "Home", nil][i % 3])
        } : []
        return extra.isEmpty ? baseRoster : baseRoster + extra
    }

    static func sessionList(now: Date) -> [SessionSummary] {
        let profiles = ["default", "inbox", "otto", "home", "app", "wren", "finance", "ivy"]
        let titles = ["Plan the week", "Fix the login redirect", "Draft the newsletter", "Compare flight options",
                      "Kitchen remodel budget", "Summarise the board meeting", "Refactor the export script",
                      "Birthday gift ideas", "Tax documents checklist", "Write the release notes",
                      "Research standing desks", "Clean up the photo library", "Reply to the landlord",
                      "Workout plan for March", "Debug the slow dashboard", "Translate the menu"]
        let previews = ["Here’s a first pass. Tell me what to change.", "Done — the redirect now keeps the page you were on.",
                        "I found three options under $400; the second has the best reviews.", "Saved to Notes.",
                        "Two questions before I start: which account, and by when?", nil]
        // A fixed spread over three weeks, newest first.
        let minutesAgo: [Double] = [3, 25, 70, 160, 300, 520, 60 * 20, 60 * 26, 60 * 30, 60 * 44, 60 * 52, 60 * 70,
                                    60 * 75, 60 * 96, 60 * 100, 60 * 120, 60 * 125, 60 * 140, 60 * 150, 60 * 170,
                                    60 * 190, 60 * 200, 60 * 230, 60 * 260, 60 * 280, 60 * 300, 60 * 330, 60 * 360,
                                    60 * 380, 60 * 400, 60 * 420, 60 * 440, 60 * 460, 60 * 480, 60 * 500, 60 * 520,
                                    60 * 540, 60 * 560, 60 * 600, 60 * 700]
        let sessionTabsDemo = UserDefaults.standard.bool(forKey: "HQDemoSessionTabs")
        let chats = minutesAgo.enumerated().map { i, minutes -> SessionSummary in
            let title = (sessionTabsDemo && i == 16) ? "Quarterly budget" : (i == 7 ? "" : titles[i % titles.count])
            var row = SessionSummary(id: "session-\(i)", profile: profiles[i % profiles.count],
                                     title: title, preview: previews[i % previews.count],
                                     lastActive: now.addingTimeInterval(-minutes * 60), source: "desktop",
                                     unread: [1, 4, 9].contains(i) || (sessionTabsDemo && i == 16), isRunning: i == 0)
            if sessionTabsDemo && i == 8 { row.pinned = true }
            return row
        }
        // Background and cron runs: not listed nor counted (spec 02 §9.2), so these never show.
        let runs = [
            SessionSummary(id: "run-tool", profile: "app", title: "Tool run", preview: nil,
                           lastActive: now.addingTimeInterval(-60), source: "tool", unread: true, isRunning: false),
            SessionSummary(id: "cron_daily_spend", profile: "finance", title: "Daily spend report", preview: nil,
                           lastActive: now.addingTimeInterval(-120), source: "cron", unread: true, isRunning: false),
        ]
        return chats + runs
    }
}

// MARK: - Fake chat

final class FakeChatModel: ChatSessionModel {
    let title: String
    let profile: String
    let head: JSONValue?
    let sessionId: String?
    var messages: [ChatMessage] = []
    var isRunning = false
    var hasOlder = false
    var isLoadingOlder = false
    var connection: ConnectionState = .ready
    var statusText: String?
    var onChange: ((ChatChange) -> Void)?

    init(title: String, profile: String, head: JSONValue?, sessionId: String? = nil) {
        self.title = title; self.profile = profile; self.head = head; self.sessionId = sessionId
    }
    func start() {}
    func stopObserving() {}
    func loadOlder() {}
    func send(_ text: String) {}
    func stop() {}
}

/// Stands in for the chat module: the bot's head and name, so opening a row can be seen and timed.
final class DemoChatViewController: UIViewController {
    private let model: ChatSessionModel
    init(model: ChatSessionModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = model.title.isEmpty ? "Untitled session" : model.title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.page
        let head = HeadView(side: 96)
        head.configure(raw: model.head, profile: model.profile)
        let label = UILabel()
        label.text = "The chat opens here.\n(Placeholder in the lists demo.)"
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = HQFont.preferred(.subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = HQPalette.label2
        let stack = UIStackView(arrangedSubviews: [head, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            head.widthAnchor.constraint(equalToConstant: 96), head.heightAnchor.constraint(equalToConstant: 96),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
    }
}

// MARK: - Fake sign-in

/// Probe answers by the address typed: "nous" → Nous only, "password"/"fleet" → password only, "nowhere" →
/// unreachable, anything else → both. Password sign-in accepts fleet / fleet; Nous succeeds unless "notowner".
final class FakeSignInDriver: SignInDriving {
    func probe(_ address: String) async -> SignInOptions {
        try? await Task.sleep(for: .milliseconds(350))
        let text = address.lowercased()
        if text.contains("nowhere") {
            return SignInOptions(reachable: false, offersNous: false, offersPassword: false,
                                 message: "Couldn’t check this address yet. Check that it’s typed right; you can still try to sign in.")
        }
        if text.contains("nous") { return SignInOptions(reachable: true, offersNous: true, offersPassword: false) }
        if text.contains("password") || text.contains("fleet") {
            return SignInOptions(reachable: true, offersNous: false, offersPassword: true)
        }
        return SignInOptions(reachable: true, offersNous: true, offersPassword: true)
    }

    func signInWithPassword(address: String, username: String, password: String) async throws {
        try await Task.sleep(for: .milliseconds(800))
        if address.contains("unreachable") { throw SignInError("unreachable") }   // [a11y] a failure that marks the address
        guard username == "fleet", password == "fleet" else { throw SignInError("auth-rejected") }
    }

    func signInWithNous(address: String) async throws {
        try await Task.sleep(for: .milliseconds(1000))
        if address.contains("notowner") { throw SignInError("not-owner") }
    }
}
#endif
