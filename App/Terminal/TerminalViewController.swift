// [terminal] The Terminal page (docs/spec/terminal.md): a shell on the Hermes computer, typed into from here. Opening it
// the first time for a computer asks whether to turn it on (Not Now leaves it off), then Face ID or the passcode each
// time, then the add-on is asked whether it has the Terminal (hermes-hq-push 0.9.25+) before the socket dials.
// What the shell prints shows in SwiftTerm's view; typed keys, the key bar and pastes go back.
// Copy: long-press (Select, Select All, Copy), ⌘C on the Mac, ⋯ › Copy All, or ⋯ › Select Text for a page of plain text.
// A program can copy too (OSC 52, as tmux and vim do). Paste: a hold of the screen, ⋯ › Paste, ⌘V or a text drop.
// Several lines ask first unless the shell takes bracketed paste, since each line would run as it arrives.
// Leaving the page keeps the shell 15 minutes on the computer; ⋯ › End Shell ends it, New Shell starts another.
// Audit 09-1/09-2: turning Require Face ID off asks for Face ID; the page hides while the app isn't in front, and with
// the lock on, Face ID is asked again once the app has been away.
// Tabs (a tester, Discord 2026-11-04: "adding multiple shells would be neat"): + (⌘T) opens another shell beside the
// first, up to 8; a strip of tabs shows once there are two. Each tab has its own screen, socket and shell; closing one
// ends its shell. The page's question, Face ID and add-on check are asked once for all of them.
// a tester 2026-11-05: the terminal shows full screen; the keyboard comes up only from the ⌨ button (not by itself, nor
// with a tap on the screen), and the screen takes its new height at once rather than squeezing along with the keyboard.

import SwiftTerm
import UIKit

final class TerminalViewController: UIViewController, TerminalViewDelegate {
    enum State: Equatable {
        /// The first-time question or Face ID is up.
        case asking
        /// [mac] Audit 2026-11-02 #6: the first-time question as the page's own card (Turn On, Not Now), not an alert.
        case consent
        /// Not Now to the first-time question.
        case off
        /// Face ID failed or was cancelled (with why, when it can't be asked at all).
        case locked(String?)
        /// Asking the add-on whether it has the Terminal.
        case checking
        /// The add-on is missing or older than 0.9.25.
        case needsAddOn
        case connection(TerminalConnection.Phase)
    }

    private let account: GatewayAccount
    private let client: any GatewayClient
    private let sockets: any GatewayTerminalSockets
    /// Shown over Bot Info (a ✕ closes it), not pushed on a stack.
    private let presented: Bool
    /// One per shell, in order; `current` is the one in front.
    private var tabs: [TerminalTab]
    private var current: Int
    private let panel = UIView()
    /// The tabs, over the screens, once there are two.
    private let strip = TerminalTabStrip()
    private var stripHeight: NSLayoutConstraint?
    private let notice = UIContentUnavailableView(configuration: .empty())
    private let banner = UILabel()
    private var bannerBacking: UIVisualEffectView?
    private var started = false
    private var updateAsked = false
    private var leftAt: ContinuousClock.Instant?
    private var observers: [NSObjectProtocol] = []
    /// [mac] The pane width the card's margins were set for.
    private var noticeWidth: CGFloat = 0
    /// The keyboard was asked for (the ⌨ button) and hasn't been put away since.
    private var keyboardOpen = false
    /// ⌨ at the screen's bottom corner while the keyboard is away.
    private let keyboardButton = UIButton(type: .system)
    /// Where the screens stop: the keyboard's top, else the safe area's bottom.
    private let textBottom = UILayoutGuide()
    private var keyboardOverlap: NSLayoutConstraint?
    /// Another tab is coming in front, or one is going: its screen giving up the keyboard isn't the keyboard put away.
    private var switching = false
    /// Audit 09-2: over everything on the panel while the app isn't in front (the app switcher's picture), as the
    /// Screen's picture hides, and once the app has been away with the lock on, until Face ID again.
    private let cover = UIContentUnavailableView(configuration: .empty())
    /// The app isn't in front (Control Centre, the app switcher, Face ID's own sheet).
    private var covered = false
    /// The app went away with the lock on: the shells stay hidden, and take no keys, until Face ID again.
    private var relocked = false
    /// Why Face ID can't be asked for again, when it can't.
    private var relockWhy: String?
    /// Face ID is asked for on the next return to the page (the app went away; not after a cancelled Face ID).
    private var askOnReturn = false
    private var unlocking = false

    private(set) var state: State = .asking {
        didSet { if state != oldValue { render() } }
    }

    static let background = UIColor(red: 0.075, green: 0.078, blue: 0.09, alpha: 1)
    static let foreground = UIColor(white: 0.9, alpha: 1)

    init(account: GatewayAccount, client: any GatewayClient, sockets: any GatewayTerminalSockets, presented: Bool = false) {
        self.account = account
        self.client = client
        self.sockets = sockets
        self.presented = presented
        let names = TerminalSettings.tabNames(account.id)
        tabs = TerminalSettings.sessions(account.id).enumerated().map { index, session in
            TerminalTab(session: session, customName: names.indices.contains(index) ? names[index] : "")
        }
        current = min(max(TerminalSettings.selectedTab(account.id), 0), tabs.count - 1)
        super.init(nibName: nil, bundle: nil)
        title = "Terminal"
        navigationItem.largeTitleDisplayMode = .never
        hidesBottomBarWhenPushed = false
    }

    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        tabs.forEach { $0.connection?.stop() }
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Views

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.page
        view.accessibilityIdentifier = "terminal.page"

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.backgroundColor = Self.background
        panel.overrideUserInterfaceStyle = .dark
        view.addSubview(panel)

        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.onSelect = { [weak self] index in self?.select(index) }
        strip.onClose = { [weak self] index in self?.closeTab(at: index) }
        strip.onRename = { [weak self] index in self?.renameTab(at: index) }
        strip.onMove = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        panel.addSubview(strip)

        // Where the text stops (the screens, the card, ⌨): the keyboard's top, else the safe area's bottom.
        view.addLayoutGuide(textBottom)
        let overlap = textBottom.topAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
        keyboardOverlap = overlap
        let down = textBottom.topAnchor.constraint(equalTo: view.bottomAnchor)
        // [mac-ui-issues] Owner 2026-11-09: at the low priority this tied with the card's wish to be only as tall as
        // its words, so "Open a Terminal?" hugged the top of an empty page. On the Mac the text's end holds the bottom
        // (the keyboard's limits above are required and still win) and the card sits in the middle.
        down.priority = DeviceWord.isMac ? .defaultHigh : .defaultLow
        NSLayoutConstraint.activate([
            textBottom.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textBottom.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textBottom.heightAnchor.constraint(equalToConstant: 0),
            textBottom.topAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor),
            overlap,
            down,
        ])
        #if !targetEnvironment(macCatalyst)
        setUpKeyboardButton()
        #endif
        notice.translatesAutoresizingMaskIntoConstraints = false
        notice.accessibilityIdentifier = "terminal.notice"
        tabs.forEach(install)

        let pill = UIVisualEffectView(effect: Theme.isDesktop ? UIBlurEffect(style: .systemThinMaterialDark) : UIGlassEffect(style: .regular))
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.layer.cornerCurve = .continuous
        pill.clipsToBounds = true
        pill.isHidden = true
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.font = .preferredFont(forTextStyle: .footnote)
        banner.adjustsFontForContentSizeCategory = true
        banner.textColor = .white
        banner.accessibilityIdentifier = "terminal.banner"
        pill.contentView.addSubview(banner)
        panel.addSubview(pill)
        bannerBacking = pill
        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.accessibilityIdentifier = "terminal.cover"
        cover.accessibilityViewIsModal = true
        cover.isHidden = true
        panel.addSubview(cover)
        NSLayoutConstraint.activate([
            cover.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            cover.topAnchor.constraint(equalTo: panel.topAnchor),
            cover.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])

        // The panel runs under the home indicator (and a tab bar); the text stops at the keyboard, or the safe area.
        let stripHeight = strip.heightAnchor.constraint(equalToConstant: 0)
        self.stripHeight = stripHeight
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            strip.topAnchor.constraint(equalTo: panel.topAnchor),
            stripHeight,
            pill.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: 10),
            pill.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            banner.leadingAnchor.constraint(equalTo: pill.contentView.leadingAnchor, constant: 14),
            banner.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor, constant: -14),
            banner.topAnchor.constraint(equalTo: pill.contentView.topAnchor, constant: 7),
            banner.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor, constant: -7),
        ])

        installMenu()
        if presented {
            let close = UIBarButtonItem.hqClose(action: UIAction { [weak self] _ in self?.close() })
            close.accessibilityIdentifier = "terminal.close"
            navigationItem.hqPlaceClose(close)
        }
        let center = NotificationCenter.default
        // a tester 2026-11-05: the "shrink" each time the keyboard came. The screens followed keyboardLayoutGuide, which
        // animates their height along with the keyboard's slide, and SwiftTerm's text stretched as it went. They now
        // stop at `textBottom`, moved at once when the keyboard is about to come or go.
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            MainActor.assumeIsolated { self?.keyboardMoved(to: end) }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardMoved(to: nil) }
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.leftAt = .now
                self?.appInactive()
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentAway() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cameToFront()
                guard let away = self.leftAt else { return }
                self.leftAt = nil
                self.tabs.forEach { $0.connection?.cameBack(after: .now - away) }
            }
        })
        showTabs()
        render()
    }

    /// The card over the screens (under the Reconnecting… pill), put back when there is something to say.
    private func attachNotice() {
        guard notice.superview == nil else { return }
        if let pill = bannerBacking { panel.insertSubview(notice, belowSubview: pill) } else { panel.addSubview(notice) }
        NSLayoutConstraint.activate([
            notice.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            notice.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            notice.topAnchor.constraint(equalTo: strip.bottomAnchor),
            notice.bottomAnchor.constraint(equalTo: textBottom.topAnchor),
        ])
    }

    /// A tab's screen in the panel, under the strip, hidden unless it is in front.
    private func install(_ tab: TerminalTab) {
        let screen = tab.view
        screen.translatesAutoresizingMaskIntoConstraints = false
        screen.terminalDelegate = self
        screen.style()
        screen.onPaste = { [weak self] text in self?.paste(text) }
        screen.onResign = { [weak self, weak screen] in
            guard let self, let screen else { return }
            screenResigned(screen)
        }
        #if targetEnvironment(macCatalyst)
        // [mac] A real keyboard has Esc, Control, Tab and the arrows: no key bar (nor SwiftTerm's own).
        screen.inputAccessoryView = nil
        // [mac] Mac polish 2026-11-06 #120: no focus ring. The system drew its blue ring inside the screen's edge, over
        // the first letter of every line; the caret already shows where typing goes (solid while it does), as Terminal's.
        screen.focusEffect = nil
        #else
        screen.keyBar = TerminalKeyBar(terminal: screen)
        screen.showsKeyboard = keyboardOpen
        screen.applyKeyboard()
        // Owner 2026-11-04 (layout A): no Hide Keyboard key. Drag the screen down into the keyboard, as in Messages
        // (the bounce lets a screen with no scrollback yet take the drag).
        screen.alwaysBounceVertical = true
        #endif
        panel.insertSubview(screen, at: 0)
        NSLayoutConstraint.activate([
            screen.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 6),
            screen.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -6),
            screen.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: 4),
            screen.bottomAnchor.constraint(equalTo: textBottom.topAnchor, constant: -4),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let pill = bannerBacking { pill.layer.cornerRadius = pill.bounds.height / 2 }
        #if targetEnvironment(macCatalyst)
        if !notice.isHidden, panel.bounds.width != noticeWidth { render() }   // [mac] #6: the card's margins follow the pane
        #endif
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !started {
            started = true
            Task { await open() }
        } else if relocked {
            if askOnReturn, presentedViewController == nil {
                askOnReturn = false
                Task { await unlockAgain() }
            }
        } else if case .connection(.live) = state, presentedViewController == nil {
            _ = terminal.becomeFirstResponder()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Popped or closed: the sockets close, the shells stay on the computer for 15 minutes.
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true { hangUp() }
    }

    private func close() {
        hangUp()
        dismiss(animated: true)
    }

    private func hangUp() {
        for tab in tabs {
            tab.connection?.stop()
            tab.connection = nil
        }
    }

    // MARK: Opening

    /// The first-time question, Face ID, the add-on, then the socket.
    private func open() async {
        state = .asking
        if !TerminalSettings.allowed(account.id) {
            #if targetEnvironment(macCatalyst)
            // [mac] Audit 2026-11-02 #6: on the Mac the iPhone's alert stood over an empty page with a bare cursor in its
            // corner, its Turn On a grey pill. The page asks itself: the card's accent Turn On (Return), Not Now (Esc).
            state = .consent
            return
            #else
            guard await askToTurnOn() else { state = .off; return }
            TerminalSettings.setAllowed(true, account: account.id)
            #endif
        }
        switch await TerminalUnlock.unlock() {
        case .unlocked: break
        case .refused: state = .locked(nil); return
        case .unavailable: state = .locked(Self.cantCheck); return
        }
        await checkAndConnect()
    }

    /// Why Face ID can't be asked for at all.
    private static var cantCheck: String {
        #if targetEnvironment(macCatalyst)
        "This Mac can’t check \(TerminalUnlock.means) right now. You can turn off Require \(TerminalUnlock.name) in the ⋯ menu."
        #else
        "This device can’t check Face ID or its passcode right now. You can turn off Require Face ID in the ⋯ menu."
        #endif
    }

    // MARK: Away (audit 09-2)

    /// Past Face ID: what the page shows, or is about to, comes from the shell.
    private var pastUnlock: Bool {
        switch state {
        case .checking, .needsAddOn, .connection: true
        case .asking, .consent, .off, .locked: false
        }
    }

    /// Control Centre, the app switcher, a call or Face ID's sheet: the shells hide, so the app switcher never shows
    /// them. [mac] No app switcher picture; a Mac app leaves the front each time another window is clicked.
    private func appInactive() {
        #if !targetEnvironment(macCatalyst)
        covered = true
        renderCover()
        #endif
    }

    /// Home, another app or the lock button with the lock on: Face ID again before the shells show (as when the page
    /// opens). The shells stay connected underneath. Select Text's sheet goes, since it holds the screen's text.
    /// [mac] Owner 2026-11-09 ("Yes", to the Mac's Terminal locking again as the iPhone's does): the Mac's app goes away
    /// when it is hidden (⌘H) or its windows are minimised, not each time another app is clicked (`appInactive`); it
    /// asks for Touch ID or the Mac's password when it comes back (`covered` lets `cameToFront` ask).
    private func wentAway() {
        guard TerminalUnlock.isRequired, pastUnlock else { return }
        if !relocked { AppLog.note("terminal", "locked again (the app went away)") }
        relocked = true
        relockWhy = nil
        askOnReturn = true
        #if targetEnvironment(macCatalyst)
        covered = true
        #endif
        if let sheet = presentedViewController as? UINavigationController, sheet.viewControllers.first is TerminalTextController {
            sheet.dismiss(animated: false)
        }
        renderCover()
    }

    private func cameToFront() {
        guard covered else { return }
        covered = false
        renderCover()
        guard relocked, askOnReturn, view.window != nil, presentedViewController == nil else { return }
        askOnReturn = false
        Task { await unlockAgain() }
    }

    private func unlockAgain() async {
        guard relocked, !unlocking else { return }
        unlocking = true
        let answer = await TerminalUnlock.unlock()
        unlocking = false
        switch answer {
        case .unlocked: unlocked()
        case .refused: relockWhy = nil
        case .unavailable: relockWhy = Self.cantCheck
        }
        renderCover()
    }

    /// Face ID passed (or the lock was turned off with it): the shells show again where they were.
    private func unlocked() {
        guard relocked else { return }
        relocked = false
        relockWhy = nil
        askOnReturn = false
        renderCover()
        showTabs()
        render()
        focus()
    }

    private func renderCover() {
        guard isViewLoaded else { return }
        if relocked {
            cover.configuration = card("lock.fill", "Terminal Locked", relockWhy ?? "Unlock with \(TerminalUnlock.means) to see the shell again.",
                                       button: "Unlock") { [weak self] in Task { await self?.unlockAgain() } }
            if terminal.isFirstResponder { _ = terminal.resignFirstResponder() }
            navigationItem.subtitle = nil
        } else {
            var config = UIContentUnavailableConfiguration.empty()
            config.background.backgroundColor = Self.background
            cover.configuration = config
        }
        cover.isHidden = !(covered || relocked)
        updateKeyboardButton()
        installMenu()
    }

    private func askToTurnOn() async -> Bool {
        await withCheckedContinuation { continuation in
            let answer = AlertAnswer(continuation, unanswered: false)
            let alert = UIAlertController(
                title: "Open a Terminal on \(computerName)?",
                message: "What you type runs on that computer with the same access Hermes has there, including its files. "
                    + "Turn this on only for a computer you trust. Face ID is asked each time the Terminal opens.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { _ in answer.answer(false) })
            let on = UIAlertAction(title: "Turn On", style: .default) { _ in answer.answer(true) }
            alert.addAction(on)
            alert.preferredAction = on
            guard let host = FailureAlert.topmost(self) else { return answer.answer(false) }
            host.present(alert, animated: true)
        }
    }

    /// [mac] The consent card's answers (its buttons, Return and Esc).
    @objc private func turnOn() {
        guard state == .consent else { return }
        TerminalSettings.setAllowed(true, account: account.id)
        Task { await open() }
    }

    @objc private func notNow() {
        guard state == .consent else { return }
        state = .off
    }

    private var computerName: String { account.label.isEmpty ? "This Computer" : account.label }

    enum AddOn: Equatable { case ready, needsUpdate, unsupported, off, unknown }

    /// The add-on's status: its `terminal` and `terminalOff` keys (0.9.25+).
    static func addOn(status: Int, body: [String: Any]?) -> AddOn {
        switch status {
        case 200:
            guard PushPolicy.terminalKnown(body) else { return .needsUpdate }
            if !PushPolicy.terminal(body) { return .unsupported }
            return PushPolicy.terminalOff(body) ? .off : .ready
        case 404: return .needsUpdate
        default: return .unknown
        }
    }

    private func checkAndConnect() async {
        state = .checking
        let answer: (Int, [String: Any]?)
        do {
            let data = try await client.rest("GET", PushPolicy.route + "/status", query: [], body: nil)
            answer = (200, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        } catch let error as HTTPError {
            answer = (error.status, nil)
        } catch {
            answer = (0, nil)
        }
        let addOn = Self.addOn(status: answer.0, body: answer.1)
        AppLog.trace("terminal", "add-on says \(addOn) (status \(answer.0))")
        switch addOn {
        case .needsUpdate: state = .needsAddOn
        case .unsupported: state = .connection(.stopped(.unsupported))
        case .off: state = .connection(.stopped(.off))
        case .ready, .unknown: tabs.forEach(connect)   // can't tell: the socket says itself
        }
    }

    private func connect(_ tab: TerminalTab) {
        tab.connection?.stop()
        tab.endedHere = false
        let sockets = self.sockets
        let connection = TerminalConnection(session: tab.session) { query in try await sockets.terminalSocket(query: query) }
        connection.onOutput = { [weak tab] data in tab?.view.feed(byteArray: ArraySlice([UInt8](data))) }
        connection.onReset = { [weak tab] in tab?.clearScreen() }
        connection.onPhase = { [weak self, weak tab] phase in
            guard let self, let tab else { return }
            phaseChanged(phase, in: tab)
        }
        tab.connection = connection
        tab.phase = .connecting
        if tab === self.frontTab { state = .connection(.connecting) }
        let size = tab.view.terminalDimensions
        connection.start(cols: size.cols, rows: size.rows)
    }

    private func phaseChanged(_ phase: TerminalConnection.Phase, in tab: TerminalTab) {
        AppLog.trace("terminal", "phase \(phase) (tab \((tabs.firstIndex { $0 === tab } ?? -1) + 1) of \(tabs.count))")
        if case .ended = phase {
            // The next open starts a fresh shell rather than dialling one that's gone.
            tab.session = TerminalWire.newSession()
            saveTabs()
            if tab.closing { return remove(tab) }
            if tab.newAfterEnd {
                tab.newAfterEnd = false
                tab.clearScreen()
                connect(tab)
                return
            }
        }
        tab.phase = phase
        strip.update(titles: tabTitles, current: current)
        guard tab === self.frontTab else { return }
        state = .connection(phase)
        if phase == .live, !relocked, view.window != nil, presentedViewController == nil, !terminal.isFirstResponder {
            _ = terminal.becomeFirstResponder()
        }
    }

    // MARK: Tabs

    /// The tab in front, its screen and its link.
    private var frontTab: TerminalTab { tabs[current] }
    private var terminal: HQTerminalView { frontTab.view }

    /// What each tab is called: the name it was given, else its number, then the title its program set or its shell
    /// ("1 zsh", "2 vim"), so two tabs of the same shell still read apart.
    private var tabTitles: [String] {
        tabs.enumerated().map { index, tab in
            if !tab.customName.isEmpty { return tab.customName }
            return tab.name.map { "\(index + 1) \($0)" } ?? "Shell \(index + 1)"
        }
    }

    private func saveTabs() {
        TerminalSettings.setSessions(tabs.map(\.session), account: account.id)
        TerminalSettings.setTabNames(tabs.map(\.customName), account: account.id)
        TerminalSettings.setSelectedTab(current, account: account.id)
    }

    /// The strip (once there are two tabs), the screen in front, and its title under the page's.
    private func showTabs() {
        guard isViewLoaded else { return }
        let several = tabs.count > 1
        strip.isHidden = !several
        stripHeight?.constant = several ? TerminalTabStrip.height : 0
        strip.update(titles: tabTitles, current: current)
        for (index, tab) in tabs.enumerated() {
            tab.view.isHidden = index != current
            tab.view.accessibilityIdentifier = index == current ? "terminal.screen" : "terminal.screen.\(index + 1)"
        }
        navigationItem.subtitle = relocked || frontTab.title.isEmpty ? nil : frontTab.title
    }

    /// Whether the shells are open (past the question, Face ID and the add-on check), so a new tab dials at once.
    private var shellsOpen: Bool {
        if case .connection = state { return !relocked }
        return false
    }

    private func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        if index != current {
            if terminal.isFirstResponder {
                switching = true
                _ = terminal.resignFirstResponder()
                switching = false
            }
            current = index
            saveTabs()
            Haptics.play(.selection)
        }
        showTabs()
        if shellsOpen { state = .connection(frontTab.phase ?? .connecting) }
        render()
        if isLive, view.window != nil, presentedViewController == nil { _ = terminal.becomeFirstResponder() }
    }

    private func newTab() {
        guard tabs.count < TerminalSettings.maxTabs else { return }
        let tab = TerminalTab(session: TerminalWire.newSession())
        tabs.append(tab)
        install(tab)
        AppLog.note("terminal", "new tab (\(tabs.count) open)")
        if shellsOpen { connect(tab) }
        select(tabs.count - 1)
        HQAnnounce.say("Shell \(tabs.count)")
    }

    /// Closing a tab ends its shell (asked first while it runs). The last tab isn't closed: End Shell is.
    private func closeTab(at index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        guard tab.phase == .live else { return remove(tab) }
        let alert = UIAlertController(title: "Close This Tab?", message: "Its shell ends, with anything still running in it.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.focus() })
        alert.addAction(UIAlertAction(title: "Close Tab", style: .destructive) { [weak self, weak tab] _ in
            guard let self, let tab else { return }
            tab.closing = true
            tab.connection?.endShell()
            // The shell's exit closes it; a link that drops first doesn't leave the tab hanging.
            Task { [weak self, weak tab] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, let tab, tabs.contains(where: { $0 === tab }) else { return }
                remove(tab)
            }
        })
        present(alert, animated: true)
    }

    private func remove(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.connection?.stop()
        tab.connection = nil
        if tab.view.isFirstResponder {
            switching = true
            _ = tab.view.resignFirstResponder()
            switching = false
        }
        tab.view.removeFromSuperview()
        tabs.remove(at: index)
        if index < current || current >= tabs.count { current = max(current - 1, 0) }
        saveTabs()
        AppLog.note("terminal", "closed a tab (\(tabs.count) open)")
        select(current)
    }

    private func cycle(_ step: Int) {
        guard tabs.count > 1 else { return }
        select((current + step + tabs.count) % tabs.count)
    }

    /// Hold a tab › Rename… (a tester 2026-11-05). Left empty, it goes back to being named by what runs in it.
    private func renameTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        let alert = UIAlertController(title: "Rename Tab", message: "Leave it empty to name it after what runs in it.", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = tab.customName
            field.placeholder = tab.name ?? "Shell \(index + 1)"
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.returnKeyType = .done
            field.accessibilityIdentifier = "terminal.tab.name"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.focus() })
        let rename = UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert, weak tab] _ in
            guard let self, let tab else { return }
            let text = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            tab.customName = String(text.prefix(40))
            saveTabs()
            strip.update(titles: tabTitles, current: current)
            AppLog.note("terminal", tab.customName.isEmpty ? "tab name cleared" : "tab renamed")
            focus()
        }
        alert.addAction(rename)
        alert.preferredAction = rename
        present(alert, animated: true)
    }

    /// Hold a tab › Move Left / Move Right (a tester 2026-11-05). `to` is its place among the others once moved; the tab
    /// in front stays in front.
    private func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        let front = frontTab
        tabs.insert(tabs.remove(at: from), at: to)
        current = tabs.firstIndex { $0 === front } ?? current
        saveTabs()
        showTabs()
        Haptics.play(.selection)
        HQAnnounce.say("Moved to position \(to + 1) of \(tabs.count)")
        AppLog.note("terminal", "moved tab \(from + 1) to \(to + 1)")
    }

    // MARK: The keyboard

    /// ⌨, bottom right over the screen, while the keyboard is away (a tester 2026-11-05: "open keyboard only on demand
    /// from a button"). Glass in the iOS look, a grey key in the Desktop Look.
    private func setUpKeyboardButton() {
        var config: UIButton.Configuration
        if Theme.isDesktop {
            config = .filled()
            config.baseBackgroundColor = UIColor(white: 0.22, alpha: 0.94)
            config.background.strokeColor = UIColor(white: 1, alpha: 0.14)
            config.background.strokeWidth = 1
            config.cornerStyle = .fixed
            config.background.cornerRadius = DesktopRows.radius
        } else {
            config = .glass()
            config.cornerStyle = .capsule
        }
        config.image = UIImage(systemName: "keyboard", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        keyboardButton.configuration = config
        keyboardButton.translatesAutoresizingMaskIntoConstraints = false
        keyboardButton.accessibilityLabel = "Show Keyboard"
        keyboardButton.accessibilityIdentifier = "terminal.keyboard"
        keyboardButton.isHidden = true
        keyboardButton.addAction(UIAction { [weak self] _ in self?.showKeyboard() }, for: .primaryActionTriggered)
        panel.addSubview(keyboardButton)
        NSLayoutConstraint.activate([
            keyboardButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            keyboardButton.bottomAnchor.constraint(equalTo: textBottom.topAnchor, constant: -12),
            keyboardButton.widthAnchor.constraint(equalToConstant: 48),
            keyboardButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func showKeyboard() {
        guard isLive else { return }
        Haptics.play(.selection)
        AppLog.trace("terminal", "keyboard asked for")
        setKeyboard(open: true)
        if !terminal.isFirstResponder { _ = terminal.becomeFirstResponder() }
    }

    private func setKeyboard(open: Bool) {
        keyboardOpen = open
        tabs.forEach { $0.view.showsKeyboard = open }
        updateKeyboardButton()
    }

    private func updateKeyboardButton() {
        #if !targetEnvironment(macCatalyst)
        keyboardButton.isHidden = keyboardOpen || !isLive || !notice.isHidden
        #endif
    }

    /// The screen in front gave up the keyboard on its own (dragged down, the key bar's Hide Keyboard, a card over it):
    /// the keyboard stays away until ⌨. A sheet or question over the page, or another tab coming in front, isn't that.
    private func screenResigned(_ screen: HQTerminalView) {
        guard keyboardOpen, !switching, screen === terminal, presentedViewController == nil else { return }
        setKeyboard(open: false)
    }

    /// The keyboard (or its key bar alone, over a hardware keyboard) is about to stand at `end`, in the screen's
    /// coordinates; nil, it's going. The screens take their height at once. A floating or split iPad keyboard leaves
    /// them as they are, as keyboardLayoutGuide does.
    private func keyboardMoved(to end: CGRect?) {
        guard isViewLoaded else { return }
        var overlap: CGFloat = 0
        if let end, let space = view.window?.windowScene?.screen.coordinateSpace {
            let frame = view.convert(end, from: space)
            let bounds = view.bounds
            if frame.maxY >= bounds.maxY - 1, frame.minX <= bounds.minX + 1, frame.maxX >= bounds.maxX - 1 {
                overlap = max(0, bounds.maxY - frame.minY)
            }
        }
        guard let keyboardOverlap, keyboardOverlap.constant != -overlap else { return }
        UIView.performWithoutAnimation {
            keyboardOverlap.constant = -overlap
            view.layoutIfNeeded()
        }
    }

    // MARK: What shows over the panel

    private func render() {
        guard isViewLoaded else { return }
        var config: UIContentUnavailableConfiguration?
        var bannerText: String?
        switch state {
        case .asking:
            #if targetEnvironment(macCatalyst)
            // [mac] Audit 2026-11-02 #6: never the bare page (SwiftTerm's cursor alone in the corner) while the Mac asks
            // for Touch ID or its password.
            config = TerminalSettings.requiresUnlock
                ? card("lock.fill", "Unlock the Terminal", "Use \(TerminalUnlock.means) to open a shell on \(computerName).")
                : loading("Connecting…")
            #else
            config = .empty()
            #endif
        case .consent:
            let unlock = TerminalSettings.requiresUnlock ? " \(TerminalUnlock.means.prefix(1).uppercased() + TerminalUnlock.means.dropFirst()) is asked each time the Terminal opens." : ""
            config = card("terminal", "Open a Terminal on \(computerName)?",
                          "What you type runs on that computer with the same access Hermes has there, including its files. "
                            + "Turn this on only for a computer you trust." + unlock,
                          button: "Turn On", secondary: ("Not Now", { [weak self] in self?.notNow() })) { [weak self] in self?.turnOn() }
        case .off:
            config = card("terminal", "Terminal Is Off",
                          "Turn it on to type commands on \(computerName). They run with the same access Hermes has there.",
                          button: "Turn On") { [weak self] in Task { await self?.open() } }
        case .locked(let why):
            config = card("lock.fill", "Terminal Locked", why ?? "Unlock with \(TerminalUnlock.means) to open the shell.",
                          button: "Unlock") { [weak self] in Task { await self?.open() } }
        case .checking:
            config = loading("Connecting…")
        case .needsAddOn:
            config = card("arrow.down.circle", "Update the Add-on",
                          updateAsked
                            ? "Once the Hermes HQ add-on on \(computerName) is updated and Hermes has restarted, try again."
                            : "The Terminal needs version 0.9.25 or later of the Hermes HQ add-on on \(computerName).",
                          button: updateAsked ? "Try Again" : "Update Add-on") { [weak self] in self?.updateAddOn() }
        case .connection(let phase):
            let tab = self.frontTab
            switch phase {
            case .connecting:
                config = loading("Opening a shell…")
            case .live:
                break
            case .reconnecting:
                bannerText = "Reconnecting…"
            case .ended(let code):
                let why = tab.endedHere ? "You ended this shell." : code.map { "It exited with code \($0)." } ?? "The shell has closed."
                config = card("checkmark.circle", "Shell Ended", why,
                              button: "New Shell", dim: true) { [weak self] in self?.newShell(confirm: false) }
            case .stopped(let ending):
                config = stopped(ending, in: tab)
            }
        }
        if var config {
            #if targetEnvironment(macCatalyst)
            // [mac] Audit 2026-11-02 #6: a card's words across the whole right pane ran one line 1000 pt wide; they wrap
            // at about a dialog's width, as the consent card's paragraph has to be read.
            let side = max(20, (panel.bounds.width - 520) / 2)
            config.directionalLayoutMargins.leading = side
            config.directionalLayoutMargins.trailing = side
            noticeWidth = panel.bounds.width
            #endif
            attachNotice()
            notice.configuration = config
            notice.isHidden = false
        } else {
            // Emptied and taken off the page, not just hidden: a hidden "Opening a shell…" spinner went on turning
            // behind a live shell (after an alert it started again), so the page never sat still and UI tests waited
            // minutes for it to idle. 2026-11-04: on iOS 27 emptying alone no longer stopped it.
            notice.configuration = UIContentUnavailableConfiguration.empty()
            notice.isHidden = true
            notice.removeFromSuperview()
        }
        terminal.isUserInteractionEnabled = notice.isHidden
        terminal.accessibilityElementsHidden = !notice.isHidden && state != .connection(.ended(code: nil))
        banner.text = bannerText
        bannerBacking?.isHidden = bannerText == nil
        if !notice.isHidden, terminal.isFirstResponder { _ = terminal.resignFirstResponder() }
        updateKeyboardButton()
        #if targetEnvironment(macCatalyst)
        if state == .consent, view.window != nil { _ = becomeFirstResponder() } else if isFirstResponder { _ = resignFirstResponder() }
        #endif
        installMenu()
    }

    private func stopped(_ ending: TerminalWire.Ending, in tab: TerminalTab) -> UIContentUnavailableConfiguration {
        let retry: () -> Void = { [weak self, weak tab] in
            guard let self, let tab else { return }
            connect(tab)
        }
        switch ending {
        case .replaced:
            return card("rectangle.on.rectangle", "Open in Another Window",
                        "This shell was opened somewhere else in the app.", button: "Open Here", action: retry)
        case .off:
            return card("terminal", "Turned Off on \(computerName)",
                        "The Terminal was turned off on that computer. To turn it back on, delete terminal.off from the Hermes HQ add-on’s data folder there.")
        case .unsupported:
            return card("exclamationmark.triangle", "No Terminal Here",
                        "\(computerName) can’t open a terminal. On a Windows computer, run hermes pm repair there, then restart Hermes.")
        case .full:
            return card("square.stack.3d.up", "Too Many Shells Open",
                        "\(computerName) has \(TerminalSettings.maxTabs) shells open. Close a tab or end one in another window, or wait a few minutes.", button: "Try Again", action: retry)
        case .refused(let reason):
            return card("exclamationmark.triangle", "Couldn’t Open a Shell", reason, button: "Try Again", action: retry)
        case .blocked:
            // The Hermes HQ edge from before 2026-11-02 answered /terminal 404; the connect command updates it.
            return card("shield.lefthalf.filled", "Terminal Blocked on the Way",
                        "Something between this \(DeviceWord.name) and \(computerName) turned the Terminal away. If you set up the connection with the Hermes HQ connect command, run that command again on \(computerName) to update it, then try again.",
                        button: "Try Again", action: retry)
        case .unreachable:
            return card("exclamationmark.triangle", "Can’t Reach the Shell",
                        "\(computerName) didn’t open a shell after several tries. Check that Hermes is running there, then try again.",
                        button: "Try Again", action: retry)
        case .retry, .ended:
            return card("exclamationmark.triangle", "Disconnected", "The link to \(computerName) closed.", button: "Try Again", action: retry)
        }
    }

    private func card(_ symbol: String, _ title: String, _ text: String, button: String? = nil, dim: Bool = false,
                      secondary: (title: String, action: () -> Void)? = nil,
                      action: (() -> Void)? = nil) -> UIContentUnavailableConfiguration {
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: symbol)
        config.imageProperties.tintColor = UIColor(white: 0.75, alpha: 1)
        config.text = title
        config.textProperties.color = .white
        config.secondaryText = text
        config.secondaryTextProperties.color = UIColor(white: 0.72, alpha: 1)
        if let button, let action {
            // [mac-ui-issues] The Mac's default push button (accent, rounded), as every other page's; it was a pill.
            var style = DeviceWord.isMac ? MacPush.configuration(.prominent) : UIButton.Configuration.hqProminentGlass()
            style.title = button
            config.button = style
            config.buttonProperties.primaryAction = UIAction { _ in action() }
        }
        if let secondary {
            var style = UIButton.Configuration.plain()
            style.title = secondary.title
            style.baseForegroundColor = UIColor(white: 0.85, alpha: 1)
            config.secondaryButton = style
            config.secondaryButtonProperties.primaryAction = UIAction { _ in secondary.action() }
        }
        config.background.backgroundColor = dim ? Self.background.withAlphaComponent(0.82) : Self.background
        return config
    }

    private func loading(_ text: String) -> UIContentUnavailableConfiguration {
        var config = UIContentUnavailableConfiguration.loading()
        config.text = text
        config.textProperties.color = UIColor(white: 0.8, alpha: 1)
        config.background.backgroundColor = Self.background
        return config
    }

    private func updateAddOn() {
        Haptics.play(.selection)
        if updateAsked {
            Task { await checkAndConnect() }
            return
        }
        updateAsked = true
        render()
        guard let model = TerminalHooks.model else { return }
        Task { [weak self] in
            let done = await PushSetupOffer.shared.check(model: model, fromSettings: true, confirm: false, from: self)
            if done { await self?.checkAndConnect() }
        }
    }

    // MARK: The ⋯ menu

    private func installMenu() {
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            MainActor.assumeIsolated { done(self?.menuItems() ?? []) }
        }])
        let item = navigationItem.rightBarButtonItems?.first { $0.accessibilityIdentifier == "terminal.more" }
            ?? UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: menu)
        item.menu = menu
        item.accessibilityLabel = "More"
        item.accessibilityIdentifier = "terminal.more"
        if navigationItem.rightBarButtonItems?.contains(where: { $0 === item }) != true {
            navigationItem.rightBarButtonItems = [item] + (navigationItem.rightBarButtonItems ?? [])
        }
        // + opens another shell in a new tab, once the shells are open.
        let add = navigationItem.rightBarButtonItems?.first { $0.accessibilityIdentifier == "terminal.newTab" }
            ?? UIBarButtonItem(image: UIImage(systemName: "plus"), primaryAction: UIAction { [weak self] _ in self?.newTab() })
        add.accessibilityLabel = "New Tab"
        add.accessibilityIdentifier = "terminal.newTab"
        add.isEnabled = shellsOpen && tabs.count < TerminalSettings.maxTabs
        if navigationItem.rightBarButtonItems?.contains(where: { $0 === add }) != true, let items = navigationItem.rightBarButtonItems,
           let at = items.firstIndex(where: { $0 === item }) {
            var items = items
            items.insert(add, at: at + 1)
            navigationItem.rightBarButtonItems = items
        }
    }

    private var isLive: Bool { state == .connection(.live) && !relocked }

    private func menuItems() -> [UIMenuElement] {
        let live = isLive
        let hasText = shellsOpen
        let paste = UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard"),
                             attributes: live && UIPasteboard.general.hasStrings ? [] : .disabled) { [weak self] _ in
            guard let text = UIPasteboard.general.string else { return }
            self?.paste(text)
        }
        let copyAll = UIAction(title: "Copy All", image: UIImage(systemName: "doc.on.doc"),
                               attributes: hasText ? [] : .disabled) { [weak self] _ in self?.copyAll() }
        let select = UIAction(title: "Select Text…", image: UIImage(systemName: "text.cursor"),
                              attributes: hasText ? [] : .disabled) { [weak self] _ in self?.showText() }
        let size = UIMenu(title: "Text Size", options: .displayInline, children: [
            UIAction(title: "Bigger", image: UIImage(systemName: "textformat.size.larger"),
                     attributes: TerminalSettings.fontSize < TerminalSettings.sizes.upperBound ? [] : .disabled) { [weak self] _ in self?.textSize(+1) },
            UIAction(title: "Smaller", image: UIImage(systemName: "textformat.size.smaller"),
                     attributes: TerminalSettings.fontSize > TerminalSettings.sizes.lowerBound ? [] : .disabled) { [weak self] _ in self?.textSize(-1) },
            UIAction(title: "Default Size", attributes: TerminalSettings.fontSize == TerminalSettings.defaultSize ? .disabled : []) { [weak self] _ in
                self?.textSize(0)
            },
            UIMenu(title: "Font", subtitle: TerminalSettings.face.title, image: UIImage(systemName: "textformat"),
                   children: TerminalSettings.Face.allCases.map { face in
                       UIAction(title: face.title, state: face == TerminalSettings.face ? .on : .off) { [weak self] _ in self?.setFace(face) }
                   }),
        ])
        let lock = UIAction(title: "Require \(TerminalUnlock.name)", image: UIImage(systemName: TerminalUnlock.symbol),
                            state: TerminalSettings.requiresUnlock ? .on : .off) { [weak self] _ in
            self?.toggleLock()
        }
        // Locked again (09-2): only the lock and the text size until Face ID.
        if relocked { return [size, UIMenu(options: .displayInline, children: [lock])] }
        var shell: [UIMenuElement] = []
        if shellsOpen {
            shell.append(UIAction(title: "New Tab", image: UIImage(systemName: "plus.square.on.square"),
                                  attributes: tabs.count < TerminalSettings.maxTabs ? [] : .disabled) { [weak self] _ in self?.newTab() })
        }
        if tabs.count > 1 {
            shell.append(UIAction(title: "Rename Tab…", image: UIImage(systemName: "pencil")) { [weak self] _ in
                guard let self else { return }
                renameTab(at: current)
            })
            shell.append(UIAction(title: "Close Tab", image: UIImage(systemName: "xmark.square")) { [weak self] _ in
                guard let self else { return }
                closeTab(at: current)
            })
        }
        if case .connection(let phase) = state, phase != .connecting {
            shell.append(UIAction(title: "New Shell", image: UIImage(systemName: "plus.rectangle")) { [weak self] _ in
                self?.newShell(confirm: live)
            })
        }
        if live {
            shell.append(UIAction(title: "End Shell", image: UIImage(systemName: "xmark.rectangle"), attributes: .destructive) { [weak self] _ in
                self?.endShell()
            })
        }
        return [UIMenu(options: .displayInline, children: [paste, copyAll, select]), size,
                UIMenu(options: .displayInline, children: [lock]), UIMenu(options: .displayInline, children: shell)]
    }

    /// ⋯ › Require Face ID. Turning it on asks nothing; turning it off asks for Face ID first (audit 09-1).
    private func toggleLock() {
        guard TerminalSettings.requiresUnlock else {
            TerminalSettings.requiresUnlock = true
            Haptics.play(.selection)
            return
        }
        Task { [weak self] in
            guard await TerminalUnlock.mayTurnOff() else { return }
            TerminalSettings.requiresUnlock = false
            AppLog.note("terminal", "lock turned off")
            Haptics.play(.selection)
            self?.unlocked()
            self?.render()
        }
    }

    // MARK: Copy and paste

    /// A paste of several lines asks first unless the shell has bracketed paste on (each line would run as it lands).
    private func paste(_ text: String) {
        guard isLive, !text.isEmpty else { return }
        let bracketed = terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: -1))?.inputState.bracketedPasteMode ?? false
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard !bracketed, lines.count > 1 else { return pasteNow(text) }
        let count = lines.last?.isEmpty == true ? lines.count - 1 : lines.count
        let alert = UIAlertController(title: count == 1 ? "Paste and Run?" : "Paste \(count) Lines?",
                                      message: "Each line runs as soon as it’s pasted, as if you typed it and pressed Return.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.focus() })
        let go = UIAlertAction(title: "Paste", style: .default) { [weak self] _ in self?.pasteNow(text) }
        alert.addAction(go)
        alert.preferredAction = go
        present(alert, animated: true)
    }

    private func pasteNow(_ text: String) {
        AppLog.trace("terminal", "paste \(text.utf8.count) bytes")
        terminal.pasteText(text)
        if !terminal.isFirstResponder { _ = terminal.becomeFirstResponder() }
    }

    /// Everything the screen and its scrollback hold, as plain text, without the blank rows at the end.
    var allText: String {
        let text = String(decoding: terminal.getBufferAsData(), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(line.reversed().drop(while: { $0 == " " }).reversed())
        }
        return lines.reversed().drop(while: \.isEmpty).reversed().joined(separator: "\n")
    }

    private func copyAll() {
        UIPasteboard.general.string = allText
        Haptics.play(.success)
        UndoPill.show(label: "Copied", duration: 2, in: self, showsUndo: false) {}
        HQAnnounce.say("Copied")
    }

    private func showText() {
        let page = TerminalTextController(text: allText)
        page.onClose = { [weak self] in self?.focus() }
        let navigation = UINavigationController(rootViewController: page)
        navigation.sheetPresentationController?.detents = [.large()]
        present(navigation, animated: true)
    }

    /// Typing again once a sheet or question over the page has gone.
    private func focus() {
        guard isLive, view.window != nil, presentedViewController == nil, !terminal.isFirstResponder else { return }
        _ = terminal.becomeFirstResponder()
    }

    // MARK: Text size

    private func textSize(_ step: CGFloat) {
        TerminalSettings.fontSize = step == 0 ? TerminalSettings.defaultSize : TerminalSettings.fontSize + step
        tabs.forEach { TerminalSettings.applyFont(to: $0.view) }
        Haptics.play(.selection)
    }

    /// ⋯ › Font (a tester 2026-11-05), for every tab.
    private func setFace(_ face: TerminalSettings.Face) {
        TerminalSettings.face = face
        tabs.forEach { TerminalSettings.applyFont(to: $0.view) }
        Haptics.play(.selection)
        AppLog.note("terminal", "font \(face.rawValue)")
    }

    // MARK: The shell

    private func newShell(confirm: Bool) {
        let tab = self.frontTab
        let start: () -> Void = { [weak self, weak tab] in
            guard let self, let tab else { return }
            if tab.phase == .live {
                tab.newAfterEnd = true
                tab.connection?.endShell()
            } else {
                tab.session = TerminalWire.newSession()
                saveTabs()
                tab.clearScreen()
                connect(tab)
            }
        }
        guard confirm else { return start() }
        let alert = UIAlertController(title: "Start a New Shell?", message: "The shell open now ends, with anything still running in it.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "New Shell", style: .destructive) { _ in start() })
        present(alert, animated: true)
    }

    private func endShell() {
        let alert = UIAlertController(title: "End This Shell?", message: "Anything still running in it stops.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.focus() })
        let tab = self.frontTab
        alert.addAction(UIAlertAction(title: "End Shell", style: .destructive) { [weak tab] _ in
            tab?.endedHere = true
            tab?.connection?.endShell()
        })
        present(alert, animated: true)
    }

    // MARK: Keys

    #if targetEnvironment(macCatalyst)
    // [mac] View › Make Text Bigger / Actual Size / Make Text Smaller (⌘+ ⌘0 ⌘−) size the terminal's text while it is
    // in front, as in Terminal.app, rather than the app's UI Scale.
    @objc func hqTextBigger(_ sender: Any?) { textSize(+1) }
    @objc func hqTextSmaller(_ sender: Any?) { textSize(-1) }
    @objc func hqTextNormal(_ sender: Any?) { textSize(0) }

    /// [mac] Audit 2026-11-02 #6: the consent card answers Return (Turn On, its default button) and Esc (Not Now), as a
    /// Mac dialog does. The page holds the keyboard while it asks, so the keys reach it.
    override var canBecomeFirstResponder: Bool { state == .consent }

    override var keyCommands: [UIKeyCommand]? {
        guard state == .consent else { return (super.keyCommands ?? []) + tabCommands }
        let on = UIKeyCommand(title: "Turn On", action: #selector(turnOn), input: "\r", modifierFlags: [])
        on.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [on]
    }

    override func validate(_ command: UICommand) {
        super.validate(command)
        switch command.action {
        case KeyCommands.textBigger: command.attributes = TerminalSettings.fontSize < TerminalSettings.sizes.upperBound ? [] : .disabled
        case KeyCommands.textSmaller: command.attributes = TerminalSettings.fontSize > TerminalSettings.sizes.lowerBound ? [] : .disabled
        case KeyCommands.textNormal: command.attributes = TerminalSettings.fontSize == TerminalSettings.defaultSize ? .disabled : []
        default: break
        }
    }
    #else
    /// A hardware keyboard's ⌘+ ⌘− ⌘0 (the Mac has them in its View menu).
    override var keyCommands: [UIKeyCommand]? {
        ([UIKeyCommand(title: "Bigger", action: #selector(bigger), input: "+", modifierFlags: .command),
          UIKeyCommand(title: "Bigger", action: #selector(bigger), input: "=", modifierFlags: .command),
          UIKeyCommand(title: "Smaller", action: #selector(smaller), input: "-", modifierFlags: .command),
          UIKeyCommand(title: "Default Size", action: #selector(defaultSize), input: "0", modifierFlags: .command)]
            .map { $0.wantsPriorityOverSystemBehavior = true; return $0 }) + tabCommands
    }

    @objc private func bigger() { textSize(+1) }
    @objc private func smaller() { textSize(-1) }
    @objc private func defaultSize() { textSize(0) }
    #endif

    /// ⌘T a new tab, ⇧⌘] and ⇧⌘[ the next and previous, as in Terminal.app.
    private var tabCommands: [UIKeyCommand] {
        guard shellsOpen else { return [] }
        return [UIKeyCommand(title: "New Tab", action: #selector(newTabKey), input: "t", modifierFlags: .command),
                UIKeyCommand(title: "Show Next Tab", action: #selector(nextTab), input: "]", modifierFlags: [.command, .shift]),
                UIKeyCommand(title: "Show Previous Tab", action: #selector(previousTab), input: "[", modifierFlags: [.command, .shift])]
            .map { $0.wantsPriorityOverSystemBehavior = true; return $0 }
    }

    @objc private func newTabKey() { newTab() }
    @objc private func nextTab() { cycle(+1) }
    @objc private func previousTab() { cycle(-1) }

    /// Escape is the shell's while it is typed into (the app's Escape would otherwise close the page).
    @objc func hqEscape(_ sender: Any?) {
        #if targetEnvironment(macCatalyst)
        if state == .consent { return notNow() }
        #endif
        if terminal.isFirstResponder { terminal.send([0x1b]) } else if presented { close() } else { navigationController?.popViewController(animated: true) }
    }

    /// ⌘W closes the Terminal shown over Bot Info, as its ✕ does.
    @objc func hqCloseChat(_ sender: Any?) { close() }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == KeyCommands.escape {
            #if targetEnvironment(macCatalyst)
            if state == .consent, presentedViewController == nil { return true }   // [mac] #6: Esc is Not Now
            #endif
            return presentedViewController == nil && (terminal.isFirstResponder || presented)
        }
        if action == KeyCommands.closeChat { return presented && presentedViewController == nil }
        return super.canPerformAction(action, withSender: sender)
    }

    // MARK: TerminalViewDelegate

    private func tab(for source: TerminalView) -> TerminalTab? { tabs.first { $0.view === source } }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        tab(for: source)?.connection?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        guard let tab = tab(for: source) else { return }
        tab.title = title
        strip.update(titles: tabTitles, current: current)
        if tab === self.frontTab, !relocked { navigationItem.subtitle = title.isEmpty ? nil : title }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        tab(for: source)?.connection?.send(Data(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        UIApplication.shared.open(url)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// A program in the shell copied (OSC 52: tmux, vim, `pbcopy` stand-ins): onto this device's clipboard.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard source === terminal else { return }
        guard let text = String(data: content, encoding: .utf8), !text.isEmpty else { return }
        UIPasteboard.general.string = text
        AppLog.trace("terminal", "a program copied \(content.count) bytes")
        // Audit 09-20: never in silence, since the clipboard it replaced may go on to the Mac (Universal Clipboard).
        UndoPill.show(label: "Copied by the Shell", duration: 2, in: self, showsUndo: false) {}
        HQAnnounce.say("Copied by the shell")
    }
}

#if DEBUG
extension TerminalViewController {
    /// MacShots' Terminal tour: the view, to type into and read its font.
    var debugTerminal: TerminalView { terminal }
    var debugTabCount: Int { tabs.count }
}
#endif

/// SwiftTerm's view with the page's paste: the long-press menu's Paste, ⌘V, iOS's paste button and a text drop all go
/// through `onPaste` (which asks first for several lines).
final class HQTerminalView: TerminalView {
    var onPaste: ((String) -> Void)?
    /// It stopped being typed into (the keyboard dragged away, another tab in front, a sheet over the page).
    var onResign: (() -> Void)?

    /// The key bar over the keyboard (none on the Mac).
    var keyBar: UIView?

    /// Whether typing into it brings up the keyboard and its key bar. A tester 2026-11-05: the terminal full screen
    /// until the keyboard is asked for. Without it the screen still takes a hardware keyboard, a hold's Paste and ⌘V:
    /// it keeps typing focus behind an empty input view, so nothing slides up.
    var showsKeyboard = true {
        didSet {
            guard showsKeyboard != oldValue else { return }
            applyKeyboard()
            if isFirstResponder { reloadInputViews() }
        }
    }

    private let noKeyboard = UIView(frame: .zero)

    func applyKeyboard() {
        #if !targetEnvironment(macCatalyst)
        inputView = showsKeyboard ? nil : noKeyboard
        inputAccessoryView = showsKeyboard ? keyBar : nil
        // Owner 2026-11-04 (layout A): drag the screen down into the keyboard to put it away, as in Messages.
        keyboardDismissMode = showsKeyboard ? .interactive : .none
        #endif
    }

    /// a tester 2026-11-05 ("Backspace"): the keyboard's delete key always has something to delete. SwiftTerm answers
    /// from its own copy of what was typed here, which is empty at a line the shell brought back (↑, a paste, tab
    /// completion), and iOS stopped a held delete there after one backspace: it asks `hasText`, then reads the text
    /// before the caret, so `reportsTextBeforeInput` puts a space there too. The line is the shell's, so every delete
    /// goes to it as a backspace.
    override var hasText: Bool { true }

    override func resignFirstResponder() -> Bool {
        let done = super.resignFirstResponder()
        if done { onResign?() }
        return done
    }

    /// A steady block cursor, as Terminal.app's default: SwiftTerm's blinking one is an animation that repeats
    /// forever (UI tests waited on it at every step), and a reset (`Esc c`) goes back to the start-up style.
    override init(frame: CGRect, font: UIFont?) {
        var options = TerminalOptions.default
        options.cursorStyle = .steadyBlock
        options.scrollback = 5000
        super.init(frame: frame, font: font, options: options)
        pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        reportsTextBeforeInput = true   // a held delete keeps repeating (see hasText)
    }

    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The 16 ANSI colours (VS Code's dark terminal): SwiftTerm's own blue (`ls`, prompts) was too dark to read on the
    /// panel's grey.
    static let palette: [SwiftTerm.Color] = [
        0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
        0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xFFFFFF,
    ].map { rgb in
        SwiftTerm.Color(red: UInt16((rgb >> 16) & 0xFF) * 257, green: UInt16((rgb >> 8) & 0xFF) * 257, blue: UInt16(rgb & 0xFF) * 257)
    }

    /// The page's colours: light text on the panel's dark grey, the app's tint for the caret and selection.
    /// Not `backgroundColor`: on a scroll view that clears the layer colour SwiftTerm paints the empty cells with, and
    /// marks the view opaque, so the cleared cells drew black.
    func style() {
        installColors(Self.palette)
        nativeBackgroundColor = TerminalViewController.background
        nativeForegroundColor = TerminalViewController.foreground
        caretColor = HQPalette.tint
        selectedTextBackgroundColor = HQPalette.tint.withAlphaComponent(0.4)
        selectedTextForegroundColor = .white
        keyboardAppearance = .dark
    }

    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        onPaste?(text)
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
            guard let text = object as? String else { return }
            Task { @MainActor [weak self] in self?.onPaste?(text) }
        }
    }
}

/// ⋯ › Select Text: the screen and its scrollback as plain text, to select any part of it (or Copy All).
final class TerminalTextController: UIViewController {
    private let text: String
    private let textView = UITextView()
    /// Closed (Done, Copy All or a swipe down).
    var onClose: (() -> Void)?

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
        title = "Select Text"
    }

    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.sheetPage
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.text = text
        textView.font = TerminalSettings.font()
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        textView.accessibilityIdentifier = "terminal.text"
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let done = UIBarButtonItem.hqClose(.done, action: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        done.accessibilityIdentifier = "terminal.text.done"
        navigationItem.hqPlaceClose(done)
        let copy = UIBarButtonItem(title: "Copy All", primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            UIPasteboard.general.string = text
            Haptics.play(.success)
            HQAnnounce.say("Copied")
            dismiss(animated: true)
        })
        copy.accessibilityIdentifier = "terminal.text.copy"
        navigationItem.rightBarButtonItems = (navigationItem.rightBarButtonItems ?? []) + [copy]
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.isBeingDismissed ?? isBeingDismissed { onClose?() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The newest lines are at the end, as in the terminal.
        textView.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0))
    }
}
