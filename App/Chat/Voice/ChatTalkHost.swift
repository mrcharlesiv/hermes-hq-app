// Live voice on one chat screen (docs/spec/3x-talk.md §5, §6): Talk in the composer's circle, the dock or its paused /
// stopped notice in the composer's place, and the "Voice chat ended" caption. Owned by the screen's `ChatVoiceHost`,
// which stays the one thing that touches the composer for voice.

import UIKit

@MainActor final class ChatTalkHost: NSObject {
    private weak var screen: ChatViewController?
    private weak var voice: ChatVoiceHost?
    private(set) weak var chat: (any ChatVoiceTurns)?
    /// The chat's scope when the screen was built (a new chat learns its stored id later).
    private let rowScope: String
    private var dock: TalkBarView?
    private var noticeDock: TalkNoticeDock?
    private let caption = UILabel()
    private var captionBase: CGFloat = 0
    private(set) var isOnScreen = false
    private var questionShown = false
    private var introRetry = false

    init(screen: ChatViewController, voice: ChatVoiceHost) {
        self.screen = screen
        self.voice = voice
        chat = screen.session as? ChatVoiceTurns
        rowScope = (screen.session as? ChatVoiceTurns)?.memoScope ?? ""
        super.init()
    }

    private var controller: TalkController { TalkController.shared }
    private var composer: ComposerView? { screen?.composer }
    var name: String {
        let name = voice?.botName ?? ""
        return name.isEmpty ? "Hermes" : name
    }
    var scope: String { chat?.memoScope ?? rowScope }
    private var scopes: [String] { rowScope == scope ? [scope] : [scope, rowScope] }

    /// Talk can start here: a live chat of the signed-in account that is not a room.
    var allowsTalk: Bool { (voice?.isAvailable ?? false) && (chat?.allowsTalk ?? false) }
    var isLiveHere: Bool { controller.isLive(in: chat) }

    // MARK: Install

    func install() {
        guard let screen, let composer else { return }
        caption.font = HQFont.preferred(.caption1)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = ChatPalette.label2
        caption.textAlignment = .center
        caption.numberOfLines = 1
        caption.adjustsFontSizeToFitWidth = true
        caption.minimumScaleFactor = 0.8
        caption.accessibilityIdentifier = "talk.ended"
        caption.isHidden = true
        screen.view.insertSubview(caption, belowSubview: composer)
        composer.talkName = name
        composer.onTalk = { [weak self] in self?.beginTalk() }
        composer.onPrimaryChange = { [weak self] in self?.voice?.talkTipCheck() }
        // Held, Talk opens the voice options (§5.2); VoiceOver has them as a custom action.
        composer.talkMenu = { [weak screen] in screen.map { TalkMenus.optionsMenu(for: $0) } }
        composer.onTalkOptions = { [weak screen] in screen.map { TalkMenus.presentOptionsList(from: $0) } }
        // The + menu's Voice Memo and Talk (§5.4), each left out when it could not work here.
        if let plus = screen.attachments?.plusMenu {
            plus.register(.memo) { [weak self] in self?.plusItems().memo ?? [] }
            plus.register(.talk) { [weak self] in self?.plusItems().talk ?? [] }
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(talkChanged), name: TalkController.didChange, object: nil)
        center.addObserver(self, selector: #selector(levelChanged), name: TalkController.levelChanged, object: nil)
        center.addObserver(self, selector: #selector(pillChanged), name: TalkAwayPill.changed, object: nil)
        refresh(animated: false)
    }

    func screenAppeared() {
        isOnScreen = true
        controller.setFront(chat, onScreen: true)
        refresh(animated: false)
        learnVoiceSettings()
    }

    /// The voice options menu says "Speech to Text is off" from what is already known (§5.2), so the bot's voice
    /// settings are asked for once when its chat shows (they are kept a minute). DECISION: the web has them in its
    /// store by then; here an unknown would read as on until the first conversation.
    private func learnVoiceSettings() {
        guard allowsTalk, let chat else { return }
        let client = chat.voiceClient, profile = chat.profile.isEmpty ? nil : chat.profile
        // [gpt-live] whether GPT-Live can run for this bot: the voice options menu offers the engine only then
        if VoiceGateway.knownLiveStatus(client: client, profile: profile) == nil {
            Task { _ = await VoiceGateway.liveStatus(client: client, profile: profile) }
        }
        // [grok-live] asked only on a device that chose it (no gateway mode names it)
        if TalkController.chosenEngine == .grokLive, VoiceGateway.knownGrokStatus(client: client, profile: profile) == nil {
            Task { _ = await VoiceGateway.grokStatus(client: client, profile: profile) }
        }
        guard VoiceGateway.knownConfig(client: client, profile: profile) == nil else { return }
        Task { TalkController.gatewayVoiceRead(await VoiceGateway.config(client: client, profile: profile)) }
    }

    func screenLeft() {
        guard isOnScreen else { return }
        isOnScreen = false
        if chat?.canReopen == false {
            // Nothing could lead back to a brand-new chat with no saved id: its conversation and notice end here.
            if isLiveHere { controller.end() }
            for key in scopes { controller.dismissNotice(scope: key) }
        }
        for key in scopes { controller.clearEndedCaption(scope: key) }
        controller.setFront(chat, onScreen: false)
    }

    // MARK: Start

    /// Every way in ends here (§5): the intro once, then the conversation.
    func beginTalk() {
        guard isOnScreen, allowsTalk, !isLiveHere, let voice else { return }
        // Tapping Talk retires its tip (§5.1); any tip showing leaves before anything else is presented.
        MemoTips.finish(.talk)
        voice.retireTip { [weak self] in self?.offerIntroOrStart() }
    }

    private func plusItems() -> (memo: [UIMenuElement], talk: [UIMenuElement]) {
        guard let screen, let composer else { return ([], []) }
        return TalkMenus.plusItems(micAvailable: composer.micAvailable && composer.isEnabled && !composer.memoActive && !composer.dictating,
                                   talkAllowed: allowsTalk && !isLiveHere, name: name,
                                   memo: { [weak screen] in screen?.beginMemo(handsFree: true) },
                                   talk: { [weak screen] in screen?.beginTalk() })
    }

    private func offerIntroOrStart() {
        guard let screen, isOnScreen, allowsTalk, !isLiveHere else { return }
        if TalkIntroSheet.seen {
            start()
            return
        }
        if TalkIntroSheet.present(.intro, name: name, from: screen, onStart: { [weak self] in self?.start() }) { return }
        // Another presentation is in flight: one retry, then voice starts anyway and the key stays unset (§5.3).
        guard !introRetry else { introRetry = false; start(); return }
        introRetry = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.introRetry else { return }
            self.offerIntroOrStart()
            self.introRetry = false
        }
    }

    private func start() {
        guard let chat, isOnScreen, allowsTalk else { return }
        for key in scopes where MemoController.shared.notice(for: key) != nil { MemoController.shared.dismissNotice(scope: key) }
        controller.start(in: chat, name: name)
    }

    /// How Voice Works (the voice options menu, Settings).
    func showHowVoiceWorks() {
        guard let voice else { return }
        voice.retireTip { [weak self] in
            guard let self, let screen = self.screen else { return }
            TalkIntroSheet.present(.info, name: self.name, from: screen)
        }
    }

    // MARK: The empty chat's intro (§5.6)

    /// The bot behind this chat, when the roster knows it (a chat whose bot record is unknown has none).
    private var bot: Bot? {
        guard let screen, let model = TalkWiring.model, model.botEditing != nil else { return nil }
        let profile = screen.session.profile
        return model.botStore?.bot(named: profile.isEmpty ? "default" : profile)
    }

    func intro() -> ChatPlaceholderView.Intro {
        let bot = self.bot
        let about = bot.flatMap { TalkWiring.model?.botStore?.rowDescription($0.id) }
        return ChatPlaceholderView.Intro(role: bot?.role, about: about, talk: allowsTalk, info: bot != nil)
    }

    func showBotInfo() {
        guard let screen, let bot, let model = TalkWiring.model, screen.presentedViewController == nil else { return }
        BotInfoSheet.present(bot: bot, from: screen, services: model)
    }

    // MARK: Typed sends

    /// Called for every typed send. True: it was a bare stop phrase that ended a live conversation and must not go out.
    func typedSend(_ text: String, hasAttachments: Bool) -> Bool {
        for key in scopes { controller.clearEndedCaption(scope: key) }
        return controller.interceptsTyped(text: text, attachments: hasAttachments ? 1 : 0)
    }

    // MARK: Drawing

    @objc private func talkChanged() { refresh(animated: true) }

    /// The pill came or went over this chat: the list keeps its newest message clear of it.
    @objc private func pillChanged() {
        guard isOnScreen, let screen, screen.isViewLoaded else { return }
        guard !HQMotion.reduced else { return screen.view.setNeedsLayout() }
        UIView.animate(withDuration: 0.25) {
            screen.view.setNeedsLayout()
            screen.view.layoutIfNeeded()
        }
    }

    /// The list's bottom edge while the pill floats over this chat (52 pt more).
    func pillTop(base: CGFloat) -> CGFloat {
        isOnScreen && TalkAwayPill.isShowing ? base - TalkAwayPill.clearance : base
    }

    @objc private func levelChanged() {
        guard let dock, isLiveHere else { return }
        dock.setLevel(controller.visualLevel)
    }

    /// A bot's question took the dock's place (T12): the conversation mutes itself until it is answered.
    func questionDockChanged(_ shown: Bool) {
        guard shown != questionShown else { return }
        questionShown = shown
        controller.questionWaiting(shown, in: chat)
    }

    func refresh(animated: Bool) {
        guard let screen, screen.isViewLoaded else { return }
        let animate = animated && isOnScreen
        if isLiveHere, let view = controller.view {
            let card = dock ?? makeDock()
            noticeDock = nil
            card.render(view, muted: controller.live?.state.muted ?? false, problem: controller.problem, elapsed: controller.elapsed)
            screen.setDock(card, for: .voice, animated: animate)
            if questionShown { controller.questionWaiting(true, in: chat) }
        } else if let notice = scopes.lazy.compactMap({ self.controller.notice(for: $0) }).first {
            dock = nil
            let card = noticeDock ?? makeNoticeDock()
            card.show(notice)
            screen.setDock(card, for: .voice, animated: animate)
        } else if dock != nil || noticeDock != nil {
            dock = nil
            noticeDock = nil
            screen.setDock(nil, for: .voice, animated: animate)
        }
        // A tip pointing at the circle has nothing to point at once a dock is in the composer's place.
        if dock != nil || noticeDock != nil { voice?.memoDismissTip() }
        let words = scopes.lazy.compactMap { self.controller.endedCaption(for: $0) }.first
        if words != caption.text || caption.isHidden != (words == nil) {
            caption.text = words
            caption.isHidden = words == nil
            if let words, isOnScreen { HQAnnounce.say(words) }
            screen.view.setNeedsLayout()
        }
        updateTalkAvailable()
    }

    /// Talk shows in the circle when a conversation could start here and nothing voice-related is already in the way
    /// (§5.1). The composer applies the rest of the order (text, a running reply).
    func updateTalkAvailable() {
        guard let composer else { return }
        composer.talkAvailable = allowsTalk && dock == nil && noticeDock == nil && !composer.memoActive && !composer.dictating
    }

    // MARK: [live words] What the person is saying, on the bar's top row (docs/spec/3x-live-words.md §4)

    private var words = LiveWordsText()

    /// This chat's conversation heard new words (empty: none to show).
    func showWords(_ words: LiveWordsText) {
        self.words = words
        guard let dock, let screen, dock.showWords(words), dock.window != nil else { return }
        HQMotion.animate(0.2, changes: { screen.view.layoutIfNeeded() })
    }

    private func makeDock() -> TalkBarView {
        let bar = TalkBarView(name: name)
        bar.showWords(words)
        bar.onMute = { TalkController.shared.toggleMute() }
        bar.onCenter = { TalkController.shared.centerTapped() }
        bar.onEnd = { TalkController.shared.end() }
        bar.problemDetail = { TalkController.shared.problemDetail }
        dock = bar
        return bar
    }

    private func makeNoticeDock() -> TalkNoticeDock {
        let card = TalkNoticeDock()
        card.onPrimary = { [weak self] action in self?.noticeAction(action) }
        card.onDone = { [weak self] in
            guard let self else { return }
            for key in self.scopes { self.controller.dismissNotice(scope: key) }
        }
        noticeDock = card
        return card
    }

    private func noticeAction(_ action: TalkNotice.Action) {
        switch action {
        case .resume, .tryAgain:
            // An explicit start always clears a stale pause.
            for key in scopes { controller.dismissNotice(scope: key) }
            beginTalk()
        case .openSettings:   // the microphone, refused ([mac] Mac polish #11: its Privacy pane on the Mac)
            PrivacySettingsLink.open(.microphone)
        }
    }

    // MARK: The ended caption

    /// The screen asks where the transcript ends: the caption sits above everything above the composer.
    func captionTop(base: CGFloat) -> CGFloat {
        captionBase = base
        return caption.isHidden ? base : base - Self.captionHeight
    }

    private static let captionHeight: CGFloat = 26

    func layout() {
        guard let screen, !caption.isHidden else { return }
        let width = screen.view.bounds.width - 32
        caption.frame = CGRect(x: 16, y: captionBase - Self.captionHeight + 2, width: max(0, width), height: Self.captionHeight - 6)
    }

    #if DEBUG
    var debugDock: TalkBarView? { dock }
    var debugNoticeDock: TalkNoticeDock? { noticeDock }
    #endif
}
