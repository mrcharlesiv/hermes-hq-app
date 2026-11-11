import UIKit

// The chat screen's side of the activity stream (docs/spec/1x-activity.md): the shelf above the composer (§4–§7), the
// row input for the Tool Call Styles and After Reply › Hide (§10), the fold (fade in place, one removal, slide — never a
// height animation, owner on build 188), In Header's tappable status line and its live Steps sheet (§10.4), the
// complete step sheet (§12), Show / Hide Steps on a reply, and the goal's actions (§6.4). `ChatViewController` owns one
// and calls it at the places marked `[activity]`.

@MainActor final class ChatActivityController: NSObject {
    unowned let chat: ChatViewController
    let shelf = ActivityShelfView()
    private var shelfHeight: NSLayoutConstraint?
    private var jumpBottom: NSLayoutConstraint?
    private weak var queueCard: UIView?
    /// What the shelf sits on (its top is the shelf's bottom + the gap).
    private weak var shelfBase: UIView?
    /// The shelf's side constraints (constant = the composer row's side inset, so the column lines up).
    private var shelfSides: [NSLayoutConstraint] = []
    private var sideInset: CGFloat = ChatMetrics.composerSideDown
    private let statusTap = UIControl()
    private var installed = false
    private var attached = false
    private var settingsObserver: NSObjectProtocol?
    /// The shelf's height is changing: the transcript's rows on screen stay where they are (§7.3).
    private(set) var shelfChanging = false

    // Shelf state (screen-only)
    private var openPieces: Set<ShelfPieceKind> = []
    private var selectedSubagent: String?
    private var steerDrafts: [String: String] = [:]
    private var steerFeedback: [String: SubagentsBody.Feedback] = [:]
    private var steerBusy: Set<String> = []
    /// The selected child as last seen live: its detail can stay a moment after it ends (while you type to it).
    private var selectedSnapshot: SubagentProgress?
    /// The selected child that ended and was announced (once).
    private var announcedEnd: String?
    /// You folded the live Tasks card: a new list doesn't open it again until your next turn starts.
    private var userFoldedTasks = false
    private var wasRunning = false
    /// A done goal or a finished Previous tasks list you hid from the shelf (memory only, while the app runs; no
    /// gateway call). Keyed by the bot, the goal's title and start, or the list's items.
    private static var hiddenPieces: Set<String> = []
    /// The jump button's width now: the round arrow, or the wider "Approval needed" capsule (L422).
    private var jumpWidth: CGFloat = ChatMetrics.jumpSize
    private lazy var subagentsBody = SubagentsBody()
    private lazy var tasksBody = TasksBody()
    private lazy var previousBody = TasksBody()
    private lazy var goalBody = GoalBody()

    // Steps (Hide fold, Show Steps)
    private var revealedFallback: Set<String> = []
    /// Replies whose steps were brought back (Show Steps): kept by the session while the app runs (§10.5).
    private var revealed: Set<String> {
        get { provider?.revealedSteps ?? revealedFallback }
        set { if let p = provider { p.revealedSteps = newValue } else { revealedFallback = newValue } }
    }
    private var folding: Set<String> = []
    /// Replies that turned done while on screen: their action row waits for the fold's removal (one motion).
    private var holdingActions: Set<String> = []
    private var workingSeen: Set<String> = []
    /// The fold whose one removal is next (its message id); until it lands, every apply notes where the rows were.
    private var foldPending: String?
    private var slideWanted = false
    private var flipFrames: [String: CGFloat]?
    private var revealPending: String?
    /// Content views a fold faded, with the cell and row they belong to: they come back only when the fold's removal
    /// lands, or at once if their cell went on to show another row (an unrelated apply never pops them back).
    private var faded: [(view: UIView, cell: ChatBaseCell, rowId: String)] = []
    // Generated images that wouldn't load (their rows are the link row until a retry).
    private var failedImages: Set<String> = []
    /// The open child last reported to the session (the tail read follows it, §4.4).
    private var reportedChild: String??
    private var inLayoutChange = false
    #if DEBUG
    /// Per-frame motion sampler for the UI tests (`-HQDebugMotionProbe YES`).
    private(set) var motionProbe: ActivityMotionProbe?
    #endif
    private weak var stepsSheet: StepsListViewController?
    private var stepsSheetMessage: String??
    private weak var openStepDetail: StepDetailViewController?
    /// [browser] The browser chip's words (App/Browser/BrowserChatCard.swift), nil while the bot isn't browsing.
    var browserChip: (words: String, asking: Bool)? { didSet { if installed { updateShelf(animated: true) } } }
    /// [browser] The chip was tapped (opens Watch Browser).
    var onBrowserChip: (() -> Void)?
    /// [browser] The chat came on screen / left it.
    var onAttachedChange: ((Bool) -> Void)?
    /// [browser] The chat's running state or status changed.
    var onStateChange: (() -> Void)?
    /// [browser] The chat's browser card (kept as long as the screen).
    var browserCard: AnyObject?

    init(chat: ChatViewController) {
        self.chat = chat
        super.init()
    }

    isolated deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        ActivityClock.shared.unsubscribe(self)
    }

    var provider: ChatActivityProviding? { chat.session as? ChatActivityProviding }

    // MARK: Install (viewDidLoad)

    /// `shelfBase`: the view the shelf sits on (integration: the voice memo notice, itself on the queue card; its top is
    /// the queue card's while collapsed). Nil = the queue card.
    func install(queueCard: UIView, jumpBottom: NSLayoutConstraint, statusAnchor: NSLayoutYAxisAnchor, shelfBase: UIView? = nil) {
        guard !installed else { return }
        installed = true
        self.queueCard = queueCard
        self.jumpBottom = jumpBottom
        self.shelfBase = shelfBase ?? queueCard
        let view = chat.view!
        ActivityCells.register(in: chat.tableView)
        shelf.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(shelf, belowSubview: chat.composer)
        let height = shelf.heightAnchor.constraint(equalToConstant: 0)
        shelfHeight = height
        sideInset = chat.dockSideInset
        shelfSides = [shelf.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: sideInset),
                      view.trailingAnchor.constraint(equalTo: shelf.trailingAnchor, constant: sideInset)]
        NSLayoutConstraint.activate(shelfSides + [
            shelf.bottomAnchor.constraint(equalTo: (shelfBase ?? queueCard).topAnchor, constant: -ActivityShelfView.gap),
            height,
        ])
        // In Header: the status line takes taps (a 44 pt area hugging the capsule; the capsule itself stays a picture).
        statusTap.translatesAutoresizingMaskIntoConstraints = false
        statusTap.isHidden = true
        statusTap.isAccessibilityElement = true
        statusTap.accessibilityTraits = .button
        statusTap.accessibilityIdentifier = "chat.status.steps"
        statusTap.addTarget(self, action: #selector(statusTapped), for: .touchUpInside)
        view.addSubview(statusTap)
        NSLayoutConstraint.activate([
            statusTap.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusTap.centerYAnchor.constraint(equalTo: statusAnchor, constant: 7),
            statusTap.widthAnchor.constraint(equalToConstant: 260),
            statusTap.heightAnchor.constraint(equalToConstant: 44),
        ])
        settingsObserver = NotificationCenter.default.addObserver(forName: ToolCallSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        provider?.onActivityChange = { [weak self] in self?.activityChanged() }
        updateShelf(animated: false)
        updateStatusTap()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HQDebugMotionProbe") { motionProbe = ActivityMotionProbe(controller: self) }
        #endif
    }

    // MARK: Screen lifecycle

    func setAttached(_ on: Bool) {
        attached = on
        onAttachedChange?(on)       // [browser]
        reportVisibility(force: true)
        if on { updateShelf(animated: false) }
        #if DEBUG
        if on { motionProbe?.start() } else { motionProbe?.stop() }
        #endif
    }

    /// Tells the session whether the chat shows and which child's detail is open (the polls and the tail follow).
    private func reportVisibility(force: Bool = false) {
        let child = attached ? openChild : nil
        guard force || reportedChild != .some(child) else { return }
        reportedChild = .some(child)
        provider?.setActivityVisible(attached, openSubagent: child)
    }

    /// The open page's child while it runs (a finished one's output stays as last read; its tail isn't polled).
    private var openChild: String? {
        let live = { (id: String?) -> String? in
            guard let id, self.provider?.activity.subagents.first(where: { $0.id == id })?.isLive == true else { return nil }
            return id
        }
        if openPieces.contains(.subagents), let sel = live(selectedSubagent) { return sel }
        // [mac-layout] Or the helper open in the inspector's Helpers tab, while it shows.
        if helpersPanel?.viewIfLoaded?.window != nil { return live(panelSelected) }
        return nil
    }

    /// `isRunning` / connection / status words changed.
    func stateChanged() {
        onStateChange?()            // [browser] the card leaves once the turn is over
        updateStatusTap()
        updateShelf(animated: true)
        refreshStepsSheet()
    }

    /// The session's rows changed.
    func sessionChanged() {
        refreshStepsSheet()
        openStepDetail?.refresh()
    }

    private func activityChanged() {
        updateShelf(animated: true)
        // The delegate cards follow their children (the ticker, statuses, timers). [perf] Only when what the cards read
        // changed: a todo tick, a goal or a tail read leaves them as they were.
        if cardsNeedRebuild(subagents: provider?.activity.subagents ?? [], turnAnchor: provider?.hiddenTurnAnchor) {
            let messages = chat.session.messages
            let ids = messages.suffix(16).filter { m in
                m.parts.contains { if case .tool(let c) = $0 { return c.name == "delegate_task" } else { return false } }
            }.map(\.id)
            if !ids.isEmpty { chat.activityRebuild(messageIds: ids) }
        }
        // Display flags may have changed (reasoning on/off, tool progress).
        if let flags = provider?.displayFlags, flags != lastFlags {
            lastFlags = flags
            invalidateCards()
            chat.activityRebuildAll()
        }
    }
    private var lastFlags = DisplayFlags()

    /// What a delegate card reads from the activity (`ActivityRows` cardRow): when it hasn't changed, the cards haven't.
    /// A card that comes to read more (tails, timers) must add it here.
    struct CardKey: Equatable {
        var subagents: [SubagentProgress]
        var turnAnchor: String?
    }
    /// The key the delegate cards were last rebuilt for (nil: rebuild on the next delivery).
    private var lastCardKey: CardKey?

    /// Whether the delegate cards read something new since their last rebuild (and notes it as rebuilt).
    func cardsNeedRebuild(subagents: [SubagentProgress], turnAnchor: String?) -> Bool {
        let key = CardKey(subagents: subagents, turnAnchor: turnAnchor)
        guard key != lastCardKey else { return false }
        lastCardKey = key
        return true
    }

    /// Everything was rebuilt some other way: the next delivery rebuilds the cards whatever it carries.
    func invalidateCards() { lastCardKey = nil }

    /// A Tool Calls setting changed (the settings screen plays its own selection tap, once).
    private func settingsChanged() {
        invalidateCards()
        chat.activityRebuildAll()
        updateStatusTap()
    }

    // MARK: Rows input (§9, §10)

    func rowsInput() -> ActivityRowsInput {
        var a = ActivityRowsInput()
        a.style = ToolCallSettings.style
        a.hideSteps = ToolCallSettings.hidesSteps
        a.showFileChanges = ToolCallSettings.showFileChanges
        a.revealed = revealed
        a.profile = chat.session.profile
        if let p = provider {
            a.showReasoning = p.displayFlags.showReasoning
            a.toolProgressOff = p.displayFlags.toolProgressOff
            a.subagents = p.activity.subagents
            a.providerWait = p.providerWait
            var seconds: [String: [Int: Double]] = [:]
            for m in chat.session.messages.suffix(40) where m.role == .assistant {
                let s = p.reasoningSeconds(messageId: m.id)
                if !s.isEmpty { seconds[m.id] = s }
            }
            a.reasoningSeconds = seconds
            a.turnAnchor = p.hiddenTurnAnchor
        }
        a.failedImages = failedImages
        if a.hideSteps { noteFolds() }
        a.folding = folding
        a.holdingActions = holdingActions
        return a
    }

    /// A reply that turned from working to done while on screen folds its steps (§10.5).
    private func noteFolds() {
        let messages = chat.session.messages
        let running = chat.session.isRunning
        let anchor = provider?.hiddenTurnAnchor
        for index in max(0, messages.count - 6)..<messages.count where messages[index].role == .assistant {
            let m = messages[index]
            guard m.parts.contains(where: { if case .text = $0 { return false } else { return true } }) else { continue }
            if StepRules.isWorking(m, at: index, in: messages, running: running, turnAnchor: anchor) { workingSeen.insert(m.id); continue }
            guard workingSeen.remove(m.id) != nil, !revealed.contains(m.id), !folding.contains(m.id),
                  StepRules.state(m.parts, working: false) == .done else { continue }
            folding.insert(m.id)
            holdingActions.insert(m.id)
            let id = m.id
            DispatchQueue.main.async { [weak self] in self?.fade(id) }
        }
    }

    // MARK: The fold: fade in place, one removal, slide what moved

    private func stepCells(of messageId: String) -> [ChatBaseCell] {
        chat.tableView.visibleCells.compactMap { $0 as? ChatBaseCell }.filter { cell in
            guard cell.rowId.hasPrefix(messageId + "|"), let row = chat.activityRow(id: cell.rowId) else { return false }
            return row.isStepBlock
        }
    }

    private func fade(_ messageId: String) {
        let cells = stepCells(of: messageId)
        guard !cells.isEmpty, chat.view.window != nil, !HQMotion.reduced else { finishFold(messageId, slide: false); return }
        #if DEBUG
        motionProbe?.foldStarted(messageId: messageId)
        #endif
        faded += cells.map { (view: $0.contentView, cell: $0, rowId: $0.rowId) }
        let curve = UICubicTimingParameters(controlPoint1: CGPoint(x: 0.4, y: 0), controlPoint2: CGPoint(x: 1, y: 1))
        let animator = UIViewPropertyAnimator(duration: 0.2, timingParameters: curve)
        animator.addAnimations {
            for v in cells.map(\.contentView) {
                v.alpha = 0
                // Scale toward the top-leading corner (the content view is flipped inside the inverted table).
                let w = v.bounds.width, h = v.bounds.height
                v.transform = CGAffineTransform(scaleX: 1, y: -1)
                    .translatedBy(x: -w * 0.015, y: h * 0.015)
                    .scaledBy(x: 0.97, y: 0.97)
            }
        }
        animator.addCompletion { [weak self] _ in self?.finishFold(messageId, slide: true) }
        animator.startAnimation()
    }

    /// Step 2: one update removes the faded steps (and brings the held action row). A stream glide or the send lift
    /// still moving the rows ends first — the slide never runs on top of them (`steps-fold.ts:69-71`).
    private func finishFold(_ messageId: String, slide: Bool, waited: Int = 0) {
        if slide, chat.activityMotionBusy, waited < 36 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
                self?.finishFold(messageId, slide: slide, waited: waited + 1)
            }
            return
        }
        #if DEBUG
        motionProbe?.note("finishFold \(messageId) slide=\(slide) busy=\(chat.activityMotionBusy) waited=\(waited)")
        #endif
        folding.remove(messageId)
        holdingActions.remove(messageId)
        foldPending = messageId
        slideWanted = slide && !HQMotion.reduced && !chat.activityMotionBusy
        chat.activityRebuild(messageIds: [messageId])
        if !chat.activityHasStepRows(of: messageId) {
            // Landed in that apply (or nothing was left to remove).
            if foldPending == messageId { landFold() }
        } else {
            // The removal waits for a measure in flight; never leave the steps faded if it doesn't come.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.foldPending == messageId else { return }
                self.landFold()
            }
        }
    }

    private func landFold() {
        foldPending = nil
        slideWanted = false
        flipFrames = nil
        for entry in faded { restore(entry.view) }
        faded = []
    }

    private func restore(_ view: UIView) {
        view.layer.removeAllAnimations()
        view.alpha = 1
        view.transform = CGAffineTransform(scaleX: 1, y: -1)
    }

    /// Before an apply while a fold or a reveal waits: where the rows on screen are (for the slide).
    func willApply() {
        guard slideWanted, foldPending != nil || revealPending != nil else { return }
        var frames: [String: CGFloat] = [:]
        for case let cell as ChatBaseCell in chat.tableView.visibleCells {
            frames[cell.rowId] = cell.convert(cell.bounds, to: chat.view).minY
        }
        flipFrames = frames
    }

    /// After an apply. Faded cells that now show another row come back at once; the fold's own apply (its steps gone)
    /// brings the faded views back and slides every row that moved from where it was (380 ms); a reveal fades its steps
    /// in (200 ms). Returns whether rows slide (the chat then starts no stream glide of its own).
    @discardableResult
    func didApply() -> Bool {
        faded.removeAll { entry in
            guard entry.cell.rowId != entry.rowId || entry.cell.window == nil else { return false }
            restore(entry.view)
            return true
        }
        var slid = false
        if let id = foldPending, !chat.activityHasStepRows(of: id) {
            let frames = flipFrames
            landFold()
            if let frames { slid = slide(from: frames, fold: true) }
            #if DEBUG
            if !slid { motionProbe?.foldEnded() }
            #endif
        }
        if let id = revealPending, chat.activityHasStepRows(of: id) {
            revealPending = nil
            if let frames = flipFrames, slideWanted { slid = slide(from: frames) || slid }
            flipFrames = nil
            slideWanted = false
            if !HQMotion.reduced {
                for cell in stepCells(of: id) {
                    cell.contentView.alpha = 0
                    UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction]) { cell.contentView.alpha = 1 }
                }
            }
        }
        return slid
    }

    /// Step 3: every visible row that moved starts where it was (a transform equal to old − new) and slides home. Rows
    /// that arrived at the newest end (the reply's action row) travel with the row above them.
    private func slide(from frames: [String: CGFloat], fold: Bool = false) -> Bool {
        let table = chat.tableView
        table.layoutIfNeeded()
        let ordered = (table.indexPathsForVisibleRows ?? []).sorted { $0.row < $1.row }
            .compactMap { table.cellForRow(at: $0) as? ChatBaseCell }
        var deltas: [CGFloat?] = ordered.map { cell in frames[cell.rowId].map { $0 - cell.convert(cell.bounds, to: chat.view).minY } }
        if let known = deltas.firstIndex(where: { $0 != nil }) {
            for i in 0..<known { deltas[i] = deltas[known] }
        }
        var moved: [UITableViewCell] = []
        for (cell, delta) in zip(ordered, deltas) {
            guard let delta, abs(delta) > 0.5 else { continue }
            // The table is flipped: a screen offset of +d is −d in its coordinates.
            cell.transform = CGAffineTransform(translationX: 0, y: -delta)
            moved.append(cell)
        }
        #if DEBUG
        motionProbe?.note("slide \(moved.count) rows: \(zip(ordered, deltas).compactMap { c, d in d.map { "\(c.rowId):\(Int($0))" } })")
        #endif
        guard !moved.isEmpty else { return false }
        let curve = UICubicTimingParameters(controlPoint1: CGPoint(x: 0.3, y: 0.1), controlPoint2: CGPoint(x: 0.2, y: 1))
        let animator = UIViewPropertyAnimator(duration: 0.38, timingParameters: curve)   // motion-ok: see the check of `moved` and its callers
        animator.addAnimations { moved.forEach { $0.transform = .identity } }
        #if DEBUG
        if fold { animator.addCompletion { [weak self] _ in self?.motionProbe?.foldEnded() } }
        #endif
        animator.startAnimation()
        return true
    }

    // MARK: Show Steps / Hide Steps (§10.5)

    /// The reply menu's item for `messageId` (nil when it has no steps to show or hide). The menus stream appends it last
    /// (`StepsMenu.item(forMessage:in:)`).
    func stepsMenuItem(forMessage messageId: String) -> UIAction? {
        let messages = chat.session.messages
        guard let index = messages.lastIndex(where: { $0.id == messageId }), messages[index].role == .assistant else { return nil }
        let m = messages[index]
        let ranTools = !turnSteps(endingAt: messageId).isEmpty
        if ToolCallSettings.style == .header {
            guard ranTools else { return nil }
            return UIAction(title: "Show Steps", image: UIImage(systemName: "list.bullet")) { [weak self] _ in
                self?.openStepsSheet(forMessage: messageId)
            }
        }
        guard ToolCallSettings.hidesSteps else { return nil }
        let hasSteps = m.parts.contains { part in
            switch part {
            case .reasoning: return true
            case .tool(let c): return !ToolCards.isCardTool(c.name) && !(ChatRunSummary.isSilent(c.name) && c.state != .failed)
            case .text: return false
            }
        }
        guard hasSteps else { return nil }
        if revealed.contains(messageId) {
            return UIAction(title: "Hide Steps", image: UIImage(systemName: "list.bullet")) { [weak self] _ in self?.hideSteps(messageId) }
        }
        let working = StepRules.isWorking(m, at: index, in: messages, running: chat.session.isRunning, turnAnchor: provider?.hiddenTurnAnchor)
        guard StepRules.state(m.parts, working: working) == .done else { return nil }
        return UIAction(title: "Show Steps", image: UIImage(systemName: "list.bullet")) { [weak self] _ in self?.showSteps(messageId) }
    }

    private func showSteps(_ id: String) {
        revealed.insert(id)
        revealPending = id
        // The rows above make room by sliding, like the fold (the reply keeps its place).
        slideWanted = !HQMotion.reduced && !chat.activityMotionBusy
        chat.activityRebuild(messageIds: [id])
        if revealPending == id && chat.activityHasStepRows(of: id) { revealPending = nil; slideWanted = false; flipFrames = nil }
    }

    private func hideSteps(_ id: String) {
        revealed.remove(id)
        folding.insert(id)
        fade(id)
    }

    // MARK: In Header (§10.4)

    private func updateStatusTap() {
        let on = ToolCallSettings.style == .header && (provider?.statusIsWorking ?? false)
        statusTap.isHidden = !on
        statusTap.accessibilityLabel = "\(chat.session.statusText ?? "Working"). Show Steps"
    }

    @objc private func statusTapped() {
        Haptics.play(.selection)
        openStepsSheet(forMessage: nil)
    }

    /// The tool calls of the turn that ends with `messageId` (nil: the latest turn), in order.
    private func turnSteps(endingAt messageId: String?) -> [StepsListViewController.Step] {
        let messages = chat.session.messages
        var end = messages.count - 1
        if let messageId, let i = messages.lastIndex(where: { $0.id == messageId }) { end = i }
        guard end >= 0 else { return [] }
        var start = end
        while start > 0, messages[start - 1].role != .user { start -= 1 }
        var stop = end
        while stop + 1 < messages.count, messages[stop + 1].role != .user { stop += 1 }
        var steps: [StepsListViewController.Step] = []
        for m in messages[start...stop] where m.role == .assistant {
            for case .tool(let call) in m.parts where !(ChatRunSummary.isSilent(call.name) && call.state != .failed) {
                steps.append(.init(messageId: m.id, call: call))
            }
        }
        return steps
    }

    func openStepsSheet(forMessage messageId: String?) {
        #if targetEnvironment(macCatalyst)
        // [mac-layout] The live turn's steps open in the inspector beside the chat when the window has one.
        if messageId == nil, let inspector = MacInspector.beside(chat) { inspector.show(.steps); return }
        #endif
        let live = messageId == nil
        let list = StepsListViewController(steps: turnSteps(endingAt: messageId), live: live)
        list.openStep = { [weak self] step in
            guard let self else { return UIViewController() }
            return self.stepDetail(messageId: step.messageId, call: step.call)
        }
        stepsSheet = list
        stepsSheetMessage = .some(messageId)
        chat.present(ChatSheet.wrap(list, title: "Steps"), animated: true)
    }

    /// [mac-layout] The inspector's Steps: the latest turn's, kept live as the sheet is.
    func makeStepsList() -> StepsListViewController {
        let list = StepsListViewController(steps: turnSteps(endingAt: nil), live: true)
        list.openStep = { [weak self] step in
            guard let self else { return UIViewController() }
            return self.stepDetail(messageId: step.messageId, call: step.call)
        }
        stepsSheet = list
        stepsSheetMessage = .some(nil)
        return list
    }

    private func refreshStepsSheet() {
        guard let sheet = stepsSheet, case .some(let message) = stepsSheetMessage else { return }
        sheet.update(turnSteps(endingAt: message))
    }

    // MARK: Generated images (§11.3)

    /// A good path that wouldn't load turns its row into the link row (one size change); the link's tap tries again.
    func imageFailed(path: String, messageId: String, retry: Bool) {
        if retry { guard failedImages.remove(path) != nil else { return } } else { guard failedImages.insert(path).inserted else { return } }
        chat.activityRebuild(messageIds: [messageId])
    }

    // MARK: The step sheet (§12)

    func stepDetail(messageId: String, call: ToolCall) -> StepDetailViewController {
        let details = chat.session as? ChatToolDetails
        let detail = details?.toolDetail(messageId: messageId, toolId: call.id)
        var source: StepOutputSource?
        if let ref = detail?.payloadRef, let live = chat.session as? LiveChatSession {
            source = StepOutputSource(client: live.client, routeName: live.perfFeatures?.routeName ?? "hermes-hq-performance", ref: ref)
        }
        let page = StepDetailViewController(call: call, detail: detail, source: source)
        page.detailProvider = { [weak details] in details?.toolDetail(messageId: messageId, toolId: call.id) }
        if detail?.screenshot != nil, let live = chat.session as? LiveChatSession {      // [screen] the step's screenshot
            let made = detail?.screenshot?.capturedAt ?? live.messages.first { $0.id == messageId }?.timestamp?.timeIntervalSince1970
            page.screenshotContext = .init(client: live.client, profile: live.profile, sessionId: live.readSessionId, completedAt: made)
        }
        openStepDetail = page
        return page
    }

    /// A step row or a bubble line: its sheet.
    func presentStep(messageId: String, call: ToolCall) {
        let page = stepDetail(messageId: messageId, call: call)
        chat.present(ChatSheet.wrap(page, title: StepDetailViewController.title(call)), animated: true)
    }

    // MARK: The shelf (§4–§7)

    private func pieceView(_ kind: ShelfPieceKind) -> ShelfPieceView {
        shelf.piece(kind) {
            let body: UIView
            switch kind {
            case .goal: body = goalBody
            case .tasks: body = tasksBody
            case .subagents: body = subagentsBody
            case .previousTasks: body = previousBody
            case .browser: body = UIView()          // [browser] a chip only: it opens the viewer
            }
            let piece = ShelfPieceView(kind: kind, body: body)
            piece.onToggle = { [weak self] in self?.toggle(kind) }
            piece.header.accessibilityIdentifier = "chat.shelf.\(kind)"
            if kind == .goal {
                piece.header.showsMore = true
                piece.header.showsLeadingDot = true
                piece.addInteraction(UIContextMenuInteraction(delegate: self))
            }
            if kind == .previousTasks { piece.header.more.accessibilityLabel = "Previous Tasks Actions" }
            if kind == .subagents { wireSubagents() }
            if kind == .goal { wireGoal() }
            return piece
        }
    }

    private func toggle(_ kind: ShelfPieceKind) {
        if kind == .browser { onBrowserChip?(); return }    // [browser]
        if openPieces.contains(kind) { openPieces.remove(kind) } else { openPieces.insert(kind) }
        if kind == .subagents && !openPieces.contains(.subagents) { selectedSubagent = nil }
        if kind == .tasks { userFoldedTasks = !openPieces.contains(.tasks) }
        updateShelf(animated: true)
    }

    private func hideKey(_ goal: GoalSnapshot) -> String {
        "\(chat.session.profile)|goal|\(goal.title)|\(goal.createdAt ?? 0)"
    }

    private func hideKey(_ todos: [TodoItem]) -> String {
        "\(chat.session.profile)|tasks|" + todos.map { "\($0.id):\($0.status.rawValue):\($0.content)" }.joined(separator: "\n")
    }

    /// Hide: a done goal or a finished Previous tasks list leaves the shelf for good (this run of the app).
    private func hide(_ key: String, _ kind: ShelfPieceKind) {
        Haptics.play(.selection)
        Self.hiddenPieces.insert(key)
        openPieces.remove(kind)
        updateShelf(animated: true)
    }

    private var presentBefore: Set<ShelfPieceKind> = []

    func updateShelf(animated: Bool) {
        guard installed, let p = provider else { return }
        let a = p.activity
        let now = Date().timeIntervalSince1970
        let idle = !chat.session.isRunning
        // A new turn starts: a fold of the Tasks card from the last one no longer holds.
        if !idle && !wasRunning { userFoldedTasks = false }
        wasRunning = !idle
        var goal = a.control.capability == .unsupported ? nil : a.goal
        if let g = goal, g.status == .done, Self.hiddenPieces.contains(hideKey(g)) { goal = nil }
        let live = a.liveSubagents
        // The card lists this turn's helpers, finished ones too (with their results), while any runs; once all are done
        // it stays while you have one open, until you fold it or the next message clears them. A finished child only
        // keeps its Steer row while words you typed to it are still in the field.
        let turn = a.subagents.filter { $0.isLive || !$0.isDelegateStandIn }
        let keepOpen = openPieces.contains(.subagents) && selectedSubagent.map { id in turn.contains { $0.id == id } } == true
        var shown = !live.isEmpty || keepOpen ? turn : []
        var ended: String?
        if let sel = selectedSubagent {
            if let child = turn.first(where: { $0.id == sel }) {
                if child.isLive {
                    announcedEnd = nil
                } else {
                    if openPieces.contains(.subagents), announcedEnd != sel, selectedSnapshot?.isLive == true {
                        announcedEnd = sel
                        HQAnnounce.say("Helper finished")   // [updates] helpers, as the work line says (owner, 2026-10-28)
                    }
                    if !(steerDrafts[sel] ?? "").isEmpty { ended = sel }
                }
                selectedSnapshot = child
            } else if subagentsBody.isEditingSteer, !(steerDrafts[sel] ?? "").isEmpty,
                      var child = selectedSnapshot.flatMap({ $0.id == sel ? $0 : nil }) {
                // Cleared from the roster while you were typing to it: kept, finished, until the field lets go.
                if child.isLive { child.status = .completed }
                shown.append(child)
                ended = sel
            }
        }
        let previousShown = idle && a.liveTodos == nil && !a.retainedTodos.isEmpty
            && !Self.hiddenPieces.contains(hideKey(a.retainedTodos))
        var present: Set<ShelfPieceKind> = []
        if goal != nil { present.insert(.goal) }
        if a.liveTodos != nil { present.insert(.tasks) }
        if !shown.isEmpty { present.insert(.subagents) }
        if previousShown { present.insert(.previousTasks) }
        if browserChip != nil { present.insert(.browser) }      // [browser]
        // The live task list opens by default each time it appears (unless you folded it this turn); the others start
        // folded.
        if present.contains(.tasks) && !presentBefore.contains(.tasks) && !userFoldedTasks { openPieces.insert(.tasks) }
        for kind in presentBefore.subtracting(present) where kind != .tasks { openPieces.remove(kind) }
        if !present.contains(.subagents) { selectedSubagent = nil }
        presentBefore = present

        if let goal {
            let piece = pieceView(.goal)
            piece.header.set(words: ControlRules.chipWords(goal), spinner: nil)
            piece.header.leadingDot.backgroundColor = {
                switch ControlRules.tone(goal) {
                case .blocked: return ChatPalette.red
                case .done: return ChatPalette.label2
                case .active: return ChatPalette.green
                case .waiting: return ChatPalette.orange
                }
            }()
            piece.header.more.menu = goalMenu(goal, entry: a.control)
            goalBody.update(goal, entry: a.control)
        }
        if let todos = a.liveTodos {
            let piece = pieceView(.tasks)
            let spinning = todos.contains { $0.status == .inProgress }
            piece.header.set(words: TodoRules.chipWords(todos, previous: false), spinner: spinning ? ChatPalette.label2 : nil)
            tasksBody.update(todos, historical: false)
        }
        if !shown.isEmpty {
            let piece = pieceView(.subagents)
            let done = shown.count - live.count
            if live.isEmpty {
                piece.header.set(words: shown.count == 1 ? "Helper finished" : "Helpers finished", spinner: nil)
            } else {
                let words = SubagentRules.chipWords(liveCount: live.count)
                piece.header.set(words: done > 0 ? "\(words) · \(done) done" : words, spinner: GlyphFrames.purple)
            }
            if let sel = selectedSubagent, !shown.contains(where: { $0.id == sel }) { selectedSubagent = nil }
            // Wide (the Mac, iPad): the list and a page side by side, so one is always open (a running one first).
            let wide = shelfWidth >= SubagentsBody.wideWidth
            if wide, openPieces.contains(.subagents), selectedSubagent == nil {
                selectedSubagent = (live.first ?? shown.first)?.id
                selectedSnapshot = shown.first { $0.id == selectedSubagent }
            }
            subagentsBody.update(children: shown, selected: selectedSubagent,
                                 tail: selectedSubagent.flatMap { a.tails[$0] },
                                 draft: selectedSubagent.flatMap { steerDrafts[$0] } ?? "",
                                 feedback: ended != nil ? .init(text: "This helper finished", isError: false)
                                     : selectedSubagent.flatMap { steerFeedback[$0] },
                                 busy: ended != nil || (selectedSubagent.map { steerBusy.contains($0) } ?? false),
                                 wide: wide, width: shelfWidth - 12, now: now)
        }
        if present.contains(.previousTasks) {
            let piece = pieceView(.previousTasks)
            piece.header.set(words: TodoRules.chipWords(a.retainedTodos, previous: true), spinner: nil)
            previousBody.update(a.retainedTodos, historical: true)
            // A list with nothing left to do can be put away (here only; nothing is sent).
            let finished = a.retainedTodos.allSatisfy { $0.status == .completed || $0.status == .cancelled }
            piece.header.showsMore = finished
            let key = hideKey(a.retainedTodos)
            piece.header.more.menu = finished ? UIMenu(children: [
                UIAction(title: "Hide Previous Tasks", image: UIImage(systemName: "eye.slash")) { [weak self] _ in self?.hide(key, .previousTasks) },
            ]) : nil
        }
        if let chip = browserChip {                             // [browser]
            let piece = pieceView(.browser)
            piece.header.leadingIcon.image = UIImage(systemName: chip.asking ? "exclamationmark.circle.fill" : "safari")
            piece.header.leadingIcon.tintColor = chip.asking ? ChatPalette.orange : ChatPalette.label2
            piece.header.leadingIcon.isHidden = false
            piece.header.set(words: chip.words, spinner: nil)
            piece.header.accessibilityHint = "Opens the bot’s browser"
            piece.header.accessibilityValue = nil
        }
        // Timers tick while the subagents card is open.
        if openPieces.contains(.subagents) && present.contains(.subagents) {
            ActivityClock.shared.subscribe(self) { [weak self] in
                guard let self else { return }
                self.subagentsBody.tick(now: Date().timeIntervalSince1970)
            }
        } else {
            ActivityClock.shared.unsubscribe(self)
        }
        layoutShelf(present: present, animated: animated)
        updateHelpersPanel()
        // A child that ended takes its open detail with it: the tail read stops too (§4.4).
        reportVisibility()
    }

    private func layoutShelf(present: Set<ShelfPieceKind>, animated: Bool) {
        let view = chat.view!
        shelf.setNeedsLayout()          // words may have changed (a chip's width)
        let motion = animated && view.window != nil && chat.shelfMayAnimate && !HQMotion.reduced
        var entering: [ShelfPieceView] = []
        for kind in ShelfPieceKind.allCases {
            guard let piece = shelf.pieces[kind] else { continue }
            let show = present.contains(kind)
            if show {
                if !piece.isPresent { entering.append(piece) }
                piece.setOpen(openPieces.contains(kind), animated: motion && piece.isPresent)
                piece.setPresent(true, animated: motion)
            } else if piece.isPresent {
                // A leaving piece fades where it stands on screen (it keeps its shape; the shelf moves under it).
                piece.leavingFromBottom = shelf.piecesHeight - (piece.center.y - piece.bounds.height / 2)
                piece.setPresent(false, animated: motion)
            }
        }
        shelf.maxCardHeight = maxCardHeight()
        shelf.maxHeight = shelfRoom()
        let width = shelfWidth
        let height = shelf.height(for: width)
        // An arriving piece starts at its own place in the stack (no growing out of the corner): it rides the shelf's
        // top up with the rows while it fades and scales in.
        if !entering.isEmpty {
            let targets = shelf.targetFrames(width: width)
            UIView.performWithoutAnimation {
                for piece in entering {
                    guard let frame = targets[piece.kind] else { continue }
                    piece.bounds = CGRect(origin: .zero, size: frame.size)
                    piece.center = CGPoint(x: frame.midX, y: frame.midY)
                    piece.layoutIfNeeded()
                }
            }
        }
        let changed = abs((shelfHeight?.constant ?? 0) - height) > 0.25
        #if DEBUG
        if changed { motionProbe?.note("shelf \(shelfHeight?.constant ?? 0) → \(height) present=\(present.map(\.rawValue).sorted())") }
        #endif
        shelfHeight?.constant = height
        updateJumpButton(shelfHeight: height)
        let apply = {
            self.shelfChanging = true
            self.shelf.setNeedsLayout()
            view.layoutIfNeeded()
            self.shelf.layoutIfNeeded()
            self.shelfChanging = false
        }
        if motion && changed {
            let spring = UISpringTimingParameters(dampingRatio: 1)
            let animator = UIViewPropertyAnimator(duration: 0.3, timingParameters: spring)   // motion-ok: `motion` is false under Reduce Motion
            animator.addAnimations(apply)
            animator.startAnimation()
        } else if changed {
            UIView.performWithoutAnimation(apply)
        } else if motion {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) { self.shelf.layoutIfNeeded() }
        } else {
            shelf.layoutIfNeeded()
        }
    }

    /// The shelf's width: the chat's, less the composer row's side inset on each side.
    private var shelfWidth: CGFloat { max(0, chat.view.bounds.width - 2 * sideInset) }

    /// The composer row's side inset changed (the keyboard came or went): the shelf follows it, in the same pass.
    func setSideInset(_ side: CGFloat) {
        guard installed, abs(side - sideInset) > 0.25 else { return }
        sideInset = side
        shelfSides.forEach { $0.constant = side }
        let height = shelf.height(for: shelfWidth)
        if abs((shelfHeight?.constant ?? 0) - height) > 0.25 {
            shelfHeight?.constant = height
            updateJumpButton(shelfHeight: height)
        }
        shelf.setNeedsLayout()
    }

    /// The most the shelf may take: from what it sits on up to 6 pt under the status line, less a strip of transcript
    /// that stays in sight (opened cards give way to it first; folded chips never shrink).
    private func shelfRoom() -> CGFloat {
        let view = chat.view!
        guard let base = shelfBase, base.frame.maxY > 0 else { return .greatestFiniteMagnitude }
        let limit = view.safeAreaInsets.top - 4 + ChatMetrics.statusLineHeight + 6 + Self.minTranscript
        return max(0, base.frame.minY - ActivityShelfView.gap - limit)
    }

    /// About three lines of the transcript's text (at most 160 pt): with several live pieces, large text or the keyboard
    /// up, the shelf never covers the whole chat.
    private static var minTranscript: CGFloat {
        min(160, (HQFont.preferred(.body).lineHeight * 3).rounded(.up) + 16)
    }

    /// 40 % of the chat's visible height; 60 % with a child's detail open and the keyboard down (§4.1). The Steer field
    /// focused counts as the keyboard up, except on the Mac, which has no keyboard to come up: there the card kept
    /// folding to 40 % under the pointer the moment its Steer field was clicked (stress test 2026-10-31).
    private func maxCardHeight() -> CGFloat {
        let view = chat.view!
        let top = view.safeAreaInsets.top + ChatMetrics.statusLineHeight
        let visible = max(200, chat.composer.frame.minY - top)
        let keyboardUp = view.keyboardLayoutGuide.layoutFrame.height > view.safeAreaInsets.bottom + 20
            || (subagentsBody.isEditingSteer && !DeviceWord.isMac)
        let detailOpen = openPieces.contains(.subagents) && selectedSubagent != nil
        // Wide (the Mac, iPad) has the room: the list and its page take up to 70 %.
        let open: CGFloat = shelfWidth >= SubagentsBody.wideWidth ? 0.7 : 0.6
        return (visible * (detailOpen && !keyboardUp ? open : 0.4)).rounded()
    }

    /// Every layout pass of the chat (the keyboard's included): an opened card's cap follows the room left, in the same
    /// pass, so the card shrinks with the keyboard's own animation instead of ending under the bar and snapping later.
    func layoutChanged() {
        // UX study #230: folded chips follow the room too (they keep to one line, then scroll).
        guard installed, !inLayoutChange, !shelf.visiblePieces.isEmpty else { return }
        let cap = maxCardHeight(), room = shelfRoom()
        guard abs(cap - shelf.maxCardHeight) > 0.5 || abs(room - shelf.maxHeight) > 0.5 else { return }
        inLayoutChange = true
        defer { inLayoutChange = false }
        shelf.maxCardHeight = cap
        shelf.maxHeight = room
        let height = shelf.height(for: shelfWidth)
        guard abs((shelfHeight?.constant ?? 0) - height) > 0.25 else { shelf.setNeedsLayout(); shelf.layoutIfNeeded(); return }
        shelfHeight?.constant = height
        updateJumpButton(shelfHeight: height)
        shelfChanging = true
        chat.view.layoutIfNeeded()
        shelf.layoutIfNeeded()
        shelfChanging = false
        revealSteerRow()
    }

    /// The jump button changed size (it became the wider "Approval needed" capsule, or the arrow again): it is placed
    /// again, above the shelf if it would now come near a folded chip.
    func jumpWidthChanged(_ width: CGFloat) {
        guard abs(width - jumpWidth) > 0.25 else { return }
        jumpWidth = width
        guard installed else { return }
        updateJumpButton(shelfHeight: shelfHeight?.constant ?? 0)
    }

    /// The jump button: beside folded chips (where it would be with no shelf); above the shelf when a card is open, the
    /// queue shows, the text is large, or the widest chip comes within 8 pt of it (§7.3). Its real width counts: the
    /// approval capsule reaches much further left than the arrow.
    private func updateJumpButton(shelfHeight: CGFloat) {
        guard let jumpBottom else { return }
        let view = chat.view!
        let queueShown = !(queueCard?.isHidden ?? true)
        // [mac] The arrow is centred there, where the chips are too: any chip sends it above the shelf.
        let jumpLeading = DeviceWord.isMac ? (view.bounds.width - jumpWidth) / 2 : view.bounds.width - ChatMetrics.jumpTrailing - jumpWidth
        let crowded = shelf.chipsTrailingEdge(in: view) > jumpLeading - 8 || estimatedChipsCrowd(jumpLeading: jumpLeading)
        let above = shelfHeight > 0 && (shelf.hasOpenCard || queueShown || ShelfText.isLarge || crowded)
        jumpBottom.constant = -ChatMetrics.jumpAboveComposer - (above ? shelfHeight + ActivityShelfView.gap : 0)
    }

    /// Before the pieces are laid out: the widest chip's estimated trailing edge.
    private func estimatedChipsCrowd(jumpLeading: CGFloat) -> Bool {
        let widest = shelf.visiblePieces.filter { !$0.isOpen }.map(\.header.fittingWidth).max() ?? 0
        return sideInset + (shelfWidth + widest) / 2 > jumpLeading - 8
    }

    /// While the Steer field is focused, the card (shrunk to its keyboard cap) keeps the Steer row in sight inside its
    /// one scroller; called in the layout pass that shrinks it, so the scroll rides the keyboard's animation.
    private func revealSteerRow() {
        guard subagentsBody.isEditingSteer, let piece = shelf.pieces[.subagents], piece.isOpen else { return }
        piece.layoutIfNeeded()              // the scroller's frame follows the card's new height first
        piece.scroll.layoutIfNeeded()
        guard let row = subagentsBody.steerRowFrame(in: piece.scroll) else { return }
        let scroll = piece.scroll
        let visible = scroll.bounds.height
        let top = row.minY - 8, bottom = row.maxY + 8
        var y = scroll.contentOffset.y
        if bottom > y + visible { y = bottom - visible }
        if top < y { y = top }
        y = max(0, min(y, scroll.contentSize.height - visible))
        if abs(y - scroll.contentOffset.y) > 0.5 { scroll.contentOffset.y = y }
        #if DEBUG
        motionProbe?.note("steer row \(row) scroll bounds=\(piece.scroll.bounds) content=\(piece.scroll.contentSize) piece=\(piece.bounds)")
        #endif
    }

    /// A tapped child's row and its detail (right under it) come into sight inside the card's one scroller: the row's
    /// top first, then as much of the detail as fits.
    private func revealSelectedChild() {
        guard let piece = shelf.pieces[.subagents], piece.isOpen else { return }
        piece.layoutIfNeeded()
        piece.scroll.layoutIfNeeded()
        guard let frame = subagentsBody.selectedFrame(in: piece.scroll) else { return }
        let scroll = piece.scroll
        let visible = scroll.bounds.height
        var y = scroll.contentOffset.y
        if frame.maxY + 8 > y + visible { y = frame.maxY + 8 - visible }
        if frame.minY - 8 < y { y = frame.minY - 8 }
        y = max(0, min(y, scroll.contentSize.height - visible))
        if abs(y - scroll.contentOffset.y) > 0.5 { scroll.setContentOffset(CGPoint(x: 0, y: y), animated: !HQMotion.reduced) }
    }

    /// The topmost dock piece (for the transcript's inset and the placeholder).
    func dockTop(base: CGFloat) -> CGFloat {
        guard (shelfHeight?.constant ?? 0) > 0 else { return base }
        return min(base, shelf.frame.minY)
    }

    // MARK: The inspector's Helpers tab (Mac)

    /// [mac-layout] Owner 2026-11-03 (the Mac layout study): the chat's helpers in the inspector, this turn's, finished
    /// ones too, as the card above the composer lists them: the list, then a helper's page (Steer, Stop, its steps).
    private weak var helpersPanel: HelpersPanelController?
    private var panelSelected: String?

    func makeHelpersPanel() -> UIViewController {
        let panel = HelpersPanelController()
        panel.body.onSelect = { [weak self] id in
            guard let self else { return }
            self.panelSelected = id
            self.updateHelpersPanel()
            self.reportVisibility()
        }
        panel.body.onDraftChange = { [weak self] id, text in self?.steerDrafts[id] = text }
        panel.body.onSteer = { [weak self] id, text in self?.steer(id, text) }
        panel.body.onStop = { [weak self] id in self?.stopChild(id) }
        panel.onShown = { [weak self] in self?.reportVisibility() }
        helpersPanel = panel
        #if DEBUG
        if let id = UserDefaults.standard.string(forKey: "HQDemoHelperOpen") { panelSelected = id }   // shots
        #endif
        updateHelpersPanel()
        return panel
    }

    private func updateHelpersPanel() {
        guard let panel = helpersPanel, let p = provider else { return }
        let helpers = p.activity.subagents.filter { $0.isLive || !$0.isDelegateStandIn }
        if let sel = panelSelected, !helpers.contains(where: { $0.id == sel }) { panelSelected = nil }
        let sel = panelSelected
        let draft = sel.flatMap { steerDrafts[$0] } ?? ""
        let feedback = sel.flatMap { steerFeedback[$0] }
        let busy = sel.map { steerBusy.contains($0) } ?? false
        let tail = sel.flatMap { p.activity.tails[$0] }
        panel.show(helpers.isEmpty ? nil : {
            panel.body.update(children: helpers, selected: sel, tail: tail, draft: draft, feedback: feedback, busy: busy,
                              wide: false, width: panel.view.bounds.width, now: Date().timeIntervalSince1970)
        })
    }

    // MARK: Subagents card (§4.1, §4.3)

    private func wireSubagents() {
        subagentsBody.onSelect = { [weak self] id in
            guard let self else { return }
            self.selectedSubagent = id
            self.updateShelf(animated: true)
            if id != nil { DispatchQueue.main.async { [weak self] in self?.revealSelectedChild() } }
        }
        subagentsBody.onDraftChange = { [weak self] id, text in self?.steerDrafts[id] = text }
        subagentsBody.onSteer = { [weak self] id, text in self?.steer(id, text) }
        subagentsBody.onStop = { [weak self] id in self?.stopChild(id) }
        // Focusing the Steer field lowers the card's cap to 40 % (the keyboard comes up with it; not on the Mac).
        subagentsBody.onEditingChange = { [weak self] in
            guard let self else { return }
            self.updateShelf(animated: true)
            if self.subagentsBody.isEditingSteer { DispatchQueue.main.async { [weak self] in self?.revealSteerRow() } }
        }
    }

    private func steer(_ id: String, _ text: String) {
        guard let p = provider, let store = p.activityStore, let rid = p.activityRuntimeId else { return }
        steerBusy.insert(id)
        updateShelf(animated: false)
        Task { [weak self] in
            let outcome = await store.steer(runtimeId: rid, subagentId: id, text: text)
            guard let self else { return }
            self.steerBusy.remove(id)
            if outcome == .queued {
                self.steerDrafts[id] = ""
                self.subagentsBodyClearField()
                self.steerFeedback[id] = .init(text: "Queued for the next checkpoint", isError: false)
                Haptics.play(.success)
            } else {
                self.rejected(id)
            }
            self.updateShelf(animated: true)
        }
    }

    private func subagentsBodyClearField() {
        // The field clears after a queued steer (it keeps the draft otherwise).
        for case let detail as SubagentDetailView in subagentsBody.allSubviews { detail.field.text = ""; detail.refreshSend() }
        if let body = helpersPanel?.body {
            for case let detail as SubagentDetailView in body.allSubviews { detail.field.text = ""; detail.refreshSend() }
        }
    }

    private func stopChild(_ id: String) {
        guard let p = provider, let store = p.activityStore, let rid = p.activityRuntimeId else { return }
        steerBusy.insert(id)
        updateShelf(animated: false)
        Task { [weak self] in
            let found = await store.interrupt(runtimeId: rid, subagentId: id)
            guard let self else { return }
            self.steerBusy.remove(id)
            if found {
                self.steerFeedback[id] = .init(text: "Stop requested", isError: false)
            } else {
                self.rejected(id)
            }
            self.updateShelf(animated: true)
        }
    }

    private func rejected(_ id: String) {
        let words = "The helper didn’t accept your message."
        steerFeedback[id] = .init(text: words, isError: true)
        Haptics.play(.error)
        HQAnnounce.say(words)
    }

    // MARK: Goal card (§6.3, §6.4)

    private func wireGoal() {
        goalBody.onDetails = { [weak self] in self?.showGoalDetails() }
        goalBody.onAddCriterion = { [weak self] in self?.addCriterion() }
        goalBody.onClearCriteria = { [weak self] in
            self?.confirm(title: "Clear All Criteria?", message: "Every criterion is removed from this goal.",
                          action: "Clear All Criteria") { self?.run("subgoal.clear", [:]) }
        }
        goalBody.onRemoveCriterion = { [weak self] index in
            let subgoals = self?.provider?.activity.goal?.subgoals ?? []
            let text = index >= 1 && index <= subgoals.count ? subgoals[index - 1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let shown = text.count > 80 ? String(text.prefix(80)) + "…" : text
            self?.confirm(title: "Remove Criterion \(index)?",
                          message: shown.isEmpty ? "It is removed from this goal." : "“\(shown)” is removed from this goal.",
                          action: "Remove Criterion \(index)") { self?.run("subgoal.remove", ["index": .number(Double(index))]) }
        }
        goalBody.onDismissError = { [weak self] in
            guard let p = self?.provider, let rid = p.activityRuntimeId else { return }
            p.activityStore?.setControlError(runtimeId: rid, nil)
        }
    }

    private func goalMenu(_ goal: GoalSnapshot, entry: ControlEntry) -> UIMenu {
        let busy = entry.pendingAction != nil
        var items: [UIMenuElement] = []
        func item(_ title: String, _ symbol: String, destructive: Bool = false, _ handler: @escaping () -> Void) -> UIAction {
            let a = UIAction(title: title, image: UIImage(systemName: symbol), attributes: destructive ? [.destructive] : []) { _ in handler() }
            if busy { a.attributes.insert(.disabled) }
            return a
        }
        if ControlRules.hasDetails(goal) { items.append(item("View Details", "info.circle") { [weak self] in self?.showGoalDetails() }) }
        if goal.status != .done { items.append(item("Add Criterion", "plus") { [weak self] in self?.addCriterion() }) }
        if goal.waitBarrier != nil {
            items.append(item("Resume Now", "play") { [weak self] in self?.run("goal.unwait", [:]) })
            items.append(item("Pause Goal", "pause") { [weak self] in self?.run("goal.pause", [:]) })
        } else if goal.status == .active {
            items.append(item("Pause Goal", "pause") { [weak self] in self?.run("goal.pause", [:]) })
        } else if goal.status == .paused {
            items.append(item("Resume Goal", "play") { [weak self] in self?.run("goal.resume", [:]) })
        }
        if goal.status == .done {
            // A done goal can leave the shelf without clearing it on the gateway (here only, while the app runs).
            let key = hideKey(goal)
            items.append(UIAction(title: "Hide Goal", image: UIImage(systemName: "eye.slash")) { [weak self] _ in self?.hide(key, .goal) })
        }
        items.append(item("Clear Goal", "trash", destructive: true) { [weak self] in
            self?.confirm(title: "Clear Goal?", message: "The goal and its criteria are removed. This can’t be undone.",
                          action: "Clear Goal") { self?.run("goal.clear", [:]) }
        })
        return UIMenu(children: items)
    }

    private func showGoalDetails() {
        guard let goal = provider?.activity.goal else { return }
        chat.present(ChatSheet.wrap(GoalDetailsViewController(goal: goal), title: "Goal Details"), animated: true)
    }

    private func addCriterion() {
        let alert = UIAlertController(title: "Add Criterion", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Enter criterion text…"
            field.accessibilityIdentifier = "goal.criterion-field"
        }
        let add = UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }
            self?.run("subgoal.add", ["text": .string(text)])
        }
        add.isEnabled = false
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(add)
        alert.preferredAction = add
        if let field = alert.textFields?.first {
            field.addAction(UIAction { [weak field, weak add] _ in
                add?.isEnabled = !(field?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }, for: .editingChanged)
        }
        chat.present(alert, animated: true)
    }

    private func confirm(title: String, message: String, action: String, _ run: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: action, style: .destructive) { _ in run() })
        chat.present(alert, animated: true)
    }

    private func run(_ action: String, _ args: [String: JSONValue]) {
        guard let p = provider, let store = p.activityStore, let rid = p.activityRuntimeId else { return }
        Task { [weak self] in
            do {
                let dispatch = try await store.runControl(runtimeId: rid, action: action, args: args)
                guard let self else { return }
                if dispatch.type == "send", let message = dispatch.message, !message.isEmpty {
                    let busy = self.chat.session.isRunning
                    p.sendHidden(message, display: dispatch.display)
                    if busy {
                        HQAnnounce.say("Goal resumed. It continues after the current reply.")
                    }
                }
                HQAnnounce.say("Action succeeded")
            } catch {
                Haptics.play(.error)
            }
        }
    }
}

extension ChatActivityController: UIContextMenuInteractionDelegate {
    /// Long-press anywhere on the goal card: the same actions as its ⋯.
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let p = provider, let goal = p.activity.goal, openPieces.contains(.goal) else { return nil }
        let menu = goalMenu(goal, entry: p.activity.control)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}

private extension UIView {
    var allSubviews: [UIView] { subviews + subviews.flatMap(\.allSubviews) }
}

// MARK: - Hooks the chat screen adopts

extension ChatViewController: ActivityCellDelegate, ChatCellMenuExtending {
    func activityCellOpenStep(rowId: String, call: ToolCall) {
        guard let row = activityRow(id: rowId) else { return }
        activity.presentStep(messageId: row.messageId, call: call)
    }

    func activityCellLoadImage(path: String, maxPixel: Int) async throws -> UIImage {
        if let cached = ActivityMedia.cachedThumbnail(path: path, maxPixel: maxPixel) { return cached }
        guard let live = session as? LiveChatSession else { throw CancellationError() }
        let image = try await ActivityMedia.loadImage(live.client, path, live.profile, live.readSessionId, maxPixel)
        ActivityMedia.keepThumbnail(image, path: path, maxPixel: maxPixel)
        return image
    }

    func activityCellOpenImage(_ image: UIImage, path: String, from view: UIView) {
        var full: (() async throws -> UIImage)?
        var context: MediaContext?
        if let live = session as? LiveChatSession {
            let client = live.client, profile = live.profile, sid = live.readSessionId
            full = { try await ActivityMedia.loadFull(client, path, profile, sid) }
            context = MediaContext(accountId: client.account.id, profile: profile, storedSessionId: sid)
        }
        ActivityMedia.present(from: view, image: image, path: path, context: context, loadFull: full)
    }

    func activityCellImageFailed(rowId: String, path: String, retry: Bool) {
        guard let messageId = activityRow(id: rowId)?.messageId else { return }
        activity.imageFailed(path: path, messageId: messageId, retry: retry)
    }

    func chatCellMenuItems(rowId: String) -> [UIMenuElement] {
        guard let messageId = activityRow(id: rowId)?.messageId, let item = activity.stepsMenuItem(forMessage: messageId) else { return [] }
        return [item]
    }

    /// [transcript] The files card, or a diff preview's own header: the same opener a bot's own `#file:` link uses
    /// (§12, n20 F10) — a relative path (an edit tool rarely reports an absolute one) resolves against the chat's
    /// folder first, so it opens exactly where the edit landed.
    func activityCellOpenFile(path: String) {
        let folder = (session as? ChatSessionMoreActions)?.workingDirectory
        guard let url = FileLinks.url(ChangedFiles.resolve(path, in: folder)) else { return }
        _ = openFileLink(url)
    }

    /// [transcript] "Review", or a file row's held "Review in Changes": the chat's Changes page. `path` is the edit
    /// tool's own (its folder may differ from the Changes list's repo-relative one — `ChangedFiles.match` allows for
    /// that), so it is passed through unresolved.
    func activityCellReviewChanges(highlighting path: String?) {
        menus?.presentChanges(highlighting: path)
    }

    /// [tasks] "Added to Tasks": the Tasks page, and that task's sheet when a row was tapped.
    func activityCellOpenTask(id: String?) {
        TasksHub.open(taskID: id)
    }

    /// [tasks] "Ask Hermes to Help": this chat's bot is asked to take its part (the task's title and id in the message,
    /// "Help me with “…”" in your bubble).
    func activityCellAskHelp(taskId: String, title: String) {
        AppLog.note("tasks", "chat card asked for help with a task")
        sendFromCard(TodoWords.helpMessage(title: title, id: taskId), display: "Help me with “\(title)”")
    }

    /// [tasks] Its Undo: `DELETE /tasks/{id}` on this chat's gateway.
    func activityCellUndoTasks(ids: [String], done: @escaping (Bool) -> Void) {
        let client = (session as? LiveChatSession)?.client
        Task {
            let ok = await TasksHub.undo(ids, client: client)
            AppLog.note("tasks", "chat undo \(ids.count) → \(ok ? "ok" : "failed")")
            done(ok)
        }
    }
}

/// The reply menu's Show / Hide Steps for the menus stream (`1x-menus.md` §9): nil when the reply has none.
enum StepsMenu {
    static func item(forMessage messageId: String, in chat: ChatViewController) -> UIAction? {
        chat.activity.stepsMenuItem(forMessage: messageId)
    }
}

/// A cell's long-press menu takes extra items from the screen (Show / Hide Steps until the menus stream lands).
@MainActor protocol ChatCellMenuExtending: AnyObject {
    func chatCellMenuItems(rowId: String) -> [UIMenuElement]
}
