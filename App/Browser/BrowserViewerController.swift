import UIKit

// Watch Browser: a bot's browser, live, full screen, and taking it over (port of the web app's src/browser-watch/
// viewer.tsx, built natively). The page is the plugin's screencast drawn on a layer; the bar at the bottom is native
// glass buttons that ride the keyboard. Holding the browser, the stage is a trackpad (BrowserStageView) and the iOS
// keyboard types into the page through BrowserKeyField (password AutoFill on sign-in fields).

final class BrowserViewerController: UIViewController, BrowserStageHost, UITextFieldDelegate {
    /// `drift`: the add-on is current but off (Hermes changed under it); its words, with no install offer.
    private enum Setup: Equatable { case checking, failed(String), missing, update, drift(BrowserEmptyCopy), ready }

    let service: BrowserService
    let scope: BrowserScope
    /// "Ask Hermes to Install It": queues the request in the main bot's chat once this viewer has closed (AppModel
    /// wires it to `MainBotRequest.queue`; [presence] spec 3x-presence §10). Throws the words for why it could not.
    var askToInstall: ((String) async throws -> Void)?
    /// [presence] The check that needs no navigation (is there a main bot to ask?); it throws the words to show under
    /// the button.
    var canAsk: (() throws -> Void)?
    /// The main bot's name, for "Ask … to Install It": the request lands in its chat ("Hermes" while it is unknown).
    var helper = "Hermes"
    /// The bot's Capabilities › Plugins page, pushed over the viewer when the browser add-on is switched off for it.
    var openPlugins: (() -> UIViewController?)?
    /// [browser-update] Starts (or opens) the add-on update sheet, the one Settings' "Add-on Update Available" row
    /// runs: the viewer closes first. `nil` where that update can't run (the bot is asked instead).
    var updateAddOn: (() -> Void)?
    /// [setup-browser] A Hermes Cloud gateway: its bots browse in Browser Use's cloud, which the add-on can't show, so
    /// a missing add-on is explained, not offered.
    var cloudGateway = false
    private static weak var current: BrowserViewerController?
    /// [presence] ✕ was tapped (or the viewer is leaving to ask the main bot): it no longer counts as open.
    private var closing = false
    /// [presence] "Ask Hermes to Install It" was tapped: the button reads "Asking…" and takes no second tap.
    private var asking = false
    private var emptyProblemText: String?

    /// [presence] What waits for this viewer to have gone (`closeCurrent`), run once when its dismissal ends.
    private var afterClose: [() -> Void] = []

    /// [presence] A viewer is on screen, open or on its way out (any bot).
    static var isUp: Bool { current != nil }

    /// [presence] A viewer for this bot's browser is up (a chat-only viewer counts for its bot too).
    static func isWatching(profile: String) -> Bool { current.map { !$0.closing && $0.scope.profile == profile } ?? false }

    /// [presence] Closes the viewer that is up, as its ✕ does (a held browser is handed back), and calls `completion`
    /// when it has gone: at once when none is up, and after the dismissal that is already running when its ✕ was just
    /// tapped (spec 3x-presence §8.4, DECISION D9).
    static func closeCurrent(completion: @escaping () -> Void) {
        guard let viewer = current else { completion(); return }
        viewer.close(completion: completion)
    }

    private var name: String { scope.title.isEmpty ? "This bot" : scope.title }
    private var setup: Setup = .checking
    private var plugin: BrowserService.Plugin?
    private var subscription: BrowserSubscription?
    private var session: BrowserWatchSession?
    private var own: OwnBrowser?? = .none
    private var ownPoll: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var appActive = UIApplication.shared.applicationState == .active
    private var observers: [NSObjectProtocol] = []

    private let stage = BrowserStageView()
    private let address = BrowserAddressField()
    private let askCard = UIView()
    private let askTitle = UILabel()
    private let askBody = UILabel()
    private let empty = UIStackView()
    private let emptySpinner = UIActivityIndicatorView(style: .medium)
    private let emptyIcon = UIImageView(image: UIImage(systemName: "safari"))
    private let emptyTitle = UILabel()
    private let emptyBody = UILabel()
    private let emptyButton = UIButton(configuration: .hqPush())   // [mac] Stress test 2026-10-28 #55 (round 6): the Mac push button; the iPhone keeps glass
    /// [presence] Why "Ask Hermes to Install It" could not ask, under the button.
    private let emptyProblem = UILabel()
    private var emptyAction: (() -> Void)?
    private let blankNote = UIStackView()
    private let notice = BrowserPill()
    private let hint = BrowserPill()
    private let bar = UIStackView()
    private let caption = UILabel()
    private let keyFields: [BrowserKeyboardSlot: BrowserKeyField]
    private var noticeTimer: Timer?
    private var hintTimer: Timer?
    private var editingAddress = false
    private var typing = false

    static func present(scope: BrowserScope, service: BrowserService, from presenter: UIViewController,
                        canAsk: (() throws -> Void)? = nil, askToInstall: ((String) async throws -> Void)? = nil,
                        openPlugins: (() -> UIViewController?)? = nil, helper: String? = nil, cloudGateway: Bool = false,
                        updateAddOn: (() -> Void)? = nil) {
        guard current == nil else { return }
        let viewer = BrowserViewerController(service: service, scope: scope)
        viewer.askToInstall = askToInstall
        viewer.canAsk = canAsk
        if let helper, !helper.isEmpty { viewer.helper = helper }
        viewer.openPlugins = openPlugins
        viewer.cloudGateway = cloudGateway
        viewer.updateAddOn = updateAddOn
        let navigation = UINavigationController(rootViewController: viewer)
        current = viewer
        Haptics.play(.selection)
        PaneViewer.present(navigation, from: presenter)   // [mac] over the right pane; full screen elsewhere
    }

    init(service: BrowserService, scope: BrowserScope) {
        self.service = service
        self.scope = scope
        let shownName = scope.title.isEmpty ? "This bot" : scope.title
        keyFields = Dictionary(uniqueKeysWithValues: BrowserKeyboardSlot.allCases.map { ($0, BrowserKeyField(slot: $0, name: shownName)) })
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        ownPoll?.cancel()
        checkTask?.cancel()
        session?.stop()
    }

    // MARK: Building

    override func viewDidLoad() {
        super.viewDidLoad()
        AppLog.note("browser", "viewer open")
        // Stress test 2026-10-28 #56, #78: in the Desktop Look, the look's page and bar (it was iOS's neutral grey, its
        // title floating over no bar).
        view.backgroundColor = HQPalette.plainPage
        if DeviceWord.isMac { view.backgroundColor = HQPalette.groupedPage }   // [mac] Stress test 2026-10-28 round 7: the grouped page, as the other Mac pages
        title = "\(name)’s Browser"
        let close = UIBarButtonItem.hqClose(action: UIAction { [weak self] _ in self?.closeTapped() })
        close.accessibilityIdentifier = "browser.close"
        navigationItem.hqPlaceClose(close)   // [mac] Stress test 2026-10-28 #55: trailing on the Mac, after the tabs
        navigationItem.largeTitleDisplayMode = .never
        let appearance = Theme.isDesktop ? ThemeChrome.solidBar(solid: true) : UINavigationBarAppearance()
        if !Theme.isDesktop { appearance.configureWithDefaultBackground() }
        if DeviceWord.isMac {   // [mac] Stress test 2026-10-28 round 7: the bar on the grouped page, no rule under it
            if !Theme.isDesktop { appearance.configureWithOpaqueBackground() }
            appearance.backgroundColor = HQPalette.groupedPage
            appearance.shadowColor = .clear
        }
        // [mac] Stress test 2026-10-28 round 8: the pane title's token (the iOS look's bar drew the system's smaller title).
        if DeviceWord.isMac { appearance.titleTextAttributes[.font] = MacType.pageTitle }
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance

        stage.host = self
        stage.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stage)

        address.translatesAutoresizingMaskIntoConstraints = false
        address.delegate = self
        address.backgroundColor = .tertiarySystemFill
        address.layer.cornerRadius = HQShape.radius(12, .card)
        address.layer.cornerCurve = .continuous
        address.font = HQFont.preferred(.subheadline)
        address.adjustsFontForContentSizeCategory = true
        address.textAlignment = .center
        address.keyboardType = .URL
        address.returnKeyType = .go
        address.autocapitalizationType = .none
        address.autocorrectionType = .no
        address.spellCheckingType = .no
        address.clearButtonMode = .whileEditing
        address.placeholder = "Search or enter address"
        address.accessibilityLabel = "Address"
        address.accessibilityIdentifier = "browser.address"
        view.addSubview(address)

        askCard.translatesAutoresizingMaskIntoConstraints = false
        askCard.backgroundColor = DeviceWord.isMac ? HQPalette.groupedCard : HQPalette.card   // [mac] round 7: a card on the grouped page
        askCard.layer.cornerRadius = HQShape.radius(12, .card)
        askCard.layer.cornerCurve = .continuous
        let stripe = UIView()
        stripe.backgroundColor = .systemOrange
        stripe.translatesAutoresizingMaskIntoConstraints = false
        askTitle.font = HQFont.preferred(.headline)
        askTitle.adjustsFontForContentSizeCategory = true
        askTitle.numberOfLines = 0
        askBody.font = HQFont.preferred(.subheadline)
        askBody.adjustsFontForContentSizeCategory = true
        askBody.textColor = HQPalette.label2
        askBody.numberOfLines = 0
        let askStack = UIStackView(arrangedSubviews: [askTitle, askBody])
        askStack.axis = .vertical
        askStack.spacing = 2
        askStack.translatesAutoresizingMaskIntoConstraints = false
        askCard.addSubview(stripe)
        askCard.addSubview(askStack)
        askCard.isAccessibilityElement = true
        askCard.accessibilityIdentifier = "browser.ask"
        askCard.clipsToBounds = true
        view.addSubview(askCard)

        empty.axis = .vertical
        empty.alignment = .center
        empty.spacing = 8
        empty.translatesAutoresizingMaskIntoConstraints = false
        // [mac] Stress test 2026-10-31: the Mac's one empty-state title and symbol (`MacType`); this page alone drew a
        // Headline title and a 40 pt symbol.
        emptyIcon.preferredSymbolConfiguration = DeviceWord.isMac ? MacType.emptySymbol
            : UIImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        emptyIcon.tintColor = HQPalette.label2
        emptyTitle.font = DeviceWord.isMac ? MacType.emptyTitle : HQFont.preferred(.headline)
        emptyTitle.adjustsFontForContentSizeCategory = true
        emptyTitle.textAlignment = .center
        emptyTitle.numberOfLines = 0
        emptyTitle.accessibilityIdentifier = "browser.empty.title"
        emptyBody.font = DeviceWord.isMac ? MacType.emptyBody : HQFont.preferred(.subheadline)
        emptyBody.adjustsFontForContentSizeCategory = true
        emptyBody.textColor = HQPalette.label2
        emptyBody.textAlignment = .center
        emptyBody.numberOfLines = 0
        emptyButton.addAction(UIAction { [weak self] _ in self?.emptyAction?() }, for: .primaryActionTriggered)
        emptyButton.accessibilityIdentifier = "browser.empty.action"
        emptyProblem.font = HQFont.preferred(.footnote)
        emptyProblem.adjustsFontForContentSizeCategory = true
        emptyProblem.textColor = .systemRed
        emptyProblem.textAlignment = .center
        emptyProblem.numberOfLines = 0
        emptyProblem.isHidden = true
        emptyProblem.accessibilityIdentifier = "browser.empty.problem"
        for item in [emptySpinner, emptyIcon, emptyTitle, emptyBody, emptyButton, emptyProblem] as [UIView] { empty.addArrangedSubview(item) }
        empty.setCustomSpacing(16, after: emptyBody)
        empty.setCustomSpacing(12, after: emptyButton)
        view.addSubview(empty)

        let blankTitle = UILabel()
        blankTitle.text = "No Page Open"
        blankTitle.font = HQFont.preferred(.headline)
        blankTitle.adjustsFontForContentSizeCategory = true
        let blankBody = UILabel()
        blankBody.font = HQFont.preferred(.subheadline)
        blankBody.adjustsFontForContentSizeCategory = true
        blankBody.textColor = HQPalette.label2
        blankBody.numberOfLines = 0
        blankBody.textAlignment = .center
        blankBody.tag = 1
        blankNote.axis = .vertical
        blankNote.alignment = .center
        blankNote.spacing = 6
        blankNote.addArrangedSubview(blankTitle)
        blankNote.addArrangedSubview(blankBody)
        blankNote.isUserInteractionEnabled = false
        blankNote.translatesAutoresizingMaskIntoConstraints = false
        blankNote.isHidden = true
        view.addSubview(blankNote)

        for pill in [notice, hint] {
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.isHidden = true
            view.addSubview(pill)
        }
        notice.accessibilityIdentifier = "browser.notice"
        hint.accessibilityIdentifier = "browser.hint"

        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        // [a11y] Icons capped at a bar's size show their name in the large content viewer (the Screen bar's way).
        bar.addInteraction(UILargeContentViewerInteraction())
        view.addSubview(bar)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (viewer: BrowserViewerController, _) in
            viewer.render()
        }
        caption.font = HQFont.preferred(.footnote)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = HQPalette.label2
        caption.numberOfLines = 0
        caption.textAlignment = .center
        caption.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(caption)

        for field in keyFields.values {
            field.onText = { [weak self] text in self?.session?.input(.text(text)) }
            field.onKey = { [weak self] key in self?.session?.input(.key(key)) }
            field.onFocusChange = { [weak self] _ in self?.typingChanged() }
            stage.addSubview(field)
            field.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        let guide = view.keyboardLayoutGuide
        guide.usesBottomSafeArea = false
        let safe = view.safeAreaLayoutGuide
        let barBottom = bar.bottomAnchor.constraint(equalTo: guide.topAnchor, constant: -8)
        barBottom.priority = .defaultHigh
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #78: centred on the stage (under the address field's room) the notice sat below
        // the middle of the pane; it goes a little above the middle of the page instead.
        let emptyMiddle = empty.centerYAnchor.constraint(equalTo: safe.centerYAnchor, constant: -40)
        #else
        let emptyMiddle = empty.centerYAnchor.constraint(equalTo: stage.centerYAnchor)
        #endif
        NSLayoutConstraint.activate([
            address.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
            address.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            address.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            address.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            askCard.topAnchor.constraint(equalTo: address.bottomAnchor, constant: 8),
            askCard.leadingAnchor.constraint(equalTo: address.leadingAnchor),
            askCard.trailingAnchor.constraint(equalTo: address.trailingAnchor),
            stripe.leadingAnchor.constraint(equalTo: askCard.leadingAnchor),
            stripe.topAnchor.constraint(equalTo: askCard.topAnchor),
            stripe.bottomAnchor.constraint(equalTo: askCard.bottomAnchor),
            stripe.widthAnchor.constraint(equalToConstant: 4),
            askStack.leadingAnchor.constraint(equalTo: stripe.trailingAnchor, constant: 12),
            askStack.trailingAnchor.constraint(equalTo: askCard.trailingAnchor, constant: -12),
            askStack.topAnchor.constraint(equalTo: askCard.topAnchor, constant: 12),
            askStack.bottomAnchor.constraint(equalTo: askCard.bottomAnchor, constant: -12),
            stage.topAnchor.constraint(equalTo: askCard.bottomAnchor, constant: 8),
            stage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -8),
            caption.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            caption.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            caption.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
            bar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(lessThanOrEqualTo: safe.bottomAnchor, constant: -8),
            barBottom,
            empty.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            emptyMiddle,
            empty.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 32),
            empty.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -32),
            blankNote.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            blankNote.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            blankNote.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 32),
            blankNote.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -32),
            notice.topAnchor.constraint(equalTo: stage.topAnchor, constant: 12),
            notice.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            notice.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
            hint.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -12),
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
        ])
        #if targetEnvironment(macCatalyst)
        // [mac] #78: over a pane the notice's line ran about 890 pt wide; a readable measure.
        empty.widthAnchor.constraint(lessThanOrEqualToConstant: 480).isActive = true
        #endif
        askHidden = askCard.heightAnchor.constraint(equalToConstant: 0)
        askHidden?.isActive = true
        barFull = bar.widthAnchor.constraint(equalTo: safe.widthAnchor, constant: -32)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stage.covered = false; self?.appActive = true; self?.updateShown() }
        })
        #if !targetEnvironment(macCatalyst)
        // Audit 09-2: the bot's page out of the app switcher (Control Centre, the switcher, a call). [mac] No switcher.
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stage.covered = true }
        })
        #endif
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appActive = false; self?.updateShown() }
        })
        render()
        check()
    }

    private var askHidden: NSLayoutConstraint?
    /// [a11y] At accessibility text sizes, while in control: the bar spans the margins so Give Back is a full-width row.
    private var barFull: NSLayoutConstraint?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateShown()
        takeKeys()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        updateShown()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sendViewSize()
        if session?.mine == true, Int(view.safeAreaLayoutGuide.layoutFrame.width) != Int(barWidth) { render() }
    }

    private var isShown: Bool { appActive && view.window != nil && !isBeingDismissed }

    #if DEBUG
    /// Tests: the setup page ("checking", "ready", "missing", "update", "failed(…)").
    var debugSetup: String { "\(setup)" }
    /// [browser-update] Screenshots: the next viewer shows the "Is Off" page without reading /health.
    static var debugOff = false
    #endif

    // MARK: Setup and the browser's row

    /// `preferCache`: a ready plugin the service already holds opens the viewer at once (no /health before the watch
    /// socket), then a fresh read checks it in the background. Try Again always reads afresh.
    private func check(preferCache: Bool = true) {
        checkTask?.cancel()
        #if DEBUG
        // [browser-update] `-HQDebugAddOnUpdate browseroff`: the "Browser Add-on Is Off" page of a 3.7.0 add-on.
        if Self.debugOff {
            setup = .drift(.addOnOff(.object(["installed": .bool(false), "protocol": .number(3), "version": .string("3.7.0"),
                                              "drift": .array([.string("browser tools unavailable (ImportError)")])])))
            render()
            return
        }
        #endif
        if preferCache, let cached = service.cachedPlugin {
            plugin = cached
            setup = .ready
            AppLog.note("browser", "viewer setup ready (cached)\(cached.legacy ? " (old plugin name)" : "")")
            updateShown()
            render()
            checkTask = Task { [weak self] in await self?.revalidate() }
            return
        }
        setup = .checking
        render()
        checkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await self.service.plugin(fresh: true)
                guard !Task.isCancelled else { return }
                self.plugin = found
                switch found.setup {
                case .ready: self.setup = .ready
                case .missing: self.setup = .missing
                case .update: self.setup = .update
                case .drift: self.setup = .drift(.addOnOff(found.health))
                }
                AppLog.note("browser", "viewer setup \(found.setup.rawValue)\(found.legacy ? " (old plugin name)" : "")")
            } catch {
                guard !Task.isCancelled else { return }
                if BrowserService.isMissing(error) { self.setup = .missing }
                else { self.setup = .failed((error as? LocalizedError)?.errorDescription ?? "Check your connection, then try again.") }
                AppLog.note("browser", "viewer setup \(BrowserService.isMissing(error) ? "missing" : "failed")")
            }
            self.updateShown()
            self.render()
        }
    }

    /// The background read behind a cached open. Only a plugin answer changes the page: a missing plugin or one that
    /// needs an update shows its page; a timeout or a lost connection leaves a working viewer alone (its socket reports
    /// its own link).
    private func revalidate() async {
        let found: BrowserService.Plugin
        do {
            found = try await service.plugin(fresh: true)
        } catch {
            guard !Task.isCancelled, !service.isShutDown, BrowserService.isMissing(error) else { return }
            setup = .missing
            AppLog.note("browser", "viewer setup missing (rechecked)")
            updateShown()
            render()
            return
        }
        guard !Task.isCancelled, !service.isShutDown else { return }
        switch found.setup {
        case .ready:
            let moved = found.base != plugin?.base
            plugin = found
            // Rare: the plugin answers under its other name now. The watch socket is rebuilt on the new base.
            if moved, let session {
                session.stop()
                self.session = nil
                stage.clear()
                rowsChanged()
            }
            return
        case .missing: setup = .missing
        // The add-on switched itself off, so its words replace the page (no update would bring it back).
        case .drift: setup = .drift(.addOnOff(found.health))
        case .update:
            // A browser already showing stays: the late "needs an update" is a note over it, not the setup page
            // swapped in under the person. The next open shows the setup page.
            if let session, session.view != nil, !session.ended {
                AppLog.note("browser", "viewer setup update (rechecked, kept the page)")
                showNotice("The browser add\u{2011}on on \(HostWord.phrase) needs an update. You can keep watching for now.", warning: false)
                return
            }
            setup = .update
        }
        AppLog.note("browser", "viewer setup \(found.setup.rawValue) (rechecked)")
        updateShown()
        render()
    }

    private func updateShown() {
        guard isViewLoaded else { return }
        let on = isShown && setup == .ready
        if on && subscription == nil {
            subscription = service.activity.subscribe { [weak self] in self?.rowsChanged() }
            rowsChanged()
        } else if !on, let subscription {
            subscription.cancel()
            self.subscription = nil
        }
        session?.setShown(on)
        updateOwnPoll()
    }

    private var row: BrowserRow? { scope.row(in: service.activity.rows) }

    private func rowsChanged() {
        let row = self.row
        if let row, row.id != session?.rowId {
            session?.stop()
            stage.clear()
            let watch = BrowserWatchSession(service: service, rowId: row.id, base: plugin?.base ?? BrowserWire.plugin,
                                            profile: row.profile, name: name)
            wire(watch)
            session = watch
            AppLog.note("browser", "viewer watching a browser")
            watch.setShown(isShown && setup == .ready)
            sendViewSize()
        }
        updateOwnPoll()
        render()
    }

    private func updateOwnPoll() {
        let wanted = setup == .ready && row == nil && session == nil && isShown
        if !wanted { ownPoll?.cancel(); ownPoll = nil; return }
        guard ownPoll == nil else { return }
        ownPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let found = try? await self.service.ownBrowser(profile: self.scope.profile) { self.own = .some(found) }
                else if self.own == nil { self.own = .some(nil) }
                self.render()
                await PowerPolls.wait(.seconds(4), floor: .zero)          // [offline] §6.9
            }
        }
    }

    private func wire(_ watch: BrowserWatchSession) {
        watch.onChange = { [weak self] in self?.render() }
        watch.onFrame = { [weak self] image, frame in
            guard let self else { return }
            self.stage.show(image, pageSize: CGSize(width: frame.width, height: frame.height))
            #if DEBUG
            self.stage.accessibilityValue = watch.pacing.summary
            #endif
        }
        watch.onNotice = { [weak self] text, warning in self?.showNotice(text, warning: warning) }
        watch.onCopied = { [weak self] text in self?.copied(text) }
        watch.onShutDown = { [weak self] in
            guard let self else { return }
            self.resignTyping()
            self.session = nil
            self.subscription?.cancel()
            self.subscription = nil
            // [presence] Through the one way out, so a page presented over the viewer goes with it.
            if self.presentingViewController != nil { self.close() }
        }
    }

    private func sendViewSize() {
        guard let session, stage.bounds.width > 0 else { return }
        let zoom = Double(stage.drawn.zoom)
        session.setViewSize(width: Double(stage.bounds.width) * zoom, height: Double(stage.bounds.height) * zoom,
                            scale: Double(view.window?.screen.scale ?? traitCollection.displayScale))
    }

    // MARK: Rendering

    private func render() {
        guard isViewLoaded else { return }
        let state = session?.view
        let mine = session?.mine ?? false
        let live = session.map { $0.page != nil && $0.view != nil && $0.link != .stalled } ?? false
        // The empty states.
        var emptyState: EmptyState?
        switch setup {
        case .checking: emptyState = EmptyState(true, false, "", "", nil)
        case .failed(let message):
            emptyState = EmptyState(false, false, "Couldn’t Reach \(name)", message, EmptyAction("Try Again", { [weak self] in self?.check(preferCache: false) }))
        case .missing where cloudGateway:
            emptyState = EmptyState(false, true, "Bots Browse in the Cloud Here",
                          "On Hermes Cloud, a bot’s browser runs on Browser Use’s servers, not on this gateway, so it can’t be shown live yet. You can still follow each page it visits in its steps.", nil)
        case .missing, .update:
            let update = setup == .update
            emptyState = EmptyState(false, true, update ? "Update Browser Watching" : "Watch Your Bots Browse",
                          update ? "\(HostWord.sentence) has an older browser add\u{2011}on from a test build. The new one leaves your bots’ own browser tools alone and needs no Chrome extension."
                                 : "See the browser a bot is using, live, and take over when it needs you to sign in or enter a code. It needs a small add\u{2011}on on \(HostWord.phrase).",
                          askToInstall == nil ? nil : EmptyAction(asking ? "Asking…" : "Ask \(helper) to Install It", { [weak self] in self?.install() }))
        case .drift(let copy):
            // No "Ask … to Install It": reinstalling brings back the same version, still off. [browser-update] An
            // older add-on that switched itself off is fixed by the update: the same sheet Settings runs.
            var action: EmptyAction?
            if copy.action == .update {
                if updateAddOn != nil {
                    action = EmptyAction(BrowserEmptyCopy.updateButton, { [weak self] in self?.startUpdate() })
                } else if askToInstall != nil {
                    action = EmptyAction(asking ? "Asking…" : "Ask \(helper) to Update It", { [weak self] in self?.install(BrowserSetupPrompt.update) })
                }
            }
            emptyState = EmptyState(false, true, copy.title, copy.body, action)
        case .ready:
            if let session, session.ended {
                emptyState = EmptyState(false, true, "Browser Closed", "When \(name) opens a web page, you’ll see it here live.", nil)
            } else if session == nil {
                if !service.activity.connected {
                    emptyState = EmptyState(true, false, "Connecting…", "", nil)
                } else {
                    let why = BrowserEmptyCopy.noBrowser(own, name: name)
                    var action: EmptyAction?
                    if plugin?.legacy == true && askToInstall != nil {
                        action = EmptyAction(asking ? "Asking…" : "Ask \(helper) to Update It", { [weak self] in self?.install() })
                    } else if why.action == .plugins, openPlugins != nil {
                        action = EmptyAction("Open \(name)’s Plugins", { [weak self] in self?.showPlugins() })
                    }
                    emptyState = EmptyState(why.waiting, !why.waiting, why.title, why.body, action)
                }
            } else if !live {
                let stalled = session?.link == .stalled
                emptyState = EmptyState(true, false, stalled ? "\(name)’s Browser Isn’t Responding" : "",
                              stalled ? "It may be busy or restarting. Hermes HQ keeps trying." : (session?.link == .reconnecting ? "Reconnecting…" : "Connecting…"), nil)
            }
        }
        if let e = emptyState {
            empty.isHidden = false
            emptySpinner.isHidden = !e.spinner
            if e.spinner { emptySpinner.startAnimating() } else { emptySpinner.stopAnimating() }
            emptyIcon.isHidden = !e.icon
            emptyTitle.text = e.title
            emptyTitle.isHidden = e.title.isEmpty
            emptyBody.text = e.body
            emptyBody.isHidden = e.body.isEmpty
            emptyAction = e.action?.run
            emptyButton.isHidden = e.action == nil
            if let action = e.action { emptyButton.configuration?.title = action.title }
            emptyButton.isEnabled = !asking
            // [presence] The words for why the request could not be made, under the button that makes it.
            emptyProblem.text = emptyProblemText
            emptyProblem.isHidden = emptyProblemText == nil || e.action == nil
        } else {
            empty.isHidden = true
            emptySpinner.stopAnimating()
        }
        stage.isHidden = emptyState != nil && !live
        let hasPage = session != nil && setup == .ready
        address.isHidden = !hasPage
        // The address: the site's host, or the whole address while the person edits it.
        let tab = state?.currentTab
        let site = BrowserAddress(tab?.url ?? row?.url)
        if !editingAddress {
            address.text = site.host.isEmpty ? (live ? "" : "Loading…") : site.host
            address.showsLock = site.secure
        }
        let blank = live && tab.map { BrowserAddress.isBlank($0.url) } == true && !editingAddress
        blankNote.isHidden = !blank
        (blankNote.viewWithTag(1) as? UILabel)?.text = mine ? "Type an address above to open a page." : "\(name) hasn’t opened a page in its browser."
        // The bot's question (browser_ask_user), while it still drives.
        let ask = state?.ask ?? row?.ask
        let asking = hasPage && ask != nil && (state?.control.state ?? .bot) == .bot
        askHidden?.isActive = !asking
        askCard.isHidden = !asking
        askTitle.text = "\(name) needs you"
        askBody.text = ask
        askCard.accessibilityLabel = asking ? "\(name) needs you. \(ask ?? "")" : nil
        renderDialog(hasPage ? state?.dialog : nil, held: mine && state?.control.state == .person)
        stage.showsCursor = mine && live
        if !mine { resignTyping() }
        if mine != lastMine {
            lastMine = mine
            Haptics.play(.selection)
            if mine {
                showHint(ControlWords.browserGestures)
                offerPopupsUpdate()
            }
        }
        // Tabs.
        if let tabs = state?.tabs, tabs.count > 1 {
            // A tab glyph with the count in it ("3.square"; SF Symbols number them up to 50), stacked squares past that.
            let symbol = tabs.count <= 50 ? "\(tabs.count).square" : "square.on.square"
            let item = UIBarButtonItem(image: UIImage(systemName: symbol) ?? UIImage(systemName: "square.on.square"), menu: tabsMenu(state!))
            item.accessibilityLabel = "\(tabs.count) tabs"
            item.accessibilityIdentifier = "browser.tabs"
            // [mac] #55: the page's own item, not the Mac's trailing Done.
            if navigationItem.hqOwnRightItem?.accessibilityLabel != item.accessibilityLabel { navigationItem.rightBarButtonItem = item }
            else { navigationItem.hqOwnRightItem?.menu = item.menu }
        } else {
            navigationItem.rightBarButtonItem = nil
        }
        followFieldFocus()
        renderBar(live: live, hasPage: hasPage)
        if session?.link == .reconnecting && live && notice.isHidden { showNotice("Reconnecting…", warning: false, keep: true) }
        if session?.link == .live, notice.text == "Reconnecting…" { hideNotice() }
    }

    private struct EmptyState {
        var spinner: Bool, icon: Bool, title: String, body: String, action: EmptyAction?
        init(_ spinner: Bool, _ icon: Bool, _ title: String, _ body: String, _ action: EmptyAction?) {
            self.spinner = spinner; self.icon = icon; self.title = title; self.body = body; self.action = action
        }
    }

    private struct EmptyAction {
        var title: String
        var run: () -> Void
        init(_ title: String, _ run: @escaping () -> Void) { self.title = title; self.run = run }
    }

    private var barSignature = ""
    /// The width the bar was last laid out for: a new one (rotation, a resized window) lays it out again.
    private var barWidth: CGFloat = 0

    private func renderBar(live: Bool, hasPage: Bool) {
        let mine = session?.mine ?? false, waiting = session?.waiting ?? false, someoneElse = session?.someoneElse ?? false
        let link = session?.link ?? .idle
        // [a11y] At accessibility text sizes, or whenever the one row would run past the margins (Extra Large on a
        // 375 pt phone), the icons keep a bar's size and Give Back takes its own full-width row under them, as on the
        // Screen bar (one row squeezed Give Back to "Give / Back").
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let width = view.safeAreaLayoutGuide.layoutFrame.width
        barWidth = width
        let signature = !hasPage ? "none" : mine ? "mine:\(typing):\(large):\(traitCollection.preferredContentSizeCategory.rawValue):\(Int(width))" : waiting ? "waiting" : someoneElse ? "other" : "watch:\(live && link == .live)"
        guard signature != barSignature else { return }
        barSignature = signature
        bar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        bar.axis = .horizontal
        bar.alignment = .center
        barFull?.isActive = false
        caption.text = nil
        caption.isHidden = true
        guard hasPage else { return }
        if mine {
            let icons = UIStackView()
            icons.axis = .horizontal
            icons.alignment = .center
            icons.spacing = 8
            icons.maximumContentSizeCategory = .accessibilityMedium
            icons.addArrangedSubview(icon("chevron.left", "Back", "browser.back") { [weak self] in self?.session?.input(.nav("back")) })
            icons.addArrangedSubview(icon("chevron.right", "Forward", "browser.forward") { [weak self] in self?.session?.input(.nav("forward")) })
            icons.addArrangedSubview(icon("arrow.clockwise", "Reload", "browser.reload") { [weak self] in self?.session?.input(.nav("reload")) })
            let keyboard = icon("keyboard", typing ? ControlWords.hideKeyboard : ControlWords.showKeyboard, "browser.keyboard") { [weak self] in self?.toggleKeyboard() }
            keyboard.isSelected = typing
            icons.addArrangedSubview(keyboard)
            icons.addArrangedSubview(clipboardButton())
            let give = UIButton(configuration: .hqGlass())   // plain glass, as on the Screen bar (3x-screen §5.5): Take Control is the prominent one
            give.configuration?.title = ControlWords.give
            give.configuration?.titleLineBreakMode = .byWordWrapping
            give.accessibilityIdentifier = "browser.give"
            give.addAction(UIAction { [weak self] _ in
                Haptics.play(.selection)
                self?.resignTyping()
                self?.session?.give()
                AppLog.note("browser", "give back")
            }, for: .primaryActionTriggered)
            give.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            bar.addArrangedSubview(icons)
            bar.addArrangedSubview(give)
            let iconsWidth = icons.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
            if BrowserBarLayout.stacks(accessibility: large, icons: iconsWidth, give: give.intrinsicContentSize.width, width: width) {
                icons.removeFromSuperview()
                give.removeFromSuperview()
                bar.axis = .vertical
                bar.alignment = .fill
                barFull?.isActive = true
                // The icons centred on their row, Give Back the whole width under them.
                let row = UIStackView(arrangedSubviews: [icons])
                row.axis = .vertical
                row.alignment = .center
                bar.addArrangedSubview(row)
                bar.addArrangedSubview(give)
            }
        } else if waiting {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            bar.addArrangedSubview(spinner)
            let label = UILabel()
            label.text = "\(name) is finishing a step…"
            label.font = HQFont.preferred(.footnote)
            label.textColor = HQPalette.label2
            label.numberOfLines = 0
            bar.addArrangedSubview(label)
            let cancel = UIButton(configuration: .hqGlass())
            cancel.configuration?.title = "Cancel"
            cancel.accessibilityIdentifier = "browser.cancelTake"
            cancel.addAction(UIAction { [weak self] _ in self?.session?.give() }, for: .primaryActionTriggered)
            bar.addArrangedSubview(cancel)
        } else if someoneElse {
            caption.text = ControlWords.browserOther   // Take Control stays hidden until then
            caption.isHidden = false
        } else {
            let take = UIButton(configuration: .hqProminentGlass())
            take.configuration?.title = ControlWords.take
            take.configuration?.buttonSize = .large
            take.accessibilityIdentifier = "browser.take"
            take.isEnabled = live && link == .live
            take.addAction(UIAction { [weak self] _ in
                Haptics.play(.selection)
                self?.hideNotice()
                self?.session?.take()
                AppLog.note("browser", "take control")
            }, for: .primaryActionTriggered)
            take.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            bar.addArrangedSubview(take)
            caption.text = "\(name) pauses its browser while you use it."
            caption.isHidden = false
        }
    }

    private func icon(_ symbol: String, _ label: String, _ id: String, _ action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.hqGlass()
        config.image = UIImage(systemName: symbol)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = id
        button.showsLargeContentViewer = true
        button.largeContentTitle = label
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return button
    }

    private func clipboardButton() -> UIButton {
        let button = icon("doc.on.clipboard", "Copy and Paste", "browser.clipboard") {}
        button.menu = UIMenu(children: [
            UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.paste() },
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.session?.input(.copy) },
            UIAction(title: "Select All", image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in self?.session?.input(.selectAll) },
        ])
        button.showsMenuAsPrimaryAction = true
        return button
    }

    private func tabsMenu(_ state: BrowserViewState) -> UIMenu {
        let follow = UIAction(title: "Follow \(name)", subtitle: "Shows the tab it’s using",
                              image: UIImage(systemName: "arrow.triangle.turn.up.right.circle"),
                              state: state.follow ? .on : .off) { [weak self] _ in self?.session?.follow() }
        let tabs = state.tabs.map { tab in
            let host = BrowserAddress(tab.url).host
            return UIAction(title: tab.title.isEmpty ? (host.isEmpty ? "New Tab" : host) : tab.title, subtitle: host,
                            state: !state.follow && tab.id == state.tab ? .on : .off) { [weak self] _ in self?.session?.showTab(tab.id) }
        }
        return UIMenu(children: [follow, UIMenu(options: .displayInline, children: tabs)])
    }

    // MARK: Actions

    private func closeTapped() { close() }

    /// [browser-update] "Update the Add-on": the viewer goes, then the update sheet comes up over the page under it.
    private func startUpdate() {
        guard let updateAddOn, !closing else { return }
        AppLog.note("browser", "viewer: update the add-on")
        close(completion: updateAddOn)
    }

    /// ✕ (and [presence] `closeCurrent`): typing ends, a held browser is handed back, the sockets close, the viewer goes.
    private func close(completion: (() -> Void)? = nil) {
        if let completion { afterClose.append(completion) }
        guard !closing else { return }             // already on its way out: `completion` runs when it has gone
        closing = true
        resignTyping()
        session?.stop()
        session = nil
        subscription?.cancel()
        subscription = nil
        ownPoll?.cancel()
        ownPoll = nil
        AppLog.note("browser", "viewer close")
        leave()
    }

    /// [presence] The one way out. The viewer is dismissed through whoever presented it, so anything presented over it
    /// (an alert, a details page) goes with it: `dismiss` on the viewer itself would take only what is on top and leave
    /// the viewer on screen with its session stopped and a ✕ that does nothing. `gone` runs when the viewer has left,
    /// before whoever waits in `afterClose`. Should the dismissal not take, the viewer is put back to work instead.
    private func leave(_ gone: (() -> Void)? = nil) {
        let host: UIViewController = navigationController ?? self
        guard let presenter = host.presentingViewController else { leaveEnded(host, gone); return }
        presenter.dismiss(animated: true) { [self] in leaveEnded(host, gone) }
    }

    private func leaveEnded(_ host: UIViewController, _ gone: (() -> Void)?) {
        let waiting = afterClose
        afterClose = []
        if host.presentingViewController != nil || viewIfLoaded?.window != nil {
            // Still on screen: ✕ and the buttons answer again, and the page comes back live.
            AppLog.note("browser", "viewer close did not take")
            closing = false
            asking = false
            updateShown()
            render()
        } else {
            if Self.current === self { Self.current = nil }
            gone?()
        }
        waiting.forEach { $0() }
    }

    /// [presence] "Ask Hermes to Install It" (spec 3x-presence §10): the request is queued in the main bot's chat, which
    /// opens once this viewer has closed (a chat pushed under a full-screen page does not start, DECISION D10). The
    /// button reads "Asking…" meanwhile; what can be known without leaving (no main bot) is said under the button.
    private func install(_ prompt: String = BrowserSetupPrompt.text) {
        guard let askToInstall, !asking, !closing else { return }
        let helper = helper
        asking = true
        emptyProblemText = nil
        render()
        do {
            try canAsk?()
        } catch {
            asking = false
            AppLog.note("browser", "install: can't ask the main bot")
            let words = (error as? LocalizedError)?.errorDescription ?? "Couldn’t send the request to the bot. Try again."
            if prompt == BrowserSetupPrompt.update { showNotice(words, warning: true); return }   // no empty screen to say it on
            emptyProblemText = words
            render()
            HQAnnounce.say(words)
            return
        }
        closing = true
        session?.stop()
        session = nil
        subscription?.cancel()
        subscription = nil
        ownPoll?.cancel()
        ownPoll = nil
        AppLog.note("browser", "viewer close: asking the main bot")
        leave {
            Task { @MainActor in
                do {
                    try await askToInstall(prompt)
                } catch {
                    // The viewer has gone, so there is no button to say it under (DECISION D11).
                    let words = (error as? LocalizedError)?.errorDescription ?? "Couldn’t send the request to the bot. Try again."
                    AppLog.note("browser", "ask the main bot failed")
                    FailureAlert.present(title: "Couldn’t Ask \(helper)", reason: words, from: MainTabController.current)
                }
            }
        }
    }

    /// "Open <Bot>'s Plugins": the bot's Plugins page on the viewer's own stack; back returns to the viewer, which
    /// looks again for the bot's browser.
    private func showPlugins() {
        guard let navigation = navigationController, !closing, let page = openPlugins?() else { return }
        page.navigationItem.largeTitleDisplayMode = .never
        navigation.pushViewController(page, animated: true)
    }

    private func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            showNotice(ControlWords.nothingToPaste, warning: true)
            return
        }
        for chunk in BrowserKeyboard.pasteChunks(text) { session?.input(.text(chunk)) }
        Haptics.play(.selection)
    }

    private func copied(_ text: String) {
        guard !text.isEmpty else {
            #if targetEnvironment(macCatalyst)
            showNotice("Nothing is selected. Double-click a word, or drag across text, then Copy.", warning: true)   // [mac]
            #else
            showNotice("Nothing is selected. Double-tap a word, or hold then drag across text, then Copy.", warning: true)
            #endif
            return
        }
        UIPasteboard.general.string = text
        Haptics.play(.success)
        showNotice("Copied", warning: false)
    }

    // MARK: Keyboard

    private var focusedField: BrowserKeyField? { keyFields.values.first { $0.isFirstResponder } }

    private var wantedSlot: (slot: BrowserKeyboardSlot, keyboard: BrowserKeyboardKind) {
        let field = session?.mine == true ? session?.view?.field : nil
        return BrowserKeyboard.slot(for: field?.focus ?? field?.under)
    }

    private func raise(_ slot: BrowserKeyboardSlot, _ keyboard: BrowserKeyboardKind) {
        guard session?.mine == true, let field = keyFields[slot] ?? keyFields[.text] else { return }
        field.use(keyboard)
        if !field.isFirstResponder { MainTrail.measure("browser.keyboard") { _ = field.becomeFirstResponder() } }   // [diagnostics]
    }

    private func toggleKeyboard() {
        if let focused = focusedField { focused.resignFirstResponder() } else { raise(wantedSlot.slot, wantedSlot.keyboard) }
    }

    private func resignTyping() { focusedField?.resignFirstResponder() }

    /// The page moved its focus to another kind of field while the keyboard is up: the keyboard follows (a password
    /// field gets the password AutoFill bar).
    private func followFieldFocus() {
        guard let focused = focusedField, session?.view?.field?.focus != nil else { return }
        let wanted = wantedSlot
        if focused.slot != wanted.slot { raise(wanted.slot, wanted.keyboard) } else { focused.use(wanted.keyboard) }
    }

    private func typingChanged() {
        let now = focusedField != nil || editingAddress
        guard now != typing else { return }
        typing = now
        barSignature = ""
        render()
        if !now { DispatchQueue.main.async { [weak self] in self?.takeKeys() } }
    }

    // MARK: Keys

    #if targetEnvironment(macCatalyst)
    /// [mac] The viewer holds the keyboard while nothing in it types, so the menu's ⌘W and Escape find it (with nothing
    /// holding the keyboard they went to the app and, the viewer being presented, did nothing or a bare dismissal).
    override var canBecomeFirstResponder: Bool { true }

    private func takeKeys() {
        guard !closing, !typing, view.window != nil, presentedViewController == nil else { return }
        becomeFirstResponder()
    }

    /// ⌘W (the menu's Close Chat) closes the viewer, as its ✕ does.
    @objc func hqCloseChat(_ sender: Any?) { close() }

    /// Escape (the menu's Stop or Close) closes it too, or first leaves the address being typed; a page field with the
    /// keyboard takes Escape itself (`BrowserKeyField.hqEscape`).
    @objc func hqEscape(_ sender: Any?) {
        if editingAddress { address.resignFirstResponder() } else { close() }
    }

    /// Not while an alert or a page is up over the viewer: the app's own Escape ladder closes that first.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == KeyCommands.closeChat || action == KeyCommands.escape { return presentedViewController == nil && !closing }
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

    /// An add-on older than 3.7 can't send the page's popups and boxes, so the person holding the browser would never
    /// see a sign-in window or a "Leave this page?" box. The first time they take control with it, say so once (per
    /// add-on version) and offer to have the main bot update it.
    private func offerPopupsUpdate() {
        let defaults = UserDefaults.standard
        guard let plugin, askToInstall != nil || (updateAddOn != nil && BrowserAddOn.need(plugin.health) != nil), presentedViewController == nil,
              let version = BrowserHealth.popupsUpdate(plugin.health, offered: defaults.string(forKey: BrowserHealth.popupsOfferKey))
        else { return }
        defaults.set(version, forKey: BrowserHealth.popupsOfferKey)
        AppLog.note("browser", "offered the popups update")
        let alert = UIAlertController(title: "Update the Browser Add-on?",
                                      message: "Sign-in windows and boxes a page pops up, like “Sign in with Google” or “Leave this page?”, can show here once the browser add\u{2011}on on \(HostWord.phrase) is updated. Until then they stay out of sight. Hermes can update it; this closes the browser and Hermes restarts for a moment.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        // [browser-update] The same update Settings runs, where it can; asking the bot otherwise.
        let sheet = updateAddOn != nil && BrowserAddOn.need(plugin.health) != nil
        let ask = sheet
            ? UIAlertAction(title: "Update", style: .default) { [weak self] _ in self?.startUpdate() }
            : UIAlertAction(title: "Ask \(helper) to Update It", style: .default) { [weak self] _ in self?.install(BrowserSetupPrompt.update) }
        alert.addAction(ask)
        alert.preferredAction = ask
        alert.view.accessibilityIdentifier = "browser.popups-update"
        present(alert, animated: true)
    }

    // MARK: Boxes the page opened

    /// An alert box or a "Sign in with…" account chooser the page opened. Chrome draws these outside the page, so the
    /// frames never show them: the person holding the browser answers them here; someone watching is told about them.
    private var shownDialog: (id: Int, alert: UIAlertController)?
    private var answeredDialog: Int?
    private var noticedDialog: Int?

    private func renderDialog(_ dialog: BrowserPageDialog?, held: Bool) {
        if let shown = shownDialog, shown.id != dialog?.id || !held {
            shownDialog = nil
            if presentedViewController === shown.alert { shown.alert.dismiss(animated: true) }
        }
        guard let dialog else {
            if noticedDialog != nil { noticedDialog = nil; hideNotice() }
            return
        }
        guard held else {
            if noticedDialog != dialog.id {
                noticedDialog = dialog.id
                let what = [.accounts, .signin].contains(dialog.kind) ? "is asking which account to sign in with" : "is showing a message"
                showNotice("\(dialog.site ?? "The page") \(what). Take control to answer it.", warning: false, keep: true)
            }
            return
        }
        if noticedDialog != nil { noticedDialog = nil; hideNotice() }
        guard shownDialog == nil, answeredDialog != dialog.id, presentedViewController == nil else { return }
        let alert = dialogAlert(dialog)
        shownDialog = (dialog.id, alert)
        AppLog.trace("browser", "page dialog shown: \(dialog.kind)")
        Haptics.play(.selection)
        present(alert, animated: true)
    }

    private func dialogAlert(_ dialog: BrowserPageDialog) -> UIAlertController {
        let says = "\(dialog.site ?? "This page") says"
        let message = dialog.message.isEmpty ? nil : dialog.message
        let alert: UIAlertController
        let answer = { [weak self] (accept: Bool, text: String?, account: Int?) in
            guard let self else { return }
            self.answeredDialog = dialog.id
            self.shownDialog = nil
            self.session?.input(.answer(id: dialog.id, accept: accept, text: text, account: account))
        }
        switch dialog.kind {
        case .alert:
            alert = UIAlertController(title: says, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in answer(true, nil, nil) })
        case .confirm:
            alert = UIAlertController(title: says, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in answer(false, nil, nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in answer(true, nil, nil) })
        case .prompt:
            alert = UIAlertController(title: says, message: message, preferredStyle: .alert)
            alert.addTextField { $0.text = dialog.defaultText }
            alert.addAction(.hqCancel { answer(false, nil, nil) })   // [mac] #17: Escape from the field answers Cancel too
            let ok = UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                answer(true, alert?.textFields?.first?.text ?? "", nil)
            }
            alert.addAction(ok)
            alert.preferredAction = ok   // Return answers OK
        case .leave:
            alert = UIAlertController(title: "Leave This Page?", message: "Changes you made may not be saved.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Stay", style: .cancel) { _ in answer(false, nil, nil) })
            alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { _ in answer(true, nil, nil) })
        case .accounts:
            alert = UIAlertController(title: dialog.title ?? "Sign In", message: message, preferredStyle: .alert)
            for (index, account) in dialog.accounts.enumerated() {
                let who = account.email.isEmpty ? account.name : account.email
                let title = dialog.accounts.count == 1 ? "Continue as \(account.name.isEmpty ? who : account.name)" : who
                alert.addAction(UIAlertAction(title: title, style: .default) { _ in answer(true, nil, index) })
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in answer(false, nil, nil) })
        case .signin:
            alert = UIAlertController(title: dialog.title ?? "Sign In", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in answer(false, nil, nil) })
            alert.addAction(UIAlertAction(title: "Continue", style: .default) { _ in answer(true, nil, nil) })
        case .signinError:
            alert = UIAlertController(title: dialog.title ?? "Couldn’t Sign In", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in answer(true, nil, nil) })
        }
        alert.view.accessibilityIdentifier = "browser.dialog"
        return alert
    }

    // MARK: Notices

    private func showNotice(_ text: String, warning: Bool, keep: Bool = false) {
        noticeTimer?.invalidate()
        guard !text.isEmpty else { hideNotice(); return }
        notice.text = text
        notice.isHidden = false
        hint.isHidden = true
        HQAnnounce.say(text)
        if warning { Haptics.play(.warning) }
        guard !keep else { return }
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideNotice() }
        }
    }

    private func hideNotice() { notice.isHidden = true; noticeTimer?.invalidate() }

    private func showHint(_ text: String) {
        guard notice.isHidden else { return }
        hint.text = text
        hint.isHidden = false
        hintTimer?.invalidate()
        hintTimer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hint.isHidden = true }
        }
    }

    // MARK: BrowserStageHost

    var stageHasControl: Bool { session?.mine ?? false }

    func stageSend(_ input: BrowserInput) { session?.input(input) }

    func stageWillTap() {
        // A tap on a text field raises the keyboard that suits it in the same touch (a password field's offers AutoFill).
        guard let under = session?.view?.field?.under else { return }
        let wanted = BrowserKeyboard.slot(for: under)
        raise(wanted.slot, wanted.keyboard)
    }

    func stageZoomed() { sendViewSize() }

    func stageWatchTap() {
        // [mac] A pinch brings no touches on the Mac, so there is no zoom to offer.
        showHint("\(DeviceWord.Tap) Take Control to click, scroll and type on this page." + (DeviceWord.isMac ? "" : " Pinch to zoom."))
    }

    private var lastMine = false

    // MARK: UITextFieldDelegate (the address)

    /// Only while in control. Watching, a tap says how to get control, as a tap on the page does (it did nothing).
    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        guard let session else { return false }
        if session.mine { return true }
        if !session.someoneElse && !session.waiting { stageWatchTap() }
        return false
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        editingAddress = true
        textField.textAlignment = .natural
        textField.text = session?.view?.currentTab?.url ?? ""
        textField.selectAll(nil)
        typingChanged()
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        editingAddress = false
        textField.textAlignment = .center
        typingChanged()
        render()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let url = BrowserAddress.url(from: textField.text ?? "") { session?.input(.go(url)) }
        textField.resignFirstResponder()
        return false
    }
}

/// A notice capsule on native glass (one line of words over the page).
final class BrowserPill: UIVisualEffectView {
    private let label = UILabel()
    var text: String? {
        get { label.text }
        set { label.text = newValue; accessibilityLabel = newValue }
    }

    init() {
        super.init(effect: UIGlassEffect(style: .regular))
        cornerConfiguration = .capsule()
        label.font = HQFont.preferred(.footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// The request the main bot gets to install the browser plugin (the web app's setup.ts, word for word but the name).
enum BrowserSetupPrompt {
    static let source = "mrcharlesiv/hermes-hq-plugins/hermes-hq-browser"
    static let text = """
    Please install Hermes HQ's browser plugin on this Hermes, so I can watch a bot's browser from my iPhone and take it over when it needs me. Do it yourself with your terminal tools; ask me only for what you can't do.

    1. This plugin used to be called dispatch-browser. If hermes plugins list shows dispatch-browser for the main profile, remove it first so two copies never both run: note which platform_toolsets lists in the main config.yaml include browser, run hermes plugins remove dispatch-browser, and if that took browser out of any of those lists, put it back. Leave its copies in other profiles alone: the new plugin switches them off itself and keeps each bot's browser.

    2. Install it once, for the main profile: run hermes plugins install \(source) --enable. Once the server restarts, the plugin adds itself to every other bot profile (and to bots made later) and gives each bot a Chrome of its own, so don't install it per profile. If it says hermes-hq-browser is already installed, run the same command again with --force added, to replace the older copy. If Hermes's security scan blocks the install, stop and show me what it found. Don't work around the scan.

    3. An older test version of this plugin replaced the bots' browser tools with a Chrome extension. If any config.yaml on this computer (the main one and each profile's) has plugins.entries.dispatch-browser.granted_capabilities, remove that entry, and if its browser.backend is 'off', ask me what it was before changing it. Leave everything else in those files alone.

    4. Check it: hermes plugins list --enabled must list hermes-hq-browser, version 3.4 or newer, and not dispatch-browser. Each bot's browser is a headless Google Chrome (or Chromium): if neither is installed on this computer, tell me.

    5. Hermes loads a plugin's web routes only when its web server starts, and its hooks when a gateway starts, so restart the server Hermes HQ connects to (hermes dashboard or hermes serve) and the messaging gateway if one runs. Find how each runs first (whether a launchd, systemd or other service manages it), then restart it the same way, keeping its arguments and profile. Restarting ends this chat's connection for a moment, so tell me before you do it, and schedule the restart in the background to start about 15 seconds after your reply, so it survives this chat (for example nohup sh -c 'sleep 15; <restart command>' >/dev/null 2>&1 &). It must run exactly once: never schedule it with launchctl submit, a LaunchAgent, cron, a systemd timer or anything else that starts it again, because a restart that repeats keeps Hermes down and locks me out. Don't restart anything else.

    When you're done, tell me in a sentence or two what you did.
    """

    /// The request to update an add-on too old for this build: popups and boxes came in 3.7.0, and [browser-update]
    /// 3.8.0 is the one that stays on after Hermes updates (`BrowserAddOn.wantedVersion`).
    static let update = """
    Please update Hermes HQ's browser plugin (hermes-hq-browser) on this Hermes to version \(BrowserAddOn.wantedVersion) or newer, so popups, sign-in windows and boxes a page shows reach my iPhone when I take over a bot's browser. Do it yourself with your terminal tools; ask me only for what you can't do.

    1. Update it for the main profile only: run hermes plugins update hermes-hq-browser. If that can't update it, run hermes plugins install \(source) --enable --force instead. Once the server restarts, the plugin copies itself to every other bot profile, so don't update it per profile. If Hermes's security scan blocks it, stop and show me what it found. Don't work around the scan.

    2. Check it: hermes plugins list --enabled must list hermes-hq-browser, version \(BrowserAddOn.wantedVersion) or newer.

    3. Hermes loads a plugin's web routes only when its web server starts, so restart the server Hermes HQ connects to (hermes dashboard or hermes serve). Find how it runs first (whether a launchd, systemd or other service manages it), then restart it the same way, keeping its arguments and profile. Restarting ends this chat's connection for a moment, so tell me before you do it, and schedule the restart in the background to start about 15 seconds after your reply, so it survives this chat (for example nohup sh -c 'sleep 15; <restart command>' >/dev/null 2>&1 &). It must run exactly once: never schedule it with launchctl submit, a LaunchAgent, cron, a systemd timer or anything else that starts it again, because a restart that repeats keeps Hermes down and locks me out. Don't restart anything else.

    When you're done, tell me in a sentence or two what you did.
    """
}
