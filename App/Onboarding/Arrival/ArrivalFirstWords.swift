// [first-run] The first run's last beat (the mock's S[5], build/first-run/spec/prototype.src.html), in the arriving
// bot's own chat once Say Hello has opened it:
//
//   1. The face flies from Hermes is here up into the chat's header (`ArrivalFlight`), so it never leaves the screen.
//   2. Their own Hermes writes the first message, live: the app asks it to with a turn that shows no bubble
//      (`LiveChatSession.sendHidden`, the gateway's own `prompt.submit … display_kind: "hidden"`; no add-on needed).
//   3. Once it has, one card above the message bar offers pings (the app's own notification-permission road,
//      `AppModel.requestPermission`), only while iOS has never been asked.
//   4. Then three starter questions, which go out as a typed message would.
//
// Only where the first run is drawn (`FirstRunArrival`), once per arrival. Nothing here runs with the switch off.

import UIKit
import UserNotifications

@MainActor final class ArrivalFirstWords {
    nonisolated enum Step: Equatable, Sendable { case greeting, ping, starters, done }

    /// How long the rest waits for the greeting (a slow model, a dropped link): then it carries on without it.
    nonisolated static let greetingWait: TimeInterval = 25

    /// What follows the greeting, or nil while it is still awaited (its turn was seen running and hasn't ended): the
    /// pings card while iOS has never been asked, else the starters. A greeting that never started, or never ends,
    /// holds the rest up no longer than `greetingWait`.
    nonisolated static func afterGreeting(ran: Bool, running: Bool, waited: TimeInterval, canAsk: Bool) -> Step? {
        guard (ran && !running) || waited >= greetingWait else { return nil }
        return canAsk ? .ping : .starters
    }

    private weak var chat: ChatViewController?
    private(set) var step = Step.greeting
    private var begun = Date()
    /// The greeting's turn was seen running (it ends when the reply is whole).
    private var ran = false
    private var canAsk = false
    private var asking = false
    private var timer: Task<Void, Never>?
    private let ping = ChatNoticeCard(identifier: "chat.firstRun.ping")

    private init(chat: ChatViewController) { self.chat = chat }

    /// The bot whose chat Say Hello is opening, until the beat begins there (or never does).
    static var expected: String?

    /// The beat leads this chat (or is about to): its own tips wait until it is done, so one thing asks at a time.
    static func leads(_ chat: ChatViewController) -> Bool {
        if let words = chat.firstWords { return words.step != .done }
        return expected != nil && expected == chat.session.profile
    }

    /// Starts the beat in `chat` (a live chat, once).
    static func begin(in chat: ChatViewController) {
        guard chat.firstWords == nil, chat.isViewLoaded, let live = chat.session as? LiveChatSession else { return }
        let words = ArrivalFirstWords(chat: chat)
        chat.firstWords = words
        expected = nil
        words.start(live)
    }

    private func start(_ live: LiveChatSession) {
        begun = Date()
        AppLog.note("onboard", "first-run first words: greeting asked for")
        live.sendHidden(OnboardingCopy.Arrival.greetingPrompt, display: nil)
        ran = live.isRunning
        Task { [weak self] in
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            self?.canAsk = status == .notDetermined
        }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.greetingWait))
            guard !Task.isCancelled else { return }
            self?.changed()
        }
    }

    /// The chat changed (every change of its session comes here).
    func changed() {
        guard let chat else { return }
        let running = chat.session.isRunning
        switch step {
        case .greeting:
            if running { ran = true }
            guard let next = Self.afterGreeting(ran: ran, running: running, waited: Date().timeIntervalSince(begun),
                                                canAsk: canAsk) else { return }
            timer?.cancel()
            AppLog.note("onboard", "first-run first words: greeting \(ran ? "done" : "never ran"), \(next == .ping ? "pings card" : "starters")")
            if next == .ping { showPing() } else { showStarters() }
        case .starters:
            // A turn began (their own words went out): the starters have done their work.
            if running { finish() }
        case .ping, .done:
            break
        }
    }

    // MARK: Pings

    private func showPing() {
        let copy = OnboardingCopy.Arrival.self
        step = .ping
        // Asked here, in context: the alert after a later reply (`askNotificationsOnce`) doesn't ask again.
        UserDefaults.standard.set(true, forKey: AppModel.askedKey)
        ping.onPrimary = { [weak self] in self?.turnOn() }
        ping.onClose = { [weak self] in self?.showStarters() }
        ping.show(ChatNoticeCard.Content(title: copy.pingTitle, body: copy.pingBody, primary: copy.pingOn, copyText: nil, bell: true))
        chat?.setGuestCard(ping)
        HQAnnounce.say("\(copy.pingTitle). \(copy.pingBody)", coalesce: true)
    }

    private func turnOn() {
        guard step == .ping, !asking else { return }
        asking = true
        Task { [weak self] in
            let granted = await AppModel.requestPermission()
            guard let self else { return }
            if granted {
                ArrivalSound.play(.pingon)
                Haptics.play(.success)
                HQAnnounce.say(OnboardingCopy.Arrival.pingsOn, coalesce: true)
            }
            self.showStarters()
        }
    }

    // MARK: Starters

    private func showStarters() {
        guard let chat, step != .starters, step != .done else { return }
        step = .starters
        let starters = ArrivalStartersView(titles: OnboardingCopy.Arrival.starters) { [weak self] text in self?.picked(text) }
        chat.setGuestCard(starters)
    }

    private func picked(_ text: String) {
        guard step == .starters, let chat else { return }
        ArrivalSound.play(.sent)
        finish()
        chat.sendFromCard(text, display: text)
    }

    private func finish() {
        step = .done
        timer?.cancel()
        chat?.setGuestCard(nil)
    }
}

/// Three starter questions in a row above the message bar (the mock's `.starts`): each a capsule at least 44 pt tall;
/// the row scrolls sideways when the words outgrow the screen.
final class ArrivalStartersView: UIView {
    private let scroller = UIScrollView()
    private let row = UIStackView()
    private let pick: (String) -> Void
    private let titles: [String]

    init(titles: [String], pick: @escaping (String) -> Void) {
        self.titles = titles
        self.pick = pick
        super.init(frame: .zero)
        accessibilityIdentifier = "chat.firstRun.starters"
        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceHorizontal = false
        scroller.clipsToBounds = false
        scroller.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroller)
        scroller.addSubview(row)
        for (index, title) in titles.enumerated() {
            let button = UIButton(configuration: .hqGlass(), primaryAction: UIAction { [weak self] _ in
                Haptics.play(.selection)
                self?.pick(title)
            })
            button.accessibilityIdentifier = "chat.firstRun.starter.\(index)"
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            row.addArrangedSubview(button)
        }
        NSLayoutConstraint.activate([
            scroller.topAnchor.constraint(equalTo: topAnchor),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroller.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
        ])
        applyFonts()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) {
            (view: ArrivalStartersView, _) in view.applyFonts()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyFonts() {
        let font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: HQFont.system(ofSize: 15, weight: .medium),
                                                                        maximumPointSize: 28, compatibleWith: traitCollection)
        for (index, view) in row.arrangedSubviews.enumerated() {
            guard let button = view as? UIButton, var config = button.configuration else { continue }
            var title = AttributedString(titles[index])
            title.font = font
            config.attributedTitle = title
            config.baseForegroundColor = ChatPalette.label
            config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
            button.configuration = config
        }
    }
}

/// Say Hello → the chat: the face stays on screen while the app opens under it, then flies up into the chat's header
/// (the mock's S[5] opening). A window of its own over the app, touches let through; gone after the landing, or after
/// `patience` when no chat came (the app's own screens are never left covered).
@MainActor final class ArrivalFlight {
    static private(set) var current: ArrivalFlight?
    /// How long the face waits for the app to open, and the first words for their chat.
    nonisolated static let patience: TimeInterval = 7
    /// Once the app shows, how long the face still covers it while the chat comes on.
    nonisolated static let landWait: TimeInterval = 2.5

    private let window: UIWindow
    private let page = UIView()
    private let face: HeadView
    private var landing = false
    private var giveUp: Task<Void, Never>?

    /// Lifts the face off Hermes is here: the words fade to the page under it, then `then` runs (the app opens).
    /// Under Reduce Motion nothing flies: `then` runs at once.
    static func takeOff(from source: HeadView, raw: JSONValue?, profile: String, then: @escaping () -> Void) {
        guard current == nil else { return }
        guard !HQMotion.reduced, let scene = source.window?.windowScene, let host = source.superview else { return then() }
        let flight = ArrivalFlight(scene: scene, side: source.bounds.width, centre: host.convert(source.center, to: nil), raw: raw, profile: profile,
                                   traits: source.traitCollection)
        current = flight
        // motion-ok: opacity only (the words fading to the page under the face); Reduce Motion never gets here.
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) { flight.page.alpha = 1 } completion: { _ in then() }
        flight.giveUp = Task { [weak flight] in
            try? await Task.sleep(for: .seconds(patience))
            guard !Task.isCancelled else { return }
            flight?.end()
        }
    }

    private init(scene: UIWindowScene, side: CGFloat, centre: CGPoint, raw: JSONValue?, profile: String, traits: UITraitCollection) {
        window = UIWindow(windowScene: scene)
        // A window of its own doesn't have the app's appearance (Settings › Appearance): it takes the face's.
        window.overrideUserInterfaceStyle = traits.userInterfaceStyle
        window.windowLevel = .normal + 1
        window.isUserInteractionEnabled = false
        window.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        root.view.isUserInteractionEnabled = false
        window.rootViewController = root
        page.backgroundColor = HQPalette.page.resolvedColor(with: traits)
        page.frame = root.view.bounds
        page.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        page.alpha = 0
        root.view.addSubview(page)
        face = HeadView(side: side)
        face.configure(raw: raw, profile: profile)
        face.isAccessibilityElement = false
        face.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        face.center = centre
        root.view.addSubview(face)
        window.isHidden = false
    }

    /// The chat is on screen: the face flies to its header's face and the page clears off the chat.
    func land(on chat: ChatViewController) {
        guard !landing else { return }
        guard let target = chat.titleAccessoryView, target.window != nil, target.bounds.width > 0 else { return end() }
        landing = true
        giveUp?.cancel()
        let frame = target.convert(target.bounds, to: nil)
        let scale = frame.width / max(face.bounds.width, 1)
        ArrivalSound.play(.fly)
        // motion-ok: opacity only (the page clearing off the chat); Reduce Motion never takes off.
        UIView.animate(withDuration: 0.45, delay: 0.1, options: [.curveEaseInOut]) { self.page.alpha = 0 }
        // motion-ok: the face's flight; Reduce Motion never takes off (`takeOff`).
        UIView.animate(withDuration: 0.85, delay: 0, options: [.curveEaseInOut]) {
            self.face.center = CGPoint(x: frame.midX, y: frame.midY)
            self.face.transform = CGAffineTransform(scaleX: scale, y: scale)
        } completion: { _ in self.remove() }
    }

    /// No chat to land on (or none in time): the page and the face fade off whatever the app shows.
    func end() {
        guard !landing else { return }
        landing = true
        giveUp?.cancel()
        // motion-ok: opacity only.
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut]) { self.window.alpha = 0 } completion: { _ in self.remove() }
    }

    private func remove() {
        window.isHidden = true
        window.rootViewController = nil
        if Self.current === self { Self.current = nil }
    }

    /// After Say Hello opened `profile`'s chat: once it is on screen (its push done), the face lands and the first
    /// words begin. Waits at most `patience`.
    static func expect(chatOf profile: String, in root: MainTabController) {
        ArrivalFirstWords.expected = profile
        Task { @MainActor in
            defer { ArrivalFirstWords.expected = nil }
            let began = Date(), until = began.addingTimeInterval(patience)
            while Date() < until {
                if let chat = root.chatOnShow ?? root.botsViewController.navigationController?.paneChat,
                   chat.session.profile == profile,
                   chat.viewIfLoaded?.window != nil,
                   chat.navigationController?.transitionCoordinator == nil {
                    current?.land(on: chat)
                    try? await Task.sleep(for: .milliseconds(current == nil ? 300 : 700))
                    ArrivalFirstWords.begin(in: chat)
                    return
                }
                // The app is up and the chat isn't on this screen yet (an iPad's second pane, a slow list): the face
                // lets the app show; the first words still begin if the chat comes.
                if Date().timeIntervalSince(began) > landWait { current?.end() }
                try? await Task.sleep(for: .milliseconds(100))
            }
            current?.end()
        }
    }
}
