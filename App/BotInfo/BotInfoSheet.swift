// Bot Info (spec 1x-settings §6.1; owner: pages inside one sheet, never "a pop up on top of a pop up"): a page sheet
// with its own navigation stack — the bot's header, About, Organize (Pinned, Show in Bots, Section) — and Edit
// Bot / Edit Head as pages pushed inside it. Other streams add groups through `BotInfoHooks`.
// [tabs] Tester feedback, 2026-11-01: "it's getting really busy there, maybe tabs for organization?" Under the header
// (head, name, status, tiles) four tabs: About (the description, Brain, Computer), Chats (Conversations, Group
// Chats), Artifacts, and Settings (Notifications, Organize, Delete). Each opening starts on About.
// [page-tabs] Owner 2026-11-01, "that page is very long": About still ran a screen and a half, so Brain is a tab of
// its own (About · Brain · Chats · Artifacts · Settings), and About keeps the description, the handle and Computer.

import SwiftUI
import UIKit

/// Groups other streams append to Bot Info (Skills & Instructions, Notifications…).
@MainActor enum BotInfoHooks {
    /// [tabs] On About, after the handle (Computer).
    static var sections: [(Bot, UIViewController) -> AnyView?] = []
    /// [groups] Groups placed after Conversations (Group Chats, the web's order); [tabs] on Chats.
    static var afterConversations: [(Bot, UIViewController) -> AnyView?] = []
    /// [tabs] The Artifacts tab's groups (none: no Artifacts tab).
    static var artifacts: ((Bot, UIViewController) -> AnyView?)?
}

/// [tabs] Bot Info's tabs.
enum BotInfoTab: String, CaseIterable, Identifiable {
    case about, brain, chats, artifacts, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .about: "About"
        case .brain: "Brain"
        case .chats: "Chats"
        case .artifacts: "Artifacts"
        case .settings: "Settings"
        }
    }
}

/// The page Bot Info opens on: itself, Edit Bot, or the face editor (Change Face in the bot's menu), each over Bot Info
/// so Cancel and Save land on it.
enum BotInfoStart { case info, editBot, face }

@MainActor enum BotInfoSheet {
    /// Presents Bot Info for `bot` (the chat stream opens it from the chat header with this too).
    /// `tab`: the tab it opens on (About unless a caller needs another).
    static func present(bot: Bot, from presenter: UIViewController, services: any AppServices, start: BotInfoStart = .info,
                        tab: BotInfoTab = .about) {
        guard let settings = services as? SettingsServices, settings.botEditing != nil else { return }
        BotFaces.shared.refresh(bot.id)       // [photoheads] another device may have changed this bot's picture
        let info = BotInfoController(botId: bot.id, fallback: bot, services: services)
        info.model.tab = tab
        let navigation = UINavigationController(rootViewController: info)
        #if targetEnvironment(macCatalyst)
        navigation.delegate = BotInfoPageBars.shared   // [mac] Mac polish #2
        #endif
        SheetStyle.apply(navigation, from: presenter)   // [m9/ipad] a centred form sheet in two panes (§4.8)
        let guardian = SheetEditGuard(navigation: navigation)
        navigation.presentationController?.delegate = guardian
        objc_setAssociatedObject(navigation, &guardKey, guardian, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        switch start {
        case .info: break
        case .editBot: navigation.pushViewController(EditBotController(info: info), animated: false)
        case .face: info.openFace(animated: false)
        }
        presenter.present(navigation, animated: true)
    }

    nonisolated(unsafe) private static var guardKey: UInt8 = 0
}

#if targetEnvironment(macCatalyst)
/// [mac] Mac polish #2: Bot Info's pages take the main window's solid page bar (`MacWindow.pageBar`) as they land. The
/// iOS look's soft edge drew a white band over the top of the page once it scrolled, the header's Talk, Memo, Screen
/// and Mute ghosting through it.
private final class BotInfoPageBars: NSObject, UINavigationControllerDelegate {
    static let shared = BotInfoPageBars()

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController,
                              animated: Bool) {
        MacWindow.pageBar(viewController)
    }
}
#endif

/// A page with unsaved changes asks before the sheet closes (Discard Changes / Keep Editing).
@MainActor protocol EditingPage: UIViewController {
    var hasChanges: Bool { get }
    /// A Save is on its way to the gateway: the page holds until it answers (no Cancel, no swipe, no discard question;
    /// stress round 1: "Discard Changes" during a slow photo upload closed the page and the picture was saved anyway).
    var isSaving: Bool { get }
    func confirmLeaving(_ leave: @escaping () -> Void)
}

extension EditingPage {
    /// A page that never saves on its own (another stream's, a test's) is never "saving".
    var isSaving: Bool { false }

    func confirmLeaving(_ leave: @escaping () -> Void) {
        guard !isSaving else { return }
        guard hasChanges else { leave(); return }
        EditingGuard.askToDiscard(from: self, leave: leave)
    }

    /// Swipe-down is held while any page on the sheet's stack has changes (verify round 3: an untouched Edit Head on a
    /// dirty Edit Bot cleared the dirty page's lock, and a swipe threw its typing away); swipe-back only while this
    /// page has them (going back to the page below keeps that page's changes).
    func updateModalLock() {
        guard let navigation = navigationController else { return }
        EditingGuard.refreshLock(navigation)
        navigation.interactivePopGestureRecognizer?.isEnabled = !hasChanges && !isSaving
        if isSaving { EditingGuard.dropQuestion() }
    }
}

@MainActor enum EditingGuard {
    /// The sheet holds while a page on its stack has changes (also re-read when a page under the editors shows again: a
    /// discarded Edit Bot leaves the stack still marked dirty).
    static func refreshLock(_ navigation: UINavigationController) {
        navigation.isModalInPresentation = dirtyPage(in: navigation) != nil || isSaving(in: navigation)
    }

    /// A page on the sheet's stack is in the middle of a Save.
    static func isSaving(in navigation: UINavigationController) -> Bool {
        navigation.viewControllers.contains { ($0 as? (any EditingPage))?.isSaving == true }
    }

    /// The discard question on screen, if any.
    private(set) static weak var question: UIAlertController?

    /// Takes the discard question down (a Save has started: there is nothing left to discard).
    static func dropQuestion() {
        guard let question, question.presentingViewController != nil else { return }
        question.dismiss(animated: false)
        self.question = nil
    }

    /// The top-most page with unsaved changes on a sheet's stack.
    static func dirtyPage(in navigation: UINavigationController) -> (any EditingPage)? {
        navigation.viewControllers.reversed().lazy.compactMap { $0 as? (any EditingPage) }.first { $0.hasChanges }
    }

    /// Discard Changes / Keep Editing, from the page on screen (a page under it can't present).
    static func askToDiscard(from page: UIViewController, leave: @escaping () -> Void) {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Discard Changes", style: .destructive) { [weak page] _ in
            // Never out from under a Save that started while the question was up.
            if let navigation = page?.navigationController, isSaving(in: navigation) { return }
            leave()
        })
        sheet.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            // From the Cancel button, as system editors do; the page's top edge when there is none.
            if let cancel = page.navigationItem.leftBarButtonItem {
                popover.sourceItem = cancel
            } else {
                popover.sourceView = page.view
                popover.sourceRect = CGRect(x: page.view.bounds.midX, y: 0, width: 0, height: 0)
            }
        }
        question = sheet
        page.present(sheet, animated: true)
    }
}

final class SheetEditGuard: NSObject, UIAdaptivePresentationControllerDelegate {
    weak var navigation: UINavigationController?
    init(navigation: UINavigationController) { self.navigation = navigation }

    /// A swipe down held by a dirty page anywhere on the stack: asked on the page showing, closed only on Discard.
    /// While a page is saving the swipe does nothing at all: the page holds until the gateway answers.
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        guard let navigation, !EditingGuard.isSaving(in: navigation) else { return }
        guard EditingGuard.dirtyPage(in: navigation) != nil, let top = navigation.topViewController else { return }
        EditingGuard.askToDiscard(from: top) { [weak navigation] in navigation?.dismiss(animated: true) }
    }
}

@MainActor @Observable
final class BotInfoModel {
    let botId: String
    let fallback: Bot
    var aboutExpanded = false
    var online = true
    /// [tabs] The tab showing.
    var tab: BotInfoTab = .about
    /// [ui-sizing 2026-11-09] The header has scrolled up under the bar (owner: "option B", the header folds away): the
    /// tabs stay pinned under the bar and the bar's title is the bot's face and name. The host swaps the title.
    var headerFolded = false {
        didSet { if headerFolded != oldValue { onHeaderFolded?(headerFolded) } }
    }
    @ObservationIgnored var onHeaderFolded: ((Bool) -> Void)?
    @ObservationIgnored let services: any AppServices
    @ObservationIgnored weak var host: UIViewController?
    /// [tester batch 3] The bot's own Default Model (its chooser, and the save).
    let modelChange: BotDefaultModel

    init(botId: String, fallback: Bot, services: any AppServices) {
        self.botId = botId
        self.fallback = fallback
        self.services = services
        modelChange = BotDefaultModel(services: services)
    }

    var settings: (any SettingsServices)? { services as? SettingsServices }
    var editing: (any BotEditing)? { settings?.botEditing }
    var bot: Bot { editing?.bot(id: botId) ?? fallback }
    var description: String? { editing?.botDescription(bot) }
    var handle: String { RosterRules.handle(forProfile: botId) }
    var sectionName: String {
        guard let editing, let id = editing.shownSectionId(of: bot) else { return "Unassigned" }
        return editing.sectionRecords.first { $0.id == id }?.name ?? "Unassigned"
    }

    /// In no section this device knows. By id, not by name: a section named like the built-in one checked both (audit
    /// 05-14).
    var isUnassigned: Bool {
        guard let editing, let id = editing.shownSectionId(of: bot) else { return true }
        return !editing.sectionRecords.contains { $0.id == id }
    }

    var gatewayTitle: String { settings?.gateways.accounts.first(where: \.isCurrent)?.title ?? "" }

    /// [tabs] The Artifacts tab's groups, made once for the sheet (they read the bot's artifacts as they open).
    @ObservationIgnored private var artifactsGroups: AnyView??

    func artifactsView() -> AnyView? {
        if let made = artifactsGroups { return made }
        guard let host else { return nil }
        let made = BotInfoHooks.artifacts?(bot, host)
        artifactsGroups = .some(made)
        return made
    }

    /// [tabs] The tabs this sheet has (no Artifacts without a gateway's pages to read).
    var tabs: [BotInfoTab] {
        BotInfoTab.allCases.filter { $0 != .artifacts || artifactsView() != nil }
    }

    func select(_ next: BotInfoTab) {
        guard next != tab else { return }
        tab = next
        AppLog.trace("botinfo", "tab \(next.rawValue)")
    }

    /// `action` is a short, fixed word for the log (never the user-facing `title`, which carries the bot's own name).
    func run(_ title: String, action: String = "write", _ work: @escaping () async throws -> Void, done: (() -> Void)? = nil) {
        let start = ContinuousClock.now
        let tag = AppLog.tag(botId)
        Task { [weak self] in
            do {
                try await work()
                AppLog.trace("botinfo", "bot \(tag) \(action) ok in \(AppLog.ms(since: start)) ms")
                done?()
            } catch {
                AppLog.note("botinfo", "bot \(tag) \(action) failed after \(AppLog.ms(since: start)) ms: \(type(of: error))")
                FailureAlert.present(error, fallbackTitle: title, from: self?.host) { [weak self] in self?.run(title, action: action, work, done: done) }
            }
        }
    }

    func setPinned(_ pinned: Bool) {
        guard let editing else { return }
        let bot = self.bot
        Haptics.play(.selection)
        run(pinned ? "Couldn’t Pin \(bot.name)" : "Couldn’t Unpin \(bot.name)", action: pinned ? "pin" : "unpin") { try await editing.setPinned(bot, pinned) }
    }

    func setShown(_ shown: Bool) {
        guard let editing else { return }
        let bot = self.bot
        Haptics.play(.selection)
        run(shown ? "Couldn’t Show \(bot.name)" : "Couldn’t Hide \(bot.name)", action: shown ? "show" : "hide") { try await editing.setHidden(bot, !shown) }
    }

    func move(to section: String?) {
        guard let editing else { return }
        let bot = self.bot
        run("Couldn’t Move \(bot.name)", action: "move to section", { try await editing.move(bot, toSection: section) }) {
            Haptics.play(.success)
        }
    }

    // MARK: Bots extras (parity §3: Conversations, Model, Notifications, Duplicate, Delete)

    /// Up to three of the bot's own recent chats (read when the sheet opens).
    var recent: [SessionSummary] = []
    var recentLoaded = false

    var isDefault: Bool { editing?.isDefault(bot) ?? (botId == "default") }
    var modelInfo: (model: String?, provider: String?) { editing?.modelInfo(bot) ?? (nil, nil) }
    var hasChat: Bool { bot.canonicalSessionId != nil }
    var mute: BotMute? { BotMuteCenter.shared.mute(of: botId) }
    var muteValue: String { BotMutes.value(mute) }

    func loadRecent() async {
        guard let editing else { recentLoaded = true; return }
        let rows = await editing.recentChats(bot)
        recent = rows
        recentLoaded = true
        AppLog.trace("botinfo", "bot \(AppLog.tag(botId)) recent chats loaded: \(rows.count)")
    }

    /// Closes the sheet, then works on the Bots list (its tab selected, anything over it closed).
    private func closeThen(_ work: @escaping (BotsViewController) -> Void) {
        guard let host else { return }
        host.dismiss(animated: true) {
            if let list = BotExtras.botsList() { work(list) }
        }
    }

    /// Bot Chat: the bot's own chat (already on screen when Info opened from its title: the sheet just closes).
    func openBotChat() {
        let id = botId
        if let chat = MainTabController.current?.chatOnShow, chat.session.profile == id,   // [m9/ipad] either layout
           (chat.session as? LiveChatSession)?.isBotChat == true {
            host?.dismiss(animated: true)
            return
        }
        closeThen { $0.open(id) }
    }

    func openRecent(_ session: SessionSummary) {
        let services = self.services
        closeThen { $0.push(services.chat(for: session)) }
    }

    func newChat() {
        let bot = self.bot
        closeThen { $0.openNewChat(bot) }
    }

    /// All Chats: the sheet closes and Sessions lists this bot's chats (its chip picked; no chip for a hidden bot).
    func openAllChats() {
        let id = botId
        guard let host else { return }
        host.dismiss(animated: true) {
            guard let root = MainTabController.current else { return }
            root.select(.sessions)
            let list = root.sessionsViewController
            list.navigationController?.popToRootViewController(animated: false)
            list.pickBot(id)
        }
    }

    /// Memo: the chat's voice memo, as the row menu's tile starts it.
    func memo() {
        let bot = self.bot
        closeThen { list in
            guard let node = BotMenuHooks.item(.memo, bot, list), case .action(let run) = node.kind else { list.open(bot.id); return }
            run()
        }
    }

    var memoAvailable: Bool { BotMenuHooks.providers[.memo] != nil }

    /// [talk] Talk: the sheet closes, the bot's chat opens, then a voice conversation starts (docs/spec/3x-talk.md §5.5).
    func talk() {
        let bot = self.bot
        closeThen { list in
            guard let node = BotMenuHooks.item(.talk, bot, list), case .action(let run) = node.kind, !node.disabled else { list.open(bot.id); return }
            run()
        }
    }

    var talkAvailable: Bool { BotMenuHooks.providers[.talk] != nil }

    // [screen] The Screen tile (docs/spec/3x-screen.md §6.1): never disabled offline, the Screen explains itself.
    var screenAvailable: Bool { BotMenuHooks.providers[.screen] != nil }
    var screenSymbol: String { ScreenHooks.kind(bot) == .screenshots ? "photo.on.rectangle" : "display" }
    /// Opens over the sheet, as Watch Browser does: closing the Screen comes back here (UX study #94).
    func screen() {
        guard let host, let node = BotMenuHooks.item(.screen, bot, host), case .action(let run) = node.kind else { return }
        run()
    }

    func toggleRead() {
        let bot = self.bot
        Haptics.play(.selection)
        if bot.unread { services.markRead(bot) } else { settings?.markUnread(bot) }
    }

    func setMute(_ choice: MuteChoice) { BotExtras.setMute(bot, choice) }

    func toggleMute() { setMute(mute == nil ? .always : .off) }

    func duplicate() {
        guard let host else { return }
        BotExtras.duplicate(bot, services: services, from: host)
    }

    func delete(source: UIView?) {
        guard let host, let editing else { return }
        BotExtras.confirmDelete(bot, editing: editing, from: host, source: source) { [weak host] in
            host?.dismiss(animated: true)
        }
    }

    /// Instructions (developer name SOUL.md) needs a More pages context (client, account); built straight from this
    /// sheet's own services rather than read off `MorePages.context`. That global is set once, by whichever
    /// account's `PagesTabs` happened to attach last (`MorePages.attach`, called from `PagesTabs.init`) — it can
    /// still be nil, or another account's, the moment Bot Info opens (a cold launch's first Bot Info, a fast account
    /// switch, a reconnect in flight). This sheet already has everything the editor needs on its own `services`, so
    /// the row no longer depends on whether that unrelated attach has run.
    var instructionsContext: MorePages.Context? {
        guard let pages = services as? PagesServices, let account = pages.account, let client = pages.gateway else { return nil }
        let makeChat: (any ChatSessionModel) -> UIViewController = (services as? AppModel)?.makeChatScreen ?? { ChatViewController(session: $0) }
        return MorePages.Context(services: services, pages: pages, client: client, account: account, makeChat: makeChat)
    }

    var soulAvailable: Bool { instructionsContext != nil }

    func openSoul() {
        guard let navigation = host?.navigationController, let context = instructionsContext else { return }
        let editor = SoulEditorViewController(context: context, profile: botId, botName: bot.name)
        editor.navigationItem.largeTitleDisplayMode = .never
        navigation.pushViewController(editor, animated: true)
    }

    /// [tester batch 3] Default Model: the chooser on this bot's own catalog, pushed inside the sheet. A read-only
    /// gateway refuses before it opens, with the reason, as this sheet's other changes do.
    func openDefaultModel() {
        if editing?.isReadOnly == true {
            FailureAlert.present(title: SettingsWords.botModelFailureTitle(bot.name), reason: BotWriteError.readOnlyReason, from: host)
            return
        }
        modelChange.open(bot, on: host?.navigationController)
    }

    /// Tester 2026-10-30: this bot's own Fallback Models and Auxiliary Models (Settings' are the default bot's).
    var modelPagesAvailable: Bool { BotModelPages.available(services) }

    func openFallbacks() { BotModelPages.openFallbacks(bot, services: services, on: host?.navigationController) }

    func openAuxiliary() { BotModelPages.openAuxiliary(bot, services: services, on: host?.navigationController) }

    /// [context-window] The bot's own config, read as the sheet opens so its row names the size; the page edits this
    /// same store, so a change shows on the row as the page closes.
    var contextStore: GatewayConfigStore?
    var contextWindow: String? {
        guard let store = contextStore, store.config != nil else { return nil }
        return ContextWindow.summary(store.value(ContextWindow.key))
    }

    func loadContextWindow() async {
        guard modelPagesAvailable else { return }
        let store = contextStore ?? BotModelPages.contextWindowStore(for: bot, services: services)
        contextStore = store
        await store?.load()
    }

    func openContextWindow() {
        BotModelPages.openContextWindow(bot, services: services, store: contextStore, on: host?.navigationController)
    }

    /// The header face's Edit Head and its photo choices (`BotInfoFace`).
    func changeFace() { (host as? BotInfoController)?.openFace() }
    func choosePhoto(_ source: BotPhotoPicker.Source) { (host as? BotInfoController)?.openPhoto(source) }

    func openSkills() {
        guard let navigation = host?.navigationController else { return }
        let page = CapabilitiesViewController(services: services, profile: botId, tab: .skills, botLocked: true)   // this bot's, no switching away
        page.navigationItem.largeTitleDisplayMode = .never
        navigation.pushViewController(page, animated: true)
    }

    func newSection() {
        guard let editing else { return }
        let bot = self.bot
        let others = editing.sectionRecords.map(\.name)
        TextPrompt.present(title: "New Section", placeholder: "e.g. Clients", action: "Create", maxLength: 40,
                           problem: { BotListLayout.sectionNameProblem($0, others: others) }, from: host) { [weak self] name in
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, BotListLayout.sectionNameProblem(clean, others: others) == nil, let self else { return }
            if editing.isReadOnly {
                FailureAlert.present(title: "Couldn’t Move \(bot.name)", reason: BotWriteError.readOnlyReason, from: self.host)
                return
            }
            // Made once; the filing is the write (its Try Again moves the bot again, never makes a second section).
            let record = editing.appendSection(named: clean)
            self.move(to: record.id)
        }
    }
}

final class BotInfoController: UIHostingController<HQScaledRoot<BotInfoView>> {
    let model: BotInfoModel
    private var timer: Timer?
    private var editItem: UIBarButtonItem?

    init(botId: String, fallback: Bot, services: any AppServices) {
        let model = BotInfoModel(botId: botId, fallback: fallback, services: services)
        self.model = model
        super.init(rootView: HQScaledRoot(BotInfoView(model: model)))
        model.host = self
        title = "Bot Info"
        navigationItem.largeTitleDisplayMode = .never
        let close = UIBarButtonItem.hqClose(action: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        close.accessibilityIdentifier = "bot-info.close"
        navigationItem.hqPlaceClose(close)   // [mac] Stress test 2026-10-28 #55: trailing on the Mac, after Edit
        let edit = UIBarButtonItem.hqWord("Edit", action: UIAction { [weak self] _ in
            guard let self else { return }
            self.navigationController?.pushViewController(EditBotController(info: self), animated: true)
        })
        edit.accessibilityIdentifier = "bot-info.edit"
        navigationItem.rightBarButtonItem = edit
        editItem = edit
        model.onHeaderFolded = { [weak self] folded in self?.showFoldedTitle(folded) }
    }

    /// [ui-sizing 2026-11-09] The header folded away under the bar: the bar's title is the bot's face and name, as the
    /// header said them; "Bot Info" again once it is back.
    private func showFoldedTitle(_ folded: Bool) {
        let swap = { [self] in
            if folded {
                let bot = model.bot
                let host = UIHostingController(rootView: HStack(spacing: 8) {
                    BotAvatar(bot: bot, size: HQFont.scaled(26), tile: true, presence: false)
                    Text(bot.name).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel).lineLimit(1)
                }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader))
                host.view.backgroundColor = .clear
                // Measured first: handed to the bar unsized, it was given the face's width and the name was cut away.
                let room = max(120, (view.window?.bounds.width ?? 375) - 180)
                let size = host.sizeThatFits(in: CGSize(width: room, height: 44))
                host.view.frame = CGRect(x: 0, y: 0, width: min(room, ceil(size.width)), height: max(28, ceil(size.height)))
                host.view.translatesAutoresizingMaskIntoConstraints = true
                navigationItem.titleView = host.view
            } else {
                navigationItem.titleView = nil
            }
        }
        guard let bar = navigationController?.navigationBar, !HQMotion.reduced else { swap(); return }
        UIView.transition(with: bar, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction], animations: swap)
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Change Face: the head editor straight away, not under Edit › Edit Head (owner 2026-11-08: "Idk that it's easy
    /// enough to find"). A saved head shows in the header at once.
    func openFace(animated: Bool = true) {
        guard let navigationController, let page = EditHeadController(bot: model.bot, info: model, onSaved: { _ in }) else { return }
        navigationController.pushViewController(page, animated: animated)
    }

    /// [photoheads] The header face's Photo Library and Choose File: Edit Bot on its Upload tab, the picker over it, so
    /// the framed photo is staged there and Save keeps it, as when chosen on that page.
    func openPhoto(_ source: BotPhotoPicker.Source) {
        guard let navigationController else { return }
        let page = EditBotController(info: self)
        page.model.pictureTab = .upload
        page.pickOnAppear = source
        navigationController.pushViewController(page, animated: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let navigationController {
            EditingGuard.refreshLock(navigationController)   // back from a discarded edit: the sheet swipes closed again
            navigationController.interactivePopGestureRecognizer?.isEnabled = true
        }
        refreshOnline()
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshOnline() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    /// Writes are off (rows dimmed, Edit disabled) while the gateway link isn't ready.
    private func refreshOnline() {
        let online = model.services.connection == .ready
        if model.online != online { model.online = online }
        editItem?.isEnabled = online
    }
}

struct BotInfoView: View {
    @Bindable var model: BotInfoModel
    /// [ui-sizing] Where the tabs and the bar's bottom edge are on screen: the header folds once the tabs reach the bar.
    @State private var tabsTop: CGFloat = .greatestFiniteMagnitude
    @State private var barBottom: CGFloat = 0

    private var tabsStrip: some View {
        WholeLabelTabs(tabs: model.tabs, title: \.title, selection: Binding(get: { model.tab }, set: { model.select($0) }),
                       identifier: "bot-info.tab")
    }

    /// [ui-sizing] The iOS look only: the Desktop Look's outlined header keeps today's page.
    private func refold() {
        let folded = !Theme.isDesktop && tabsTop < barBottom - 0.5
        if model.headerFolded != folded { model.headerFolded = folded }
    }

    var body: some View {
        let bot = model.bot
        List {
            Section {
                VStack(spacing: Theme.isDesktop ? 10 : 8) {
                    // [botslist] The head with the list's status badge (parity §3 L213, `info-sheet.tsx:142-155`).
                    // [compact] 80 pt (was 96): the header filled half the sheet (owner 2026-10-17).
                    BotInfoFace(model: model, size: Theme.isDesktop ? 96 : 80)
                    Text(bot.name)
                        .font(Font.hq(.title2).weight(.semibold))
                        .foregroundStyle(Color.hqLabel)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("bot-info.name")
                    // The role shows only when it says something the name does not, and not when it is About's own
                    // text (UX study 2026-10-19 #2: the description showed twice).
                    if let role = BotInfoWords.headerRole(name: bot.name, role: bot.role, about: model.description) {
                        Text(role)
                            .font(Font.hq(.subheadline))
                            .foregroundStyle(Color.hqLabel2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("bot-info.role")
                    }
                    BotInfoStatusLine(model: model)
                    BotInfoTiles(model: model)
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)
                .listRowBackground(Color.clear)
            }
            .listSectionSpacing(.compact)

            // [tabs] Under the header, as Capabilities' tabs sit under its Bot row.
            Section {
                tabsStrip
                    .opacity(model.headerFolded ? 0 : 1)   // [ui-sizing] the pinned copy stands in for it
                    .accessibilityHidden(model.headerFolded)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { tabsTop = $0; refold() }
                    .hqSegmentRow(otherwise: Theme.isDesktop ? EdgeInsets(top: 4, leading: 12, bottom: 12, trailing: 12)
                                                             : EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
            }
            .listSectionSpacing(.compact)

            switch model.tab {
            case .about: BotInfoAboutTab(model: model)
            case .brain: BotInfoModelSection(model: model)
            case .chats: BotInfoChatsTab(model: model)
            case .artifacts:
                if let view = model.artifactsView() { view }
            case .settings: BotInfoSettingsTab(model: model)
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        // [desktoplook] The look's header card is an outlined box: it keeps the list's own top inset, as Settings does,
        // instead of butting into the bar (UX study #122).
        .contentMargins(.top, Theme.isDesktop ? nil : 0, for: .scrollContent)
        // [ui-sizing 2026-11-09] Owner: "option B". The header folds away: once the tabs scroll up to the bar they stay
        // pinned under it (this copy, on the page's colour) and the bar's title becomes the face and name (the host).
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear.frame(height: 0)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { barBottom = $0; refold() }
                if model.headerFolded {
                    tabsStrip
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .background(Color.hqGroupedPage)
                }
            }
        }
        .accessibilityIdentifier("bot-info.list")
        .task(id: bot.id) {
            async let context: Void = model.loadContextWindow()
            await model.loadRecent()
            await context
        }
    }
}

/// The header's face, which changes it (owner 2026-11-08: the head editor sat under Edit › Picture › Edit Head). A
/// pencil on its corner says so. A tap opens the head editor; on a gateway that stores pictures it is a menu that also
/// offers a photo. Offline it is the face alone, as Edit is disabled then.
struct BotInfoFace: View {
    @Bindable var model: BotInfoModel
    var size: CGFloat

    var body: some View {
        let bot = model.bot
        let face = BotAvatar(bot: bot, size: size, tile: true, presence: false)
            .overlay(alignment: .bottomTrailing) {
                // Not over the face's own badge (attention, waking, working, computer): that corner is the status's.
                if model.online, !Self.hasBadge(bot) {
                    EditFaceBadge(height: BotAvatar.badgeSize(size) + 4).offset(x: 4, y: 4)
                }
            }
            .contentShape(Rectangle())
        Group {
            if BotFaces.shared.supportsPictures {
                Menu {
                    Button { model.changeFace() } label: { Label("Edit Head", systemImage: "face.smiling") }
                        .accessibilityIdentifier("bot-info.face.head")
                    Section("Use a Photo") {
                        Button { model.choosePhoto(.library) } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                            .accessibilityIdentifier("bot-info.face.library")
                        Button { model.choosePhoto(.file) } label: { Label("Choose File", systemImage: "folder") }
                            .accessibilityIdentifier("bot-info.face.file")
                    }
                } label: { face }
                .menuStyle(.button)
                .menuOrder(.fixed)
                .menuIndicator(.hidden)
            } else {
                Button { model.changeFace() } label: { face }
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!model.online)
        .accessibilityLabel(BotFaces.shared.showsPhoto(bot.id) ? "\(bot.name)’s photo" : "\(bot.name)’s head")
        .accessibilityHint(model.online ? "Changes the face" : "")
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("bot-info.face")
    }

    static func hasBadge(_ bot: Bot) -> Bool {
        let status = BotList.rowStatus(bot)
        return status == .attention || status == .waking || BotList.rowBadge(bot) != nil
    }
}

/// The pencil on Bot Info's face: the tint's disc, ringed in the page as the face's other badges are.
struct EditFaceBadge: View {
    var height: CGFloat
    var body: some View {
        Image(systemName: "pencil")
            .font(Font.hqSystem(size: height * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: height, height: height)
            .background(Circle().fill(Color.hqTint))
            .background(Circle().fill(Color.hqGroupedPage).padding(-2))
            .accessibilityHidden(true)
    }
}

/// [tabs] About: the description and handle, then the Computer group ([page-tabs] Brain is its own tab).
struct BotInfoAboutTab: View {
    @Bindable var model: BotInfoModel

    var body: some View {
        let bot = model.bot
        Section {
            if let description = model.description, !description.isEmpty {
                BotInfoAbout(text: description, expanded: $model.aboutExpanded)
            }
            LabeledContent("Handle", value: "@\(model.handle)")
        }

        ForEach(Array(BotInfoHooks.sections.enumerated()), id: \.offset) { _, make in
            if let host = model.host, let view = make(bot, host) { view }
        }
    }
}

/// [tabs] Chats: Conversations, then Group Chats.
struct BotInfoChatsTab: View {
    @Bindable var model: BotInfoModel

    var body: some View {
        let bot = model.bot
        BotInfoConversations(model: model)

        ForEach(Array(BotInfoHooks.afterConversations.enumerated()), id: \.offset) { _, make in   // [groups]
            if let host = model.host, let view = make(bot, host) { view }
        }
    }
}

/// [tabs] Settings: Notifications, Organize, Delete Bot, and the bot's id.
struct BotInfoSettingsTab: View {
    @Bindable var model: BotInfoModel

    var body: some View {
        let bot = model.bot
        Section {
            Menu {
                // A timed mute checks no choice: its end time shows checked above them, so the pick reads as taken.
                if model.mute != nil, BotMutes.choice(model.mute) == nil {
                    Section {
                        Button {} label: { Label(model.muteValue, systemImage: "checkmark") }
                            .disabled(true)
                    }
                }
                ForEach(MuteChoice.allCases, id: \.self) { choice in
                    Button { model.setMute(choice) } label: {
                        if BotMutes.choice(model.mute) == choice { Label(choice.title, systemImage: "checkmark") } else { Text(choice.title) }
                    }
                }
            } label: {
                HStack {
                    Text("Mute Notifications").foregroundStyle(Color.hqLabel)
                    Spacer()
                    Text(model.muteValue).foregroundStyle(Color.hqLabel2)
                    Image(systemName: "chevron.up.chevron.down").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel3)
                }
            }
            .accessibilityIdentifier("bot-info.mute")
            .accessibilityValue(model.muteValue)
        } header: { HQSectionLabel {
            Text("Notifications")
        } } footer: { HQSectionFooter {
            Text(BotMutes.scope)
        } }

        // [bot-colour] Owner 2026-11-11: this bot's own message colour.
        BotColourSection(bot: bot)

        Section {
            Toggle("Pinned", isOn: Binding(get: { model.bot.pinned }, set: { model.setPinned($0) }))
                .accessibilityIdentifier("bot-info.pinned")
            Toggle("Show in Bots", isOn: Binding(get: { !model.bot.hidden }, set: { model.setShown($0) }))
                .accessibilityIdentifier("bot-info.shown")
            Menu {
                Button { model.move(to: nil) } label: {
                    if model.isUnassigned { Label("Unassigned", systemImage: "checkmark") } else { Text("Unassigned") }
                }
                ForEach(model.editing?.sectionRecords ?? [], id: \.id) { record in
                    Button { model.move(to: record.id) } label: {
                        if model.editing?.shownSectionId(of: model.bot) == record.id {
                            Label(record.name, systemImage: "checkmark")
                        } else {
                            Text(record.name)
                        }
                    }
                }
                Section {
                    Button("New Section…", systemImage: "folder.badge.plus") { model.newSection() }
                }
            } label: {
                HStack {
                    Text("Section").foregroundStyle(Color.hqLabel)
                    Spacer()
                    Text(model.sectionName).foregroundStyle(Color.hqLabel2)
                    Image(systemName: "chevron.up.chevron.down").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel3)
                }
            }
            .accessibilityIdentifier("bot-info.section")
            Button("Duplicate Bot") { model.duplicate() }
                .accessibilityIdentifier("bot-info.duplicate")
        } header: { HQSectionLabel {
            Text("Organize")
        } } footer: { HQSectionFooter {
            if !model.online { Text("You can change this bot again once its gateway is back.") }
        } }
        .disabled(!model.online)
        .opacity(model.online ? 1 : 0.5)

        if BotExtrasRules.canDelete(isDefault: model.isDefault) {
            Section {
                Button("Delete Bot", role: .destructive) { model.delete(source: nil) }
                    .accessibilityIdentifier("bot-info.delete")
            }
            .disabled(!model.online)
        }

        Section {
        } footer: { HQSectionFooter {
            Text("Bot ID \(bot.id) · \(model.gatewayTitle)")
        } }
    }
}

/// [botslist] The header's status line (parity §3 L213): a tone dot and the bot's live status in the row's own words,
/// or how long ago it was active; " · Watch" opens its screen while it is using its computer (the Screen tile's own
/// action, so the word is never there without somewhere to go).
struct BotInfoStatusLine: View {
    @Bindable var model: BotInfoModel
    /// The dot's size: Caption 2 (11 pt at the default size), growing with the text but never past 14 pt, as the
    /// gateway card's dot, so it isn't a blot at accessibility sizes (UX study #12).
    @ScaledMetric(relativeTo: .caption2) private var dotPoint: CGFloat = 11

    var body: some View {
        let bot = model.bot
        if let status = BotList.infoStatus(bot) {
            let colour = status.tone == .tint ? Color.hqTint : status.tone == .attention ? Color.hqOrange : Color.hqLabel2
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // The dot sits in the words (a small type size, so it grows with the text and wraps with the first
                // line at the largest sizes instead of floating beside the block); the text is the dot's own tone.
                Text("\(Text(Image(systemName: "circle.fill")).font(dotFont))\u{00A0}\(status.text)")
                    .font(Font.hq(.footnote))
                    .foregroundStyle(colour)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(status.text)
                    .accessibilityIdentifier("bot-info.status")
                if bot.presence?.usingComputer == true, model.screenAvailable {
                    Text("·").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel3).accessibilityHidden(true)
                    Button { model.screen() } label: {
                        // A 44 pt target (UX study #169) that doesn't make the line taller when Watch comes and goes.
                        Text("Watch").padding(.vertical, 13).contentShape(Rectangle())
                    }
                        .font(Font.hq(.footnote).weight(.semibold))
                        .buttonStyle(.borderless)
                        .padding(.vertical, -13)
                        .accessibilityIdentifier("bot-info.watch")
                        .accessibilityHint("Shows what it is doing on its computer.")
                }
            }
        }
    }

    /// The Desktop Look's type is a fixed size already; the iOS look's grows with Dynamic Type, so it is capped.
    private var dotFont: Font { Theme.isDesktop ? Font.hq(.caption2) : Font.system(size: min(dotPoint, 14)) }
}

/// [botslist] About (parity §3 L213, `info-sheet.tsx:157-166`): the description, four lines; "More" shows only when the
/// text really is cut off (measured at this width and text size, not guessed from its length), and "Less" folds it back.
struct BotInfoAbout: View {
    var text: String
    @Binding var expanded: Bool
    @State private var fullHeight: CGFloat = 0
    @State private var foldedHeight: CGFloat = 0

    private var cut: Bool { fullHeight > foldedHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("About").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).accessibilityAddTraits(.isHeader)
            Text(text)
                .foregroundStyle(Color.hqLabel)
                .lineLimit(expanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(text)            // VoiceOver reads all of it, folded or not
                .accessibilityIdentifier("bot-info.about")
                .background(alignment: .topLeading) {
                    // The two heights the text could have at this width: all of it, and four lines of it.
                    ZStack(alignment: .topLeading) {
                        Text(text).fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                        Text(text).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { foldedHeight = $0 }
                    }
                    .hidden()
                    .accessibilityHidden(true)
                }
            if cut {
                HStack {
                    Spacer(minLength: 0)
                    Button(expanded ? "Less" : "More") { Haptics.play(.selection); expanded.toggle() }
                        .font(Font.hq(.footnote).weight(.semibold))
                        .buttonStyle(.borderless)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("bot-info.about.toggle")
                        .accessibilityHint("Shows the whole description.")
                }
            }
        }
        .padding(.vertical, Theme.isDesktop ? 12 : 2)   // [compact] iOS look: the List row pads it already
    }
}

/// The header's tiles (`info-state.ts` tiles): Talk, Memo, Screen, Mute.
struct BotInfoTiles: View {
    @Bindable var model: BotInfoModel

    /// [morepages] Drawn by the shared quick-action tiles (docs/spec/3x-morepages.md §8): equal tiles filling the
    /// sheet's width, two columns from AX1, full-width rows from AX3. Order: Talk · Memo · Screen · Mute, as on the web
    /// (`S/ui-bots/info-state.ts:130-135`); a tile whose feature is absent is not shown.
    var body: some View {
        QuickActionTiles(actions: Self.actions(model))
    }

    static func actions(_ model: BotInfoModel) -> [QuickAction] {
        let muted = model.mute != nil
        var actions: [QuickAction] = []
        if model.talkAvailable {   // [talk]
            actions.append(QuickAction(id: "talk", label: "Talk", symbol: "waveform", disabled: !model.online,
                                       identifier: "bot-info.tile.talk") { model.talk() })
        }
        if model.memoAvailable {
            actions.append(QuickAction(id: "memo", label: "Memo", symbol: "mic.fill", disabled: !model.online,
                                       identifier: "bot-info.tile.memo") { model.memo() })
        }
        if model.screenAvailable {   // [screen]
            actions.append(QuickAction(id: "screen", label: "Screen", symbol: model.screenSymbol, identifier: "bot-info.tile.screen") { model.screen() })
        }
        // The glyph is the state, as the row's muted bell (UX study #249); the label stays the action.
        actions.append(QuickAction(id: "mute", label: muted ? "Unmute" : "Mute", symbol: muted ? "bell.slash.fill" : "bell.fill",
                                   identifier: "bot-info.tile.mute", value: muted ? "Muted" : "Not Muted") { model.toggleMute() })
        return actions
    }

    /// [talk] The row's widest before the tiles filled the sheet (kept for callers that size by it).
    nonisolated static func rowWidth(tiles: Int) -> CGFloat {
        max(260, CGFloat(max(1, tiles)) * 80 + CGFloat(max(0, tiles - 1)) * 10)
    }
}

/// Brain (its own tab): the bot's own Default Model (tester batch 3: it was a label, and Settings › Model changes only the default
/// profile's) and its provider as the roster names them, its Skills, and its Instructions (developer name SOUL.md).
struct BotInfoModelSection: View {
    @Bindable var model: BotInfoModel

    var body: some View {
        let info = model.modelInfo
        Section {
            ValueRow(title: "Default Model", value: model.modelChange.value(model.bot)) { model.openDefaultModel() }
                .accessibilityIdentifier("bot-info.default-model")
                .disabled(!model.online || !model.modelChange.available || model.modelChange.switching != nil)
            // Item 5: the display name these providers use for their API key cards, not the gateway's lowercase slug.
            if let provider = info.provider { LabeledContent("Provider", value: EnvKeys.providerDisplayName(forSlug: provider)) }
            // Tester 2026-10-30: this bot's own, not only the default bot's under Settings › Model.
            if model.modelPagesAvailable {
                // [context-window] Owner 2026-11-01: "If I have to ask you, then I'm sure others may not ever even find it."
                ValueRow(title: "Context Window", value: model.contextWindow) { model.openContextWindow() }
                    .accessibilityIdentifier("bot-info.context-window")
                    .disabled(!model.online)
                link("Fallback Models", id: "bot-info.fallbacks") { model.openFallbacks() }
                link("Auxiliary Models", id: "bot-info.auxiliary") { model.openAuxiliary() }
            }
        } footer: { HQSectionFooter {
            // [model-scope] Owner 2026-11-03 (menu review #2): this bot's alone, and for the default bot the same setting
            // as Settings › Model (only a code comment said so).
            Text(SettingsWords.botModelScope(bot: model.bot.name, isDefault: model.isDefault))
                .accessibilityIdentifier("bot-info.model-scope")
        } }
        // [page-tabs] On its own tab, titled Brain: no "Brain" header over it (UX #118's rule, as Theme's grid), and the
        // models apart from what it knows and is told.
        Section {
            link("Skills", id: "bot-info.skills") { model.openSkills() }
            // UX study #190: the instructions editor, also here and not only under More › Bot Profiles.
            if model.soulAvailable { link("Instructions", id: "bot-info.soul") { model.openSoul() } }
        } footer: { HQSectionFooter {
            if model.soulAvailable { Text(BotInfoWords.instructionsFooter(botName: model.bot.name)) }
        } }
    }

    /// A row that opens a page (pushed inside the sheet); offline it can't.
    private func link(_ title: String, id: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack {
                Text(title).foregroundStyle(Color.hqLabel)
                Spacer()
                SettingsChevron()
            }
        }
        .accessibilityIdentifier(id)
        .disabled(!model.online)
    }
}

/// Conversations: Bot Chat, three recent chats (and All Chats when there may be more), New Chat, Mark Bot Chat as
/// Read/Unread.
/// [botinfo-chats] Every row here but the last closes the sheet (onto the chat, or onto Sessions), so none wears a
/// chevron, which says "a page opens inside this sheet" (owner 2026-11-03, menu/nav review). Bot Chat, All Chats and
/// New Chat are action rows in the list's tint, like Contacts' Send Message and this section's own read row; the
/// recent chats keep their title and time.
struct BotInfoConversations: View {
    @Bindable var model: BotInfoModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let bot = model.bot
        Section {
            action("Bot Chat", detail: "Your ongoing chat with \(bot.name)", id: "bot-info.bot-chat") { model.openBotChat() }
            ForEach(model.recent.prefix(3), id: \.id) { session in
                Button { model.openRecent(session) } label: { recentLabel(session) }
                    .accessibilityIdentifier("bot-info.recent")
            }
            // Three is all the sheet reads: with a full three there may be more, which Sessions lists with this bot's
            // chip picked (UX study #191). A hidden bot has no chip, so Sessions would drop the filter: no row.
            if model.recent.count >= 3 && !model.bot.hidden {
                action("All Chats with \(bot.name)", detail: BotInfoWords.allChatsSubtitle, id: "bot-info.all-chats") {
                    model.openAllChats()
                }
            }
            action("New Chat", id: "bot-info.new-chat") { model.newChat() }
                .disabled(!model.online)
            if model.hasChat || bot.unread {
                Button(BotInfoWords.readTitle(unread: bot.unread)) { model.toggleRead() }
                    .accessibilityIdentifier("bot-info.unread")
            }
        } header: { HQSectionLabel { Text("Conversations") } }
    }

    /// [botinfo-chats] An action row: the title in the list's tint (no foregroundStyle, so it matches the read row and
    /// Duplicate Bot in both looks and dims when disabled), with an optional plain subtitle under it.
    private func action(_ title: String, detail: String? = nil, id: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                }
            }
            .padding(.vertical, detail == nil ? 0 : 4)
        }
        .accessibilityIdentifier(id)
    }

    /// A recent chat: title and time on one line; at accessibility sizes the time goes under the title, since side by
    /// side the title was cut to a word or two ([botinfo-chats] "Visa forms" read "Visa for…" at AX-L).
    @ViewBuilder private func recentLabel(_ session: SessionSummary) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).foregroundStyle(Color.hqLabel).lineLimit(2)
                Text(ListTime.string(session.lastActive)).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
            }
        } else {
            HStack(spacing: 8) {
                Text(session.title).foregroundStyle(Color.hqLabel).lineLimit(1)
                Spacer(minLength: 8)
                Text(ListTime.string(session.lastActive)).foregroundStyle(Color.hqLabel2).lineLimit(1).fixedSize()
            }
        }
    }
}
