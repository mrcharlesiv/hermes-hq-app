// Read Aloud on one chat screen (docs/spec/3x-talk.md §7): the action row's button and the hold menu's tile ask
// `ReadAloudCenter`; Read Replies Aloud reads a reply that completes while this chat is on screen; the strip above
// the composer and the bar beside the reply show what is being read. Owned by the screen's `ChatVoiceHost`.

import UIKit

@MainActor final class ChatReadAloudHost: NSObject {
    private weak var screen: ChatViewController?
    private weak var voice: ChatVoiceHost?
    private weak var chat: (any ChatVoiceTurns)?
    let strip = ReadAloudStrip()
    private var stripBase: CGFloat = 0
    private(set) var isOnScreen = false
    /// The newest reply already heard, or passed over on purpose: Read Replies Aloud never reads it.
    private var heardId: String?
    /// A turn was seen running while this chat was on screen (history arriving is not a reply completing).
    private var sawRunning = false
    /// The newest reply that finished while something else was being read or recorded: read next.
    private var nextId: String?
    private var levelTimer: Timer?
    private var slotInstalled = false

    init(screen: ChatViewController, voice: ChatVoiceHost) {
        self.screen = screen
        self.voice = voice
        chat = screen.session as? ChatVoiceTurns
        super.init()
    }

    private var center: ReadAloudCenter { ReadAloudCenter.shared }
    private var scope: String { chat?.memoScope ?? "" }
    private var readingHere: Bool { center.state != .idle && center.scope == scope }

    // MARK: Install

    func install() {
        guard let screen else { return }
        strip.isHidden = true
        strip.onStop = { ReadAloudCenter.shared.stop() }
        screen.view.insertSubview(strip, belowSubview: screen.composer)
        let notes = NotificationCenter.default
        notes.addObserver(self, selector: #selector(centerChanged), name: ReadAloudCenter.didChange, object: nil)
        notes.addObserver(self, selector: #selector(speechChanged), name: .talkSpeechChanged, object: nil)
        notes.addObserver(self, selector: #selector(switchChanged), name: TalkController.readRepliesAloudChanged, object: nil)
        notes.addObserver(self, selector: #selector(talkChanged), name: TalkController.didChange, object: nil)
        notes.addObserver(self, selector: #selector(phoneVoiceStarted(_:)), name: PhoneVoiceFallback.started, object: nil)
    }

    func screenAppeared() {
        isOnScreen = true
        Self.onScreen = Self.onScreen.filter { $0.value.host != nil }
        Self.onScreen[scope] = WeakReader(host: self)
        installMenuSlot()
        markHeard()
        sawRunning = chat?.isRunning ?? false
        center.warmUp(for: chat)
        refresh(animated: false)
    }

    func screenLeft() {
        guard isOnScreen else { return }
        isOnScreen = false
        nextId = nil
        // Leaving the chat stops the reading (§7.4).
        center.stop(scope: scope)
        center.warmUp(for: nil)
        refresh(animated: false)
    }

    /// The reply that is the latest now will never be read by Read Replies Aloud.
    private func markHeard() {
        guard let chat, let reply = chat.newestReply, !reply.pending, !chat.isRunning else { return }
        heardId = reply.messageId
    }

    // MARK: Read Replies Aloud (§7.4)

    /// The chat changed (called by the screen for every change of its session).
    func sessionChanged() {
        guard let chat, isOnScreen else { return }
        if chat.isRunning {
            sawRunning = true
            return
        }
        guard let reply = chat.newestReply, !reply.pending, reply.messageId != heardId else { return }
        heardId = reply.messageId
        // Only a reply that completed in front of the person, with the switch on.
        guard sawRunning, TalkController.readsRepliesAloud else { return }
        sawRunning = false
        // A conversation that paused or stopped here left its notice in the composer's place ("Voice stops when … leaves
        // the screen"): the reply to what was said in it is not read out next to those words (stress round 1; spec
        // §15 S-I2 "no audio after return"). It counts as heard; Read Aloud on the reply still reads it when asked.
        guard Self.readsCompletedReply(switchOn: true, voiceNotice: TalkController.shared.notice(for: scope) != nil) else { return }
        readNext(reply.messageId)
    }

    /// Whether Read Replies Aloud reads a reply that just completed on screen.
    nonisolated static func readsCompletedReply(switchOn: Bool, voiceNotice: Bool) -> Bool { switchOn && !voiceNotice }

    private var busyElsewhere: Bool {
        guard let composer = screen?.composer else { return false }
        return composer.memoActive || composer.dictating
    }

    private func readNext(_ messageId: String) {
        guard let chat, isOnScreen, TalkController.readsRepliesAloud, !TalkController.shared.isLive else { return }
        // One at a time: while a reply is read, or a memo or a dictation records, only the newest waits.
        if readingHere || busyElsewhere {
            nextId = messageId
            return
        }
        guard chat.newestReply?.messageId == messageId, let reply = chat.spokenText(messageId: messageId) else { return }
        center.read(messageId: messageId, markdown: reply.text, in: chat, auto: true)
    }

    /// A memo take or a dictation ended: the reply that waited is read if it is still the newest.
    func inputEnded() {
        guard let id = nextId, !busyElsewhere, !readingHere else { return }
        nextId = nil
        readNext(id)
    }

    /// A message was sent from this chat: whatever is being read stops.
    func messageSent() {
        nextId = nil
        center.stop(scope: scope)
    }

    @objc private func switchChanged() {
        if TalkController.readsRepliesAloud {
            markHeard()
        } else {
            nextId = nil
            if readingHere, TalkSpeaker.shared.owner == .repliesAloud { center.stop() }
        }
        if isOnScreen { center.warmUp(for: chat) }
        // The ⋯ menu stays open on this row: its rows are redrawn in place (a new bar item would close it).
        if isOnScreen { screen?.refreshVisibleMoreMenu() }
    }

    @objc private func talkChanged() {
        // A conversation speaks its own replies: nothing waits behind it.
        if TalkController.shared.isLive { nextId = nil }
    }

    // MARK: The reply's button and the hold menu (§7.1, §7.2)

    private static func messageId(ofRow rowId: String) -> String { String(rowId.prefix { $0 != "|" }) }

    func button(forRow rowId: String) -> ReadAloudCenter.Button { center.button(for: Self.messageId(ofRow: rowId)) }

    func toggle(messageId: String) {
        guard let chat else { return }
        if center.state.messageId == messageId {
            Haptics.play(.light)   // stopped, as the read strip's own Stop
            center.stop()
            return
        }
        nextId = nil
        guard let reply = chat.spokenText(messageId: messageId) else {
            failed(VoiceFailure(reason: ReadAloudCenter.nothingToRead, detail: nil))
            return
        }
        Haptics.play(.selection)
        center.toggle(messageId: messageId, markdown: reply.text, in: chat)
    }

    func toggle(rowId: String) { toggle(messageId: Self.messageId(ofRow: rowId)) }

    /// Words that are not a reply of this chat (a folded delivery or result row's): read as given.
    func toggle(messageId: String, text: String) {
        guard let chat else { return }
        if center.state.messageId == messageId {
            Haptics.play(.light)   // stopped, as the read strip's own Stop
            center.stop()
            return
        }
        nextId = nil
        Haptics.play(.selection)
        center.toggle(messageId: messageId, markdown: text, in: chat)
    }

    /// The hold menu's tile for one reply: Read Aloud, or Stop Reading while it is being read.
    func isReading(messageId: String) -> Bool { center.state.messageId == messageId }

    // MARK: The ⋯ menu (§7.3)

    private func installMenuSlot() {
        guard !slotInstalled, let menus = screen?.menus, chat?.allowsTalk == true else { return }
        slotInstalled = true
        menus.slotItems[.readAloud] = { [weak self] in self?.menuItems() ?? [] }
        #if targetEnvironment(macCatalyst)
        screen?.updateReadAloudButton()   // [mac-audit] the bar's speaker, when the switch is already on
        #endif
    }

    private func menuItems() -> [UIMenuElement] {
        guard chat?.allowsTalk == true else { return [] }
        return [Self.repliesItem(on: TalkController.readsRepliesAloud) { [weak self] in
            TalkController.readsRepliesAloud.toggle()
            self?.saySwitch()
        }]
    }

    /// [mac] Stress test 2026-10-28 #79: the Mac's menu closes on the click (the iPhone's stays open with its tick
    /// moving), so the chat says what the switch is now; the Chat menu's item carries the tick too.
    func saySwitch() {
        guard DeviceWord.isMac else { return }
        screen?.showNotice(TalkController.readsRepliesAloud ? "Read Replies Aloud is on" : "Read Replies Aloud is off")
    }

    static func repliesItem(on: Bool, toggle: @escaping () -> Void) -> UIAction {
        let action = UIAction(title: "Read Replies Aloud", image: UIImage(systemName: "speaker.wave.2"), attributes: .keepsMenuPresented,
                              state: on ? .on : .off) { _ in toggle() }
        action.accessibilityIdentifier = "chat.menu.read-replies"
        return action
    }

    // MARK: Failures (§7.6)

    private static var onScreen: [String: WeakReader] = [:]
    private struct WeakReader { weak var host: ChatReadAloudHost? }

    func failed(_ failure: VoiceFailure) {
        guard isOnScreen, let screen else { return }
        FailureAlert.present(title: ReadAloudCenter.failureTitle, reason: failure.reason, detail: failure.detail, from: screen)
    }

    /// The centre's failures reach the chat they belong to, when it is the one on screen.
    static func failed(_ failure: VoiceFailure, scope: String) {
        onScreen[scope]?.host?.failed(failure)
    }

    // MARK: The iPhone's voice took over (§7.7)

    /// The computer's voice failed and the iPhone's reads instead: the chat on screen says so once, quietly, with Fix….
    /// A conversation's reply counts too (the notice sits under the title, clear of the dock).
    @objc private func phoneVoiceStarted(_ note: Notification) {
        guard isOnScreen, let chat, let screen, let info = note.userInfo,
              Self.noticeBelongs(account: info["account"] as? String, profile: info["profile"] as? String,
                                 chatAccount: chat.voiceClient.account.id, chatProfile: chat.profile),
              let key = info["key"] as? String, PhoneVoiceFallback.shared.claimNotice(key) else { return }
        let name = voice?.botName ?? ""
        let profile = chat.profile
        let client = chat.voiceClient
        AppLog.note("voice", "phone voice notice shown")
        screen.showNotice(PhoneVoiceWords.notice(botName: name), action: (PhoneVoiceWords.fix, { [weak screen] in
            guard let screen else { return }
            VoiceSettingsScreens.openTextToSpeech(profile: profile, client: client, botName: name, from: screen)
        }), duration: 8)
    }

    /// The notice is this chat's when the voice that failed is its bot's (same gateway, same profile).
    nonisolated static func noticeBelongs(account: String?, profile: String?, chatAccount: String, chatProfile: String) -> Bool {
        account == chatAccount && (profile ?? "") == chatProfile
    }

    // MARK: Drawing

    @objc private func centerChanged() {
        refresh(animated: true)
        if center.state == .idle, isOnScreen { inputEnded() }
    }

    /// The speaker began or stopped (a conversation's reply too): the bar beside the reply follows.
    @objc private func speechChanged() {
        guard isOnScreen else { return }
        screen?.talkRefreshSpokenCells()
    }

    private func refresh(animated: Bool) {
        guard let screen, screen.isViewLoaded else { return }
        // Never during a conversation (the dock says "<name> is speaking").
        let shown = isOnScreen && readingHere && !TalkController.shared.isLive
        if shown {
            strip.show(center.state, level: center.level)
            startLevels()
        } else {
            levelTimer?.invalidate()
            levelTimer = nil
        }
        if strip.isHidden == shown {
            strip.isHidden = !shown
            if shown { HQAnnounce.say(strip.spoken) }
            if animated, isOnScreen, !HQMotion.reduced {
                UIView.animate(withDuration: 0.2) {
                    screen.view.setNeedsLayout()
                    screen.view.layoutIfNeeded()
                }
            } else {
                screen.view.setNeedsLayout()
            }
        }
        screen.talkRefreshSpokenCells()
    }

    private func startLevels() {
        guard levelTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.strip.setLevel(self.center.level)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    /// The screen asks where the transcript ends: the strip sits above everything above the composer.
    func stripTop(base: CGFloat) -> CGFloat {
        stripBase = base
        return strip.isHidden ? base : base - ReadAloudStrip.height - 8
    }

    func layout() {
        // [Mac UI check 2026-11-13] L8: the jump button stands above the strip while it shows (it sat on "Reading aloud").
        screen?.activity.jumpLift = strip.isHidden ? 0 : ReadAloudStrip.height + 8
        guard let screen, !strip.isHidden else { return }
        let width = min(screen.view.bounds.width - 32, strip.fittingWidth)
        strip.frame = CGRect(x: ((screen.view.bounds.width - width) / 2).rounded(), y: stripBase - ReadAloudStrip.height - 4,
                             width: width, height: ReadAloudStrip.height)
    }
}

// MARK: - The strip (§7.5)

/// A compact glass capsule: a spinner and "Preparing audio", or three bars and "Reading aloud"; the route's name when
/// it is not the built-in speaker; Stop.
final class ReadAloudStrip: UIView {
    static let height: CGFloat = 44

    var onStop: (() -> Void)?
    private let glass: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        view.cornerConfiguration = .capsule()
        return view
    }()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let bars = ReadAloudBars()
    private let label = UILabel()
    private let route = TalkRouteButton()
    private let stopButton = UIButton(type: .system)
    private let row = UIStackView()
    private(set) var spoken = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "read.strip"
        addSubview(glass)
        label.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: HQFont.system(ofSize: 15, weight: .semibold))
        label.adjustsFontForContentSizeCategory = true
        label.maximumContentSizeCategory = .accessibilityMedium
        label.textColor = .label   // system-ink-ok: words on the strip's system glass take its vibrant ink
        label.accessibilityIdentifier = "read.strip.label"
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        route.accessibilityIdentifier = "read.strip.route"
        route.isHidden = true
        route.onChange = { [weak self] in self?.routeChanged() }
        var stop = UIButton.Configuration.plain()
        stop.title = "Stop"
        stop.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 6)
        stop.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: HQFont.system(ofSize: 15, weight: .semibold))
            return outgoing
        }
        stopButton.configuration = stop
        stopButton.maximumContentSizeCategory = .accessibilityMedium
        stopButton.accessibilityLabel = "Stop reading"
        stopButton.accessibilityIdentifier = "read.strip.stop"
        stopButton.addAction(UIAction { [weak self] _ in
            Haptics.play(.light)
            self?.onStop?()
        }, for: .touchUpInside)
        stopButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        bars.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([bars.widthAnchor.constraint(equalToConstant: 16), bars.heightAnchor.constraint(equalToConstant: 16)])
        for view in [spinner, bars, label, route, stopButton] as [UIView] { row.addArrangedSubview(view) }
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.setCustomSpacing(12, after: label)
        row.setCustomSpacing(0, after: route)
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            stopButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            stopButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        show(.preparing(""), level: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The width the capsule wants for what it shows.
    var fittingWidth: CGFloat {
        row.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + 16 + 8
    }

    func show(_ state: ReadAloudCenter.State, level: Double) {
        let preparing: Bool = if case .preparing = state { true } else { false }
        spinner.isHidden = !preparing
        if preparing { spinner.startAnimating() } else { spinner.stopAnimating() }
        bars.isHidden = preparing
        label.text = preparing ? "Preparing audio" : "Reading aloud"
        spoken = label.text ?? ""
        label.accessibilityLabel = spoken
        bars.setLevel(level)
        routeChanged()
    }

    func setLevel(_ level: Double) { bars.setLevel(level) }

    /// The route's name shows only when sound is not going to the built-in speaker.
    private func routeChanged() {
        let away = route.kind == .headphones || route.kind == .other
        guard route.isHidden == away else { return }
        route.isHidden = !away
        superview?.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
    }

    /// Stop's touch area reaches the capsule's edge.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, bounds.contains(point) else { return nil }
        let hit = super.hitTest(point, with: event)
        if let hit, hit.isDescendant(of: route) || hit.isDescendant(of: stopButton) { return hit }
        return convert(point, to: stopButton).x >= -8 ? stopButton : (hit ?? self)
    }
}

/// Three small bars that follow the speaker's level.
final class ReadAloudBars: UIView {
    private let layers = (0..<3).map { _ in CALayer() }
    private var level = 0.0
    private static let weights: [Double] = [0.7, 1, 0.7]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        for bar in layers {
            bar.cornerRadius = 1.5
            bar.backgroundColor = tintColor.cgColor
            layer.addSublayer(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        for bar in layers { bar.backgroundColor = tintColor.cgColor }
    }

    func setLevel(_ level: Double) {
        self.level = max(0, min(1, level.isFinite ? level : 0))
        place(animated: !HQMotion.reduced)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        place(animated: false)
    }

    private func place(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.09)
        let width: CGFloat = 3, gap: CGFloat = 3
        let total = width * 3 + gap * 2
        var x = (bounds.width - total) / 2
        for (index, bar) in layers.enumerated() {
            let part = 0.3 + 0.7 * Self.weights[index] * level
            let height = max(4, bounds.height * CGFloat(part))
            bar.frame = CGRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
            x += width + gap
        }
        CATransaction.commit()
    }
}

// MARK: - The action row's Read Aloud button asks the chat screen

extension ChatViewController {
    func chatCellReadAloud(rowId: String) -> ReadAloudCenter.Button? { voice.talkReadButton(rowId: rowId) }
    func chatCellToggleReadAloud(rowId: String) { voice.talkToggleRead(rowId: rowId) }
}
