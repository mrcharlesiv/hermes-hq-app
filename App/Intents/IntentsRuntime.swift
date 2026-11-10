// What happens after a shortcut asked for a voice note (docs/spec/3x-intents.md §7, §8; a port of the web's
// W:src/action-voice-runtime.ts): one delivery at a time, the newest request wins, the bot's own chat opens, the
// recorder starts hands-free in that chat and no other, and the request is acknowledged whether it started or failed
// ("A failed shortcut must not spontaneously record on a later foreground event."). Also brings a voice note an older
// build left behind into its bot's chat as a memo draft. Everything it needs from the app comes through `IntentsHost`,
// so the unit tests run it with a fake.

import Foundation
import Intents

/// The app as the runtime sees it.
@MainActor protocol IntentsHost: AnyObject {
    /// `url + "\n" + username` of the signed-in account; nil when signed out.
    var account: String? { get }
    /// The app is on screen and active.
    var isActive: Bool { get }
    /// A scene of the app is in the foreground, active or about to be. A scene callback can precede the app's own
    /// active state (W:ios/App/App/VoiceNoteIntent.swift: "Scene callbacks can precede UIApplication's aggregate
    /// active state"), so a kick that finds the app in front but not yet active waits for it.
    var isForeground: Bool { get }
    /// A cold launch the system ran a shortcut on after the scene connected: the last chat is not reopened under (or
    /// instead of) the shortcut's chat.
    func cancelLaunchRestore()
    /// Signed in and the tabs are in a window.
    var isReady: Bool { get }
    var rosterLoaded: Bool { get }
    func bot(forKey key: String) -> Bot?
    /// One roster read; returns when it answered or failed.
    func refreshRoster() async
    /// The pickers' catalog follows the roster just read.
    func syncCatalog()
    /// The bot's own chat on top of the Bots tab; nil when it did not come on screen within 3 s. Throws `IntentsKept`
    /// when a sheet holding unsaved edits was kept (UX study #263).
    func openBotChat(_ bot: Bot) async throws -> (any IntentsChat)?
    /// The memo recorder: whether a take is in progress, and its bot's key (nil for a chat that is no bot's own).
    var takeInProgress: (key: String?, active: Bool) { get }
    /// Milliseconds since 1970.
    func now() -> Double
    func sleep(ms: Int) async
    /// DECISION I8: one alert at a time; a newer one replaces it.
    func show(_ notice: IntentsNoticeContent)
    func dismissNotice()
    /// The notice is still on screen.
    func isShowing(_ notice: IntentsNoticeContent) -> Bool

    // The saved older-build note (§8).
    /// Where the note's recording really is, nil when it is not a file of ours (`LegacyNoteFile.resolve`).
    func noteFile(_ path: String) -> URL?
    /// Copies the recording into the memo folder and measures it; nil when that failed.
    func importNote(_ file: URL) async -> MemoFile?
    /// Makes `memo` the chat's draft; false when the draft store does not hold it afterwards.
    func setDraft(_ memo: MemoFile, scope: String) -> Bool
    /// An imported copy that was not attached after all.
    func discard(_ memo: MemoFile)
    func delete(_ file: URL)

    // Home Screen quick actions (§9.4).
    /// The profile of a chat the Sessions list holds, nil when it does not hold that id.
    func sessionProfile(_ stored: String) -> String?
    /// Opens a listed chat: on top (≤ 3 s) and, when the gateway answers quickly (≤ 4 s more) that it no longer has
    /// the chat, closed again.
    func openSessionChat(stored: String, profile: String) async -> IntentsSessionOpen
    /// Opens a group chat by its room key, as a tapped alert does; `.gone` when this gateway has no such room (UX study #265).
    func openRoom(_ key: String) async -> IntentsSessionOpen
    /// The Sessions tab with its search field focused and empty (DECISION I6).
    func openSearch()
}

/// How opening a listed chat (or a group chat, by its room key) ended (§9.4).
nonisolated enum IntentsSessionOpen: Equatable, Sendable {
    case opened
    /// No chat with that id was on top 3 s later.
    case failed
    /// The gateway no longer has it: the screen was closed again, so no blank or stale chat is left on show.
    case gone
    /// A sheet holding unsaved edits asked first and the owner kept it (UX study #263): nothing opened, nothing to say.
    case kept
}

/// The app left the screen while a chat was being opened for a shortcut or a saved note.
nonisolated struct IntentsAway: Error {}

/// A sheet holding unsaved edits asked before a chat opened, and the owner kept editing (UX study #263): the owner's
/// own choice, so no failure is said.
nonisolated struct IntentsKept: Error {}

/// A quick action in front and signed in, with the tabs not up after 10 s (offline, a stalled launch; UX study #264):
/// it is held and runs if they come up within `IntentsRuntime.replayCap`.
nonisolated struct IntentsNotConnected: Error {}

/// A chat screen the runtime may record in.
@MainActor protocol IntentsChat: AnyObject {
    /// `"ios-direct::<profile>"` for a bot's own chat, else nil.
    var botKey: String? { get }
    /// Still the top screen of the selected tab, in a window.
    var isTop: Bool { get }
    /// The composer can take a memo now.
    var composerReady: Bool { get }
    /// The memo draft store's key.
    var scope: String { get }
    func beginHandsFreeMemo()
}

/// One alert (DECISION I8, §8.2, §8.4, §9.4).
nonisolated struct IntentsNoticeContent: Equatable, Sendable {
    enum Choice: String, Sendable { case ok, openChat, discardAndRecord, cancel, recover, discard }
    enum Role: Sendable { case plain, preferred, destructive, cancel }
    enum Haptic: Sendable { case none, warning, error }
    struct Button: Equatable, Sendable {
        let choice: Choice
        let title: String
        let role: Role
    }
    var title: String
    var message: String?
    var buttons: [Button]
    var haptic: Haptic

    static let okButton = Button(choice: .ok, title: IntentsText.ok, role: .cancel)

    /// §7.4.
    static func voiceNote(_ message: String) -> IntentsNoticeContent {
        IntentsNoticeContent(title: IntentsText.voiceNoteTitle, message: message, buttons: [okButton], haptic: .warning)
    }
    /// §8.2.
    static func savedNote(bot: String) -> IntentsNoticeContent {
        IntentsNoticeContent(title: IntentsText.savedNoteTitle, message: IntentsText.savedNoteWaiting(bot),
                             buttons: [Button(choice: .openChat, title: IntentsText.openChat, role: .preferred),
                                       Button(choice: .discardAndRecord, title: IntentsText.discardAndRecord, role: .destructive),
                                       Button(choice: .cancel, title: IntentsText.cancel, role: .cancel)],
                             haptic: .none)
    }
    /// §8.4.
    static func recovery(_ message: String, retry: Bool) -> IntentsNoticeContent {
        IntentsNoticeContent(title: IntentsText.savedNoteTitle, message: message,
                             buttons: retry ? [Button(choice: .recover, title: IntentsText.recoverRecording, role: .preferred),
                                               Button(choice: .discard, title: IntentsText.discardRecording, role: .destructive),
                                               Button(choice: .cancel, title: IntentsText.cancel, role: .cancel)] : [okButton],
                             haptic: .warning)
    }
    /// §9.4.
    static func shortcut(_ message: String?) -> IntentsNoticeContent {
        IntentsNoticeContent(title: message == nil ? IntentsText.shortcutUnknownTitle : IntentsText.shortcutTitle, message: message,
                             buttons: [okButton], haptic: .error)
    }
}

/// A sentence for the owner (§7.4, §8.3, §9.4).
nonisolated struct IntentsFailure: Error, Equatable, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

@MainActor final class IntentsRuntime {
    static let shared = IntentsRuntime()

    /// The app (set once the account activates; a fake in tests).
    weak var host: (any IntentsHost)?
    let store: VoiceNoteRequestStore
    let defaults: UserDefaults
    /// What happened, in order ("open ivy", "memo started ivy", "ack <id>", "notice <text>"): the DEBUG state file and
    /// the tests read it.
    var onEvent: ((String) -> Void)?

    private(set) var busy = false
    private var again = false
    private var latestRequestId: String?
    private(set) var started: Set<String> = []
    /// A saved older-build note could not be brought in during this run (its bot left the roster, the copy failed):
    /// it is not tried again by itself on every foreground. "Recover recording" still tries.
    private var legacyFailedThisRun = false
    /// A delivery is waiting for the app to become active (one waits; the others leave it to that one).
    private var awaitingActive = false
    /// §8.2: the owner is being asked about this note and this request.
    private var asking: (note: PendingVoiceNote, request: VoiceNoteRequest, notice: IntentsNoticeContent)?
    /// Deliveries started and not yet returned, the most that ever overlapped, and how many got past the gate (the
    /// stress checks read them: one at a time, and a burst of triggers costs one delivery more, not fifty).
    private(set) var deliveriesRunning = 0
    private(set) var mostOverlapping = 0
    private(set) var deliveries = 0
    /// Counts sign-outs and account changes: work that was in flight across one says nothing afterwards.
    private var signIns = 0

    init(store: VoiceNoteRequestStore = VoiceNoteRequestStore(defaults: .standard), defaults: UserDefaults = .standard,
         host: (any IntentsHost)? = nil) {
        self.store = store
        self.defaults = defaults
        self.host = host
    }

    // MARK: Triggers

    /// A shortcut wrote a request (also every foreground, and the account activating): deliver it when the app is up.
    func kick() { Task { await deliver() } }

    /// Sign-out or a different account: nothing waits any more.
    func reset() {
        signIns += 1
        store.clear()
        latestRequestId = nil
        asking = nil
        again = false
        legacyFailedThisRun = false
        started = []
        host?.dismissNotice()
    }

    // MARK: Delivery (§7.2)

    func deliver(explicitRecovery: Bool = false) async {
        guard let host else { return }
        guard store.pending != nil || VoiceBotCatalog.pendingNote(defaults) != nil else { return }
        // The system may run a shortcut after the scene of a cold launch connected, when nothing told the scene.
        if store.pending != nil { host.cancelLaunchRestore() }
        if !host.isActive {
            // In the background: the next foreground delivers. In front and about to be active (the Action Button on
            // an app that was not running): wait for it, 2 s at most, so the kick is not lost.
            guard store.pending != nil, host.isForeground, !awaitingActive else { return }
            awaitingActive = true
            defer { awaitingActive = false }
            for _ in 0..<20 where !host.isActive && host.isForeground { await host.sleep(ms: 100) }
            guard host.isActive, store.pending != nil else { return }
        }
        if busy {
            again = true
            if let id = store.pending?.id { latestRequestId = id }
            return
        }
        busy = true
        deliveriesRunning += 1
        deliveries += 1
        mostOverlapping = max(mostOverlapping, deliveriesRunning)
        onEvent?("deliver begin")
        AppLog.trace("intents", "voice note delivery #\(deliveries) start")
        var legacy = false
        let signIn = signIns
        defer {
            deliveriesRunning -= 1
            onEvent?("deliver end")
            release()
        }
        // A cold launch: sign-in is being restored and the tabs are not on screen yet. Not ready within 10 s (the
        // sign-in form is showing): return quietly; the request stays until its minute passes.
        guard await ready(host, within: 10) else { return }
        do {
            if let request = store.pending {
                latestRequestId = request.id
                if let note = savedNote(host, sameAccountAs: request) { ask(host, about: note, request); return }
                try await launch(request, host)
            } else {
                if (!started.isEmpty && !explicitRecovery) || host.takeInProgress.active { return }
                if legacyFailedThisRun, !explicitRecovery { return }
                // The owner is being asked about this note (§8.2): the answer decides.
                if let asking, host.isShowing(asking.notice) { return }
                if let note = VoiceBotCatalog.pendingNote(defaults) {
                    legacy = true
                    try await recover(note, host)
                }
            }
        } catch let failure as IntentsFailure {
            // Signed out (or another account) while this ran: there is nobody to tell.
            AppLog.note("intents", "voice note delivery\(legacy ? " (saved note)" : "") refused")
            if signIn == signIns { fail(host, failure.message, legacy: legacy) }
        } catch is IntentsAway {
            // The app left the screen while the chat was opening. A request is over, with its sentence (§7.4: "the
            // app left the screen … before the start"); a saved note stays and the next foreground brings it in.
            AppLog.note("intents", "voice note delivery cancelled: app left the screen")
            if signIn == signIns, !legacy { fail(host, IntentsText.canceledRunAgain, legacy: false) }
        } catch is IntentsKept {
            // The owner kept a sheet's edits rather than open the chat: their own choice, so nothing is said. A
            // request is over (it is acknowledged); a saved note stays.
            onEvent?("kept")
            AppLog.trace("intents", "voice note delivery: a sheet's edits were kept")
        } catch {
            AppLog.note("intents", "voice note delivery failed\(legacy ? " (saved note)" : "")")
            if signIn == signIns { fail(host, IntentsText.couldNotStart, legacy: legacy) }
        }
    }

    /// Runs `work` alone, after any delivery in flight: the quick actions, "Open Bot" and the saved-note alert's Open
    /// chat go through the same gate as a delivery, so they can never interleave. One delivery can hold the gate for
    /// about 28 s (10 s for the sign-in, 10 s for the roster, 3 s for the chat, 5 s for the composer), so this waits
    /// 30 s; false when the gate was still held then (the caller says so).
    @discardableResult func exclusively(_ work: () async -> Void) async -> Bool {
        guard let host else { return false }
        var waited = 0
        while busy, waited < 300 {
            await host.sleep(ms: 100)
            waited += 1
        }
        guard !busy else { return false }
        busy = true
        defer { release() }
        await work()
        return true
    }

    private func release() {
        busy = false
        if again {
            again = false
            Task { await deliver() }
        }
    }

    /// [phone-logs] True when the app is active, after waiting (≤ `seconds`) while it is in front but inactive. On a
    /// cold launch the shortcut's own banner (or Control Center, a system alert) makes the app inactive for a few
    /// seconds while its scene stays in front: build 906 cancelled the memo then, 1 s after its chat opened, and the
    /// app was active again 5 s later. Left for the background, it is false at once.
    func backInFront(_ host: any IntentsHost, within seconds: Int = 10) async -> Bool {
        guard !host.isActive, host.isForeground else { return host.isActive }
        AppLog.trace("intents", "voice note delivery: the app is in front but inactive, waiting for it")
        for _ in 0..<(seconds * 10) where !host.isActive && host.isForeground { await host.sleep(ms: 100) }
        AppLog.trace("intents", "voice note delivery: \(host.isActive ? "active again" : "not back")")
        return host.isActive
    }

    private func ready(_ host: any IntentsHost, within seconds: Int) async -> Bool {
        for _ in 0..<(seconds * 10) {
            if host.isReady { return host.isActive }
            guard host.isActive else { return false }
            await host.sleep(ms: 100)
        }
        return host.isReady && host.isActive
    }

    private func fail(_ host: any IntentsHost, _ message: String, legacy: Bool) {
        if legacy { legacyFailedThisRun = true }
        if legacy, message == IntentsText.noteOtherAccount {
            // A retry cannot work until the owner signs back in: said once per note, not once per run of the app.
            let id = VoiceBotCatalog.pendingNote(defaults)?.id ?? ""
            guard defaults.string(forKey: Self.foreignNoteSaidKey) != id else { return }
            defaults.set(id, forKey: Self.foreignNoteSaidKey)
            show(host, .recovery(message, retry: false))
            return
        }
        show(host, legacy ? .recovery(message, retry: true) : .voiceNote(message))
    }

    /// The id of the other account's saved note the owner has been told about.
    static let foreignNoteSaidKey = "intents.foreignNoteSaid"

    private func show(_ host: any IntentsHost, _ notice: IntentsNoticeContent) {
        onEvent?("notice " + (notice.message ?? notice.title))
        host.show(notice)
    }

    // MARK: A request (§7.3)

    private func launch(_ request: VoiceNoteRequest, _ host: any IntentsHost) async throws {
        if started.contains(request.id) || request.expiresAt <= host.now() {
            acknowledge(request.id)
            return
        }
        defer { acknowledge(request.id) }                  // always: a failed shortcut never records later
        let take = host.takeInProgress
        if take.active {
            if take.key == request.key { return }          // already recording for this bot: leave it running
            throw IntentsFailure(IntentsText.finishCurrent)
        }
        let chat = try await open(account: request.account, key: request.key, name: request.name, host)
        if let id = store.pending?.id { latestRequestId = id }
        guard store.pending?.id == request.id else { return }     // a newer request replaced this one
        let allowed = { [weak self] in
            self?.latestRequestId == request.id && host.isActive && host.now() < request.expiresAt
                && chat.isTop && chat.botKey == request.key
        }
        _ = await backInFront(host)
        guard allowed() else { throw IntentsFailure(IntentsText.canceledRunAgain) }
        try await startMemo(in: chat, host, allowed: allowed)
        started.insert(request.id)
        onEvent?("memo started " + (VoiceBotCatalog.profile(key: request.key) ?? request.key))
        AppLog.note("intents", "voice note delivery started a hands-free memo")
        host.dismissNotice()
    }

    private func acknowledge(_ id: String) {
        store.acknowledge(id)
        onEvent?("ack " + id)
    }

    /// The bot's own chat on top (port of `open`, W:src/action-voice-runtime.ts:46-58).
    func open(account: String, key: String, name: String, _ host: any IntentsHost) async throws -> any IntentsChat {
        guard let current = host.account, VoiceBotCatalog.sameAccount(account, current) else {
            throw IntentsFailure(IntentsText.otherAccount)
        }
        var bot = host.bot(forKey: key)
        if bot == nil, !host.rosterLoaded {
            // A cold launch: the roster is on its way.
            for _ in 0..<100 where !host.rosterLoaded && host.isActive { await host.sleep(ms: 100) }
            bot = host.bot(forKey: key)
        }
        if bot == nil {
            await host.refreshRoster()
            host.syncCatalog()
            bot = host.bot(forKey: key)
            // The read took a while: the owner may have signed out, or switched gateways, meanwhile.
            guard let current = host.account, VoiceBotCatalog.sameAccount(account, current) else {
                throw IntentsFailure(IntentsText.otherAccount)
            }
        }
        guard let bot else { throw IntentsFailure(IntentsText.botUnavailable(name)) }
        // Nothing is pushed while the app is not on screen (the roster wait above can outlast the owner's patience).
        guard await backInFront(host) else { throw IntentsAway() }
        onEvent?("open " + bot.id)
        guard let chat = try await host.openBotChat(bot) else {
            if !(await backInFront(host)) { throw IntentsAway() }
            throw IntentsFailure(IntentsText.botChatDidNotOpen)
        }
        guard chat.botKey == key else { throw IntentsFailure(IntentsText.botChatChanged) }
        return chat
    }

    /// The chat's own recorder, locked (hands-free), once its composer can take it (≤ 5 s; port of `startMemoIn`,
    /// W:src/ui-voice/entry-live.ts:59-70).
    func startMemo(in chat: any IntentsChat, _ host: any IntentsHost, allowed: () -> Bool) async throws {
        for attempt in 0...50 {
            if !host.isActive { _ = await backInFront(host) }
            guard allowed() else { throw IntentsFailure(IntentsText.canceled) }
            if chat.composerReady {
                chat.beginHandsFreeMemo()
                return
            }
            if attempt < 50 { await host.sleep(ms: 100) }
        }
        throw IntentsFailure(IntentsText.fieldNotReady)
    }

    // MARK: The saved older-build note (§8)

    /// The note that waits for the request's account, when its recording can still be found. One whose recording is
    /// gone is not recoverable: it is forgotten, and nothing is shown.
    private func savedNote(_ host: any IntentsHost, sameAccountAs request: VoiceNoteRequest) -> PendingVoiceNote? {
        guard let note = VoiceBotCatalog.pendingNote(defaults) else { return nil }
        guard host.noteFile(note.path) != nil else { forget(note); return nil }
        return VoiceBotCatalog.sameAccount(note.bot.account, request.account) ? note : nil
    }

    private func forget(_ note: PendingVoiceNote) {
        VoiceBotCatalog.clearPendingNote(defaults)
        AppLog.note("intents", "saved note gone")
        onEvent?("saved note gone")
    }

    /// §8.2. `busy` is released while the alert is up; the chosen button acknowledges or replaces the request.
    private func ask(_ host: any IntentsHost, about note: PendingVoiceNote, _ request: VoiceNoteRequest) {
        let notice = IntentsNoticeContent.savedNote(bot: note.bot.name)
        let already = asking.map { $0.note == note && host.isShowing($0.notice) } ?? false
        asking = (note, request, notice)
        if already { return }                              // the same question is on screen: the newest request answers it
        onEvent?("ask saved note")
        host.show(notice)
    }

    /// A button of one of our alerts was tapped.
    func choose(_ choice: IntentsNoticeContent.Choice, from notice: IntentsNoticeContent) {
        switch choice {
        case .ok: break
        case .recover: Task { await deliver(explicitRecovery: true) }
        case .discard:
            // "Discard recording" on a note that could not be brought in: the owner's way to stop being asked.
            guard let host, let note = VoiceBotCatalog.pendingNote(defaults) else { return }
            if let file = host.noteFile(note.path) { host.delete(file) }
            VoiceBotCatalog.clearPendingNote(defaults)
            legacyFailedThisRun = false
            onEvent?("saved note discarded")
        case .cancel:
            guard let asking, asking.notice == notice else { return }
            self.asking = nil
            acknowledge(asking.request.id)                 // the note stays; it is recovered quietly on a later foreground
        case .openChat:
            guard let asking, asking.notice == notice else { return }
            self.asking = nil
            acknowledge(asking.request.id)
            Task { await recoverNow(asking.note) }
        case .discardAndRecord:
            guard let asking, asking.notice == notice, let host else { return }
            self.asking = nil
            if let file = host.noteFile(asking.note.path) { host.delete(file) }
            VoiceBotCatalog.clearPendingNote(defaults)
            onEvent?("saved note discarded")
            // A new minute: the owner's tap is the request.
            store.enqueue(account: asking.request.account, key: asking.request.key, name: asking.request.name)
            Task { await deliver() }
        }
    }

    /// "Open chat": the note goes to its chat now, whatever a shortcut started earlier in this run.
    private func recoverNow(_ note: PendingVoiceNote) async {
        await exclusively {
            guard let host = self.host, host.isActive else { return }
            let signIn = self.signIns
            do {
                try await self.recover(note, host)
            } catch let failure as IntentsFailure {
                if signIn == self.signIns { self.fail(host, failure.message, legacy: true) }
            } catch is IntentsAway {
                // The app left the screen: the note stays, and the next foreground brings it in.
            } catch is IntentsKept {
                // The owner kept a sheet's edits: the note stays, for the next foreground or Open chat.
            } catch {
                if signIn == self.signIns { self.fail(host, IntentsText.noteNotSaved, legacy: true) }
            }
        }
    }

    /// The note becomes its bot chat's memo draft (DECISION I10). It is never sent.
    func recover(_ note: PendingVoiceNote, _ host: any IntentsHost) async throws {
        guard let file = host.noteFile(note.path) else { forget(note); return }
        guard let current = host.account, VoiceBotCatalog.sameAccount(note.bot.account, current) else {
            throw IntentsFailure(IntentsText.noteOtherAccount)
        }
        let chat = try await open(account: note.bot.account, key: note.bot.key, name: note.bot.name, host)
        guard let memo = await host.importNote(file) else { throw IntentsFailure(IntentsText.noteNotSaved) }
        guard chat.isTop, chat.botKey == note.bot.key else {
            host.discard(memo)
            throw IntentsFailure(IntentsText.noteStillSaved)
        }
        guard host.setDraft(memo, scope: chat.scope) else {
            host.discard(memo)
            throw IntentsFailure(IntentsText.noteNotSaved)
        }
        host.delete(file)
        VoiceBotCatalog.clearPendingNote(defaults)
        onEvent?("saved note recovered " + (VoiceBotCatalog.profile(key: note.bot.key) ?? note.bot.key))
        host.dismissNotice()
    }

    // MARK: Home Screen quick actions and "Open Bot" (§9.4; port of `routeShortcut`, W:src/ui-voice/shortcuts.ts:61-98)

    /// `fallback`: the target "Open Bot" resolved from the pickers' catalog, used when the quick-action catalog does
    /// not hold the id.
    func route(_ action: String, id: String, epoch: String?, fallback: ShortcutTarget? = nil) async {
        AppLog.trace("intents", "shortcut \(action) start")
        let ran = await exclusively {
            guard let host = self.host else { return }
            var queued = false
            while true {
                do {
                    try await self.routeNow(action, id: id, epoch: epoch, fallback: fallback, host)
                    self.onEvent?("routed " + action)
                    AppLog.note("intents", "shortcut \(action) done")
                } catch is IntentsNotConnected {
                    // UX study #264: said, then held: it runs if the tabs come up within the cap, once.
                    guard !queued else { return }
                    queued = true
                    self.show(host, .shortcut(IntentsText.notReady()))
                    self.onEvent?("queued " + action)
                    AppLog.note("intents", "shortcut \(action) held: not connected yet")
                    guard await self.tabsAppear(host, within: Self.replayCap) else {
                        AppLog.note("intents", "shortcut \(action) gave up: tabs never came up")
                        return
                    }
                    host.dismissNotice()
                    continue
                } catch let failure as IntentsFailure {
                    AppLog.note("intents", "shortcut \(action) refused")
                    self.show(host, .shortcut(failure.message))
                } catch is IntentsKept {
                    self.onEvent?("kept " + action)
                    AppLog.trace("intents", "shortcut \(action): a sheet's edits were kept")
                } catch {
                    AppLog.note("intents", "shortcut \(action) failed")
                    self.show(host, .shortcut(nil))
                }
                return
            }
        }
        // Something else held the gate for 30 s: the item the owner chose is not dropped without a word.
        if !ran, let host {
            AppLog.note("intents", "shortcut \(action) refused: another delivery held the gate for 30 s")
            show(host, .shortcut(IntentsText.busy()))
        }
    }

    /// How long a held quick action waits for the tabs after "isn't connected yet" is said (UX study #264).
    static let replayCap = 10_000

    /// The tabs came up, in front, within `ms`; leaving the app gives up (a replay on a later return would surprise).
    private func tabsAppear(_ host: any IntentsHost, within ms: Int) async -> Bool {
        let deadline = host.now() + Double(ms)
        while host.now() < deadline {
            guard host.isActive else { return false }
            if host.isReady { return true }
            await host.sleep(ms: 100)
        }
        return host.isActive && host.isReady
    }

    private func routeNow(_ action: String, id: String, epoch: String?, fallback: ShortcutTarget?, _ host: any IntentsHost) async throws {
        let deadline = host.now() + 10_000
        while !(host.isActive && host.isReady) {
            // UX study #264: in front and signed in, the tabs just never came up (offline, a stalled launch): say that,
            // not "open the app".
            guard host.now() < deadline else {
                if host.isActive && host.account != nil { throw IntentsNotConnected() }
                throw IntentsFailure(IntentsText.openAppFirst())
            }
            await host.sleep(ms: 100)
        }
        guard let current = ShortcutPolicy.epoch(defaults), epoch == nil || epoch == current else {
            throw IntentsFailure(IntentsText.previousSignIn)
        }
        if action == "search" {
            onEvent?("search")
            host.openSearch()
            return
        }
        guard let target = ShortcutPolicy.targets(defaults).first(where: { $0.id == id && $0.id.hasPrefix(current + ":") }) ?? fallback else {
            throw IntentsFailure(IntentsText.chatGone())
        }
        if action == "memo", target.kind != "bot" { throw IntentsFailure(IntentsText.memoNeedsBot) }
        switch target.kind {
        case "bot":
            let key = target.botKey ?? ""
            while host.bot(forKey: key) == nil {
                guard host.now() < deadline else { throw IntentsFailure(IntentsText.botNotOnRoster) }
                await host.sleep(ms: 100)
            }
            guard let bot = host.bot(forKey: key) else { throw IntentsFailure(IntentsText.botNotOnRoster) }
            if action == "memo" {
                let take = host.takeInProgress
                if take.active {
                    if take.key == key { return }
                    throw IntentsFailure(IntentsText.finishCurrent)
                }
            }
            onEvent?("open " + bot.id)
            guard let chat = try await host.openBotChat(bot), chat.botKey == key else { throw IntentsFailure(IntentsText.chatDidNotOpen) }
            guard action == "memo" else { return }
            try await startMemo(in: chat, host, allowed: { chat.isTop && host.isActive })
            onEvent?("memo started " + bot.id)
            host.dismissNotice()
        case "session":
            let stored = target.sessionId ?? ""
            var profile = host.sessionProfile(stored)
            while profile == nil, host.now() < deadline {
                await host.sleep(ms: 100)
                profile = host.sessionProfile(stored)
            }
            guard let profile else { throw IntentsFailure(IntentsText.chatDidNotOpen) }
            onEvent?("open session " + stored)
            switch await host.openSessionChat(stored: stored, profile: profile) {
            case .opened: break
            case .failed: throw IntentsFailure(IntentsText.chatDidNotOpen)
            case .gone: throw IntentsFailure(IntentsText.chatGone())
            case .kept: throw IntentsKept()
            }
        case "room":
            // UX study #265 (DECISION I7 deferred rooms only until group chats shipped): its room, by key.
            guard let key = target.group, !key.isEmpty else { throw IntentsFailure(IntentsText.roomGone) }
            switch await host.openRoom(key) {
            case .opened: break
            case .kept: throw IntentsKept()
            case .failed, .gone: throw IntentsFailure(IntentsText.roomGone)
            }
            onEvent?("open room")
        default:
            throw IntentsFailure(IntentsText.roomGone)
        }
    }
}

/// A conversation the system hands back (§10.3).
nonisolated enum IntentsRouting {
    /// The stored chat id of a donated conversation: the interaction's intent is a message intent whose conversation
    /// id is one an alert may name. Anything else is nil. The message text an activity carries is never read and
    /// never sent.
    static func conversation(_ interaction: INInteraction?) -> String? {
        guard let intent = interaction?.intent as? INSendMessageIntent, let id = intent.conversationIdentifier,
              NotificationRules.valid(id) else { return nil }
        return id
    }
}
