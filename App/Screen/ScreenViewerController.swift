import Network
import UIKit

/// The Screen viewer alone rotates (DECISION D8); the rest of the app stays portrait.
final class ScreenNavigationController: UINavigationController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    /// Every way out (Close, a notification that dismisses what is presented, sign-out) ends here.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            (viewControllers.first as? ScreenViewerController)?.left()
        }
    }
}

/// A bot's whole-computer Screen (docs/spec/3x-screen.md §4): watch it live, take control, or — when the gateway has
/// no live screen — see the bot's latest screenshots and set the live Screen up. One at a time (`current`).
final class ScreenViewerController: UIViewController {
    static weak var current: ScreenViewerController?

    let profile: String
    let botName: String
    private let service: ScreenService
    private let session: ScreenSession
    /// "Set up with Hermes" (`resume`: a request made before may be continued). Set by the app.
    var requestSetup: ((_ resume: Bool) async -> ScreenSetupError?)?
    /// Whether setup was already requested for this bot in this run.
    var setupRequested: (() -> Bool)?
    /// The bot's gateway is a Hermes Cloud agent: Nous picks its image, so there is nothing to install there (Screen comes
    /// with 8 GB or more, CloudScreen). Opens that agent's page in Hermes Cloud.
    var openCloudAgent: (() -> Void)?

    private let notes = ScreenNotesView()
    private let content = UIView()
    private let stage = ScreenStageView()
    private let bar = ScreenControlBar()
    private let panel = ScreenStatePanel()
    private let pill = BrowserPill()
    private let keyField = ScreenKeyField()
    private let debug = UILabel()
    private var fallback: LatestScreenshotsView?
    private var pillTimer: Timer?
    private var refreshTimer: Timer?
    private var debugTimer: Timer?
    private var armed: Set<ScreenKeys.Modifier> = []
    private var typing = false
    /// The person raised the keyboard: it comes back by itself when a paused stream does (iOS's own "Allow Paste"
    /// question, a glance at another app), until they lower it or control ends.
    private var typingWanted = false
    private var pasting = false
    private var pendingPaste: (text: String, until: Date)?
    private var appActive = true
    private var appeared = false
    private var covered = false
    private var sheetUp = false
    private var gone = false
    private var inCompact = false
    private var savedView: ScreenView?
    private var touchedView = false
    private var observers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    private var pathSatisfied = true
    private weak var opener: UIViewController?
    #if targetEnvironment(macCatalyst)
    private lazy var zoomInItem = zoomItem(.zoomIn)
    private lazy var zoomOutItem = zoomItem(.zoomOut)
    /// [mac] `isIdleTimerDisabled` does nothing on a Mac (round 2 #47): this keeps its display awake instead.
    private var awake: NSObjectProtocol?
    #endif
    /// The content ends at the bar while it shows, else at the bottom of the screen.
    private var aboveBar: NSLayoutConstraint?
    private var toBottom: NSLayoutConstraint?

    static func present(profile: String, name: String, service: ScreenService, from presenter: UIViewController,
                        configure: (ScreenViewerController) -> Void = { _ in }) {
        guard current == nil else { return }
        let viewer = ScreenViewerController(profile: profile, name: name, service: service)
        configure(viewer)
        viewer.opener = presenter
        let navigation = ScreenNavigationController(rootViewController: viewer)
        current = viewer
        Haptics.play(.selection)
        PaneViewer.present(navigation, from: presenter)   // [mac] over the right pane; full screen elsewhere
    }

    init(profile: String, name: String, service: ScreenService) {
        self.profile = profile
        botName = name.isEmpty ? "This bot" : name
        self.service = service
        session = service.session(profile: profile, name: name)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        pillTimer?.invalidate()
        refreshTimer?.invalidate()
        debugTimer?.invalidate()
        pathMonitor?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Whether this phone is in control right now (other streams ask before interrupting).
    var isInControl: Bool { session.holding }

    // MARK: View

    override func viewDidLoad() {
        super.viewDidLoad()
        // Stress test 2026-10-28 #56, #78: in the Desktop Look, the look's page and bar, as Watch Browser.
        view.backgroundColor = HQPalette.plainPage
        navigationItem.title = "\(botName)’s Screen"   // the Browser viewer's pattern ("Ivy’s Browser")
        navigationItem.largeTitleDisplayMode = .never
        let close = UIBarButtonItem.hqClose(action: UIAction { [weak self] _ in self?.close() })
        close.accessibilityIdentifier = "screen.close"
        navigationItem.hqPlaceClose(close)   // [mac] Stress test 2026-10-28 #55: trailing on the Mac, after the zoom
        #if targetEnvironment(macCatalyst)
        // [mac] A mouse has no pinch (round 2 #37): Zoom Out and Zoom In beside the title (= / - / 0 and ⌘-scroll too).
        navigationItem.rightBarButtonItems = [zoomInItem, zoomOutItem]
        #endif
        let appearance = Theme.isDesktop ? ThemeChrome.solidBar(solid: true) : UINavigationBarAppearance()
        if !Theme.isDesktop { appearance.configureWithDefaultBackground() }
        // [mac] Stress test 2026-10-28 round 8: the pane title's token (the iOS look's bar drew the system's smaller title).
        if DeviceWord.isMac { appearance.titleTextAttributes[.font] = MacType.pageTitle }
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance

        for piece in [notes, content, bar, pill] as [UIView] {
            piece.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(piece)
        }
        for piece in [stage, panel] as [UIView] {
            piece.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(piece)
            NSLayoutConstraint.activate([
                piece.leadingAnchor.constraint(equalTo: content.leadingAnchor), piece.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                piece.topAnchor.constraint(equalTo: content.topAnchor), piece.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        view.addSubview(keyField)
        let safe = view.safeAreaLayoutGuide
        let room = content.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        room.priority = .defaultHigh
        // The notes and the bar take only what their words and buttons need; the picture gets the rest.
        let slimNotes = notes.heightAnchor.constraint(equalToConstant: 0), slimBar = bar.heightAnchor.constraint(equalToConstant: 0)
        slimNotes.priority = UILayoutPriority(240)
        slimBar.priority = UILayoutPriority(240)
        let ending = content.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        aboveBar = content.bottomAnchor.constraint(equalTo: bar.topAnchor)
        toBottom = ending
        NSLayoutConstraint.activate([
            notes.leadingAnchor.constraint(equalTo: view.leadingAnchor), notes.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            notes.topAnchor.constraint(equalTo: safe.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor), content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: notes.bottomAnchor),
            ending, slimNotes, slimBar,
            bar.leadingAnchor.constraint(equalTo: safe.leadingAnchor), bar.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 16),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -16),
            room,
        ])
        pill.alpha = 0
        pill.isHidden = true
        // A short note over the picture stays a note at the largest text sizes (it is also spoken).
        pill.maximumContentSizeCategory = .accessibilityMedium
        stage.botName = botName
        wire()
        #if DEBUG
        if ProcessInfo.processInfo.environment["HQN_UI_SCREEN"] == "1" { installDebug() }
        #endif
        render()
        session.open()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        onViewChanged(immediately: true)
        takeKeys()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        notes.setHeightCap(view.bounds.height * 0.4)
        updateCompactTyping()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.render() }
    }

    private func wire() {
        session.onChange = { [weak self] in self?.render() }
        session.onFrame = { [weak self] image, width, height in
            guard let self else { return }
            let first = !stage.hasPicture
            stage.show(image, width: width, height: height)
            if first { render() }
        }
        session.onNotice = { [weak self] notice in self?.noticed(notice) }

        stage.onPointer = { [weak self] mask, x, y in self?.session.sendPointer(mask: mask, x: x, y: y) }
        stage.onHoldArmed = { Haptics.play(.selection) }
        stage.onView = { [weak self] _, committed in
            guard let self else { return }
            if inCompact { touchedView = true }
            if committed { renderBar() } else if bar.model.fit != (stage.view.zoom > 1.001) { renderBar() }
        }

        bar.onTake = { [weak self] in self?.session.takeOver() }
        bar.onGive = { [weak self] in
            Haptics.play(.selection)   // as the Browser's Give Back
            self?.session.handBack()
        }
        bar.onForce = { [weak self] in self?.session.forceHandBack() }
        bar.onFit = { [weak self] in
            guard let self else { return }
            if inCompact { touchedView = true }
            stage.setView(.fit, animated: true)
            renderBar()
        }
        bar.onKeyboard = { [weak self] in
            guard let self else { return }
            if keyField.isFirstResponder {
                typingWanted = false
                keyField.resignFirstResponder()
            } else if session.canSendInput {
                typingWanted = true
                keyField.becomeFirstResponder()
            }
        }
        bar.onKey = { [weak self] key in self?.press(key.keysym, []) }
        bar.onModifier = { [weak self] which in
            guard let self else { return }
            Haptics.play(.selection)   // a key held for the next one, or let go
            if armed.contains(which) { armed.remove(which) } else { armed.insert(which) }
            renderBar()
        }
        bar.onPaste = { [weak self] in self?.paste() }

        keyField.onText = { [weak self] text in
            guard let self, session.canSendInput else { return }
            session.type(text, mods: armed)
            clearArmed()
        }
        keyField.onKey = { [weak self] key, mods in self?.press(key.keysym, mods) }
        keyField.onChord = { [weak self] character, mods in
            guard let scalar = character.unicodeScalars.first else { return }
            self?.press(ScreenKeys.keysym(for: scalar.value), mods)
        }
        keyField.onFocusChange = { [weak self] on in
            guard let self else { return }
            typing = on
            updateCompactTyping()
            render()
            if !on { DispatchQueue.main.async { [weak self] in self?.takeKeys() } }
        }

        notes.onDismissError = { [weak self] in self?.session.dismissError() }
        notes.onEnableControl = { [weak self] in self?.showControlSetup() }
        panel.onPrimary = { [weak self] in self?.panelPrimary() }
        panel.onSecondary = { [weak self] in self?.panelSecondary() }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appChanged(active: false, background: false) }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appChanged(active: false, background: true) }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appChanged(active: true, background: false) }
        })
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let back = ok && !pathSatisfied
                pathSatisfied = ok
                if back { session.resumeSignal() }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    // MARK: On view (§5.11)

    private var onView: Bool { appeared && appActive && !sheetUp && !gone }

    private func appChanged(active: Bool, background: Bool) {
        appActive = active
        if !active {
            // Another computer's screen should not sit in the app switcher (DECISION D17).
            covered = true
            stage.covered = true
            stage.dropTouches()
            // A system question over the app (iOS's "Allow Paste") leaves the keyboard where it is.
            if background { keyField.resignFirstResponder() }
        } else {
            covered = false
            stage.covered = false
        }
        onViewChanged(immediately: active || background)
        if active { session.resumeSignal() }
    }

    private func onViewChanged(immediately: Bool) {
        session.setOnView(onView, immediately: immediately)
        render()
    }

    // MARK: Render

    private func render() {
        guard isViewLoaded, !gone else { return }
        let phase = session.phase
        let live = phase == .live
        var fallbackReason: ScreenSession.Fallback?
        if case .fallback(let reason) = phase { fallbackReason = reason }

        let label = session.label
        navigationItem.subtitle = (fallbackReason != nil || inCompact || label.isEmpty) ? nil : label
        stage.screenLabel = label
        stage.accessibilityValue = label
        stage.control = session.canSendInput
        stage.dimmed = phase == .attaching && stage.hasPicture
        stage.isHidden = !(live || phase == .attaching)
        if !session.canSendInput {
            if keyField.isFirstResponder { keyField.resignFirstResponder() }
        } else if typingWanted, appActive, !sheetUp, !keyField.isFirstResponder {
            keyField.becomeFirstResponder()
        }
        flushPaste()
        // Sideways with the keyboard up there is little room: the top bar steps aside until the keyboard goes down.
        let hideTop = inCompact && traitCollection.verticalSizeClass == .compact
        if let navigation = navigationController, navigation.isNavigationBarHidden != hideTop {
            navigation.setNavigationBarHidden(hideTop, animated: !HQMotion.reduced)
        }
        bar.isHidden = !live
        if aboveBar?.isActive != live {
            toBottom?.isActive = !live
            aboveBar?.isActive = live
        }
        renderBar()
        renderNotes(phase)
        renderPanel(phase)
        renderFallback(fallbackReason)
        keepAwake(live && onView && stage.hasPicture)
        if live, stage.hasPicture { offerRotateHint() }
        #if targetEnvironment(macCatalyst)
        let zoomable = live && stage.hasPicture
        if zoomInItem.isEnabled != zoomable { zoomInItem.isEnabled = zoomable; zoomOutItem.isEnabled = zoomable }
        #endif
        updateDebug()
    }

    private func renderBar() {
        var model = ScreenControlBar.Model()
        model.caption = session.caption
        model.held = session.held != nil && !session.holding
        model.take = session.holding ? nil : ControlWords.take(held: session.held != nil)
        model.takeEnabled = session.canTake
        model.give = session.holding || session.held != nil
        model.force = session.otherHolds
        model.busy = session.busy
        model.fit = stage.view.zoom > 1.001
        model.keyboard = session.canSendInput
        model.typing = typing
        model.mac = session.isMac
        model.armed = armed
        bar.model = model
    }

    private func renderNotes(_ phase: ScreenSession.Phase) {
        var model = ScreenNotesView.Model()
        model.error = session.errorLine.map(ScreenWire.plain)
        if phase == .live || phase == .attaching {
            if session.held != nil, !session.holding {
                model.lines.append(.init(text: ControlWords.heldNote, id: "screen.note.held"))
            }
            if session.otherHolds {
                model.lines.append(.init(text: ControlWords.otherNote, id: "screen.note.other"))
            }
            if session.isMac, !inCompact {
                model.lines.append(.init(text: "This is the Mac’s own screen, shared by all bots on this Mac.", id: "screen.note.mac"))
            }
            if let mac = session.mac {
                if !mac.control {
                    model.lines.append(.init(text: "Control needs setup on this Mac before \(DeviceWord.tap)s and typing can work.", warning: true, id: "screen.note.control"))
                }
                if mac.locked {
                    model.lines.append(.init(text: "The Mac is locked: \(DeviceWord.tap)s and typing are ignored until it is unlocked at the Mac.", warning: true, id: "screen.note.locked"))
                }
                if mac.secureInput {
                    model.lines.append(.init(text: "A password field has focus on the Mac, so macOS blocks typed text.", warning: true, id: "screen.note.secure"))
                }
            }
            model.enableControl = phase == .live && session.isMac && session.mac?.inputReady != true && !inCompact
        }
        notes.model = model
    }

    private func renderPanel(_ phase: ScreenSession.Phase) {
        var model = ScreenStatePanel.Model()
        switch phase {
        case .connecting:
            model = .init(id: "screen.connecting", spinner: true, body: "Connecting to the screen…")
        case .noAnswer(let failure):
            let lead = failure.map { ScreenWire.sentence(ScreenWire.plain($0)) } ?? "The screen’s status never arrived."
            model = .init(id: "screen.no-answer", title: "Couldn’t Reach \(botName)’s Screen",
                          body: "\(lead) Check that \(HostWord.phrase) is on and reachable, then try again.",
                          primary: "Try Again", primaryId: "screen.retry")
        case .missing where openCloudAgent != nil:
            // The desktop app's words for the same case (hermes-agent 757705867a): no install offer on a managed agent.
            model = .init(id: "screen.cloud-missing", title: "Screen Isn’t Included",
                          body: "Hermes Cloud includes Screen on agents with 8 GB of memory or more. \(botName)’s agent is smaller, so it can’t be added there.",
                          primary: "Agent Size…", primaryId: "screen.cloud-agent")
        case .missing:
            let command = session.status?.installCommand.flatMap { $0.isEmpty ? nil : $0 }
            // Plain words (UX study #83): the add-on, not its package names; the command stays for whoever runs it.
            model = .init(id: "screen.missing", title: "Screen Add-on Missing",
                          body: "\(HostWord.sentence) needs a desktop add-on before \(botName) can have a screen. Whoever looks after it can run this there:",
                          code: command, primary: "Check Again", primaryId: "screen.check-again",
                          secondary: command == nil ? nil : "Copy", secondaryId: "screen.copy")
        case .off:
            var note: String?
            if let placement = session.status?.placement, placement.hasPrefix("terminal:") {
                note = "Screen runs inside the \(placement.dropFirst("terminal:".count)) sandbox, with the terminal."
            }
            model = .init(id: "screen.off", title: "Screen Is Off",
                          body: "Start this bot’s desktop to watch what it does and take over when it needs you.",
                          footnote: note, primary: "Start Screen", primaryId: "screen.start", working: session.busy == .start)
        case .attaching:
            model = .init(id: "screen.attaching", spinner: true, body: "Connecting to the screen…", overPicture: true)
        case .ended(let title, let detail):
            // The panel carries the words now: the short note over it would say the same thing twice.
            if pill.accessibilityIdentifier == "screen.pill.taken", !pill.isHidden { hidePill() }
            model = .init(id: "screen.ended", title: ScreenWire.plain(title), body: detail.map(ScreenWire.plain) ?? "",
                          primary: "Reconnect", primaryId: "screen.reconnect")
        case .live, .fallback:
            model.hidden = true
        }
        panel.model = model
    }

    private func renderFallback(_ reason: ScreenSession.Fallback?) {
        guard let reason else {
            fallback?.setVisible(false)
            fallback?.isHidden = true
            refreshTimer?.invalidate()
            refreshTimer = nil
            return
        }
        let page = fallback ?? makeFallback()
        page.isHidden = false
        page.managed = openCloudAgent != nil
        page.update(reason: reason, blocker: session.status?.blocker)
        page.setVisible(onView)
        // The plugin can finish installing while its Screen is still open: the live Screen then opens by itself.
        let wanted = onView && !page.card.windows
        if wanted, refreshTimer == nil {
            let every: TimeInterval = ScreenPower.slow ? 10 : 5
            refreshTimer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.session.refresh() }
            }
        } else if !wanted {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func makeFallback() -> LatestScreenshotsView {
        let feed = ScreenshotFeed(client: service.client, profile: profile, name: botName)
        feed.isMine = { [weak self] event in self?.ownsSession?(event.sessionId) ?? false }
        let page = LatestScreenshotsView(feed: feed, client: service.client)
        page.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: content.leadingAnchor), page.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            page.topAnchor.constraint(equalTo: content.topAnchor), page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        configure(page.card, controlOnly: false)
        fallback = page
        return page
    }

    /// Whether a live event's runtime session is one of this bot's chats (the app knows which chats it has live).
    var ownsSession: ((String) -> Bool)?

    private func configure(_ card: ScreenSetupCard, controlOnly: Bool) {
        if setupRequested?() == true { card.showRequested() }
        card.onSetup = { [weak self, weak card] in
            guard let self, let requestSetup else { return .notConnected }
            return await requestSetup((card?.requested ?? false) || controlOnly)
        }
        card.onCheck = { [weak self] in
            guard let self else { throw CancellationError() }
            let line = try await service.checkSetup(profile: profile)
            session.refresh()
            return ScreenWire.plain(line)
        }
    }

    private func showControlSetup() {
        let sheet = ScreenSetupSheet()
        configure(sheet.card, controlOnly: true)
        let navigation = ChatSheet.wrap(sheet, title: "Screen Control")
        // The Screen under a sheet is out of view: its stream pauses after a second and comes back by itself.
        sheetUp = true
        onViewChanged(immediately: false)
        sheet.onGone = { [weak self] in
            guard let self else { return }
            sheetUp = false
            onViewChanged(immediately: true)
        }
        present(navigation, animated: true)
    }

    // MARK: Actions

    private func panelPrimary() {
        switch session.phase {
        case .missing where openCloudAgent != nil: openCloudAgent?()
        case .noAnswer, .missing: session.open()
        case .off: session.start()
        case .ended: session.reconnect()
        default: break
        }
    }

    private func panelSecondary() {
        guard case .missing = session.phase, let command = session.status?.installCommand, !command.isEmpty else { return }
        UIPasteboard.general.string = command
        Haptics.play(.success)
        showPill("Copied", id: "screen.pill.copied", seconds: 2)
    }

    private func press(_ keysym: UInt32, _ extra: Set<ScreenKeys.Modifier>) {
        guard session.canSendInput else { return }
        session.sendKeys(ScreenKeys.chord(keysym, mods: armed.union(extra)))
        clearArmed()
    }

    private func clearArmed() {
        guard !armed.isEmpty else { return }
        armed = []
        renderBar()
    }

    private func paste() {
        guard session.canSendInput, !pasting else { return }
        pasting = true
        // The clipboard is read only on this tap, and off the main thread: iOS may ask first ("Allow Paste"), and the
        // picture and this phone's control keep going while the person decides. A refusal reads as an empty clipboard.
        Task { [weak self] in
            let text = await Task.detached(priority: .userInitiated) { () -> String? in
                UIPasteboard.general.hasStrings ? UIPasteboard.general.string : nil
            }.value
            guard let self else { return }
            pasting = false
            guard !gone else { return }
            guard let text, !text.isEmpty else {
                Haptics.play(.warning)   // as the Browser's Paste
                showPill(ControlWords.nothingToPaste, id: "screen.pill.clipboard", seconds: 3)
                clearArmed()
                return
            }
            pendingPaste = (text, Date().addingTimeInterval(8))
            flushPaste()
        }
    }

    /// The text goes out as soon as this phone can send input: iOS's question can pause the stream for a moment. It is
    /// kept for a few seconds at most, and never once control has ended.
    private func flushPaste() {
        guard let pending = pendingPaste else { return }
        guard Date() <= pending.until else {
            pendingPaste = nil
            return
        }
        guard session.canSendInput else { return }
        pendingPaste = nil
        session.paste(pending.text)
        Haptics.play(.selection)   // the text went
        clearArmed()
    }

    private func noticed(_ notice: ScreenSession.Notice) {
        switch notice {
        case .controlStarted:
            Haptics.play(.light)
            HQAnnounce.say("You are in control")
            showPill(ControlWords.screenGestures,
                     id: "screen.hint.gestures", seconds: 8, announce: true)
        case .controlEnded:
            typingWanted = false
            pendingPaste = nil
            keyField.resignFirstResponder()
            stage.dropTouches()
            if pill.accessibilityIdentifier == "screen.hint.gestures" { hidePill() }
            HQAnnounce.say(session.caption)
        case .controlTaken:
            Haptics.play(.warning)
            typingWanted = false
            pendingPaste = nil
            keyField.resignFirstResponder()
            stage.dropTouches()
            showPill(ScreenSession.controlTaken, id: "screen.pill.taken", seconds: 5, announce: true)
        case .live:
            break
        }
        render()
    }

    private func offerRotateHint() {
        let portrait = view.bounds.height > view.bounds.width
        let phone = traitCollection.userInterfaceIdiom == .phone
        guard ScreenViewMath.wantsRotateHint(seen: service.holds.rotateHintSeen, portrait: portrait, phone: phone) else { return }
        service.holds.rotateHintSeen = true
        guard pill.isHidden else { return }
        showPill("Turn your \(DeviceWord.name) sideways for a larger screen", id: "screen.hint.rotate", seconds: 6, announce: true)   // UX study #179: the device by name
    }

    // MARK: Compact typing (§5.7)

    private func updateCompactTyping() {
        guard isViewLoaded else { return }
        let size = stage.bounds.size
        let compact = ScreenViewMath.compactTyping(typing: typing, visible: size) && session.phase == .live
        guard compact != inCompact else { return }
        inCompact = compact
        if compact {
            savedView = stage.view
            touchedView = false
            if let next = ScreenViewMath.fillWidthView(width: size.width, height: size.height, aspect: stage.aspect, fy: stage.tappedRow) {
                stage.setView(next, animated: true)
            }
        } else {
            if !touchedView, let savedView { stage.setView(savedView, animated: true) }
            savedView = nil
        }
        render()
    }

    // MARK: Pills (above the bar, never under the top bar)

    private func showPill(_ text: String, id: String, seconds: TimeInterval, announce: Bool = false) {
        pillsShown += 1
        lastPill = id + ":" + text.replacingOccurrences(of: " ", with: "_")
        pillTimer?.invalidate()
        pill.text = text
        pill.accessibilityIdentifier = id
        pill.isHidden = false
        UIView.animate(withDuration: 0.2) { self.pill.alpha = 1 }   // motion-ok: opacity only
        if announce { HQAnnounce.say(text) }
        pillTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePill() }
        }
    }

    private func hidePill() {
        pillTimer?.invalidate()
        pillTimer = nil
        UIView.animate(withDuration: 0.2, animations: { self.pill.alpha = 0 }, completion: { [weak self] _ in   // motion-ok: opacity only
            guard let self, pillTimer == nil else { return }
            pill.isHidden = true
        })
    }

    /// The display stays on while a live picture is on view: the iPhone's idle timer, the Mac's display sleep.
    private func keepAwake(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
        #if targetEnvironment(macCatalyst)
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                          reason: "Watching a bot's screen")
        } else if !on, let token = awake {
            ProcessInfo.processInfo.endActivity(token)
            awake = nil
        }
        #endif
    }

    // MARK: Keys and zoom (round 2 #37)

    /// = / - / 0 zoom in, out and back to Fit, as a pinch and the bar's Fit do; not while the keyboard types on the
    /// bot's screen (those keys are the bot's then). ⌘= and ⌘- stay the app's UI Scale.
    override var keyCommands: [UIKeyCommand]? {
        guard !keyField.isFirstResponder, stage.hasPicture, session.phase == .live else { return [] }
        let keys: [(String, UIKeyModifierFlags, String)] = [("=", [], "Zoom In"), ("+", .shift, "Zoom In"),
                                                             ("-", [], "Zoom Out"), ("0", [], "Fit Screen")]
        return keys.map { input, flags, title in
            let command = UIKeyCommand(title: title, action: #selector(zoomKey(_:)), input: input, modifierFlags: flags)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func zoomKey(_ command: UIKeyCommand) {
        guard let step = command.input.flatMap(ZoomStep.forKey) else { return }
        zoom(step)
    }

    private func zoom(_ step: ZoomStep) {
        guard stage.hasPicture else { return }
        if inCompact { touchedView = true }
        if let factor = step.factor { stage.zoom(by: factor) } else { stage.fit() }
    }

    #if targetEnvironment(macCatalyst)
    private func zoomItem(_ step: ZoomStep) -> UIBarButtonItem {
        let zoomIn = step == .zoomIn
        let item = UIBarButtonItem(image: UIImage(systemName: zoomIn ? "plus.magnifyingglass" : "minus.magnifyingglass"),
                                   primaryAction: UIAction { [weak self] _ in self?.zoom(step) })
        item.accessibilityLabel = zoomIn ? "Zoom In" : "Zoom Out"
        item.accessibilityIdentifier = zoomIn ? "screen.zoomIn" : "screen.zoomOut"
        item.isEnabled = false
        return item
    }

    /// [mac] The viewer holds the keyboard while nothing in it types, so = / - / 0, ⌘W and Escape find it.
    override var canBecomeFirstResponder: Bool { true }

    private func takeKeys() {
        guard !gone, !keyField.isFirstResponder, view.window != nil, presentedViewController == nil else { return }
        becomeFirstResponder()
    }

    /// ⌘W (the menu's Close Chat) closes the viewer, as its ✕ does.
    @objc func hqCloseChat(_ sender: Any?) { close() }

    /// Escape (the menu's Stop or Close) closes it too. Typing on the bot's screen, Escape is the bot's (the key view
    /// reads it itself; should the menu take it first, it is passed on).
    @objc func hqEscape(_ sender: Any?) {
        if keyField.isFirstResponder { press(ScreenKeys.Named.escape.keysym, []) } else { close() }
    }

    /// Not while a sheet is up over the viewer: the app's own Escape ladder closes that first.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == KeyCommands.closeChat || action == KeyCommands.escape { return presentedViewController == nil && !gone }
        return super.canPerformAction(action, withSender: sender)
    }

    override func validate(_ command: UICommand) {
        super.validate(command)
        if command.action == KeyCommands.closeChat { command.title = "Close"; command.attributes = [] }
        if command.action == KeyCommands.escape { command.attributes = [] }
    }
    #else
    private func takeKeys() {}
    #endif

    // MARK: Leaving (§5.8, §6.2)

    private func close() {
        typingWanted = false
        pendingPaste = nil
        keyField.resignFirstResponder()
        // Leave first: the hand-back does not wait for the dismissal, and never for the network.
        left()
        presentingViewController?.dismiss(animated: true)
    }

    /// Idempotent. Runs the leaving rules, stops every timer and gives the screen back to the system.
    func left() {
        guard !gone else { return }
        gone = true
        typingWanted = false
        pendingPaste = nil
        stage.dropTouches()
        session.leave()
        pillTimer?.invalidate()
        refreshTimer?.invalidate()
        debugTimer?.invalidate()
        pathMonitor?.cancel()
        pathMonitor = nil
        fallback?.setVisible(false)
        keepAwake(false)
        if Self.current === self { Self.current = nil }
        let opener = self.opener
        DispatchQueue.main.async {
            opener?.setNeedsUpdateOfSupportedInterfaceOrientations()
            opener?.view.window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    // MARK: Test seam (UI tests read the stream's pacing and the stage's state)

    /// How many short notes were shown, and the newest one's identifier and words (they last 3 s: a loaded test run can
    /// miss one on screen).
    private var pillsShown = 0
    private var lastPill = "-"

    private func installDebug() {
        debug.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        debug.alpha = 0.02
        debug.isAccessibilityElement = true
        debug.accessibilityIdentifier = "screen.debug"
        debug.accessibilityLabel = "debug"
        view.addSubview(debug)
        debugTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDebug() }
        }
    }

    private func updateDebug() {
        guard debug.superview != nil else { return }
        let at = stage.pointerPixel
        let view = stage.view
        debug.accessibilityValue = session.pacing.summary
            + String(format: " zoom=%.2f pan=%.0f,%.0f pointer=%d,%d", view.zoom, view.x, view.y, at.x, at.y)
            + " control=\(session.canSendInput ? 1 : 0) typing=\(typing ? 1 : 0) compact=\(inCompact ? 1 : 0)"
            + " landscape=\(self.view.bounds.width > self.view.bounds.height ? 1 : 0) idle=\(UIApplication.shared.isIdleTimerDisabled ? 1 : 0)"
            + " backlog=\(session.typingBacklog) covered=\(covered ? 1 : 0)"
            + String(format: " shotZoom=%.2f", Double(fallback?.zoomScale ?? 0))   // a Double: a bare 0 would be passed as an Int
            + " pills=\(pillsShown) lastPill=\(lastPill)"
    }
}

/// The centred words and buttons of the states that are not a picture (S0, S1, S3, S4, S5, S7).
final class ScreenStatePanel: UIView {
    struct Model: Equatable {
        var hidden = false
        var id = ""
        var spinner = false
        var title: String?
        var body = ""
        var footnote: String?
        var code: String?
        var primary: String?
        var primaryId = ""
        var secondary: String?
        var secondaryId = ""
        var working = false
        /// Drawn over the (dimmed) picture: light text, no page behind it.
        var overPicture = false
    }

    var onPrimary: (() -> Void)?
    var onSecondary: (() -> Void)?
    var model = Model() { didSet { if model != oldValue { apply() } } }

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let title = UILabel()
    private let body = UILabel()
    private let footnote = UILabel()
    private let code = UITextView()
    private let primary = UIButton(configuration: .hqProminentGlass())
    private let secondary = UIButton(configuration: .hqGlass())

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        // The words sit in the middle of the page, and scroll when they are taller than it. The page's own height is
        // never theirs to decide: they are centred in the scrolled content, which is at least as tall as the page.
        let snug = scroll.contentLayoutGuide.heightAnchor.constraint(equalToConstant: 0)
        snug.priority = UILayoutPriority(1)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(greaterThanOrEqualTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: scroll.contentLayoutGuide.centerYAnchor),
            scroll.contentLayoutGuide.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
            snug,
        ])
        title.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: HQFont.system(ofSize: 20, weight: .semibold))
        title.accessibilityTraits = .header
        body.font = HQFont.preferred(.body)
        footnote.font = HQFont.preferred(.footnote)
        for label in [title, body, footnote] {
            label.numberOfLines = 0
            label.textAlignment = .center
            label.adjustsFontForContentSizeCategory = true
        }
        code.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: HQFont.mono(ofSize: 13, weight: .regular))
        code.adjustsFontForContentSizeCategory = true
        code.isEditable = false
        code.isScrollEnabled = false
        code.backgroundColor = HQPalette.card
        code.layer.cornerRadius = HQShape.radius(12, .card)
        code.layer.cornerCurve = .continuous
        code.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        code.accessibilityIdentifier = "screen.command"
        for button in [primary, secondary] {
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        }
        primary.addAction(UIAction { [weak self] _ in self?.onPrimary?() }, for: .primaryActionTriggered)
        secondary.addAction(UIAction { [weak self] _ in self?.onSecondary?() }, for: .primaryActionTriggered)
        for view in [spinner, title, body, footnote, code, secondary, primary] as [UIView] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(18, after: code)
        stack.setCustomSpacing(22, after: body)
        stack.setCustomSpacing(22, after: footnote)
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func apply() {
        isHidden = model.hidden
        guard !model.hidden else { spinner.stopAnimating(); return }
        backgroundColor = model.overPicture ? .clear : HQPalette.plainPage   // #78
        isUserInteractionEnabled = !model.overPicture
        let text: UIColor = model.overPicture ? .white : HQPalette.label
        let quiet: UIColor = model.overPicture ? UIColor.white.withAlphaComponent(0.85) : HQPalette.label2
        spinner.isHidden = !model.spinner
        spinner.color = model.overPicture ? .white : nil
        if model.spinner { spinner.startAnimating() } else { spinner.stopAnimating() }
        title.text = model.title
        title.textColor = text
        title.isHidden = model.title == nil
        title.accessibilityIdentifier = model.id + ".title"
        body.text = model.body
        body.textColor = model.title == nil ? quiet : HQPalette.label2
        body.isHidden = model.body.isEmpty
        body.accessibilityIdentifier = model.id
        footnote.text = model.footnote
        footnote.textColor = HQPalette.label2      // label-3 is for glyphs, never words
        footnote.isHidden = model.footnote == nil
        footnote.accessibilityIdentifier = model.id + ".footnote"
        code.text = model.code
        code.isHidden = model.code == nil
        primary.isHidden = model.primary == nil
        primary.configuration?.title = model.primary
        primary.configuration?.showsActivityIndicator = model.working
        primary.isEnabled = !model.working
        primary.accessibilityIdentifier = model.primaryId
        secondary.isHidden = model.secondary == nil
        secondary.configuration?.title = model.secondary
        secondary.accessibilityIdentifier = model.secondaryId
    }
}
