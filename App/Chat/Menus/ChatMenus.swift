import UIKit

/// The chat screen's menus (spec 1x): the ⋯ menu (Share and Info tiles, Model ▸, Rename…, fixed slots for later
/// streams), the Model switcher's alerts and notices, the Models and Commands sheets, the slash dispatcher's hooks, and
/// the message hold menus. Installed by the app model on each chat screen (`install(on:account:info:)`).
final class ChatMenus: NSObject, ModelSwitchUI {
    /// The ⋯ rows in their fixed order (spec 1x §4.1). Later streams fill their slot through `slotItems` without moving
    /// the others.
    enum Slot: Int, CaseIterable {
        case tiles = 0, model = 10, tools = 15, pin = 20, unread = 30, rename = 40, readAloud = 50, more = 60, danger = 70, browser = 80
    }

    private(set) weak var screen: ChatViewController?
    let session: any ChatSessionModel
    var live: LiveChatSession? { session as? LiveChatSession }
    /// For logs: the same scope `ChatViewController` tags itself with.
    var logScope: String { (session as? ChatSessionDetails)?.layoutScope ?? "\(session.profile)|\(session.title)" }
    /// The app's side of the ⋯'s list actions (pin and unread state, opening a branch, leaving after Archive/Delete).
    weak var host: (any ChatMenuHosting)?
    /// [tasks] The chat is a task's own, on its page (TaskPage): the ⋯ leaves out what would cut it from the task.
    var isTaskChat = false
    /// One Branch, Export or Delete at a time (a second tap meanwhile does nothing).
    var actionInFlight = false
    let prefs: ModelPrefs?
    let context: ModelMenuContext?
    private(set) var switcher: ModelSwitcher?
    let info: () -> Void
    /// Rows other streams add at their slot (pin, unread, read aloud, more, archive/delete, Watch Browser).
    var slotItems: [Slot: () -> [UIMenuElement]] = [:]
    var preparingShare = false

    private init(screen: ChatViewController, account: GatewayAccount?, info: @escaping () -> Void) {
        self.screen = screen
        self.session = screen.session
        self.info = info
        if let live = screen.session as? LiveChatSession {
            let prefs = ModelPrefs(accountId: (account ?? live.account).id)
            self.prefs = prefs
            self.context = ModelMenuContext(chat: live, prefs: prefs)
        } else {
            prefs = nil
            context = nil
        }
        super.init()
        if let context { switcher = ModelSwitcher(context: context, ui: self) }
    }

    /// Puts the menus on a chat screen: the ⋯ menu, ☰ (1:1 chats on iPhone), the dispatcher's hooks, hold menus.
    @discardableResult
    static func install(on screen: ChatViewController, account: GatewayAccount?, info: @escaping () -> Void) -> ChatMenus {
        let menus = ChatMenus(screen: screen, account: account, info: info)
        screen.menus = menus
        screen.moreMenu = menus.makeMoreMenu()
        if let live = menus.live {
            screen.composer.showsCommands = true   // [m9/ipad] D12: iPad has the same one composer, so ☰ shows there too
            screen.composer.onCommands = { [weak screen] in screen?.presentCommandsSheet() }
            // [composer-expand] The two-row bar's model chip; [model-panel] a tap opens the model panel.
            if let context = menus.context, menus.switcher != nil {
                // The model's name (a "provider/model" id shows its model part); its effort is only spoken.
                screen.composer.modelChipTitle = { [weak context] in
                    #if DEBUG
                    if let name = UserDefaults.standard.string(forKey: "HQDebugModelChipName") {   // screenshots of long names
                        let effort = UserDefaults.standard.string(forKey: "HQDebugModelChipEffort") ?? "xhigh"
                        return ModelChip.Title(name: name, effort: ModelNames.effortLabel(effort),
                                               bareName: UserDefaults.standard.string(forKey: "HQDebugModelChipBare"))
                    }
                    #endif
                    guard let input = context?.input() else { return nil }
                    let name = input.current.name.split(separator: "/").last.map(String.init) ?? ""
                    let thinks = !input.offline && !input.reasoningLevels.isEmpty
                    let bare = ModelNames.modelDisplayParts(input.current.id.isEmpty ? name : input.current.id).name
                    return ModelChip.Title(name: name, effort: thinks ? ModelNames.effortLabel(input.reasoningCurrent) : nil,
                                           bareName: bare == name ? nil : bare)
                }
                screen.composer.modelChip.onTap = { [weak menus] in menus?.presentModelPanel() }
            }
            live.menus.transcriptUserLine = ChatTranscriptText.userLine
            live.slashHooks = ChatSlashHooks(
                prefill: { [weak screen] text in
                    guard let screen else { return }
                    screen.composer.text = text
                    screen.focusComposer()
                },
                openModels: { [weak screen] query in screen?.presentModelSheet(query: query) },
                openCommands: { [weak screen] in screen?.presentCommandsSheet() },
                alert: { [weak menus] title, message in menus?.alert(title: title, message: message) },
                titleApplied: nil,
                newChat: { [weak screen, weak menus] draft in
                    guard let screen, let menus, let host = menus.host else { return false }
                    return host.openNewChat(like: menus.session, draft: draft, replacing: screen)
                })
        }
        return menus
    }

    // MARK: - ⋯ (spec 1x §4)

    /// One deferred, uncached element: every open reads the current state (offline, model, favourites, title) with no
    /// network wait (spec 1x §4.2).
    func makeMoreMenu() -> UIMenu {
        UIMenu(identifier: Self.moreMenuIdentifier, children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.moreMenuElements() ?? [])
        }])
    }

    /// [talk] Names the ⋯ menu, so an open one can be redrawn in place (`ChatViewController.refreshVisibleMoreMenu`).
    static let moreMenuIdentifier = UIMenu.Identifier("hq.chat.more")

    var offline: Bool { session.connection != .ready }

    /// The ⋯ in the web's order (S:phone-chat-menu-model.ts `chatMenuModel`): Share · Find · Info, Model, Pin, Mark as
    /// Read/Unread, Rename…, More ▸ (Files, Changes, Branch, Export Chat), Archive, Delete Chat, then Watch Browser.
    func moreMenuElements() -> [UIMenuElement] {
        context?.warmUp()
        let state = menuState()
        let rows = ChatMenuModel.rows(state)
        let actions = session as? ChatSessionMoreActions
        var bySlot: [Slot: [UIMenuElement]] = [:]
        for slot in Slot.allCases {
            var out: [UIMenuElement] = []
            switch slot {
            case .tiles: out.append(tiles(state))
            case .model: if let row = modelRow() { out.append(row) }
            case .tools: out += toolRows()
            case .pin: if actions != nil, let row = rows.first(where: { $0.id == .pin }) { out.append(menuAction(row)) }
            case .unread: if actions != nil, let row = rows.first(where: { $0.id == .unread }) { out.append(menuAction(row)) }
            case .rename: if session is ChatSessionActions, let row = rows.first(where: { $0.id == .rename }) { out.append(menuAction(row)) }
            case .more:
                if actions != nil {
                    out.append(UIMenu(title: "More", image: UIImage(systemName: "ellipsis.circle"), children: ChatMenuModel.more(state).map(menuAction)))
                }
                // [activity] DEBUG items other streams add here (Tool Calls) stay in the ⋯ itself, after More.
                out += slotItems[.more]?() ?? []
            case .danger:
                if actions != nil {
                    let danger = ChatMenuModel.danger(state).map(menuAction)
                    if !danger.isEmpty { out.append(UIMenu(title: "", options: .displayInline, children: danger)) }
                }
            default: out += slotItems[slot]?() ?? []
            }
            bySlot[slot] = out
        }
        #if targetEnvironment(macCatalyst)
        return Self.macSections(bySlot)
        #else
        return Slot.allCases.flatMap { bySlot[$0] ?? [] }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// [mac-audit] Owner 2026-11-02 (Mac audit #16): on the Mac the ⋯ is a real menu of up to 19 rows, and as one flat
    /// list in the web's order it read as a wall. It is grouped the way a Mac menu is, by separators (no section
    /// headings: the owner hates clutter): Share · Find · Info; the chat itself (Model, Pin, Unread, Rename…); what it
    /// does as you watch (Read Replies Aloud, Watch Browser); its tools (Prompts, Usage & Limits, Model Prices, More ▸);
    /// and Archive and Delete Chat last, Delete in red. Every row is still there. The iPhone keeps the web's order.
    static func macSections(_ bySlot: [Slot: [UIMenuElement]]) -> [UIMenuElement] {
        func section(_ slots: [Slot]) -> UIMenuElement? {
            let children = slots.flatMap { bySlot[$0] ?? [] }.flatMap { element -> [UIMenuElement] in
                // An untitled inline group inside a section would only add a second separator: its rows join it.
                if let menu = element as? UIMenu, menu.options.contains(.displayInline), menu.title.isEmpty { return menu.children }
                return [element]
            }
            return children.isEmpty ? nil : UIMenu(title: "", options: .displayInline, children: children)
        }
        let groups = [section([.model, .pin, .unread, .rename]), section([.readAloud, .browser]), section([.tools, .more]),
                      section([.danger])]
        return (bySlot[.tiles] ?? []) + groups.compactMap { $0 }
    }
    #endif

    private func tiles(_ state: ChatMenuState) -> UIMenu {
        var tiles = ChatMenuModel.tiles(state)
        // Find needs the screen's transcript; the demo's fake session has no other actions to offer either.
        if session as? ChatSessionMoreActions == nil { tiles.removeAll { $0.id == .find } }
        return UIMenu(title: "", options: .displayInline, preferredElementSize: .medium, children: tiles.map(menuAction))
    }

    /// One ⋯ row as a UIAction ("chat.more.<id>").
    func menuAction(_ row: ChatMenuRow) -> UIAction {
        var attributes: UIMenuElement.Attributes = row.disabled ? .disabled : []
        if row.destructive { attributes.insert(.destructive) }
        let action = UIAction(title: row.title, subtitle: row.subtitle, image: UIImage(systemName: row.symbol), attributes: attributes) { [weak self] _ in
            if row.id == .delete { Haptics.play(.warning) } else { Haptics.play(.selection) }
            self?.perform(row.id)
        }
        action.accessibilityIdentifier = "chat.more.\(row.id.rawValue)"
        return action
    }

    func perform(_ id: ChatMenuItemID) {
        AppLog.trace("chatui", "menu action chosen \(AppLog.tag(logScope)): \(id.rawValue)")
        switch id {
        case .share: shareTranscript()
        case .find: screen?.showFind()
        case .info:
            #if targetEnvironment(macCatalyst)
            if let screen, let inspector = MacInspector.beside(screen), screen.makeInfoContent != nil { inspector.show(.info); return }   // [mac-layout]
            #endif
            info()
        case .rename: promptRename()
        default: performListAction(id)
        }
    }

    // MARK: Model (spec 1x §4.6)

    /// One row, the model and its thinking under "Model", that opens the panel the bubble opens. It used to be a
    /// submenu with its own copy of the picker, thinking and Fast; owner 2026-11-01 ("Do the weak points"): one place
    /// for them, and the ⋯ the way to it when the bar shows no bubble (the keys down, or the Desktop Look).
    private func modelRow() -> UIAction? {
        guard let context, switcher != nil else { return nil }
        let node = ModelMenuModel.build(context.input())
        let row = UIAction(title: node.title, subtitle: node.subtitle, image: UIImage(systemName: "cpu")) { [weak self] _ in
            Haptics.play(.selection)
            // After the ⋯ has gone, so the bar grows into its two rows with nothing over it.
            DispatchQueue.main.async { self?.presentModelPanel() }
        }
        row.accessibilityIdentifier = "chat.more.model"
        return row
    }

    // MARK: Model panel (owner 2026-10-31)

    private weak var modelPanel: ModelPanelView?

    /// What the panel shows now: the ⋯ › Model input with this chat's context window, the price and what is left.
    private func modelPanelState() -> ModelPanelState? {
        #if DEBUG
        let sample = UserDefaults.standard.string(forKey: "HQDebugModelPanelCase").flatMap(ModelPanelModel.debugCase)
            ?? (UserDefaults.standard.bool(forKey: "HQDebugModelPanelSample") ? ModelPanelModel.debugSample : nil)
        if var sample {
            // The approvals the stand-in gateway reports once one is picked, so a pick shows.
            if let state = live?.modelState, !state.approvalMode.isEmpty {
                sample.approvalMode = state.approvalMode
                sample.yolo = state.yolo
            }
            return sample
        }
        #endif
        guard let context else { return nil }
        let input = context.input()
        let current = input.current
        let options = context.options
        let listed = ModelsDevCache.shared.stored()
        return ModelPanelModel.build(input, contextMax: live?.menus.usage?.contextMax, contextUsed: live?.menus.usage?.contextUsed,
                                     listedContext: listed?.contextWindow(provider: current.provider, model: current.id),
                                     price: ModelPricesModel.menuSubtitle(options, model: current.id, provider: current.provider, fallback: listed),
                                     limit: UsageLimitsModel.menuSubtitle(options, provider: current.provider))
    }

    /// Opens the panel out of the composer's model bubble (the bubble, or ⋯ › Model). It takes the keyboard's place: the
    /// keys go down, the bar keeps its two rows (growing into them first when it was one), and the caret comes back when
    /// the panel closes (if it was in the field). The Desktop Look's bar has no bubble: the card rises in place.
    func presentModelPanel() {
        guard modelPanel == nil, let screen, let switcher, context != nil else { return }
        // [ghost-stars] The catalog is read as the panel opens (when the one in memory isn't fresh), so Switch Model's
        // Favorites are the bot's own by the time the menu is opened, not the last read's.
        if let context, !context.offline, context.cache.fresh(context.key) == nil {
            Task { _ = try? await context.load() }
        }
        let composer = screen.composer
        let hadFocus = composer.textView.isFirstResponder
        composer.holdsRows = true
        screen.view.endEditing(true)
        let host: UIView = screen.view
        // A one-row bar has just been told to grow: settle it now, so the floor and the bubble are where they'll be.
        host.layoutIfNeeded()
        // Where the card's bottom rests: above the bar once the keys are down (the bar's bottom 29 pt above the
        // screen's, or 8 pt above the home indicator's area, whichever is higher).
        let keysDownBottom = min(host.bounds.maxY - ChatMetrics.composerBottomDown,
                                 host.bounds.maxY - host.safeAreaInsets.bottom - ChatMetrics.composerBottomUp)
        // A "Replying to …" or "Editing Message" banner rides on top of the field: the card rests above it, not on it.
        let restsOn = min(composer.fieldFrame.minY, composer.editBanner?.frame.minY ?? .infinity)
        let floor = keysDownBottom - composer.bounds.height + restsOn - 12
        let actions = ModelPanelActions(
            state: { [weak self] in self?.modelPanelState() },
            pick: { [weak screen] model in
                _ = await switcher.switchModel(model)
                screen?.composer.refreshModelChip()
            },
            setEffort: { [weak screen] level in
                _ = await switcher.setReasoning(level)
                screen?.composer.refreshModelChip()
            },
            setFast: { [weak screen] on in
                _ = await switcher.setFast(on)
                screen?.composer.refreshModelChip()
            },
            setApprovalMode: { [weak self] mode in
                do { try await switcher.setApprovalMode(mode) } catch {
                    Haptics.play(.error)
                    self?.failure(title: "Couldn’t Change Approvals", reason: MenusError.text(error), retry: nil)
                }
            },
            setYolo: { [weak self] on in
                do { try await switcher.setYolo(on) } catch {
                    Haptics.play(.error)
                    self?.failure(title: on ? "Couldn’t Turn On YOLO" : "Couldn’t Turn Off YOLO", reason: MenusError.text(error), retry: nil)
                }
            },
            loadApprovals: { await switcher.loadApprovalMode() },
            openAll: { [weak self] in self?.presentModelSheet(query: nil) },
            toggleFavorite: { [weak context] in
                guard let context else { return }
                let current = context.current()
                guard !current.id.isEmpty else { return }
                context.prefs.toggleFavorite(provider: current.provider, model: current.id)
            },
            allModels: { [weak context] in
                #if DEBUG
                let defaults = UserDefaults.standard
                if defaults.string(forKey: "HQDebugModelPanelCase") != nil || defaults.bool(forKey: "HQDebugModelPanelSample") {
                    let opus = ModelPanelModel.debugCatalog[0]
                    return ModelPanelModel.groups(ModelPanelModel.debugCatalog, current: opus)
                }
                #endif
                guard let context else { return nil }
                let catalog = (try? await context.load()) ?? context.models()
                return catalog.isEmpty ? nil : ModelPanelModel.groups(catalog, current: context.current())
            },
            reloadModels: { [weak context] in _ = try? await context?.load(refresh: true) },
            closed: { [weak screen] handingOff in
                guard let screen else { return }
                screen.composer.holdsRows = false
                // [keys-return] Back to the keys it opened over; All Models brings them back when it closes instead.
                guard hadFocus else { return }
                if handingOff { screen.oweKeys() } else { screen.focusComposer() }
            },
            // The facts' Price and Plan open the ⋯'s pages; the face opens the bot's Bot Info.
            openUsage: { [weak self] in self?.presentUsage() },
            openPrices: { [weak self] in self?.presentPrices() },
            openContextWindow: self.host?.contextWindow(for: screen.session, over: screen).map { open in
                { [weak screen] in
                    screen?.stowKeys()
                    open()
                }
            },
            bot: self.host?.botInfo(for: screen.session, over: screen))
        AppLog.trace("chatui", "model panel opened \(AppLog.tag(logScope))")
        modelPanel = ModelPanelView.present(in: host, under: composer, from: composer.modelChip, floor: floor,
                                            face: (screen.session.head, screen.session.profile), actions: actions)
        if modelPanel == nil { composer.holdsRows = false }
        // A context window models.dev lists shows on the next open once its copy is fetched (a day old at most).
        Task { _ = await ModelsDevCache.shared.load() }
    }

    var modelPanelOpen: Bool { modelPanel != nil }

    /// Closes the model panel if it is open (a send: the chat moves on, the settings already took).
    func closeModelPanel() { modelPanel?.close() }

    #if DEBUG
    func debugHoldModelPanelDial(at position: CGFloat) { modelPanel?.debugHoldDial(at: position) }
    func debugSweepModelPanelDial() { modelPanel?.debugSweepDial() }
    func debugCloseModelPanel() { modelPanel?.close() }
    func debugModelPanelAllModels() { modelPanel?.debugAllModels() }
    func debugOpenModelPanelApprovals() { modelPanel?.debugOpenApprovals() }
    func debugOpenModelPanelFact(_ title: String) { modelPanel?.debugOpenFact(title) }   // [context-window]
    func debugOpenModelPanelMenu() { modelPanel?.debugOpenMenu() }
    func debugWarpModelPanelDial() { modelPanel?.debugWarpDial() }
    #endif

    // MARK: Prompts · Usage & Limits · Model Prices (TestFlight feedback 2026-10-24)

    /// Under Model ▸, in a bot's chat and any other: the prompt library, what is left on your plans, and what each model
    /// costs. The last two read the gateway (offline: off, "Offline"); their subtitles come from the cached catalog.
    private func toolRows() -> [UIMenuElement] {
        guard live != nil, let context else { return [] }
        let options = context.options
        let current = context.current()
        func row(_ id: String, _ title: String, _ subtitle: String?, _ symbol: String, needsGateway: Bool,
                 _ open: @escaping (ChatMenus) -> Void) -> UIAction {
            let off = needsGateway && offline
            let action = UIAction(title: title, subtitle: off ? "Offline" : subtitle, image: UIImage(systemName: symbol),
                                  attributes: off ? .disabled : []) { [weak self] _ in
                Haptics.play(.selection)
                if let self { open(self) }
            }
            action.accessibilityIdentifier = "chat.more.\(id)"
            return action
        }
        let count = PromptLibrary.shared.prompts.count
        return [
            row("prompts", "Prompts", count == 0 ? nil : count == 1 ? "1 saved" : "\(count) saved", "text.book.closed",
                needsGateway: false) { $0.presentPrompts() },
            row("usage", "Usage & Limits", UsageLimitsModel.menuSubtitle(options, provider: current.provider),
                "gauge.with.dots.needle.33percent", needsGateway: true) { $0.presentUsage() },
            row("prices", "Model Prices", ModelPricesModel.menuSubtitle(options, model: current.id, provider: current.provider,
                                                                        fallback: ModelsDevCache.shared.stored()),
                "dollarsign.circle", needsGateway: true) { $0.presentPrices() },
        ]
    }

    /// [mac] Stress test 2026-10-31: the menu bar's Chat menu offers the same three rows (`ChatMenuBar`).
    enum ToolRow: String { case prompts, usage, prices }

    /// Whether the ⋯ would offer the row now and not dim it: Prompts in any chat (a group room's ⋯ has it too); Usage
    /// and Prices in a live chat with a model list, with the gateway.
    func canOpen(_ row: ToolRow) -> Bool {
        if row == .prompts { return screen != nil }
        guard live != nil, context != nil else { return false }
        return row == .prompts || !offline
    }

    func open(_ row: ToolRow) {
        switch row {
        case .prompts: presentPrompts()
        case .usage: presentUsage()
        case .prices: presentPrices()
        }
    }

    func presentPrompts() {
        guard let screen else { return }
        let draft = screen.composer.text
        screen.stowKeys()
        // [ipad-polish] Under ⋯ in two panes.
        let bar = screen.navigationController?.navigationBar
        PanePopover.hangNext(on: bar, rect: bar?.hqTrailingButtonRect, arrow: .up, from: screen)
        let sheet = PromptsSheet.make(draft: draft) { [weak screen] text in
            screen?.composer.insertPrompt(text)
        }
        MenusSheet.top(screen)?.present(sheet, animated: true)
    }

    func presentUsage() {
        guard let screen, let context, let live else { return }
        screen.stowKeys()
        MenusSheet.top(screen)?.present(UsageLimitsSheet.make(context: context, chat: live), animated: true)
    }

    func presentPrices() {
        guard let screen, let context else { return }
        screen.stowKeys()
        MenusSheet.top(screen)?.present(ModelPricesSheet.make(context: context), animated: true)
    }

    // MARK: ModelSwitchUI (spec 1x §5)

    func confirmModelChange(_ message: String) async -> Bool {
        // A sheet still closing (the Models sheet after a pick) would refuse the alert without an error: wait it out.
        for _ in 0..<40 {
            guard let top = MenusSheet.top(screen),
                  top.transitionCoordinator != nil || top.presentedViewController?.isBeingDismissed == true else { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await withCheckedContinuation { continuation in
            // Answered exactly once: by a button, or as Cancel when the alert never showed.
            // [intents] Or when it went away with no button tapped (a shortcut, a quick action, a tapped notification).
            let once = AlertAnswer(continuation, unanswered: false)
            let alert = UIAlertController(title: "Change Model?", message: message.isEmpty ? nil : message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in once.answer(false) })
            let change = UIAlertAction(title: "Change Model", style: .default) { _ in once.answer(true) }
            alert.addAction(change)
            alert.preferredAction = change
            guard let top = MenusSheet.top(screen) else { once.answer(false); return }
            top.present(alert, animated: true) { [weak alert] in
                if alert?.presentingViewController == nil { once.answer(false) }
            }
            // `present` can drop the alert without calling back (another presentation or dismissal won the race).
            Task { [weak alert] in
                try? await Task.sleep(for: .seconds(1))
                if alert?.presentingViewController == nil { once.answer(false) }
            }
        }
    }

    func modelChangeFailed(_ reason: String) {
        Haptics.play(.error)
        failure(title: "Couldn’t Change Model", reason: reason, retry: nil)
    }

    func switchNotice(_ text: String, duration: TimeInterval?, spinner: Bool) {
        screen?.showNotice(text, duration: duration, spinner: spinner)
    }

    func hideSwitchNotice() { screen?.hideNotice() }

    // MARK: Alerts

    /// For logs only: a quoted title or file name inside a UI string is not the app's own words.
    private static func logSafe(_ text: String) -> String {
        text.replacingOccurrences(of: "“[^”]*”|\"[^\"]*\"", with: "“…”", options: .regularExpression)
    }

    /// A failure with its reason: Show Details · (Try Again) · OK (S:ui-kit/native-alert.ts:103-121).
    func failure(title: String, reason: String, retry: (() -> Void)?) {
        AppLog.note("chatui", "failure alert shown \(AppLog.tag(logScope)): \(Self.logSafe(title)), retry offered: \(retry != nil)")
        let alert = UIAlertController(title: title, message: reason, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Show Details", style: .default) { [weak self] _ in
            guard let top = MenusSheet.top(self?.screen) else { return }
            top.present(ChatErrorDetailsSheet.make(details: reason), animated: true)
        })
        if let retry, !SessionActionText.isRefusal(reason) {
            let again = UIAlertAction(title: "Try Again", style: .default) { _ in retry() }
            alert.addAction(again)
            alert.preferredAction = again
        }
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        MenusSheet.top(screen)?.present(alert, animated: true)
    }

    func alert(title: String, message: String) {
        Haptics.play(.error)
        AppLog.note("chatui", "alert shown \(AppLog.tag(logScope)): \(Self.logSafe(title))")
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        MenusSheet.top(screen)?.present(alert, animated: true)
    }

    // MARK: Share (spec 1x §4.4)

    func shareTranscript() {
        guard !preparingShare, let screen else { return }
        guard let actions = session as? ChatSessionActions, let live else {
            present(text: ChatTranscriptText.make(session))
            return
        }
        preparingShare = true
        let fetches = live.hasOlder || live.openPhase != .open
        if fetches { screen.showNotice("Preparing transcript…", duration: nil, spinner: false) }
        Task { [weak self] in
            do {
                let text = try await actions.transcriptText()
                guard let self else { return }
                self.preparingShare = false
                if fetches { self.screen?.hideNotice() }
                self.present(text: text)
            } catch {
                guard let self else { return }
                self.preparingShare = false
                if fetches { self.screen?.hideNotice() }
                Haptics.play(.error)
                self.failure(title: "Couldn’t Share Chat", reason: MenusError.text(error)) { [weak self] in self?.shareTranscript() }
            }
        }
    }

    private func present(text: String) {
        guard let screen else { return }
        let messages = session.messages.contains { ($0.role == .user || $0.role == .assistant) && !ChatTranscript.blocks($0).isEmpty }
        guard messages || text.split(separator: "\n").count > 1 else {
            AppLog.trace("chatui", "share chat \(AppLog.tag(logScope)) skipped: nothing to share")
            screen.showNotice("Nothing to share yet.")
            return
        }
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        DebugHooks.recordText(text, as: "share.txt")
        #endif
        let share = UIActivityViewController(activityItems: [TranscriptShareItem(text: text, title: title.isEmpty ? "Chat" : title)],
                                             applicationActivities: nil)
        share.popoverPresentationController?.sourceItem = screen.moreBarItem
        AppLog.trace("chatui", "share chat \(AppLog.tag(logScope)) sheet shown: \(text.count) characters")
        MenusSheet.top(screen)?.present(share, animated: true)
    }

    // MARK: Rename (spec 1x §4.5)

    /// The titles a chat has before anyone names it: a new chat's "New Chat", a cleared title's "Untitled Chat".
    static func isUnnamed(_ title: String) -> Bool {
        ["", "new chat", "untitled chat"].contains(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The empty chat's Name Chat shortcut shows: the ⋯ would offer Rename… and the chat has no name of its own yet.
    var canName: Bool {
        guard let actions = session as? ChatSessionActions, !actions.isBotChat else { return false }
        return Self.isUnnamed(session.title)
    }

    /// An unnamed chat's field opens empty (not "New Chat" to delete first) and Save waits for a name.
    func promptRename(_ prefill: String? = nil) {
        guard let actions = session as? ChatSessionActions else { return }
        let current = session.title
        let unnamed = Self.isUnnamed(current)
        let alert = UIAlertController(title: unnamed ? "Name Chat" : "Rename Chat", message: nil, preferredStyle: .alert)
        var field: UITextField?
        alert.addTextField { text in
            text.text = prefill ?? (unnamed ? "" : current)
            text.placeholder = unnamed ? "Chat Name" : "Untitled Chat"
            text.autocapitalizationType = .sentences
            text.autocorrectionType = .yes
            text.clearButtonMode = .whileEditing
            text.accessibilityIdentifier = "rename.field"
            field = text
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let save = UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            let typed = field?.text ?? ""
            self?.rename(actions, to: typed)
        }
        func savable(_ typed: String) -> Bool {
            let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed != current && !(unnamed && Self.isUnnamed(trimmed))
        }
        save.isEnabled = savable(prefill ?? (unnamed ? "" : current))
        alert.addAction(save)
        alert.preferredAction = save
        field?.addAction(UIAction { _ in save.isEnabled = savable(field?.text ?? "") }, for: .editingChanged)
        MenusSheet.top(screen)?.present(alert, animated: true)
    }

    private func rename(_ actions: ChatSessionActions, to typed: String) {
        Task { [weak self] in
            do {
                try await actions.rename(to: typed)
                Haptics.play(.success)   // as a rename from Sessions
                // Never the new title: just that it took.
                if let self { AppLog.trace("chatui", "rename chat \(AppLog.tag(self.logScope)) succeeded") }
            } catch {
                Haptics.play(.error)
                if let self { AppLog.note("chatui", "rename chat \(AppLog.tag(self.logScope)) failed") }
                self?.failure(title: "Couldn’t Rename Chat", reason: SessionActionText.plain(MenusError.text(error), owner: self?.menuState().owner)) { [weak self] in self?.rename(actions, to: typed) }
            }
        }
    }

    // MARK: Sheets

    /// More Models… (spec 1x §6); `query` fills its search field (`/model <query>`).
    func presentModelSheet(query: String?) {
        guard let context, let switcher, let screen else { return }
        screen.stowKeys()
        let bot = host?.botInfo(for: screen.session, over: screen)?.name   // [model-scope] for "Change <Bot>'s default…"
        #if targetEnvironment(macCatalyst)
        // [mac-popups] A pop-over hung off the composer's ☰, not a window-tall form sheet; the caret goes back to the
        // field when it closes, whichever way.
        let panel = MacModelsPanel(anchor: Self.composerAnchor(screen), clearOf: screen.composer, context: context, query: query, bot: bot, onPick: { [weak screen] model in
            Task { await switcher.switchModel(model) }
            screen?.focusComposer()
        }, onCancel: { [weak screen] in screen?.focusComposer() })
        if let host = MenusSheet.top(screen) { _ = MacPickPanel.present(panel.panel, from: host) }
        return
        #else
        PanePopover.hangNext(on: screen.composer.modelChip, arrow: .down, from: screen)   // [ipad-polish] off the model's name in two panes
        let sheet = ModelSheetViewController.make(context: context, query: query, bot: bot) { model in
            Task { await switcher.switchModel(model) }
        }
        MenusSheet.top(screen)?.present(sheet, animated: true)
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// What the Mac's composer pop-overs hang off: the ☰ when it shows, else the composer's own box.
    static func composerAnchor(_ screen: ChatViewController) -> UIView {
        let button = screen.composer.commandsButton
        return button.isHidden || button.window == nil ? screen.composer : button
    }
    #endif

    /// The ☰ commands sheet (spec 1x §7): the keyboard goes down for it; nothing touches the field until a pick.
    func presentCommandsSheet() {
        guard let live, let screen else { return }
        screen.stowKeys()
        let loader: (Bool) async throws -> CommandsCatalog = { [weak live] fresh in
            guard let live else { throw CancellationError() }
            return try await live.loadCommandsCatalog(fresh: fresh)
        }
        // [mac-popups] The Mac gives the caret back to the field after a pick (and after an Esc), as a pop-over does.
        let refocus = DeviceWord.isMac
        let onPick: (SlashCatalog.Row, SlashCatalog.PickAction) -> Void = { [weak self, weak screen, weak live] row, action in
            switch action {
            case .send:
                guard let screen else { return }
                // /yolo, /pause and /undo ask first (they change the session at once); everything else sends.
                guard let confirm = SlashCatalog.confirmation(row.command, yoloOn: live?.modelState.yolo ?? false) else {
                    screen.runCommand(row.command)
                    if refocus { screen.focusComposer() }
                    return
                }
                let alert = UIAlertController(title: confirm.title, message: confirm.message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak screen] _ in
                    if refocus { screen?.focusComposer() }
                })
                alert.addAction(UIAlertAction(title: confirm.button, style: .destructive) { [weak screen] _ in
                    screen?.runCommand(row.command)
                    if refocus { screen?.focusComposer() }
                })
                MenusSheet.top(screen)?.present(alert, animated: true)
            case .models: self?.presentModelSheet(query: nil)
            case .insert: screen?.composer.insertCommand(row.command)
            }
        }
        #if targetEnvironment(macCatalyst)
        // [mac-popups] Owner 2026-10-31: the ☰ opened an iPhone form sheet. On the Mac it is a pop-over hung off the ☰.
        let panel = MacCommandsPanel(anchor: Self.composerAnchor(screen), clearOf: screen.composer, cached: live.latestCommandsCatalog, isBotChat: live.isBotChat,
                                     favorites: CommandFavorites(accountId: live.account.id), loader: loader, onPick: onPick,
                                     onCancel: { [weak screen] in screen?.focusComposer() })
        if let host = MenusSheet.top(screen) { _ = MacPickPanel.present(panel.panel, from: host) }
        #else
        // This profile's list paints at once when one was read before (then the fresh answer replaces it).
        PanePopover.hangNext(on: screen.composer.commandsButton, arrow: .down, from: screen)   // [ipad-polish] off ☰ in two panes
        let sheet = CommandsSheetViewController.make(cached: live.latestCommandsCatalog, isBotChat: live.isBotChat,
                                                     favorites: CommandFavorites(accountId: live.account.id), loader: loader, onPick: onPick)
        MenusSheet.top(screen)?.present(sheet, animated: true)
        #endif
    }

    // MARK: Hold menus (spec 1x §9)

    func messageMenu(rowId: String, source: UIView) -> UIMenu? {
        let messageId = String(rowId.prefix { $0 != "|" })
        guard let message = session.messages.last(where: { $0.id == messageId }), message.role != .system else { return nil }
        // [groups] A delivery from another bot is not your message (§7.12): a reply's items without Branch and
        // Regenerate, its sender in the title, its text without the prefix.
        var delivery: (name: String, body: String)?
        if message.role == .user, case .text(let text)? = message.parts.first, DeliveryMessages.mayBeDelivery(text),
           let parsed = DeliverySender.parse(text) {
            delivery = (DeliveryMessages.sender(for: parsed, roster: DeliveryRoster.seats).name, parsed.body)
        }
        let you = message.role == .user && delivery == nil
        let bot = ((session as? ChatSessionDetails)?.botName ?? session.title).trimmingCharacters(in: .whitespaces)
        let sender = delivery?.name ?? (you ? "You" : (bot.isEmpty ? "Hermes" : bot))
        let markdown = delivery?.body ?? Self.copyText(message)
        let actions = session as? ChatSessionMoreActions
        var ctx = MessageMenuContext()
        ctx.streaming = message.isStreaming
        ctx.running = session.isRunning
        ctx.offline = offline
        if you {
            ctx.canEdit = actions?.canRewind(messageId) ?? false
            ctx.canRewind = ctx.canEdit
            ctx.undelivered = actions != nil && message.error != nil && !message.isPending
        } else {
            ctx.latest = actions != nil && latestReplyId == messageId
            ctx.reading = screen?.voice.talkIsReading(messageId: messageId)   // [talk] the Read Aloud tile
        }
        let kind: MessageMenuKind = you ? .you : .reply
        var tiles = MessageMenuModel.tiles(kind, ctx)
        var rows = MessageMenuModel.rows(kind, ctx)
        // Branch from a reply asks the live chat; a chat without the actions keeps Copy, Share and Select Text.
        if actions == nil { rows.removeAll { $0.id == .branch || $0.id == .regenerate } ; tiles.removeAll { $0.id == .edit } }
        if delivery != nil { rows.removeAll { $0.id == .branch || $0.id == .regenerate } }   // [groups]
        func item(_ row: MessageMenuRow, tile: Bool = false) -> UIAction {
            var attributes: UIMenuElement.Attributes = row.disabled ? .disabled : []
            if row.destructive { attributes.insert(.destructive) }
            // [talk] "Stop Reading" is wider than a tile: it breaks at its space, where the system would hyphenate it
            // ("Stop Read-ing").
            let title = tile && row.id == .readAloud && row.title.count > 10 ? row.title.replacingOccurrences(of: " ", with: "\n") : row.title
            let action = UIAction(title: title, subtitle: row.subtitle, image: UIImage(systemName: row.symbol), attributes: attributes) {
                [weak self, weak source] _ in
                self?.performMessage(row.id, messageId: messageId, markdown: markdown, source: source)
            }
            action.accessibilityIdentifier = "message.\(row.id == .selectText ? "select" : row.id.rawValue)"
            return action
        }
        var children: [UIMenuElement] = [UIMenu(title: "", options: .displayInline, preferredElementSize: .medium,
                                                children: tiles.map { item($0, tile: true) })]
        children += rows.map { item($0) }
        // Reply (Swipe to Reply's menu twin, and the Mac's way in): first under the tiles.
        if !you, delivery == nil, message.role == .assistant, let screen, screen.chatCellCanReply(rowId: rowId) {
            let reply = UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak self] _ in
                self?.beginReply(messageId)
            }
            reply.accessibilityIdentifier = "message.reply"
            children.insert(reply, at: 1)
        }
        // [activity] Show / Hide Steps on a reply that has steps (docs/spec/1x-activity.md §10.5; spec 1x §9 table).
        if !you, let screen, let steps = StepsMenu.item(forMessage: messageId, in: screen) {
            let at = children.firstIndex { ($0 as? UIAction)?.accessibilityIdentifier == "message.rewind" } ?? children.count
            children.insert(steps, at: at)
        }
        // Message Reactions (Settings, default Off): the six Tapbacks, after Select Text. Yours is ticked; picking it
        // again takes it off.
        if delivery == nil, let react = reactMenu(messageId: messageId, current: message.reactions.first(where: \.isMine)?.emoji) {
            let at = children.firstIndex { ($0 as? UIAction)?.accessibilityIdentifier == "message.select" }.map { $0 + 1 }
                ?? min(1, children.count)
            children.insert(react, at: at)
        }
        // Your message into ⋯ › Prompts (before Delete and the other red rows).
        let words = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if you, !words.isEmpty {
            let saved = PromptLibrary.shared.contains(text: words)
            let save = UIAction(title: saved ? "Saved to Prompts" : "Save as Prompt", image: UIImage(systemName: "text.book.closed"),
                                attributes: saved ? .disabled : []) { [weak self] _ in
                PromptLibrary.shared.add(text: words)
                Haptics.play(.success)
                MenusHUD.show("Saved to Prompts", in: self?.screen?.view)
            }
            save.accessibilityIdentifier = "message.savePrompt"
            let at = children.firstIndex { ($0 as? UIAction)?.attributes.contains(.destructive) == true } ?? children.count
            children.insert(save, at: at)
        }
        // "<sender> · <when>" (the model joins it only when a reply's own model differs from the chat's; the transcript
        // this app reads doesn't carry a reply's model).
        let title = MessageMenuModel.title(sender: sender, model: nil, currentModel: nil, when: ChatTranscript.when(message.timestamp))
        return UIMenu(title: title, children: children)
    }

    /// React › the six Tapbacks; nil when this chat can't take one now (the switch is off, an older Hermes, offline, a
    /// message not stored yet).
    private func reactMenu(messageId: String, current: String?) -> UIMenu? {
        guard let live = session as? LiveChatSession, live.canReact(to: messageId) else { return nil }
        let items = MessageReactions.quick.map { emoji in
            let action = UIAction(title: "\(emoji)  \(MessageReactions.name(emoji))", state: emoji == current ? .on : .off) { [weak self] _ in
                self?.react(live, messageId: messageId, emoji: emoji)
            }
            action.accessibilityLabel = MessageReactions.name(emoji)
            action.accessibilityIdentifier = "message.react.\(MessageReactions.quick.firstIndex(of: emoji) ?? 0)"
            return action
        }
        let menu = UIMenu(title: "React", image: UIImage(systemName: "face.smiling"), children: items)
        menu.accessibilityIdentifier = "message.react"
        return menu
    }

    private func react(_ live: LiveChatSession, messageId: String, emoji: String) {
        Haptics.play(.selection)
        Task { [weak self] in
            do {
                try await live.react(to: messageId, emoji: emoji)
            } catch LiveChatSession.ReactError.unsupported {
                FailureAlert.present(title: "Reactions Aren’t Available", reason: "This Hermes doesn’t support reactions yet.",
                                     from: self?.screen)
            } catch LiveChatSession.ReactError.failed(let reason) {
                FailureAlert.present(title: "Couldn’t React", reason: reason, from: self?.screen)
            } catch {
                FailureAlert.present(title: "Couldn’t React", reason: MenusError.text(error), from: self?.screen)
            }
        }
    }

    /// Your badge tapped: it comes off (as picking it again in React does).
    func removeReaction(messageId: String) {
        guard let live = session as? LiveChatSession, live.canReact(to: messageId),
              let mine = live.messages.last(where: { $0.id == messageId })?.reactions.first(where: \.isMine) else { return }
        react(live, messageId: messageId, emoji: mine.emoji)
    }

    /// The newest reply that shows words (Regenerate is offered on it).
    var latestReplyId: String? {
        session.messages.last { $0.role == .assistant && !ChatTranscript.blocks($0).isEmpty }?.id
    }

    private func performMessage(_ id: MessageMenuItemID, messageId: String, markdown: String, source: UIView?) {
        switch id {
        case .copy:
            UIPasteboard.general.string = markdown
            #if DEBUG
            DebugHooks.recordText(UIPasteboard.general.string ?? "", as: "copy.txt")
            #endif
            Haptics.play(.success)
            MenusHUD.show("Copied", in: screen?.view)
        case .share: shareMessage(markdown, from: source)
        case .selectText:
            guard let top = MenusSheet.top(screen) else { return }
            top.present(SelectTextViewController.make(text: ChatTranscript.readableText(markdown)), animated: true)
        case .steps: break   // the [activity] stream's own item
        case .readAloud: screen?.voice.talkToggleRead(messageId: messageId)   // [talk]
        default: performMessageAction(id, messageId: messageId)
        }
    }

    /// What Copy, Share and Select Text take from a message: its Markdown; for your voice memo, the words said and
    /// anything typed with it, never the `MEDIA:` directive and the gateway's file path (M1's Copy, ChatRow.swift).
    /// A reply's hidden thinking (`<think>…</think>` written into its words) is never copied or shared.
    static func copyText(_ message: ChatMessage) -> String {
        let markdown = ChatTranscript.messageText(message)
        if message.role == .assistant { return ReasoningTags.strip(markdown) }
        guard message.role == .user, let memo = VoiceMemo.parse(markdown) else { return markdown }
        return memo.copyText
    }

    func shareMessage(_ markdown: String, from source: UIView?) {
        guard let screen else { return }
        let share = UIActivityViewController(activityItems: [ChatTranscript.readableText(markdown)], applicationActivities: nil)
        if let source {
            share.popoverPresentationController?.sourceItem = source
        } else if let popover = share.popoverPresentationController {
            // [m9/ipad] Never without an anchor on iPad (it crashes): the screen's centre, no arrow.
            popover.sourceView = screen.view
            popover.sourceRect = CGRect(x: screen.view.bounds.midX, y: screen.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        MenusSheet.top(screen)?.present(share, animated: true)
    }
}

/// The transcript for the share sheet, titled with the chat's title.
final class TranscriptShareItem: NSObject, UIActivityItemSource {
    let text: String
    let title: String

    init(text: String, title: String) {
        self.text = text
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { text }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        text
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        title
    }
}

// MARK: - The chat screen's menu entry points

extension ChatViewController {
    /// More Models… from anywhere (the ⋯, `/model`, later the error banner's "Choose a model").
    func presentModelSheet(query: String? = nil) { menus?.presentModelSheet(query: query) }

    /// The ☰ commands sheet.
    func presentCommandsSheet() { menus?.presentCommandsSheet() }

    func chatCellMenu(rowId: String, source: UIView) -> UIMenu? {
        if let roomChrome { return roomChrome.messageMenu(rowId: rowId, source: source) }   // [groups] Copy · Reply · Mention (Read Aloud joins with voice)
        return menus?.messageMenu(rowId: rowId, source: source)
    }

    /// A folded row held (UX study 2026-10-19): a delivery or a finished subagent / background task offers Copy, Read
    /// Aloud and Share of its words; a tool row of one step, Copy Command and Copy Output. The row stays folded.
    func chatCellRowMenu(rowId: String, source: UIView) -> UIMenu? {
        guard let row = activityRow(id: rowId) else { return nil }
        func copy(_ title: String, _ text: String, id: String) -> UIAction {
            let action = UIAction(title: title, image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                UIPasteboard.general.string = text
                Haptics.play(.success)
                MenusHUD.show("Copied", in: self?.view)
            }
            action.accessibilityIdentifier = id
            return action
        }
        var held: BackgroundResultRow?
        switch row.kind {
        case .backgroundResult(let result):
            guard (result.group?.count ?? 1) == 1 else { return nil }   // [updates] a group's line: its members have menus
            held = result
        case .updateMember(let member):
            held = member.result                                         // [updates] a member of an opened group
        default:
            break
        }
        switch row.kind {
        case .backgroundResult, .updateMember:
            guard let result = held else { return nil }
            let text = RowHoldMenu.resultText(title: result.title, result: result.result, delivery: result.delivery || result.cron)
            guard !text.isEmpty else { return nil }
            var children: [UIMenuElement] = [copy("Copy", text, id: "row.copy")]
            if voice.talkReadsAloud {
                let reading = voice.talkIsReading(messageId: row.messageId) == true
                let read = UIAction(title: reading ? "Stop Reading" : "Read Aloud",
                                    image: UIImage(systemName: reading ? "stop.circle" : "speaker.wave.2")) { [weak self] _ in
                    self?.voice.talkToggleRead(messageId: row.messageId, text: text)
                }
                read.accessibilityIdentifier = "row.readAloud"
                children.append(read)
            }
            let share = UIAction(title: MenuWords.share, image: UIImage(systemName: "square.and.arrow.up")) { [weak self, weak source] _ in
                self?.menus?.shareMessage(text, from: source)
            }
            share.accessibilityIdentifier = "row.share"
            children.append(share)
            return UIMenu(children: children)
        case .toolRun(let run):
            guard run.line == nil, !run.live, run.tools.count == 1, let call = run.tools.first else { return nil }
            let detail = (session as? ChatToolDetails)?.toolDetail(messageId: row.messageId, toolId: call.id)
            let copies = RowHoldMenu.copies(detail)
            var children: [UIMenuElement] = []
            if let command = copies.command { children.append(copy("Copy Command", command, id: "row.copyCommand")) }
            if let output = copies.output { children.append(copy("Copy Output", output, id: "row.copyOutput")) }
            return children.isEmpty ? nil : UIMenu(children: children)
        default:
            return nil
        }
    }

    func chatCellRemoveReaction(rowId: String) {
        menus?.removeReaction(messageId: String(rowId.prefix { $0 != "|" }))
    }

    /// Swipe to Reply: a member's message in a group room (its own thread reply), else a reply in a chat you can send in.
    func chatCellCanReply(rowId: String) -> Bool {
        if roomChrome != nil { return true }
        guard menus != nil, session is LiveChatSession else { return false }
        let messageId = String(rowId.prefix { $0 != "|" })
        return session.messages.last { $0.id == messageId }?.role == .assistant
    }

    func chatCellReply(rowId: String) {
        if let roomChrome {
            if roomChrome.reply(rowId: rowId) { Haptics.play(.selection) }
            return
        }
        menus?.beginReply(String(rowId.prefix { $0 != "|" }))
    }

    /// MENUS: the latest reply's action row (Regenerate · More) in a chat that has them.
    var chatCellOffersRegenerate: Bool { menus?.offersReplyActions ?? false }
    func chatCellReplyMore(rowId: String, source: UIView) -> UIMenu? { menus?.replyMoreMenu(rowId: rowId, source: source) }
    func chatCellRegenerate(rowId: String) { menus?.confirmRegenerate() }

    /// [transcript] A held link's menu (docs/spec/3x-transcript.md L492, L568): the whole address as its title, then Open
    /// (as a tap does), Open in Safari for a web page, Copy Link and Share…; a file path, Open and Copy Path. An
    /// attachment's `#media:` link keeps the message's menu, except a page's ([pins] Open, Pin, Share…, Copy Path).
    func chatCellLinkMenu(url: URL, source: UIView) -> UIMenu? {
        if let ref = MarkdownMedia.ref(fromLink: url) { return pageCardMenu(ref, url: url) }
        let open = UIAction(title: "Open", image: UIImage(systemName: "arrow.up.right.square")) { [weak self] _ in
            self?.chatCellOpen(url: url)
        }
        open.accessibilityIdentifier = "link.open"
        // A file path a bot names (`FileLinks`): the path itself as the title and on the clipboard, not its `#file:`
        // link, which titled the menu in percent escapes and copied as one (stress test 2026-10-31: a right-click is
        // how a Mac copies a path).
        if let path = FileLinks.path(fromLink: url) {
            let copy = UIAction(title: "Copy Path", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                UIPasteboard.general.string = path
                Haptics.play(.success)
                MenusHUD.show("Copied", in: self?.view)
            }
            copy.accessibilityIdentifier = "link.copy-path"
            let pin = pinAction(path: path, name: (path as NSString).lastPathComponent)   // [pins]
            return UIMenu(title: path, children: [open] + (pin.map { [$0] } ?? []) + [copy])
        }
        var children: [UIMenuElement] = [open]
        if case .page(let page) = LinkTargets.target(url) {
            let safari = UIAction(title: LinkOpener.outsideTitle, image: UIImage(systemName: "safari")) { _ in LinkOpener.openOutside(page) }   // [links-browser]
            safari.accessibilityIdentifier = "link.safari-open"
            children.append(safari)
        }
        let copy = UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            UIPasteboard.general.url = url
            Haptics.play(.success)
            MenusHUD.show("Copied", in: self?.view)
        }
        copy.accessibilityIdentifier = "link.copy"
        let share = UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self, weak source] _ in
            guard let self else { return }
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceItem = source ?? self.view
            MenusSheet.top(self)?.present(sheet, animated: true)
        }
        share.accessibilityIdentifier = "link.share"
        children += [copy, share]
        return UIMenu(title: url.absoluteString, children: children)
    }

    /// A long opened One Line card's "Show All N Steps": the reply's turn in the Steps sheet.
    func chatCellShowAllSteps(rowId: String) {
        guard let row = activityRow(id: rowId) else { return }
        activity.openStepsSheet(forMessage: row.messageId)
    }

    /// The thinking row tapped: the running turn's steps, live (owner, 2026-10-29: "aren't clickable").
    func chatCellShowLiveSteps() {
        activity.openStepsSheet(forMessage: nil)
    }
}
