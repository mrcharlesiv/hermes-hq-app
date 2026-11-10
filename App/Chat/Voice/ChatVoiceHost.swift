// Voice memos on one chat screen (spec 1x-voice §3): wires the composer's mic to `MemoController`, hosts the recorder's
// rows in the field and its floating circle over the screen, the draft chip, the notice card and the tips. Owned by
// `ChatViewController`; everything shared with other streams stays in the screen's few marked VOICE lines.

import UIKit

@MainActor final class ChatVoiceHost: NSObject {
    private weak var screen: ChatViewController?
    private weak var memos: (any ChatVoiceMemos)?
    /// The chat's scope when the screen was built (its rows carry it).
    private let rowScope: String
    /// The chat's scope now: a bot chat opened before its stored id was known learns it after the open.
    var scope: String { memos?.memoScope ?? rowScope }
    let botName: String
    /// The notice card (placed by the screen at the top of its dock).
    let notice = MemoNoticeCard()
    /// The circle, halo and lock capsule (over the whole screen).
    let overlay = MemoRecorderOverlay()
    private let holdRow = MemoHoldRow()
    private let lockedRow = MemoLockedRow()
    private let chip = MemoDraftChip()
    private(set) var isOnScreen = false
    private var appearedAt: CFTimeInterval = 0
    private var pendingTip: MemoTip?
    private var tipTimer: Timer?
    /// [talk] The tip showing (Talk's, or a memo tip): a card in the chat's own view, never a popover
    /// (TalkTipBubble.swift says why).
    private var talkTip: TalkTipBubble?
    /// [ui-sizing 2026-11-09] The Talk tip has shown in this chat: leaving it retires the tip for good (owner: "option B",
    /// show once), so it is the first chat's card and no other's, with or without its ✕.
    private var talkTipShownHere = false
    /// The top of what the Talk tip sits on (the composer, or the notice above it), as the screen last said.
    private var talkTipBase: CGFloat = 0
    /// Each memo's load failure as this screen last drew it.
    private var failureShown: [String: Bool] = [:]
    /// The screen shows or hides the notice card (it moves the dock and the transcript's bottom with it).
    var onNoticeChange: ((_ shown: Bool) -> Void)?

    private var composer: ComposerView? { screen?.composer }
    private var controller: MemoController { MemoController.shared }
    // [talk] Live voice on this screen: Talk in the circle, the dock, its notices (docs/spec/3x-talk.md §5, §6).
    private(set) lazy var talk = ChatTalkHost(screen: screen!, voice: self)
    // [talk] Read Aloud and Read Replies Aloud on this screen (§7).
    private(set) lazy var reader = ChatReadAloudHost(screen: screen!, voice: self)
    /// [talk] Dictation into the field (docs/spec/3x-talk.md §8).
    private(set) lazy var dictation = ChatDictationHost(screen: screen!, voice: self)

    init(screen: ChatViewController) {
        self.screen = screen
        memos = screen.session as? ChatVoiceMemos
        rowScope = (screen.session as? ChatSessionDetails)?.layoutScope ?? screen.session.profile
        botName = ((screen.session as? ChatSessionDetails)?.botName ?? screen.session.title).trimmingCharacters(in: .whitespaces)
        super.init()
        _ = MemoController.shared   // it keeps the chats' memo notices from here on
    }

    /// Voice is offered in a live chat of the signed-in account.
    var isAvailable: Bool { memos != nil && MemoAccountStores.shared.key != nil }

    // MARK: Install

    func install() {
        guard let screen, let composer else { return }
        notice.isHidden = true
        notice.onClose = { [weak self] in self?.dismissNotices() }
        notice.onAction = { [weak self] action in self?.noticeAction(action) }
        screen.view.addSubview(overlay)
        // [talk] Back from the background with a reply still running: the screen is kept awake again (§10.2).
        NotificationCenter.default.addObserver(self, selector: #selector(appCameBack), name: UIScene.willEnterForegroundNotification, object: nil)
        guard isAvailable else { return }
        talk.install()   // [talk]
        reader.install() // [talk]
        dictation.install() // [talk]
        LiveWords.prepare()   // [live words] whether this device can hear words, before the first memo or Talk
        NotificationCenter.default.addObserver(self, selector: #selector(talkWordsChanged), name: TalkController.wordsChanged, object: nil)
        ReadAloudCenter.shared.onFailure = { scope, failure in ChatReadAloudHost.failed(failure, scope: scope) }
        composer.micAvailable = true
        let mic = composer.mic
        mic.onDown = { [weak self] in self?.micDown(a11y: false) }
        mic.onMove = { [weak self] dx, dy in
            guard let self, self.controller.isTarget(self) else { return }
            self.controller.input(.move(dx: Double(dx), dy: Double(dy)))
        }
        mic.onUp = { [weak self] in
            guard let self, self.controller.isTarget(self) else { return }
            self.controller.input(.up(at: CACurrentMediaTime() * 1000))
        }
        mic.onCancel = { [weak self] in
            guard let self, self.controller.isTarget(self) else { return }
            self.controller.input(.pointerCancel)
        }
        mic.onAccessibilityOpen = { [weak self] in self?.micDown(a11y: true) }
        composer.onMemoSend = { [weak self] in self?.primarySend() }
        // [live words] A memo's words fixed in review are the words it carries (spec 3x-live-words §3.1.1).
        composer.onHeardEdited = { [weak self] words in
            guard let self, self.controller.isTarget(self) else { return }
            self.controller.reviseWords(words)
        }
        lockedRow.onDelete = { MemoController.shared.input(.delete) }
        lockedRow.onStop = { MemoController.shared.input(.stop) }
        lockedRow.onPlay = { [weak self] in self?.toggleReviewPlayback() }
        chip.onRemove = { [weak self] in
            guard let self else { return }
            MemoAccountStores.shared.drafts?.set(nil, for: self.scope)
        }
        registerPlayback()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(draftsChanged(_:)), name: MemoDraftStore.didChange, object: nil)
        center.addObserver(self, selector: #selector(noticesChanged(_:)), name: MemoController.noticesChanged, object: nil)
        center.addObserver(self, selector: #selector(playerChanged(_:)), name: MemoPlayer.didChange, object: nil)
        refreshChip()
        refreshNotice()
    }

    // MARK: Screen lifecycle

    func screenAppeared() {
        isOnScreen = true
        appearedAt = CACurrentMediaTime()
        #if DEBUG
        // [talk] The probe's event order shows that nothing records before the chat is on screen (E12f).
        if TalkDebugHooks.probe { VoiceEvents.note("debug: chat on screen") }
        #endif
        refreshTurnHold()   // [talk]
        guard isAvailable else { return }
        registerPlayback()
        refreshChip()
        refreshNotice()
        talk.screenAppeared()   // [talk]
        reader.screenAppeared() // [talk]
        refreshWords()          // [live words] a conversation's words, back on its chat
        // [talk] The Talk tip, once, when no memo tip is waiting (docs/spec/3x-talk.md §5.1).
        if pendingTip == nil, talkTip == nil, talk.allowsTalk, !MemoTips.isDone(.talk) { pendingTip = .talk }
        scheduleTip()
    }

    /// The chat left the screen (popped, another tab, its tab hidden): a take left behind becomes a draft chip here;
    /// a playing memo pauses; this chat's notice goes (spec §3.4, §3.7, §6.4).
    func screenLeft() {
        guard isOnScreen else { return }
        isOnScreen = false
        refreshTurnHold()   // [talk]
        tipTimer?.invalidate()
        tipTimer = nil
        hideTalkTip(finish: false, animated: false)   // [talk] it comes back with the chat
        if talkTipShownHere { MemoTips.finish(.talk); talkTipShownHere = false; if pendingTip == .talk { pendingTip = nil } }
        controller.screenLeft(self)
        MemoPlayer.shared.pause()
        dismissNotices()
        if isAvailable {
            talk.screenLeft()     // [talk] the conversation carries on; the pill leads back
            reader.screenLeft()   // [talk] a reading stops with its chat
            dictation.composerGone()   // [talk] a dictation is thrown away with its chat
        }
        refreshWords()   // [live words] a conversation's words come back with the chat
    }

    /// Integration (verify round 1): a bot's question dock replaced the composer, recorder and all. A take still
    /// recording (or waiting in review) must not go on out of sight: it is kept as this chat's draft chip, as when the
    /// chat is left, and shows above the field when the dock goes.
    func composerCovered() {
        if isAvailable { dictation.composerGone() }   // [talk] nor does a dictation (3x-talk §8)
        guard controller.isActive(for: self) else { return }
        tipTimer?.invalidate()
        tipTimer = nil
        dismissTipNow(finish: false)
        controller.input(.leave)
    }

    /// How this chat's memo bubbles fetch their files (under the rows' scope and the current one).
    private func registerPlayback() {
        if let room = screen?.session as? GroupRoomSession {
            // [groups] A room's memos sit in the default profile's files folder (`GroupRoomSession.sendMemo`).
            MemoPlaybackContexts.register(scope: scope, client: room.memoClient, profile: nil)
            return
        }
        guard let live = screen?.session as? LiveChatSession else { return }
        for key in Set([rowScope, scope]) {
            MemoPlaybackContexts.register(scope: key, client: live.client, profile: live.profileParam)
        }
    }

    /// The circle rides the keyboard: re-measured every layout pass.
    func layout() {
        guard let screen, let composer else { return }
        if overlay.frame != screen.view.bounds { overlay.frame = screen.view.bounds }
        if overlay.superview === screen.view, screen.view.subviews.last !== overlay { screen.view.bringSubviewToFront(overlay) }
        overlay.anchor = composer.convert(composer.micCenter, to: screen.view)
        if holdRow.superview != nil {
            holdRow.circleReachX = holdRow.convert(CGPoint(x: overlay.reachX, y: 0), from: screen.view).x
        }
        if isAvailable {
            talk.layout()     // [talk] the "Voice chat ended" caption
            reader.layout()   // [talk] the Read Aloud strip
            layoutTalkTip()   // [talk]
        }
        layoutWords()   // [live words]
    }

    // [talk] The seams the screen calls (docs/spec/3x-talk.md §5, §6.7).
    func beginTalk() { if isAvailable { talk.beginTalk() } }
    func talkIntro() -> ChatPlaceholderView.Intro { isAvailable ? talk.intro() : ChatPlaceholderView.Intro() }
    func talkShowBotInfo() { if isAvailable { talk.showBotInfo() } }
    func talkPillTop(base: CGFloat) -> CGFloat { isAvailable ? talk.pillTop(base: base) : base }
    /// From the composer up: the Talk tip, the Read Aloud strip, the "Voice chat ended" caption.
    func talkCaptionTop(base: CGFloat) -> CGFloat {
        isAvailable ? talk.captionTop(base: reader.stripTop(base: talkTipTop(base: base))) : base
    }
    func talkTypedSend(_ text: String, hasAttachments: Bool) -> Bool {
        guard isAvailable else { return false }
        reader.messageSent()
        return talk.typedSend(text, hasAttachments: hasAttachments)
    }
    func talkSessionChanged() {
        refreshTurnHold()
        if isAvailable { reader.sessionChanged() }
    }

    // MARK: [talk] The screen stays awake while a reply runs in the chat on screen (docs/spec/3x-talk.md §10.2)

    private var turnHold: KeepAwake.Owner?
    /// Whether the last look wanted the hold; a fresh one (with a fresh ten minutes) is taken only when that changes.
    private var turnWanted = false

    /// Called when the chat appears, leaves, its turn starts or ends, and when the app comes back to the screen.
    func refreshTurnHold(again: Bool = false) {
        let wanted = isOnScreen && screen?.session.isRunning == true
        if wanted, !turnWanted || again {
            if let old = turnHold { KeepAwake.release(old) }
            let hold = KeepAwake.Owner.turn(scope)
            turnHold = hold
            KeepAwake.hold(hold, cap: KeepAwake.turnCap)
        } else if !wanted, let old = turnHold {
            turnHold = nil
            KeepAwake.release(old)
        }
        turnWanted = wanted
    }

    @objc private func appCameBack() { refreshTurnHold(again: true) }
    /// Read Aloud is offered on replies of a chat that can talk (not in a room).
    var talkReadsAloud: Bool { isAvailable && talk.allowsTalk }
    func talkReadButton(rowId: String) -> ReadAloudCenter.Button? { talkReadsAloud ? reader.button(forRow: rowId) : nil }
    func talkToggleRead(rowId: String) { if talkReadsAloud { reader.toggle(rowId: rowId) } }
    func talkToggleRead(messageId: String) { if talkReadsAloud { reader.toggle(messageId: messageId) } }
    /// A folded row's words (a delivery, a finished task): read as given, not as a reply of this chat.
    func talkToggleRead(messageId: String, text: String) { if talkReadsAloud { reader.toggle(messageId: messageId, text: text) } }
    func talkIsReading(messageId: String) -> Bool? { talkReadsAloud ? reader.isReading(messageId: messageId) : nil }
    /// The reply whose words are leaving the speaker in this chat (Read Aloud, Read Replies Aloud, a conversation).
    var talkSpokenMessageId: String? {
        guard isAvailable, let id = ReadAloudCenter.shared.spokenMessageId else { return nil }
        let here = talk.isLiveHere || ReadAloudCenter.shared.scope == scope
        return here ? id : nil
    }
    func talkQuestionDock(shown: Bool) {
        guard isAvailable else { return }
        if shown { dictation.composerGone() }
        talk.questionDockChanged(shown)
    }
    /// The dictation row took the field's place: no tip over it, no Talk in the circle.
    func dictationShown() {
        tipTimer?.invalidate()
        tipTimer = nil
        dismissTipNow(finish: false)
        talk.updateTalkAvailable()
        screen?.view.setNeedsLayout()
    }
    /// The dictation ended: a reply that waited behind it is read (§7.4).
    func dictationEnded() {
        talk.updateTalkAvailable()
        reader.inputEnded()
        screen?.view.setNeedsLayout()
    }

    var canSendMemo: Bool { isOnScreen && (composer?.isEnabled ?? false) }

    // MARK: Mic

    private func target() -> MemoTarget? {
        guard let key = MemoAccountStores.shared.key else { return nil }
        return MemoTarget(scope: scope, host: self, session: memos, botName: botName.isEmpty ? "Hermes" : botName, accountKey: key)
    }

    private func micDown(a11y: Bool) {
        guard let composer, let target = target() else { return }
        controller.memoDown(target, width: Double(composer.bounds.width), a11y: a11y, keyboardUp: composer.textView.isFirstResponder)
    }

    /// The seam for the + menu, Bots "hold › Memo", the Action Button and Siri (spec §2.4): the locked recorder in this
    /// chat (`startMemoIn` → `memoDown(…, {a11y:true})`). Set-aside (typed text going back into the field after the memo
    /// sends on its own) isn't reachable yet: the mic only shows on an empty composer.
    func beginMemo(handsFree: Bool) {
        micDown(a11y: handsFree)
    }

    #if DEBUG
    /// Screenshots (`-HQDebugMemoShot`): a touch-down on the mic without a finger, and review's Play.
    func debugDown() { micDown(a11y: false) }
    func debugPlayReview() { toggleReviewPlayback() }
    #endif

    /// Send: the recorder's (locked, review), or the draft chip's with the field's words.
    private func primarySend() {
        let phase = controller.state.phase
        if controller.isTarget(self), phase == .locked || phase == .review {
            controller.input(.send)
            return
        }
        guard let composer, let drafts = MemoAccountStores.shared.drafts, drafts.draft(for: scope) != nil else { return }
        guard let draft = drafts.take(scope) else { return }
        let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        composer.text = ""
        if MemoPlayer.shared.isCurrent(draft.path) { MemoPlayer.shared.stop() }
        screen?.sendMemo(draft, text: text)
    }

    func memoSend(_ file: MemoFile, keyboardWasUp: Bool) {
        guard let composer else { return }
        // A held memo sent with the keyboard down: nothing raises it by itself (spec §3.8). Only programmatic focus
        // waits (`ChatViewController.focusComposer`); a tap on the field always focuses it.
        if !keyboardWasUp { composer.focusSuppressedUntil = CACurrentMediaTime() + 1.5 }
        screen?.sendMemo(file, text: "")
    }

    // MARK: Recorder state

    func memoStateChanged() {
        guard let composer else { return }
        let active = controller.isActive(for: self)
        let phase = active ? controller.state.phase : .idle
        let shown = active ? controller.shownPhase : .idle
        // While pressing, the mic keeps its pressed look (never red before recording is confirmed).
        composer.memoActive = active && phase != .pressing
        composer.mic.pressed = active && phase == .pressing
        let state = controller.state
        switch phase {
        case .holding:
            composer.recorderContent = holdRow
            composer.memoPrimary = .hidden
            overlay.show()
            layout()
            holdRow.update(seconds: state.seconds, limit: controller.limit, dx: state.dx, armed: state.cancelArmed)
            overlay.move(dx: state.dx, dy: state.dy, lockNear: state.lockNear)
            overlay.setLevel(controller.level)
        case .ending where shown == .holding:
            overlay.hide()
            composer.recorderContent = holdRow
            composer.memoPrimary = .hidden
        case .locked, .ending:
            overlay.hide()
            composer.recorderContent = lockedRow
            composer.memoPrimary = .send(enabled: phase == .locked)
            lockedRow.showLocked(seconds: state.seconds, limit: controller.limit, level: controller.level, levels: controller.levels, ending: phase == .ending)
        case .review:
            overlay.hide()
            composer.recorderContent = lockedRow
            composer.memoPrimary = .send(enabled: true)
            if let file = controller.file { lockedRow.showReview(file: file, ending: false) }
        case .idle, .pressing:
            overlay.hide()
            if !composer.dictating { composer.recorderContent = nil }   // [talk] the dictation row is not the memo's to remove
            composer.memoPrimary = .normal
            if phase == .idle { scheduleTip() }
            if phase == .idle, isAvailable { reader.inputEnded() }   // [talk] a reply that waited behind the take is read
        }
        if phase != .idle && phase != .pressing { dismissTipNow(finish: false) }
        refreshWords()   // [live words]
        talk.updateTalkAvailable()   // [talk] no Talk while a take is on screen
        screen?.view.setNeedsLayout()
    }

    /// The light path, within one phase (a finger's move, the clock's tick, a level): only the recorder's row and the
    /// circle redraw; the screen doesn't lay out again.
    func memoLevelChanged() {
        guard controller.isActive(for: self) else { return }
        let state = controller.state
        switch state.phase {
        case .holding:
            holdRow.update(seconds: state.seconds, limit: controller.limit, dx: state.dx, armed: state.cancelArmed)
            overlay.move(dx: state.dx, dy: state.dy, lockNear: state.lockNear)
            overlay.setLevel(controller.level)
        case .locked:
            lockedRow.showLocked(seconds: state.seconds, limit: controller.limit, level: controller.level, levels: controller.levels, ending: false)
        default:
            break
        }
    }

    // MARK: [live words] The words as you speak (docs/spec/3x-live-words.md §4)

    /// The memo's words changed.
    func memoWordsChanged() { refreshWords() }

    @objc private func talkWordsChanged() { refreshWords() }

    /// The memo's words, in the composer's top row while it records (and in its review): nil for none. While
    /// recording with nothing heard yet, "Listening…" holds their place; once it stops, only words keep the row.
    private var memoHeard: ComposerView.Heard? {
        guard controller.isActive(for: self) else { return nil }
        let words = controller.words
        switch controller.state.phase {
        case .holding, .locked:
            let listening = controller.hearsWords
            return listening || !words.isEmpty ? ComposerView.Heard(words: words, listening: listening) : nil
        case .ending:
            return words.isEmpty ? nil : ComposerView.Heard(words: words, listening: false)
        case .review:
            // Fixable: a tap puts a caret in them. Kept while being fixed even when every word is gone.
            let fixing = composer?.heardView.isEditingWords == true
            return words.isEmpty && !fixing ? nil : ComposerView.Heard(words: words, listening: false, editable: true)
        case .idle, .pressing:
            return nil
        }
    }

    /// This chat's conversation's words, for the Talk bar's top row.
    private var talkWords: LiveWordsText {
        guard isAvailable, talk.isLiveHere, talk.isOnScreen else { return LiveWordsText() }
        return TalkController.shared.words(in: talk.chat)
    }

    /// The words row follows the memo's words, or [live words] this chat's dictation's (one at a time: the mic and
    /// Dictate never both run).
    func refreshWords() {
        composer?.heard = memoHeard ?? (isAvailable ? dictation.heard : nil)
        if isAvailable { talk.showWords(talkWords) }
        layoutWords()
    }

    /// While a memo is held the words stop short of the recorder's circle and the lock above it; once locked (or in
    /// review) they have the bar's width.
    private func layoutWords() {
        guard let screen, let composer else { return }
        let phase = controller.isActive(for: self) ? controller.state.phase : .idle
        let held = phase == .holding || (phase == .ending && controller.shownPhase == .holding)
        composer.heardLimitX = held ? composer.convert(CGPoint(x: overlay.anchor.x - 64, y: 0), from: screen.view).x : nil
    }

    /// Locked hands-free: the keyboard goes, VoiceOver moves to the status (spec §3.8).
    func memoFocusStatus() {
        composer?.textView.resignFirstResponder()
        DispatchQueue.main.async { [lockedRow] in
            HQAnnounce.layoutChanged(lockedRow.statusElement)
        }
    }

    func memoConfirmDelete(seconds: Double, recording: Bool, answer: @escaping (Bool) -> Void) {
        guard let screen, screen.presentedViewController == nil else { answer(false); return }
        // A take still recording names the length its timer shows; a finished one its rounded total.
        let length = recording ? MemoPolicy.length(seconds) : MemoPolicy.total(seconds)
        let alert = UIAlertController(title: "Delete This \(length) Voice Memo?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: recording ? "Keep Recording" : "Keep", style: .cancel) { _ in answer(false) })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in answer(true) })
        alert.view.accessibilityIdentifier = "memo.confirm-delete"
        screen.present(alert, animated: true)
    }

    private func toggleReviewPlayback() {
        guard let file = controller.file else { return }
        let path = file.path
        MemoPlayer.shared.toggle(path) {
            guard FileManager.default.fileExists(atPath: path) else { throw HTTPError(status: 404, body: "missing") }
            return URL(fileURLWithPath: path)
        }
    }

    // MARK: Draft chip

    /// Any chat's draft changed: this chat's chip follows its own (a lookup; a draft kept under the chat's earlier
    /// scope is found too).
    @objc private func draftsChanged(_ note: Notification) {
        refreshChip()
    }

    private func refreshChip() {
        guard let composer, isAvailable else { return }
        if let draft = memos?.memoDraft {
            chip.show(draft)
            if composer.memoChip !== chip { composer.memoChip = chip } else { composer.setNeedsLayout() }
            // A queued memo handed back when its chat was left brings the words typed beside it into an empty field.
            if let drafts = MemoAccountStores.shared.drafts, let words = drafts.text(for: scope), composer.text.isEmpty {
                composer.text = words
                drafts.clearText(for: scope)
            }
        } else if composer.memoChip != nil {
            composer.memoChip = nil
        }
    }

    // MARK: Notices

    /// This chat's notices: under its scope now, or the one it had when the screen was built (a take begun before a
    /// new chat learned its stored id).
    private var noticeScopes: [String] { rowScope == scope ? [scope] : [scope, rowScope] }

    @objc private func noticesChanged(_ note: Notification) {
        guard let changed = note.userInfo?["scope"] as? String, noticeScopes.contains(changed) else { return }
        refreshNotice()
    }

    private func refreshNotice() {
        if let current = noticeScopes.lazy.compactMap({ self.controller.notice(for: $0) }).first {
            if notice.notice != current { notice.show(current) }
            if notice.isHidden { onNoticeChange?(true) }
        } else if !notice.isHidden {
            onNoticeChange?(false)
        }
    }

    /// A memo is going out from this chat: a "Saved as a Draft" card here is dealt with (a send that fails again posts
    /// a new one).
    func memoSending() {
        for key in noticeScopes where controller.notice(for: key)?.draft == true { controller.dismissNotice(scope: key) }
    }

    private func dismissNotices() {
        for key in noticeScopes where controller.notice(for: key) != nil { controller.dismissNotice(scope: key) }
    }

    private func noticeAction(_ action: MemoNotice.Action) {
        dismissNotices()
        switch action {
        case .openSettings:   // the microphone, refused ([mac] Mac polish #11: its Privacy pane on the Mac)
            PrivacySettingsLink.open(.microphone)
        case .retry:
            beginMemo(handsFree: true)
        case .retryTalk:          // [talk]
            talk.beginTalk()
        case .voiceSettings:      // [talk]
            if let screen { TalkMenus.openVoiceSettings(from: screen) }
        case .retryDictation:     // [talk]
            dictation.begin()
        }
    }

    // MARK: Playback

    @objc private func playerChanged(_ note: Notification) {
        let path = note.userInfo?[MemoPlayer.pathKey] as? String
        if controller.isActive(for: self), controller.state.phase == .review, let file = controller.file, path == nil || path == file.path {
            lockedRow.showReview(file: file, ending: false)
        }
        guard let path, let screen else { return }
        // A memo whose file couldn't be fetched says so on its own line (or stops saying so after Retry).
        let failed = MemoLoadFailures.contains(path)
        guard failureShown[path] != failed else { return }
        failureShown[path] = failed
        screen.voiceRebuildMessages { message in
            guard message.role == .user, let text = message.plainTextIfMemo else { return false }
            return VoiceMemo.parse(text)?.path == path
        }
    }

    // MARK: Tips

    func memoShowTip(_ tip: MemoTip) {
        guard !MemoTips.isDone(tip) else { return }
        pendingTip = tip
        scheduleTip()
    }

    func memoDismissTip() {
        pendingTip = nil
        dismissTipNow(finish: false)
    }

    /// Takes the tip off the screen. Unless it is finished (closed, or its lesson learned), it shows again at the next
    /// settle.
    /// [talk] Talk was tapped, or a voice sheet is about to open: whatever tip shows leaves first, then `done` runs.
    /// Every tip is a card in the chat (never a popover that would refuse the sheet): it is in nothing's way, it just
    /// leaves.
    func retireTip(then done: @escaping () -> Void) {
        hideTalkTip(finish: false)
        if pendingTip == .talk, MemoTips.isDone(.talk) { pendingTip = nil }
        done()
    }

    private func dismissTipNow(finish: Bool) {
        hideTalkTip(finish: finish)
    }

    /// Shown only when the mic is visible, nothing records, the chat has settled (0.7 s after it appears) and the jump
    /// button isn't showing (voice-extras.tsx:40-41,70-78), nor while a task's page holds the task's top. Never times out.
    private func scheduleTip() {
        guard pendingTip != nil, isOnScreen else { return }
        tipTimer?.invalidate()
        let wait = max(0.05, appearedAt + 0.7 - CACurrentMediaTime())
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.showTipIfReady() } }
        RunLoop.main.add(timer, forMode: .common)
        tipTimer = timer
    }

    private func showTipIfReady() {
        tipTimer = nil
        guard let tip = pendingTip, !MemoTips.isDone(tip), let screen, let composer, isOnScreen,
              controller.state.phase == .idle || !controller.isTarget(self),
              tip == .talk ? composer.primary == .talk : !composer.mic.isHidden,       // [talk] its tip points at the circle
              !screen.isJumpButtonShown, !screen.holdsLeadTop, screen.presentedViewController == nil else {
            if pendingTip == .talk, MemoTips.isDone(.talk) { pendingTip = nil }
            if pendingTip != nil, isOnScreen { scheduleTipLater() }
            return
        }
        // A memo tip showing keeps its place over the Talk tip (it earned its moment, voice-extras.tsx).
        if tip == .talk, let shown = talkTip, shown.tip != .talk { return }
        showTipCard(tip)
    }

    // MARK: [talk] The tips, in place (docs/spec/3x-talk.md §5.1)

    /// VoiceOver hears each tip once per app run, not every time it comes back (after typing, the jump button, in
    /// another chat).
    private static var announcedTips: Set<MemoTip> = []

    private func showTipCard(_ tip: MemoTip) {
        guard let screen else { return }
        if let shown = talkTip {
            guard shown.tip != tip else { pendingTip = nil; return }
            hideTalkTip(finish: false, animated: false)   // a memo tip earns its moment over the Talk tip (voice-extras.tsx)
        }
        let bubble = TalkTipBubble(tip: tip, name: talk.name)
        if tip == .talk { talkTipShownHere = true }
        ThemeChrome.followCorners(bubble)   // [desktop-corners] docked on the text box
        bubble.onClose = { [weak self] in self?.hideTalkTip(finish: true) }   // closed: done for good
        pendingTip = nil
        talkTip = bubble
        screen.view.insertSubview(bubble, belowSubview: screen.composer)
        layoutTalkTip()
        bubble.alpha = 0
        if HQMotion.reduced { screen.view.setNeedsLayout(); screen.view.layoutIfNeeded() }   // the list is simply at its new place; the tip fades
        UIView.animate(withDuration: 0.2) {
            bubble.alpha = 1
            screen.view.setNeedsLayout()   // the transcript's end makes room
            screen.view.layoutIfNeeded()
        }
        if Self.announcedTips.insert(tip).inserted { HQAnnounce.say(bubble.spoken) }
    }

    /// Takes the tip away. Not finished, it waits for the next settle.
    private func hideTalkTip(finish: Bool, animated: Bool = true) {
        guard let bubble = talkTip else { return }
        if finish { MemoTips.finish(bubble.tip) }
        talkTip = nil
        bubble.onClose = nil
        if !MemoTips.isDone(bubble.tip) { pendingTip = pendingTip ?? bubble.tip }
        guard animated, let screen, isOnScreen else {
            bubble.removeFromSuperview()
            screen?.view.setNeedsLayout()
            return
        }
        if HQMotion.reduced { screen.view.setNeedsLayout(); screen.view.layoutIfNeeded() }   // the list is simply at its new place; the tip fades
        UIView.animate(withDuration: 0.2, animations: {
            bubble.alpha = 0
            screen.view.setNeedsLayout()
            screen.view.layoutIfNeeded()
        }, completion: { _ in bubble.removeFromSuperview() })
    }

    /// The circle stopped being what the tip names (words in the field, a take, a dock: Talk for the Talk tip, the
    /// mic for a memo tip) or the jump-to-latest button came, which sits where the tip does: the tip steps aside until
    /// that passes (ui-kit/tip.tsx `yieldTo`).
    /// Asked from inside the composer's and the screen's own updates, so the card leaves on the next turn of the main
    /// loop (its leaving lays the screen out).
    func talkTipCheck() {
        guard talkTip != nil, !talkTipCheckQueued, talkTipYields else { return }
        talkTipCheckQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.talkTipCheckQueued = false
                guard self.talkTip != nil, self.talkTipYields else { return }
                self.hideTalkTip(finish: false)
                if self.isOnScreen, self.pendingTip != nil { self.scheduleTipLater() }
            }
        }
    }

    private var talkTipCheckQueued = false
    private var talkTipYields: Bool {
        guard let screen, let composer, let shown = talkTip else { return true }
        let away = shown.tip == .talk ? composer.primary != .talk : composer.mic.isHidden
        return away || screen.isJumpButtonShown
    }

    private func talkTipFrame(base: CGFloat) -> CGRect? {
        guard let screen, let bubble = talkTip else { return nil }
        // [ui-hunt] On the composer's edges, like the other cards docked above it (it sat 16 pt from the right at
        // 320 pt wide, lined up with nothing).
        let bounds = screen.view.bounds, safe = screen.view.safeAreaInsets
        let side = screen.composer.currentSideInset - screen.composer.boxOutset   // [desktoplook2] the one box's edges
        let width = max(120, bounds.width - safe.left - safe.right - 2 * side)
        // At most about a third of the chat, and never under the top bar (at AX5 it covered the whole chat).
        let top = safe.top + 8
        let limit = max(120, (base - safe.top) * 0.35)
        let height = bubble.height(for: width, limit: limit)
        return CGRect(x: safe.left + side, y: max(top, base - height - 8), width: width, height: height)
    }

    /// [mac] Stress test 2026-10-28 round 8: the room the tip adds above itself on the Mac (7 + the transcript's own 7 = the bubbles' 14).
    private static let macTipGap: CGFloat = 7

    /// The screen asks where the transcript ends: above the tip while it shows.
    private func talkTipTop(base: CGFloat) -> CGFloat {
        talkTipBase = base
        guard let top = talkTipFrame(base: base)?.minY else { return base }
        // [mac] Stress test 2026-10-28 round 8: the last bubble stood 7 pt over the tip's card, against about 14 between
        // bubbles; on the Mac it keeps the bubbles' gap.
        return DeviceWord.isMac ? top - Self.macTipGap : top
    }

    private func layoutTalkTip() {
        guard let bubble = talkTip, let frame = talkTipFrame(base: talkTipBase), bubble.frame != frame else { return }
        bubble.frame = frame
    }

    private func scheduleTipLater() {
        tipTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.showTipIfReady() } }
        RunLoop.main.add(timer, forMode: .common)
        tipTimer = timer
    }
}

private extension ChatMessage {
    /// The message's text when it may be a memo (cheap check first).
    var plainTextIfMemo: String? {
        for part in parts {
            if case .text(let t) = part, t.contains("MEDIA:\"") { return t }
        }
        return nil
    }
}
