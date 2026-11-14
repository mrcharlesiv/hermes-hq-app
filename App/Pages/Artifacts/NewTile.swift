// [dashboard] New Tile (owner 2026-11-03: "an easy button" for live dashboards that size and work properly): pick a bot,
// say what the tile should show, and the bot makes it in a new chat while you stay on the Dashboard. The bot follows
// the add-on's dashboard-tile skill (hermes-hq-push 0.9.30: a page that fills its tile at any size, checked at every
// size, kept fresh by a scheduled job; 0.9.50: the bot gives the tile's data and the skill's kit draws it, so the
// words here leave the how to the skill, whichever one that bot has). When its reply names the page, the tile pins
// itself; a reply without one (a question, a refusal) offers its chat instead.

import SwiftUI
import UIKit

@MainActor @Observable
final class NewTileModel {
    @ObservationIgnored weak var services: PagesServices?
    var bot: String
    var what = ""
    @ObservationIgnored var onMake: ((Bot, String) -> Void)?
    @ObservationIgnored weak var controller: UIViewController?

    /// What a tile can be: a tap fills the field (the person's own words still come first). The first six show; More
    /// Ideas the rest (owner 2026-11-03: "I also want more suggested tile ideas").
    static let ideas: [(words: String, symbol: String)] = [
        ("Revenue this week, with a chart by day", "chart.bar.fill"),
        ("Today’s calendar and the next meeting", "calendar"),
        ("Unread emails that need a reply", "envelope.badge"),
        ("Weather here for the next 12 hours", "cloud.sun.fill"),
        ("My open tasks, due soonest first", "checklist"),
        ("Jobs that ran today, and any that failed", "clock.badge.checkmark"),
        ("Deals closing this month and their total", "target"),
        ("Spending this month against last month", "dollarsign.circle"),
        ("My stocks and crypto, today’s change", "chart.line.uptrend.xyaxis"),
        ("Messages that mention me in Slack", "bubble.left.and.exclamationmark.bubble.right"),
        ("GitHub pull requests waiting on me", "arrow.triangle.pull"),
        ("Website and server status", "server.rack"),
        ("My next trip: flights, hotel and times", "airplane"),
        ("Birthdays and follow-ups due this week", "person.2"),
        ("Steps, sleep and workouts this week", "figure.run"),
        ("Top headlines in my industry today", "newspaper"),
        ("A countdown to a date that matters", "hourglass"),
        ("Quote or word of the day", "quote.bubble"),
    ]
    static let firstIdeas = 6

    init(services: PagesServices, bot: String?) {
        self.services = services
        let bots = services.bots
        self.bot = bot.flatMap { id in bots.first { $0.id == id }?.id } ?? bots.first?.id ?? ""
    }

    var bots: [Bot] { services?.bots ?? [] }
    var canMake: Bool { !what.pgTrim.isEmpty && bots.contains { $0.id == bot } }

    func make() {
        guard canMake, let chosen = bots.first(where: { $0.id == bot }) else { return }
        PagesHaptics.success()
        controller?.dismiss(animated: true)
        onMake?(chosen, what.pgTrim)
    }
}

enum NewTileSheet {
    static func make(services: PagesServices, bot: String?, onMake: @escaping (Bot, String) -> Void) -> UIViewController {
        let model = NewTileModel(services: services, bot: bot)
        model.onMake = onMake
        let host = NewTileHostController(model: model)
        let nav = ChatSheet.wrap(host, title: "New Tile")
        host.installClose()
        SheetEditGuard.install(on: nav)   // [Mac UI check 2026-11-13] typed words ask before Cancel, Escape or ⌘W drop them
        nav.sheetPresentationController?.selectedDetentIdentifier = .large
        return nav
    }
}

final class NewTileHostController: UIHostingController<HQScaledRoot<NewTileView>>, EditingPage {
    let model: NewTileModel
    private var makeItem: UIBarButtonItem!

    init(model: NewTileModel) {
        self.model = model
        super.init(rootView: HQScaledRoot(NewTileView(model: model)))
        model.controller = self
        title = "New Tile"
        makeItem = UIBarButtonItem(title: "Make", primaryAction: UIAction { [weak self] _ in self?.model.make() })
        makeItem.style = .prominent
        makeItem.accessibilityIdentifier = "tile.new.make"
        navigationItem.rightBarButtonItem = makeItem
        updateMake()
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var keyCommands: [UIKeyCommand]? { (super.keyCommands ?? []) + (model.canMake ? [.save("Make", #selector(makeFromKeyboard))] : []) }
    override var canBecomeFirstResponder: Bool { true }
    @objc private func makeFromKeyboard() { model.make() }

    /// [Mac UI check 2026-11-13] Words of your own ask before they go; an idea picked as it stands doesn't.
    var hasChanges: Bool {
        let what = model.what.pgTrim
        return !what.isEmpty && !NewTileModel.ideas.contains { $0.words == what }
    }

    func installClose() {
        let close = UIBarButtonItem.hqClose(DeviceWord.isMac ? .cancel : .close, action: UIAction { [weak self] _ in
            guard let self else { return }
            self.view.endEditing(true)
            self.confirmLeaving { [weak self] in self?.dismiss(animated: true) }
        })
        close.accessibilityIdentifier = "sheet.close"
        navigationItem.hqPlaceFormClose(close)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "tile.new.sheet"
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = model.what
            _ = model.bot
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.updateMake(); self?.observe() }
        }
    }

    private func updateMake() {
        makeItem.setProminentEnabled(model.canMake)
        if let navigation = navigationController { EditingGuard.refreshLock(navigation) }
    }
}

struct NewTileView: View {
    @Bindable var model: NewTileModel
    @FocusState private var focused: Bool
    @State private var allIdeas = false

    var body: some View {
        Form {
            Section {
                TextField("What should it show?", text: $model.what, axis: .vertical)
                    .lineLimit(2...6)
                    .focused($focused)
                    .accessibilityIdentifier("tile.new.what")
            } header: { HQSectionLabel { Text("On the Tile") } } footer: { HQSectionFooter {
                Text("The bot makes a live tile that fits any size and keeps it up to date. It pins itself here when it’s ready.")
            } }
            if model.what.pgTrim.isEmpty {
                Section {
                    let shown = allIdeas ? NewTileModel.ideas : Array(NewTileModel.ideas.prefix(NewTileModel.firstIdeas))
                    ForEach(shown, id: \.words) { idea in
                        Button {
                            PagesHaptics.selection()
                            model.what = idea.words
                        } label: {
                            Label { Text(idea.words).foregroundStyle(Color.hqLabel) } icon: {
                                Image(systemName: UIImage(systemName: idea.symbol) != nil ? idea.symbol : "sparkles").foregroundStyle(Color.hqTint)
                            }
                        }
                    }
                    if !allIdeas {
                        Button {
                            PagesHaptics.selection()
                            withAnimation(HQMotion.reduced ? nil : .default) { allIdeas = true }
                        } label: {
                            Label { Text("More Ideas").foregroundStyle(Color.hqTintText) } icon: {
                                Image(systemName: "ellipsis.circle").foregroundStyle(Color.hqTint)
                            }
                        }
                        .accessibilityIdentifier("tile.new.more-ideas")
                    }
                } header: { HQSectionLabel { Text("Ideas") } }
            }
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 4) {
                        ForEach(model.bots, id: \.id) { bot in
                            Button {
                                if model.bot != bot.id { PagesHaptics.selection() }
                                model.bot = bot.id
                            } label: {
                                VStack(spacing: 6) {
                                    HeadImage(raw: bot.head, profile: bot.id, size: HQFont.scaled(44))
                                        .frame(width: HQFont.scaled(44), height: HQFont.scaled(44))
                                        .allowsHitTesting(false)
                                        .padding(3)
                                    Text(bot.name)
                                        .font(Font.hq(.caption))
                                        .foregroundStyle(model.bot == bot.id ? Color.hqTintText : Color.hqLabel2)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(width: HQFont.scaled(76))   // [ui-sizing] × UI Scale, as its caption: names broke mid-word at 150 %
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(model.bot == bot.id ? Color.hqTint.opacity(0.14) : .clear))
                                // The whole card takes the tap: the face is a UIKit view that took it for itself, so
                                // only the name chose the bot (owner 2026-11-03).
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(bot.name)
                            .accessibilityAddTraits(model.bot == bot.id ? .isSelected : [])
                            .accessibilityIdentifier("tile.new.bot.\(bot.id)")
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            } header: { HQSectionLabel { Text("Made By") } } footer: { HQSectionFooter {
                Text("Pick a bot that can reach the data, for example one signed in to your mail or calendar.")
            } }
        }
        .hqGroupedPage()
        .onAppear { focused = true }
    }
}

/// One tile being made: the new chat it's asked in, watched until the bot's turn ends, then the page it names pinned.
/// Lives while the bot works (`active`). Opening its chat hands the chat's changes to that screen, which reports the turn's
/// end here (`turnEnded`).
@MainActor
final class TileMaker {
    private(set) static var active: [TileMaker] = []
    /// Posted when a tile starts or finishes (the Dashboard's header says "Making a tile…" meanwhile).
    static let changed = Notification.Name("hq.tile.makers")
    /// [tiles] A tile's bot finished a Change… (`userInfo["id"]`: the pin; `"done"`: the bot said it's done, so the tile
    /// is marked for a moment): its picture is drawn again.
    static let tileChanged = Notification.Name("hq.tile.changed")

    let chat: any ChatSessionModel
    let bot: Bot
    let accountId: String
    /// What the person asked for (the Tiles page's "making" row says it).
    private(set) var what = ""
    /// [tiles] Change…: the tile being changed (its pin id and name), nil for a New Tile.
    private(set) var changing: (id: String, name: String)?
    /// [live-tiles] A button on a live tile asked this (`window.hermes.send`): sent hidden, no bubble, as on the desktop.
    private(set) var acting = false
    /// The making row's title: what was asked, or for a change, the tile and the change.
    var rowTitle: String {
        if acting, let changing { return "Updating \(changing.name): \(what)" }
        return changing.map { "\($0.name): \(what)" } ?? what
    }
    /// The row's identity on the Tiles page.
    let id = UUID().uuidString
    private weak var page: UIViewController?
    /// [live-tiles] A button's turn ended (the opened tile reads its page again).
    var ended: (() -> Void)?
    private var sawRunning = false
    private var asked = Date()
    private var watching = true

    static func making(accountId: String) -> Int { makers(accountId: accountId).count }
    static func changing(accountId: String) -> Int { makers(accountId: accountId).filter { $0.changing != nil }.count }
    static func makers(accountId: String) -> [TileMaker] { active.filter { $0.accountId == accountId && $0.watching } }
    /// [tiles] The bot working on this tile now (a Change…, or one of its buttons), if one is.
    static func working(on pinId: String, accountId: String) -> TileMaker? {
        makers(accountId: accountId).first { $0.changing?.id == pinId }
    }
    /// [tiles] What the tile says on itself while its bot works on it.
    var tileWords: String { acting ? "Updating…" : "\(bot.name) is changing it…" }
    /// [tiles] Change… (not a button's turn).
    var isChange: Bool { changing != nil && !acting }

    /// The row's second line: the step the bot is on now ("💻 python3 check_tile.py …"), else its status words.
    var stepWords: String {
        if let step = (chat as? ChatActivityProviding)?.liveStep { return step.statusWords }
        if let words = chat.statusText, !words.isEmpty { return words }
        return chat.isRunning ? "Working…" : "Starting…"
    }

    /// What the bot is asked: the skill, the person's words, the hand-over line the app looks for, and the rules in
    /// short for a computer whose add-on predates the skill.
    nonisolated static func prompt(_ what: String) -> String {
        """
        Make me a live tile for my Hermes HQ Dashboard showing: \(what)

        Use the hermes-hq-push:dashboard-tile skill (open it with skill_view first) and follow it: make the tile \
        the way it says, with the real numbers in, run its check_tile.py until it passes, and look at the pictures \
        it makes. Keep it up to date with a scheduled job on a sensible schedule, and tell me how often.

        If that skill isn't there: one self-contained .html file that fills its window exactly at any size from \
        about 160×160 to 800×600 (100vw/100vh, text in em from a size that grows with the window, charts in SVG \
        with a viewBox, no scrolling, nothing loaded from the network), with a light and a dark look.

        When it's ready, end your reply with the page alone on its own line: MEDIA:/absolute/path/to/the/tile.html \
        (the app pins it to my Dashboard by itself, so don't tell me how to pin it)
        """
    }

    /// What the chat's bubble shows instead of the whole instruction.
    nonisolated static func display(_ what: String) -> String { "New tile: \(what)" }

    /// [tiles] Change…: the same file changed in place, its name, job id and the rest of its look kept, and the job that
    /// rewrites it changed too (or the next update would undo the change).
    nonisolated static func changePrompt(path: String, what: String) -> String {
        """
        Change my Hermes HQ Dashboard tile \(path): \(what)

        Use the hermes-hq-push:dashboard-tile skill (open it with skill_view first). Change that same tile in place, \
        the way the skill says: keep its path, its name (unless I asked for a new one), the job that keeps it fresh \
        (its <meta name="hq-tile-job">) and everything I didn't ask to change. If a \
        scheduled job or a refresh script rewrites this tile, change it too so the next update keeps the change. Run \
        check_tile.py until it passes and look at the pictures it makes.

        If you need something from me first (which data, a sign-in), ask me and leave out the MEDIA line. When it's \
        done, say in a line or two what you changed, then end your reply with the page alone on its own line: \
        MEDIA:\(path)
        """
    }

    nonisolated static func changeDisplay(name: String, what: String) -> String { "Change tile \(name): \(what)" }

    /// [live-tiles] A tile's button, as its bot gets it: the page's own words, and which file to update so the tile shows
    /// the outcome (the bot answers a widget by rewriting its page, as the desktop's `::preview` widgets do).
    nonisolated static func actionPrompt(path: String, name: String, prompt: String) -> String {
        """
        \(prompt)

        (Asked from my Hermes HQ tile “\(name)”, \(path). Do it, then give that tile its new data in place so it \
        shows the result (the way the hermes-hq-push:dashboard-tile skill says); keep its look, its name and its \
        job. Reply in a line or two.)
        """
    }

    /// [tile-versions] After a roll back, for a tile a job keeps up to date: the page is already back as it was, and the
    /// job (or its refresh script) may still write the newer look, so the tile's bot brings it in line.
    nonisolated static func rolledBackPrompt(path: String, name: String, version: Int) -> String {
        """
        I rolled my Hermes HQ tile “\(name)” (\(path)) back to its version \(version). The file is already restored and \
        looks the way I want: don't change its look, layout, <title> or <meta> tags.

        If a scheduled job or a refresh script rewrites this tile, make sure its next run keeps this version's look and \
        fills in the data this version shows (change the script or the job's prompt if it would bring the newer look \
        back). Then refresh the tile's data once so it's current. Reply in a line or two.
        """
    }

    /// [tile-versions] The hidden turn after a roll back (`rolledBackPrompt`): the tile says "Updating…" meanwhile.
    @discardableResult
    static func rolledBack(_ pin: ArtifactPin, path: String, bot: Bot, version: Int, accountId: String, chat: any ChatSessionModel,
                           from page: UIViewController?) -> TileMaker {
        let maker = TileMaker(chat: chat, bot: bot, accountId: accountId, page: page)
        maker.changing = (pin.id, pin.name)
        maker.acting = true
        maker.path = path
        maker.rawPrompt = rolledBackPrompt(path: path, name: pin.name, version: version)
        active.append(maker)
        maker.begin("its updates follow Version \(version)")
        return maker
    }

    /// [live-tiles] A live tile's button (`window.hermes.send` / `data-hermes-send`): the prompt goes to the tile's bot
    /// with no bubble, the Tiles page shows "Updating <tile>…" while it works, and the tile is read again when it ends.
    @discardableResult
    static func act(_ pin: ArtifactPin, path: String, bot: Bot, prompt: String, accountId: String, chat: any ChatSessionModel,
                    from page: UIViewController?) -> TileMaker {
        let maker = TileMaker(chat: chat, bot: bot, accountId: accountId, page: page)
        maker.changing = (pin.id, pin.name)
        maker.acting = true
        maker.path = path
        active.append(maker)
        maker.begin(prompt)
        return maker
    }

    @discardableResult
    static func change(_ pin: ArtifactPin, path: String, bot: Bot, what: String, accountId: String, chat: any ChatSessionModel,
                       from page: UIViewController) -> TileMaker {
        let maker = TileMaker(chat: chat, bot: bot, accountId: accountId, page: page)
        maker.changing = (pin.id, pin.name)
        maker.path = path
        active.append(maker)
        // [tile-versions] The tile as it is before the bot edits it, kept if it isn't a version yet.
        TileVersions.shared.keepSoon(pinId: pin.id, accountId: accountId, kind: .outside, what: nil)
        maker.begin(what)
        return maker
    }

    /// The newest page a reply named: `MEDIA:/…/x.html` first, else any absolute .html path.
    nonisolated static func pagePath(in text: String) -> String? {
        func last(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.matches(in: text, range: range).last, let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        return last(#"MEDIA:\s*`?((?:/|~/)[^\s`"'<>]+?\.html?)`?(?=\s|$)"#)
            ?? last(#"(?:^|[\s`(\"'])((?:/|~/)[^\s`"'<>()]+?\.html?)(?=[\s`)\"'.,:;]|$)"#)
    }

    @discardableResult
    static func start(bot: Bot, what: String, accountId: String, chat: any ChatSessionModel, from page: UIViewController) -> TileMaker {
        let maker = TileMaker(chat: chat, bot: bot, accountId: accountId, page: page)
        active.append(maker)
        maker.begin(what)
        return maker
    }

    private init(chat: any ChatSessionModel, bot: Bot, accountId: String, page: UIViewController?) {
        self.chat = chat
        self.bot = bot
        self.accountId = accountId
        self.page = page
        dashboardPage = ArtifactPins.of(accountId: accountId).currentPage
    }

    /// [dashboard] The Dashboard page New Tile was asked from: the tile goes there, whatever page is shown when it lands.
    private let dashboardPage: String
    /// [tiles] The changed tile's file (Change…).
    private var path = ""
    /// [tile-versions] The whole prompt of a hidden turn that isn't a button's (the roll back's).
    private var rawPrompt: String?

    private func begin(_ what: String) {
        self.what = what
        chat.onChange = { [weak self] _ in self?.check() }
        chat.start()
        if acting, let changing {
            // [live-tiles] Hidden, as the desktop sends a widget's prompt: the tile updating is the answer.
            let prompt = rawPrompt ?? Self.actionPrompt(path: path, name: changing.name, prompt: what)
            if let activity = chat as? ChatActivityProviding { activity.sendHidden(prompt, display: nil) } else { chat.send(prompt) }
            AppLog.note("pages", "live tile button asked of \(AppLog.tag(bot.id)) (\(what.count) chars)")
            NotificationCenter.default.post(name: Self.changed, object: nil)
            // [tile-versions] A hidden ask that never started (the send was refused, the gateway is away) has no turn to
            // end: the tile would say "Updating…" until the app next opened. It gives up, and the tile is drawn again.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.startGrace) { [weak self] in
                guard let self, self.watching, !self.sawRunning, !self.chat.isRunning else { return }
                AppLog.note("pages", "live tile ask of \(AppLog.tag(self.bot.id)) never started; letting the tile go")
                self.finish(lastTry: true)
            }
            return
        }
        let prompt = changing == nil ? Self.prompt(what) : Self.changePrompt(path: path, what: what)
        let display = changing.map { Self.changeDisplay(name: $0.name, what: what) } ?? Self.display(what)
        if let live = chat as? LiveChatSession {
            live.send(prompt, display: display)
        } else {
            chat.send(prompt)
        }
        AppLog.note("pages", "\(changing == nil ? "new tile" : "tile change") asked of \(AppLog.tag(bot.id)) (\(what.count) chars)")
        NotificationCenter.default.post(name: Self.changed, object: nil)
        if let page {
            PagesHUD.show(changing == nil ? "\(bot.name) is making your tile" : "\(bot.name) is changing your tile",
                          symbol: changing == nil ? "sparkles" : "wand.and.sparkles", from: page)
        }
    }

    private func check() {
        guard watching else { return }
        if chat.isRunning { sawRunning = true; return }
        guard sawRunning else {
            // [tile-versions] A hidden ask refused before it ran: done, with its problem.
            if acting, turnError() != nil { finish(lastTry: true) }
            return
        }
        finish()
    }

    /// How long a hidden ask (a tile's button, the turn after a roll back) may take to start before the tile stops
    /// saying "Updating…".
    static let startGrace: TimeInterval = 40

    /// The page the bot's reply to this ask names, if that reply is in the chat yet.
    private func handedOverPath() -> String? {
        guard (chat as? ChatAttachmentSending)?.mediaContext != nil else { return nil }
        let replies = chat.messages.filter { $0.role == .assistant && ($0.timestamp ?? .distantFuture) >= asked.addingTimeInterval(-5) }
        let text = replies.flatMap(\.parts).compactMap { part -> String? in if case .text(let words) = part { words } else { nil } }
            .joined(separator: "\n")
        return Self.pagePath(in: text)
    }

    /// How long a New Tile whose turn ended without a page waits for the reply to show up. A phone that was away hears
    /// the end before it has the reply: the watchdog settles the gone runtime first and the tail read lands a moment
    /// later (owner 2026-11-10: "Otto Needs You… didn't hand over a tile" with the reply's MEDIA line 0.3 s behind; two of
    /// the three earlier misses that week were the same).
    static let replyGrace: TimeInterval = 12
    /// The turn ended with no page yet: re-checked as the chat changes and on a few timers until `replyGrace`.
    private var waitingForReply = false

    /// The first problem a turn after the ask ended on ("The model is overloaded"), nil when none did.
    private func turnError() -> String? {
        chat.messages.last { $0.error != nil && ($0.timestamp ?? .distantFuture) >= asked.addingTimeInterval(-5) }?.error
    }

    private func finish(lastTry: Bool = false) {
        // A New Tile or a Change… whose reply hasn't named its page yet waits a moment for it (a button's turn doesn't
        // name one, and a turn that failed has nothing more to come).
        if !acting, !lastTry, handedOverPath() == nil, turnError() == nil {
            guard !waitingForReply else { return }
            waitingForReply = true
            AppLog.note("pages", "\(changing == nil ? "new tile" : "tile change") from \(AppLog.tag(bot.id)): turn ended before its reply was read; waiting up to \(Int(Self.replyGrace)) s")
            for delay in [1.0, 3.0, 6.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.watching else { return }
                    self.finish()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.replyGrace) { [weak self] in
                guard let self, self.watching else { return }
                self.finish(lastTry: true)
            }
            return
        }
        watching = false
        defer {
            Self.active.removeAll { $0 === self }
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
        let problem = turnError()
        if let changing {
            if acting {
                // The bot changed the file in place: the tile is drawn again whatever the reply said.
                NotificationCenter.default.post(name: Self.tileChanged, object: nil, userInfo: ["id": changing.id])
                AppLog.note("pages", "live tile button by \(AppLog.tag(bot.id)) ended")
                ended?()
                // The tile shows it; a turn that failed is said, as "Updating…" goes.
                if problem != nil, let page, page.viewIfLoaded?.window != nil {
                    PagesHaptics.error()
                    PagesHUD.show("Couldn’t Update \(changing.name)", symbol: "exclamationmark.triangle", from: page)
                }
                return
            }
            // [tiles] Change…: drawn again whatever the reply said (the bot may have changed the file before stopping),
            // the ring marking it only once the bot said it's done; a problem or a reply without the page offers the
            // chat, and a problem offers to ask again (owner 2026-11-10: "greatly improved").
            let done = problem == nil && handedOverPath() != nil
            NotificationCenter.default.post(name: Self.tileChanged, object: nil, userInfo: ["id": changing.id, "done": done])
            // [tile-versions] Whatever the reply said: when the page's look changed, that's the next version.
            TileVersions.shared.keepSoon(pinId: changing.id, accountId: accountId, kind: .changed, what: what)
            if let problem {
                AppLog.note("pages", "tile change by \(AppLog.tag(bot.id)) failed")
                Haptics.play(.error)
                offerChat(title: "Couldn’t Change \(changing.name)",
                          "\(bot.name) stopped with a problem: \(Self.firstLine(problem)) Open the chat to see what happened, or ask again.",
                          retry: { [what] page in page.changeTile(id: changing.id, what: what) })
                return
            }
            guard done else {
                AppLog.note("pages", "tile change by \(AppLog.tag(bot.id)) ended without naming the page\(waitingForReply ? " (waited \(Int(Self.replyGrace)) s)" : "")")
                offerChat("\(bot.name) didn’t say the change is done. It may have a question for you. Open the chat to see what it said.")
                return
            }
            Haptics.play(.success)
            AppLog.note("pages", "tile change by \(AppLog.tag(bot.id)) ended")
            if let page, page.viewIfLoaded?.window != nil { PagesHUD.show("\(changing.name) Changed", symbol: "checkmark", from: page) }
            return
        }
        guard let path = handedOverPath(), let context = (chat as? ChatAttachmentSending)?.mediaContext else {
            AppLog.note("pages", "new tile from \(AppLog.tag(bot.id)): the reply named no page\(waitingForReply ? " (waited \(Int(Self.replyGrace)) s)" : "")")
            if let problem {
                Haptics.play(.error)
                offerChat(title: "Couldn’t Make the Tile",
                          "\(bot.name) stopped with a problem: \(Self.firstLine(problem)) Open the chat to see what happened.")
            } else {
                offerChat("\(bot.name) didn’t hand over a tile yet. Open the chat to see what it said.")
            }
            return
        }
        let pins = ArtifactPins.of(accountId: context.accountId)
        let name = (path as NSString).lastPathComponent
        let record = PinActions.record(path: path, name: name, kind: .file, context: context, sessionId: context.storedSessionId,
                                       sessionTitle: chat.title)
        if !pins.isPinned(record), !pins.toggle(record) {
            // Audit 863 (08b-6): every pin is taken; the page is made, in the chat, and said.
            Haptics.play(.error)
            AppLog.note("pages", "new tile from \(AppLog.tag(bot.id)) not pinned: \(ArtifactPins.limit) pinned")
            offerChat("\(PinActions.fullWords). \(PinActions.fullDetail) Your new page is in the chat.")
            return
        }
        pins.setPage(dashboardPage, id: ArtifactPin.key(profile: record.profile, value: record.value))
        // [tile-versions] A new tile's page is its Version 1.
        TileVersions.shared.keepSoon(pinId: ArtifactPin.key(profile: record.profile, value: record.value), accountId: context.accountId,
                                     kind: .made, what: what)
        Haptics.play(.success)
        AppLog.note("pages", "new tile from \(AppLog.tag(bot.id)) pinned")
        if let page, page.viewIfLoaded?.window != nil { PagesHUD.show("Your New Tile Is Pinned", symbol: "pin.fill", from: page) }
    }

    /// A problem's first line, ending in a full stop (the alert's words go on after it).
    nonisolated static func firstLine(_ problem: String) -> String {
        let line = problem.split(whereSeparator: \.isNewline).first.map(String.init)?.pgTrim ?? ""
        let short = line.count > 160 ? String(line.prefix(159)) + "…" : line
        guard let last = short.last else { return "" }
        return ".!?…".contains(last) ? short : short + "."
    }

    /// The reply had no page, or the turn failed: a question or a problem for the person, in the chat. `retry`: Try
    /// Again (the same ask, in a new chat).
    private func offerChat(title: String? = nil, _ words: String, retry: ((ArtifactsViewController) -> Void)? = nil) {
        guard let page, page.viewIfLoaded?.window != nil else { return }
        let alert = UIAlertController(title: title ?? "\(bot.name) Needs You", message: words, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        let open = UIAlertAction(title: "Open Chat", style: .default) { [weak self, weak page] _ in
            guard let self, let page else { return }
            (page as? ArtifactsViewController)?.openTileChat(self.chat)
        }
        alert.addAction(open)
        if let retry, let tiles = page as? ArtifactsViewController {
            alert.addAction(UIAlertAction(title: "Try Again", style: .default) { [weak tiles] _ in
                if let tiles { retry(tiles) }
            })
        }
        alert.preferredAction = open
        page.present(alert, animated: true)
    }

    /// A chat screen let go of the chat (Back from the tile's chat): the maker watches it again, or the finished tile
    /// would never pin.
    static func screenClosed(_ chat: any ChatSessionModel) {
        guard let maker = active.first(where: { $0.chat === chat && $0.watching }) else { return }
        chat.onChange = { [weak maker] _ in maker?.check() }
        chat.start()
        maker.check()
    }

    /// A chat screen's turn ended (that screen took the chat's changes when it opened): a tile asked in it pins now.
    static func turnEnded(_ chat: any ChatSessionModel) {
        guard let maker = active.first(where: { $0.chat === chat && $0.watching }) else { return }
        maker.sawRunning = true
        maker.finish()
    }
}

/// [tiles] A tile being made, on the Tiles page (owner 2026-11-03: "it says making a tile but idk where to see it doing
/// anything"): what was asked, the bot and the step it's on now, a spinner and a chevron (a tap opens the chat). A plain
/// cell drawn as a card: a list cell took the list's own row look over the card.
@MainActor
final class TileMakingCell: UICollectionViewCell {
    private let card = UIView()
    private let icon = UIImageView(image: UIImage(systemName: "sparkles"))
    private let title = UILabel()
    private let detail = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        title.numberOfLines = 2
        title.adjustsFontForContentSizeCategory = true
        detail.numberOfLines = 1
        detail.adjustsFontForContentSizeCategory = true
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .small)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        let words = UIStackView(arrangedSubviews: [title, detail])
        words.axis = .vertical
        words.spacing = 3
        let row = UIStackView(arrangedSubviews: [icon, words, spinner, chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.setCustomSpacing(10, after: spinner)
        [card, row].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        contentView.addSubview(card)
        card.addSubview(row)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            icon.widthAnchor.constraint(equalToConstant: 24),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "tile.making"
        accessibilityHint = "Opens the chat"
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(what: String, detail words: String, changing: Bool = false) {
        // Colours, fonts and the card's shape read each time: the theme's come along (as the tiles: their corner, and
        // their edge, 1 pt in the Desktop Look).
        card.layer.cornerRadius = HQShape.radius(14, .card)
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = Theme.isDesktop ? 1 : 0.5
        card.layer.borderColor = HQPalette.stroke.resolvedColor(with: traitCollection).cgColor
        card.backgroundColor = isHighlighted ? HQPalette.fill3 : HQPalette.card
        icon.tintColor = HQPalette.tint
        icon.image = UIImage(systemName: changing ? "wand.and.sparkles" : "sparkles")
        let font = HQFont.preferred(.subheadline)
        title.font = UIFont(descriptor: font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor, size: 0)
        title.textColor = HQPalette.label
        title.text = what
        detail.font = HQFont.preferred(.footnote)
        detail.textColor = HQPalette.label2
        detail.text = words
        chevron.tintColor = HQPalette.label3
        spinner.color = HQPalette.label2
        spinner.startAnimating()
        accessibilityLabel = (changing ? "Changing a tile: " : "Making a tile: ") + what
        accessibilityValue = words
    }

    override var isHighlighted: Bool {
        didSet { card.backgroundColor = isHighlighted ? HQPalette.fill3 : HQPalette.card }
    }
}
