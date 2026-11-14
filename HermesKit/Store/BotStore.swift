// The Bots list's data (spec 02 §1–8, 11, 12): the roster from `profiles.list`, painted from the device cache at
// once, then the slim answer, then the full answer; polled on the phone's cadence; device-local unread dots; and the
// canonical "Bot Chat" lookup a tap needs. Makes no gateway writes except minting a Bot Chat when the registry and a
// full roster both confirm a bot has none (§8.2), and never that while `readOnlyGateway` is on (§12.5).

import Foundation
import Observation

nonisolated enum RosterPhase: Int, Sendable, Comparable {
    case none, cache, slim, full
    static func < (a: RosterPhase, b: RosterPhase) -> Bool { a.rawValue < b.rawValue }
}

/// Why the last roster read failed. `busy` = the gateway did not answer in time (or said it was overloaded): the UI
/// says "Your gateway is busy…" (no rows) or shows the stale card over a painted list (spec 02 §2.1.1, §3 step 8).
nonisolated struct RosterFailure: Sendable, Equatable {
    var message: String
    var busy: Bool
    var at: Date
}

nonisolated enum RosterLoadState: Sendable, Equatable {
    case idle
    /// A read is out; with `phase == .none` the list shows skeleton rows.
    case loading
    case ready
    /// The last read failed (after its retries). Rows painted earlier stay; `BotStore.lastUpdated` says from when.
    case failed(RosterFailure)
}

/// Timing knobs (spec 02 §2.1.1, §3 step 6). Tests shrink them.
nonisolated struct BotStoreTiming: Sendable {
    var fullTimeout: Duration = .seconds(120)
    var slimTimeout: Duration = .seconds(30)
    var lookupTimeout: Duration = .seconds(30)
    var slimWait: Duration = .milliseconds(1500)
    var settle: Duration = .seconds(2)
    var onListPoll: Duration = .seconds(30)
    var offListPoll: Duration = .seconds(120)
    var pollCostFactor: Double = 10
    var openWait: Duration = .seconds(5)
    /// How long a tap on a bot the roster has not yet described (cache or slim rows carry no sessions) waits for the
    /// full answer before giving up rather than minting.
    var confirmWait: Duration = .seconds(30)
    /// Bound on waiting for the socket to report ready before the settle (§3 step 3).
    var readyWait: Duration = .seconds(120)
    /// [offline] §6.2: one quick retry (the web's query rule); a timeout or an unreachable gateway gets none.
    var retryDelays: [Duration] = [QueryRetry.delay]
    var staleOnReturn: Duration = .seconds(30)
    /// [botsaid] Read each Bot Chat's tail for the bot's own newest words (tests that count REST calls turn it off).
    var readsBotSaid = true
    static let standard = BotStoreTiming()
}

/// Errors from opening a bot's chat (spec 02 §8.3–8.4). The words match the web's so support threads line up.
nonisolated enum BotChatError: Error, LocalizedError, Sendable, Equatable {
    /// The registry lookup failed (RPC error): retry, never mint.
    case registryCheckFailed(bot: String, detail: String?)
    /// The lookup came back empty although the roster named a Bot Chat: fail closed.
    case registryUnconfirmed(bot: String)
    /// Minting the Bot Chat failed.
    case createFailed(bot: String, detail: String)
    /// The bot has no Bot Chat and the read-only testing switch refuses to create one.
    case readOnly(bot: String)
    case unknownBot(String)

    var errorDescription: String? {
        switch self {
        case .registryCheckFailed(let bot, let detail):
            return "Couldn’t check \(bot)'s Bot Chat registry\(detail.map { " (\($0))" } ?? "") — not starting a new chat"
        case .registryUnconfirmed(let bot): return "Couldn’t confirm \(bot)'s Bot Chat registry — not starting a new chat"
        case .createFailed(let bot, let detail): return "Couldn’t open \(bot)'s chat (\(detail))"
        case .readOnly(let bot): return "\(bot) has no Bot Chat yet, and this gateway is read-only — not starting a new chat"
        case .unknownBot(let name): return "No bot named \(name)"
        }
    }
}

/// Device-local Bots state, persisted per gateway account (spec 02 §11).
nonisolated struct BotDeviceState: Codable, Sendable, Hashable {
    /// Merged `hermes-bots` meta snapshot by profile (§5.2).
    var meta: [String: JSONValue] = [:]
    /// User sections in display order (adopted from meta).
    var sections: [RosterSectionRecord] = []
    /// Tile order (profile names).
    var pinOrder: [String] = []
    var unread = BotUnreadState()
    /// Settings stream (1x-settings §7.5): heads this phone saved that the roster hasn't caught up with, by profile.
    /// Optional so older state files still decode.
    var headOverlay: [String: HeadOverlayEntry]? = nil
    /// [botsaid] Each bot's newest words in its Bot Chat, by profile (`BotStore+BotSaid.swift`). Optional so older state
    /// files still decode.
    var botSaid: [String: BotSaidEntry]? = nil
    /// [manualorder] Sort By › Manual: the rows' order, profile names, top row first (`BotRowOrder`); nil is Recent
    /// Activity. Optional so older state files still decode (as Recent Activity).
    var rowOrder: [String]? = nil
}

/// The last full roster this device saw for the account (`dispatch.roster.v1`).
nonisolated struct RosterCacheFile: Codable, Sendable {
    var at: Double                   // ms since the epoch
    var profiles: [JSONValue]
}

@MainActor @Observable
final class BotStore {
    let account: GatewayAccount

    /// Rows in display order: tiles, the Pinned section, user sections, unassigned, hidden (spec 02 §7.5).
    private(set) var bots: [Bot] = []
    /// The same rows grouped for drawing.
    private(set) var layout = RosterLayout()
    private(set) var phase: RosterPhase = .none
    private(set) var loadState: RosterLoadState = .idle
    /// When the shown roster was read from the gateway (the cache's own time for a cached paint).
    private(set) var lastUpdated: Date?
    /// Bots tab badge: unread bots, hidden ones and empty chats excluded (§6.7).
    private(set) var unreadCount = 0
    /// A full read is in flight (pull to refresh joins it).
    private(set) var isRefreshing = false
    /// [offline] §4.3: the last failed read's reason in plain words (nil when it has none worth showing); never a raw code.
    @ObservationIgnored private(set) var failureWords: String?

    /// Called on the main actor after the rows, layout or load state changed.
    @ObservationIgnored var onChange: (() -> Void)?
    /// [load-cache] A bot this phone deleted (its name): the app drops its saved chat tails.
    @ObservationIgnored var onDeleted: ((String) -> Void)?
    /// Model id → label for "Model changed to …" previews (the chat module owns model names).
    @ObservationIgnored var modelLabel: (String) -> String = { $0 } {
        didSet { previews = RosterPreviewCache(); rebuild() }
    }
    /// Verify round 3: the words typed and not sent in a bot's chat (`profile`, its stored id when known), for the row's
    /// "Draft:" line (spec 02 §6.4 item 4). The app model reads the composer's drafts; `refreshDrafts()` after they change.
    @ObservationIgnored var draftWords: ((_ profile: String, _ chatId: String?) -> String?)?

    /// The composer's drafts changed (a chat was left, words came back off screen): the rows say so.
    func refreshDrafts() { rebuild() }
    /// [botslist] The words of the oldest send in a bot's Bot Chat that may never have arrived (the app reads
    /// `LostSends`); the row then says "Not Delivered: <words>" ahead of any draft (parity §3 L189). `chatIds`: every id
    /// the Bot Chat goes by.
    @ObservationIgnored var lostWords: ((_ profile: String, _ chatIds: [String]) -> String?)?

    /// Testing switch for the owner's real gateway (spec 02 §12.5): refuse every write. Here that is the Bot Chat
    /// mint; a tap on a bot with no Bot Chat throws `BotChatError.readOnly` instead. Set together with
    /// `SessionStore.readOnlyGateway` from one app-wide flag.
    @ObservationIgnored var readOnlyGateway = false

    // Settings stream (1x-settings §2): internal (not private) so BotStore+Editing.swift can patch rows and meta.
    @ObservationIgnored let client: any GatewayClient
    @ObservationIgnored let timing: BotStoreTiming
    /// Settings stream: write fence, per-bot write queue, pending section deletes (BotStore+Editing.swift).
    @ObservationIgnored let editing = BotEditingState()
    /// [photoheads] Which bots wear a photo, and the pictures (docs/spec/3x-photoheads.md §4). Fed every roster answer.
    @ObservationIgnored let photos: BotPhotoStore
    @ObservationIgnored private let rosterURL: URL
    @ObservationIgnored private let stateURL: URL
    /// [sync] No device state on disk at launch (signed out and back in, or never saved): `GatewaySync` takes the
    /// gateway's orders instead of sending this empty copy.
    @ObservationIgnored private(set) var syncStartedEmpty = false
    @ObservationIgnored var profiles: [RosterProfile] = []
    @ObservationIgnored var rawRows: [JSONValue] = []
    @ObservationIgnored private var details: [String: BotRowDetail] = [:]
    @ObservationIgnored var device = BotDeviceState()
    /// Busy chats by profile: the stored id of each chat running a turn or holding live work ("" = not stored yet).
    @ObservationIgnored private var workingChats: [String: Set<String>] = [:]
    @ObservationIgnored private var needsInput: [String: NeedsInput] = [:]   // [questions]
    @ObservationIgnored private var presence: [String: BotPresence] = [:]    // [presence]
    @ObservationIgnored private var steps: [String: [String: String]] = [:]  // [toolnow] profile → stored id → words
    // [botslist] Row status that is display only (BotStore+RowStatus.swift): bots whose open passed the grace, the
    // sleeps that flip them, and each bot's standing problem.
    @ObservationIgnored var wakingBots: Set<String> = []
    @ObservationIgnored var wakingTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var wakingGrace: Duration = .seconds(1)
    @ObservationIgnored var attention: [String: Attention] = [:]
    // [botslist] Pinned reconcile (BotStore+PinnedReconcile.swift, parity §3 L147): on in the app; bots with a reconcile
    // write out; when a failed one may be tried again; the clock (tests replace it).
    @ObservationIgnored var reconcilesPinned = false
    @ObservationIgnored var pinnedWriting: Set<String> = []
    @ObservationIgnored var pinnedRetryAt: [String: Date] = [:]
    @ObservationIgnored var pinnedClock: () -> Date = { Date() }
    /// [presence] DEBUG counter for load checks: how many times the presence map made the roster rebuild.
    @ObservationIgnored private(set) var presenceRebuilds = 0
    @ObservationIgnored var mintedChats: [String: String] = [:]
    /// [perf] A pull always ends with a notify (it ends the spinner and redraws the "updated" time), even when the
    /// answer matches the last one; a poll with the same answer stays quiet.
    @ObservationIgnored private var forceNextNotify = false
    /// [perf] When the roster cache was last written: an unchanged answer rewrites it at most every 10 minutes (its
    /// `at` is the next offline launch's "updated N ago"). Nil after a local row patch, so the poll that confirms it
    /// rewrites the cache.
    @ObservationIgnored var lastRosterWriteAt: ContinuousClock.Instant?
    @ObservationIgnored private var mintTasks: [String: Task<String, Error>] = [:]
    /// Bots the last full answer (this run) said have no Bot Chat. Only these may be minted for: a cached or slim
    /// row carries no sessions, so its missing `canonical_session` proves nothing.
    @ObservationIgnored private var confirmedNoChat: Set<String> = []
    @ObservationIgnored private var previews = RosterPreviewCache()
    // [botsaid] Bot Chat tails being read, waiting, and answers not yet drawn (BotStore+BotSaid.swift).
    /// [botsaid] Reads out (one per bot): the roster state each was asked for, and when it went out.
    @ObservationIgnored var botSaidOut: [String: (mark: String, asked: ContinuousClock.Instant)] = [:]
    @ObservationIgnored var botSaidQueue: [(profile: String, session: String, at: Double, mark: String)] = []
    /// [botsaid] When this device last saw each bot say something in its Bot Chat (`noteBotSaid`).
    @ObservationIgnored var botSaidSeenAt: [String: ContinuousClock.Instant] = [:]
    /// [botsaid] Each Bot Chat's `BotSaidRules.mark` from the last full roster, as the gateway gave it.
    @ObservationIgnored var botSaidMarks: [String: String] = [:]
    @ObservationIgnored var botSaidDirty = 0
    /// [botsaid] Bots whose chat is read again whatever the roster says of it (`rereadBotSaid`).
    @ObservationIgnored var botSaidStale: Set<String> = []
    /// [botunread] When each bot began waiting for a read of its chat (`BotUnreadState.pending`): only a read asked
    /// for after that has seen the rows that moved it.
    @ObservationIgnored var unreadHeldAt: [String: ContinuousClock.Instant] = [:]

    // Lifecycle and cadence.
    @ObservationIgnored private var started = false
    @ObservationIgnored private(set) var stopped = false
    @ObservationIgnored private var appActive = true
    @ObservationIgnored private var listVisible = false
    @ObservationIgnored private var chatOpening = false
    /// Opens waiting for a full roster to confirm a bot's Bot Chat: the full read must not wait for them.
    @ObservationIgnored private var opensAwaitingRoster = 0
    @ObservationIgnored private var focus: (profile: String, sessionId: String)?
    @ObservationIgnored private var socketOpenedAt: ContinuousClock.Instant?
    @ObservationIgnored private var lastReadDuration: Duration = .zero
    /// Full reads in a row that found nothing new: the poll on the list stretches with them (`pollInterval`).
    @ObservationIgnored private var unchangedReads = 0
    @ObservationIgnored private var lastAttemptEnded: ContinuousClock.Instant?
    @ObservationIgnored private var lastSuccess: ContinuousClock.Instant?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var statesTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var slimTask: Task<Void, Never>?
    @ObservationIgnored private var fullTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Bumped by every start/stop and by each new load or full read: a task's completion only touches the store's
    /// bookkeeping while its token is still current (a cancelled task finishing late must not clobber its successor).
    @ObservationIgnored private var lifecycle = 0
    @ObservationIgnored private var fullToken = 0
    @ObservationIgnored private var readyWaiters: [UUID: (continuation: CheckedContinuation<Void, Never>, timeout: Task<Void, Never>)] = [:]

    /// Builds the store and paints the cached roster synchronously; `autoStart` then begins the fetch pipeline.
    init(client: any GatewayClient, account: GatewayAccount, cacheDirectory: URL, timing: BotStoreTiming = .standard,
         photoTiming: BotPhotoTiming = .standard, autoStart: Bool = true) {
        self.client = client
        self.account = account
        self.timing = timing
        photos = BotPhotoStore(client: client, account: account, cacheDirectory: cacheDirectory, timing: photoTiming)   // [photoheads]
        rosterURL = RosterDisk.url(cacheDirectory, RosterDisk.rosterKind, account)
        stateURL = RosterDisk.url(cacheDirectory, RosterDisk.botStateKind, account)
        if let state = RosterDisk.read(BotDeviceState.self, from: stateURL) { device = state } else { syncStartedEmpty = true }
        if let cached = RosterDisk.read(RosterCacheFile.self, from: rosterURL), !cached.profiles.isEmpty {
            rawRows = cached.profiles
            profiles = Self.decodeRows(cached.profiles)
            phase = .cache
            lastUpdated = Date(timeIntervalSince1970: cached.at / 1000)
        }
        rebuild(notify: false)
        if autoStart { start() }
    }

    // MARK: - Lifecycle

    /// Subscribe to the gateway and load (cache → slim → settle → full), then poll. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        stopped = false
        lifecycle &+= 1
        AppLog.trace("bots", "store start: \(profiles.count) bots from cache")
        let client = self.client
        eventsTask = Task { [weak self] in
            for await event in client.events() {
                guard let self else { return }
                self.handle(event)
            }
        }
        statesTask = Task { [weak self] in
            for await state in client.connectionStates() {
                guard let self else { return }
                self.handle(state)
            }
        }
        let generation = lifecycle
        loadTask = Task { [weak self] in await self?.initialLoad(generation) }
        photos.start()       // [photoheads]
    }

    /// Stop every task (sign-out, account switch). The cache stays.
    func stop() {
        AppLog.trace("bots", "store stop")
        stopped = true
        started = false
        lifecycle &+= 1
        fullToken &+= 1
        for task in [eventsTask, statesTask, loadTask, slimTask, fullTask, pollTask] { task?.cancel() }
        eventsTask = nil; statesTask = nil; loadTask = nil; slimTask = nil; fullTask = nil; pollTask = nil
        for task in mintTasks.values { task.cancel() }
        mintTasks = [:]
        for task in wakingTasks.values { task.cancel() }   // [botslist]
        wakingTasks = [:]; wakingBots = []
        socketOpenedAt = nil; socketOpenedDate = nil
        resumeReadyWaiters()
        isRefreshing = false
        photos.stop()       // [photoheads]
    }

    /// Forget this account's cached roster and device state (sign-out of the account).
    func removeCachedData() {
        RosterDiskWriter.shared.remove(rosterURL)
        RosterDiskWriter.shared.remove(stateURL)
        photos.removeCachedData()       // [photoheads]
    }

    func appDidBecomeActive() {
        appActive = true
        photos.appDidBecomeActive()       // [photoheads]
        guard started, loadTask == nil else { return }
        if let ended = lastAttemptEnded, ContinuousClock.now - ended < pollInterval() { schedulePoll() } else { refreshSoon() }
    }

    func appDidEnterBackground() {
        appActive = false
        photos.appDidEnterBackground()       // [photoheads]
        pollTask?.cancel()
        pollTask = nil
    }

    /// The Bots or Sessions list is on screen (30 s cadence) or not (120 s). Coming back to the list with data
    /// older than 30 s refreshes at once without cancelling a read in flight.
    func setListVisible(_ visible: Bool) {
        let wasVisible = listVisible
        listVisible = visible
        guard started, appActive, loadTask == nil else { return }
        if visible, !wasVisible, isStale(timing.staleOnReturn) { refreshSoon() } else { schedulePoll() }
    }

    /// A chat is opening: a roster read that falls due waits up to 5 s for it.
    func noteChatOpening(_ opening: Bool) { chatOpening = opening }

    /// The chat on screen (after it applied fresh history), or nil when it leaves. While a bot's chat is focused a full
    /// roster acknowledges that bot instead of marking it unread. On leaving (nil, or another chat) the bot's baseline
    /// moves to `seenThrough`: the server time of the newest message the chat showed, else now. So the user's own
    /// exchange since the last roster is not read as unseen activity by the next roster.
    func setFocusedChat(profile: String?, sessionId: String?, seenThrough: Date? = nil) {
        var next: (profile: String, sessionId: String)?
        if let profile, let sessionId { next = (profile: profile, sessionId: sessionId) }
        if let previous = focus, previous.profile != next?.profile || previous.sessionId != next?.sessionId {
            noteLeft(previous, seenThrough: seenThrough ?? Date())
        }
        focus = next
        photos.setFocus(next?.profile)       // [photoheads] the open chat's bot is fetched first
    }

    private func noteLeft(_ chat: (profile: String, sessionId: String), seenThrough: Date) {
        guard isOwnChat(chat) else { return }
        device.unread.left(chat.profile, seenThrough: seenThrough.timeIntervalSince1970)
        persistState()
    }

    /// Only the bot's own Bot Chat moves its baseline (a side chat of the bot is not its activity owner's chat).
    private func isOwnChat(_ chat: (profile: String, sessionId: String)) -> Bool {
        if let profile = profile(named: chat.profile), !profile.canonicalIds.isEmpty,
           !profile.canonicalIds.contains(chat.sessionId), mintedChats[chat.profile] != chat.sessionId { return false }
        return true
    }

    /// A chat left right after its turn ended read that turn's stored end only afterwards (the read waits 1.2 s): the
    /// baseline moves to what it saw, and a dot a roster set meanwhile for that same activity goes (spec 02 §6.7; the
    /// user watched the whole reply). Activity newer than `seenThrough` keeps its dot.
    func noteSeenAfterLeaving(profile name: String, sessionId: String, seenThrough: Date) {
        if let focus, focus.profile == name { return }          // back on screen: the roster acknowledges it anyway
        guard isOwnChat((profile: name, sessionId: sessionId)) else { return }
        let seen = seenThrough.timeIntervalSince1970
        device.unread.left(name, seenThrough: seen)
        if let profile = profile(named: name) { device.unread.acknowledgeIfSeen(profile, seenThrough: seen) }
        persistState()
        rebuild()
    }

    /// A turn in a bot's own chat ended, seen by this device (its chat on screen, or a turn the device watched that ended
    /// off screen): the row shows that reply and its time now instead of after the next roster read (up to 30 s on the
    /// list, verification round 3), and gets the dot when nobody was looking (`unseen`). The next full roster replaces
    /// the patch with the gateway's own values.
    ///
    /// [botsaid] `said` is false for a reply known only by its words (a turn that ended off screen): it may be written
    /// to another bot, so the row's words come from a read of the chat instead (`rereadBotSaid`).
    func noteChatActivity(profile name: String, sessionId: String?, preview: String?, at time: Date, unseen: Bool, said: Bool = true) {
        guard let i = profiles.firstIndex(where: { $0.name == name }), var canonical = profiles[i].canonicalSession else { return }
        if let sessionId, !profiles[i].canonicalIds.contains(sessionId), mintedChats[name] != sessionId { return }
        var changed = false
        let stamp = time.timeIntervalSince1970
        if stamp > (canonical.lastActive ?? 0) {
            canonical.lastActive = stamp
            changed = true
        }
        if said, let text = preview.map({ ChatText.compactPreview($0, max: 80) }), !text.isEmpty, text != canonical.preview {
            canonical.preview = text
            changed = true
        }
        // [botsaid] The row draws the bot's own words: these are kept with the chat until its next read.
        if said, let preview, noteBotSaid(profile: name, sessionId: canonical.openId, text: preview, at: stamp) { changed = true }
        if !said, preview != nil { rereadBotSaid(profile: name) }
        if (canonical.messageCount ?? 0) == 0 { canonical.messageCount = max(1, canonical.messageCount ?? 0); changed = true }
        guard changed else { return }
        profiles[i].canonicalSession = canonical
        // Only the bot's own chat on screen sees this: one of its side chats on screen doesn't.
        let watched = focus.map { $0.profile == name && isOwnChat($0) } ?? false
        if unseen, !watched {
            device.unread.mark(profiles[i])
            persistState()
        }
        rebuild()
    }

    /// The chat engine's word on which of a bot's chats are busy. Like the desktop's bot list, the bot says "Working…"
    /// only for its own Bot Chat: a side chat that is busy says so on its Sessions row, not on the bot.
    func setWorkingChats(_ profile: String, _ storedIds: Set<String>) {
        guard (workingChats[profile] ?? []) != storedIds else { return }
        workingChats[profile] = storedIds.isEmpty ? nil : storedIds
        rebuild()
    }

    /// Bots whose Bot Chat is busy: a busy chat counts when it is one of the ids the roster (or this device's freshly
    /// made Bot Chat) gives the bot's own chat, or when it has no stored id yet (a Bot Chat being made).
    private func workingProfiles(_ profiles: [RosterProfile]) -> Set<String> {
        var out: Set<String> = []
        for profile in profiles {
            guard let busy = workingChats[profile.name], !busy.isEmpty else { continue }
            if !busy.isDisjoint(with: ownChatIds(profile)) { out.insert(profile.name) }
        }
        return out
    }

    /// [toolnow] Each bot's running chats' newest steps (profile → stored id, "" for one not stored yet → words,
    /// LiveSteps). Its row names its own Bot Chat's step instead of "Working…"; a side chat's shows on its Sessions row.
    /// Replaces the whole map.
    func setSteps(_ next: [String: [String: String]]) {
        guard steps != next else { return }
        steps = next
        rebuild()
    }

    /// [toolnow] The step of each working bot's own Bot Chat, by profile.
    private func ownSteps(_ profiles: [RosterProfile], working: Set<String>) -> [String: String] {
        var out: [String: String] = [:]
        for profile in profiles where working.contains(profile.name) {
            guard let chats = steps[profile.name] else { continue }
            let own = ownChatIds(profile)
            if let words = chats.first(where: { own.contains($0.key) })?.value { out[profile.name] = words }
        }
        return out
    }

    /// [live-chats] The bots' other chats running a turn now (stored ids only), each with its newest step: the Lock
    /// Screen gives each its own card, as it does a Bot Chat (a tester, 2026-11-05). Sorted, so a caller can
    /// compare one answer with the last.
    func busySideChats() -> [(profile: String, storedId: String, step: String?)] {
        var out: [(profile: String, storedId: String, step: String?)] = []
        for profile in profiles {
            guard let busy = workingChats[profile.name], !busy.isEmpty else { continue }
            let own = ownChatIds(profile)
            for id in busy.subtracting(own).sorted() { out.append((profile.name, id, steps[profile.name]?[id])) }
        }
        return out
    }

    /// The stored ids of a bot's own Bot Chat: the roster's, this device's freshly made one, and "" (one not stored yet).
    /// Nil for a bot the roster doesn't know.
    func ownChatIds(_ name: String) -> Set<String>? { profile(named: name).map(ownChatIds) }

    private func ownChatIds(_ profile: RosterProfile) -> Set<String> {
        var own = Set(profile.canonicalIds)
        own.insert("")
        if let minted = mintedChats[profile.name] { own.insert(minted) }
        return own
    }

    /// [questions] The server-request centre's word on whether a bot's chat waits for an answer (spec 1x §3.6).
    func setNeedsInput(_ profile: String, _ kind: NeedsInput?) {
        guard needsInput[profile] != kind else { return }
        needsInput[profile] = kind
        rebuild()
    }

    /// [presence] What each bot is doing outside its chat (spec 3x-presence §3.3). Replaces the whole map.
    func setPresence(_ next: [String: BotPresence]) {
        let cleaned = next.filter { !$0.value.isEmpty }
        guard presence != cleaned else { return }
        presence = cleaned
        presenceRebuilds += 1
        rebuild()
    }

    /// Pull to refresh: joins a full read in flight instead of starting another.
    func refresh() async {
        guard started, !stopped else { return }
        AppLog.trace("bots", "pull to refresh: started")
        forceNextNotify = true
        await fullReadTask().value
    }

    // MARK: - Reads for the UI

    func detail(for bot: Bot) -> BotRowDetail? { details[bot.id] }
    func profile(named name: String) -> RosterProfile? { profiles.first { $0.name == name } }
    func bot(named name: String) -> Bot? { bots.first { $0.id == name } }

    /// The row's second line (§6.5) for the M1 data: "Waking up…" (pass `opening` once an open has taken 1 s),
    /// "Working…", else the preview with its prefix, the role, or "No messages yet".
    func secondLine(for bot: Bot, opening: Bool = false) -> RosterRules.SecondLine {
        let parts = details[bot.id]?.preview ?? RosterPreview.Parts(prefix: nil, text: bot.role ?? "No messages yet", isFallback: true)
        return RosterRules.secondLine(isWorking: bot.isWorking, step: bot.step, opening: opening, preview: parts)
    }

    /// The bots a search shows (§7.1), hidden ones included only when asked.
    func search(_ query: String, includeHidden: Bool = false) -> [Bot] {
        bots.filter { (includeHidden || !$0.hidden) && RosterRules.matches($0, query: query) }
    }

    /// Device-local tile order (profile names, first tile first).
    func setTileOrder(_ names: [String]) {
        device.pinOrder = Array(names.prefix(PinOrder.limit))
        persistState()
        rebuild()
    }

    /// A tile drop: the tiles shown as `before` (profile names) now read `after` (`S/ui-bots/pinned-order.ts`).
    func placeTiles(before: [String], after: [String]) {
        let next = PinOrder.next(saved: device.pinOrder, before: before, after: after)
        guard next != device.pinOrder else { return }
        device.pinOrder = next
        persistState()
        rebuild()
    }

    // MARK: - Manual order [manualorder]

    /// Filter › Sort By: the rows follow this device's order (Manual) rather than recent activity.
    var rowsManual: Bool { device.rowOrder != nil }

    /// Sort By › Manual keeps every row where it is now; Recent Activity drops the saved order (`setSidebarOrdering`
    /// clears the ids: picking a sort is the only way out of a hand-dragged order).
    func setRowsManual(_ manual: Bool) {
        guard manual != rowsManual else { return }
        device.rowOrder = manual ? layout.rows.map(\.id) : nil
        persistState()
        rebuild()
    }

    /// A row dropped in a new place or moved up or down: a block's rows (profile names, top first) now read `rows`.
    /// Turns Manual on (dragging is how you pick it, as on the desktop). Device-local; nothing is sent.
    func placeRows(_ rows: [String]) {
        let next = BotRowOrder.placed(rows, in: device.rowOrder ?? layout.rows.map(\.id))
        guard next != device.rowOrder else { return }
        device.rowOrder = next
        persistState()
        rebuild()
    }

    // MARK: - Unread (device-local, §6.7)

    /// The bot's chat was read: call once an open applied fresh history from the gateway (a cached paint is not
    /// enough). Ignored when a newer roster time arrived since `bot` was taken (its newer messages are unseen).
    func markRead(_ bot: Bot) {
        guard let profile = profile(named: bot.id) else { return }
        if let seen = bot.lastActive?.timeIntervalSince1970, let current = details[bot.id]?.time, current > seen + 0.0005 { return }
        device.unread.acknowledge(profile)
        persistState()
        rebuild()
    }

    /// Mark as Unread from the row menu (device-local). No-op for a bot with no chat yet.
    func markUnread(_ bot: Bot) {
        guard let profile = profile(named: bot.id), profile.canonicalSession != nil else { return }
        device.unread.mark(profile)
        persistState()
        rebuild()
    }

    // MARK: - Opening a bot (§8)

    /// The stored session id to open for a tap on `bot`. A row whose roster names its Bot Chat opens it at once (the
    /// lineage tip); ask `registryReplacement(for:openedId:)` in parallel. A row with no Bot Chat goes lookup-first and
    /// mints one only when the registry finds none **and** a full roster read in this run confirms there is none (a
    /// cached or slim row carries no sessions; an empty lookup from a backend mid-restart must not fork the chat). In
    /// the cache and slim phases that means waiting for the full answer (at most `confirmWait`). Throws
    /// `BotChatError` (show §8.4), never mints while `readOnlyGateway` is on.
    func chatSessionId(for bot: Bot) async throws -> String {
        guard let profile = profile(named: bot.id) else { throw BotChatError.unknownBot(bot.id) }
        if let known = profile.canonicalSession, !known.id.isEmpty { return known.openId }
        if let minted = mintedChats[profile.name] { return minted }
        if let found = try await registryLookup(name: profile.name, displayName: bot.name) { return found.openId }
        if !confirmedAbsent(profile.name) {
            // The registry answered empty for a bot no full roster has described yet: let the full answer decide.
            AppLog.trace("bots", "bot chat for \(bot.id): unconfirmed, waiting for the full roster")
            await awaitFullRoster(bound: timing.confirmWait)
            if let known = self.profile(named: profile.name)?.canonicalSession, !known.id.isEmpty { return known.openId }
            if let minted = mintedChats[profile.name] { return minted }
            guard confirmedAbsent(profile.name) else { throw BotChatError.registryUnconfirmed(bot: bot.name) }
        }
        if readOnlyGateway { throw BotChatError.readOnly(bot: bot.name) }
        AppLog.trace("bots", "bot chat for \(bot.id): confirmed absent, minting")
        return try await mintChat(self.profile(named: profile.name) ?? profile, displayName: bot.name)
    }

    /// The registry lookup (§8.3): `session.list {profile, title:"Bot Chat", limit:200, include_hidden:true}`; returns
    /// the tip to open, nil only for a confirmed absence (the registry has no Bot Chat and the last full roster read
    /// in this run named none). Fails closed: an RPC error, or an empty answer that no full roster confirms, throws.
    func lookupChatSessionId(for bot: Bot) async throws -> String? {
        try await lookup(name: bot.id, displayName: bot.name)?.openId
    }

    /// The background half of a usual tap (§8.1 step 4.5): when the registry names a *different* Bot Chat row than the
    /// roster did, the tip to open instead; nil when it agrees, fails, or is doubtful (the known chat stays).
    func registryReplacement(for bot: Bot, openedId: String) async -> String? {
        guard let profile = profile(named: bot.id), let known = profile.canonicalSession, !known.id.isEmpty else { return nil }
        guard let answer = try? await registryLookup(name: bot.id, displayName: bot.name), !answer.id.isEmpty else { return nil }
        if answer.id == known.id || answer.openId == openedId { return nil }
        return answer.openId
    }

    /// The registry's Bot Chat row for `name`, or nil when the registry answered without one. Throws only for an RPC
    /// error (never read as "no Bot Chat").
    func registryLookup(name: String, displayName: String) async throws -> RosterSessionRef? {
        let result: JSONValue
        do {
            result = try await client.call("session.list", ["profile": .string(name), "title": .string(RosterRules.botChatTitle),
                                                            "limit": 200, "include_hidden": true], timeout: timing.lookupTimeout)
        } catch {
            let detail = RosterText.nonBlank((error as? RPCError)?.message ?? RosterRules.errorText(error))
            throw BotChatError.registryCheckFailed(bot: displayName, detail: detail)
        }
        let rows = (result["sessions"]?.array ?? []).compactMap { RosterSessionRef(json: $0) }
        return rows.first(where: \.isBotChat)
    }

    /// `findExistingCanonicalChat` with the native confirmation rule: nil only for a confirmed absence.
    private func lookup(name: String, displayName: String) async throws -> RosterSessionRef? {
        if let match = try await registryLookup(name: name, displayName: displayName) { return match }
        guard confirmedAbsent(name) else { throw BotChatError.registryUnconfirmed(bot: displayName) }
        return nil
    }

    /// A full roster read in this run said the bot has no Bot Chat, nothing since says otherwise, and this device has
    /// not minted one.
    private func confirmedAbsent(_ name: String) -> Bool {
        guard confirmedNoChat.contains(name), mintedChats[name] == nil else { return false }
        if let known = profile(named: name)?.canonicalSession, !known.id.isEmpty { return false }
        return true
    }

    /// Wait (bounded) for a full roster answer: the one in flight, else a new one.
    private func awaitFullRoster(bound: Duration) async {
        guard started, !stopped else { return }
        opensAwaitingRoster += 1
        defer { opensAwaitingRoster -= 1 }
        await Self.wait(for: fullReadTask(), atMost: bound)
    }

    /// Wait for `task` or `bound`, whichever comes first. (A task group would not do: awaiting another task's value
    /// ignores cancellation, so the group would still wait for the task.)
    private static func wait(for task: Task<Void, Never>, atMost bound: Duration) async {
        let gate = WaitGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.continuation = continuation
            gate.timer = Task { try? await Task.sleep(for: bound); gate.open() }
            Task { await task.value; gate.open() }
        }
    }

    /// `createCanonicalChat` (§8.2): one creation per bot at a time; adopt before mint; `session.create` then
    /// `session.title` to materialise the row; a title clash adopts the winner.
    private func mintChat(_ profile: RosterProfile, displayName: String) async throws -> String {
        if let running = mintTasks[profile.name] { return try await running.value }
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performMint(profile, displayName: displayName)
        }
        mintTasks[profile.name] = task
        defer { mintTasks[profile.name] = nil }
        return try await task.value
    }

    private func performMint(_ profile: RosterProfile, displayName: String) async throws -> String {
        if readOnlyGateway { throw BotChatError.readOnly(bot: displayName) }
        if let found = try await lookup(name: profile.name, displayName: displayName) { return found.openId }
        if readOnlyGateway { throw BotChatError.readOnly(bot: displayName) }
        let created: JSONValue
        do {
            created = try await SessionCreate.call(client, profile: profile.name, ["profile": .string(profile.name), "title": .string(RosterRules.botChatTitle),
                                                               "hidden": true, "follow_profile_config": true], timeout: timing.lookupTimeout)
        } catch {
            AppLog.note("bots", "mint chat for \(profile.name): create failed, \(RosterRules.errorText(error))")
            throw BotChatError.createFailed(bot: displayName, detail: RosterRules.errorText(error))
        }
        guard let stored = RosterText.trimmed(created["stored_session_id"]) ?? RosterText.trimmed(created["session_id"]) else {
            AppLog.note("bots", "mint chat for \(profile.name): gateway returned no session id")
            throw BotChatError.createFailed(bot: displayName, detail: "the gateway returned no session id")
        }
        if let runtime = RosterText.trimmed(created["session_id"]) {
            do {
                // `profile` on every session RPC (04 §1.4).
                _ = try await client.call("session.title", ["session_id": .string(runtime), "title": .string(RosterRules.botChatTitle),
                                                            "profile": .string(profile.name)],
                                          timeout: timing.lookupTimeout)
            } catch let error where Self.titleInUse.test(RosterRules.errorText(error)) {
                // Another device minted it first: open the winner.
                AppLog.trace("bots", "mint chat for \(profile.name): title race, another device won, opening it")
                if let winner = try await registryLookup(name: profile.name, displayName: displayName) { return winner.openId }
                throw BotChatError.registryUnconfirmed(bot: displayName)
            } catch {
                // An older gateway without eager titles: the row persists on the first message (no kickoff here).
            }
        }
        AppLog.trace("bots", "mint chat for \(profile.name): created \(AppLog.tag(stored))")
        mintedChats[profile.name] = stored
        rebuild()
        return stored
    }

    // MARK: - Pipeline

    private static let titleInUse = JSRegex("already in use", "i")

    private static func decodeRows(_ rows: [JSONValue]) -> [RosterProfile] {
        var seen = Set<String>()
        return rows.compactMap { RosterProfile(json: $0) }.filter { seen.insert($0.name).inserted }
    }

    private func handle(_ event: GatewayEvent) {
        guard event.type == "gateway.ready", !stopped else { return }
        noteSocketOpen()
        // A gateway that came back after a failed or never-finished load: read now instead of waiting for the poll.
        if started, appActive, fullTask == nil, loadTask == nil, phase < .full || isFailed { refreshSoon() }
    }

    private func handle(_ state: ConnectionState) {
        guard !stopped else { return }
        if state == .ready { noteSocketOpen() } else {
            socketOpenedAt = nil; socketOpenedDate = nil
            // [offline] §4.2: a refresh waiting for a socket the outage gate now calls down stops waiting and says so.
            if phase != .none, client.isGatewayDown { resumeReadyWaiters() }
        }
    }

    /// [offline] §4.2: with a list on show and the gateway known down, a refresh fails at once ("Waiting for your
    /// gateway.") instead of waiting out `readyWait`; the reconnect reads again (`handle(_ event:)`).
    static let waitingMessage = "Hermes HQ is waiting for your gateway to reconnect."
    private func failWaitingIfDown() -> Bool {
        guard socketOpenedAt == nil, phase != .none, client.isGatewayDown else { return false }
        lastAttemptEnded = .now
        failureWords = Self.waitingMessage
        setLoadState(.failed(RosterFailure(message: Self.waitingMessage, busy: false, at: Date())))
        return true
    }

    /// [offline] A failed load that the socket has opened since (or is opening now) is out of date: the read that
    /// follows the open has not answered yet. The launch screen covers that read instead of showing "Couldn’t Load Bots"
    /// for a moment (stress round 1).
    var failurePredatesOpen: Bool {
        guard case .failed(let failure) = loadState else { return false }
        guard let opened = socketOpenedDate else { return true }
        return failure.at <= opened
    }
    private var socketOpenedDate: Date?

    private func noteSocketOpen() {
        if socketOpenedAt == nil { socketOpenedAt = .now; socketOpenedDate = Date() }
        resumeReadyWaiters()
    }

    /// Wait until the socket reports ready (bounded): the settle counts from the open, so a read that starts while
    /// the socket is still connecting must not go out the instant it opens (§3 step 3).
    private func waitForSocketOpen(bound: Duration) async {
        guard socketOpenedAt == nil, !stopped, !Task.isCancelled else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: bound)
                    self?.resumeReadyWaiter(id)
                }
                readyWaiters[id] = (continuation, timeout)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeReadyWaiter(id) }
        }
    }

    private func resumeReadyWaiter(_ id: UUID) {
        guard let waiter = readyWaiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume()
    }

    private func resumeReadyWaiters() {
        let waiters = readyWaiters
        readyWaiters = [:]
        for waiter in waiters.values { waiter.timeout.cancel(); waiter.continuation.resume() }
    }

    private var isFailed: Bool { if case .failed = loadState { return true } else { return false } }

    private func initialLoad(_ generation: Int) async {
        if phase <= .cache { await paintSlim(generation) }
        guard generation == lifecycle, !stopped, !Task.isCancelled else { return }
        loadTask = nil
        await fullReadTask().value
    }

    /// The slim answer (§3 step 2), painted over the cache; the full read waits for it at most 1.5 s.
    private func paintSlim(_ generation: Int) async {
        if loadState == .idle { setLoadState(.loading) }
        let client = self.client, timeout = timing.slimTimeout
        let issued = Date()       // settings stream: the write fence compares against when the read was sent
        let slim = Task { [weak self] in
            guard let result = try? await client.call("profiles.list", ["include_sessions": false], timeout: timeout),
                  let rows = result["profiles"]?.array, let self, !Task.isCancelled, !self.stopped,
                  generation == self.lifecycle, self.phase < .full else { return }
            self.applySlim(rows, issuedAt: issued)
        }
        slimTask = slim
        await Self.wait(for: slim, atMost: timing.slimWait)
    }

    private func applySlim(_ rows: [JSONValue], issuedAt: Date = .distantPast) {
        rawRows = RosterSnapshot.mergeSlim(rows.map(RosterText.cleanRow), over: rawRows)
        profiles = Self.decodeRows(rawRows)
        AppLog.trace("bots", "slim read: \(rows.count) rows merged, \(profiles.count) bots")
        rowsArrived(issuedAt: issuedAt)       // settings stream
        phase = .slim
        rebuild()
        photos.rowsArrived(profiles, order: bots.map(\.id), issuedAt: issuedAt)       // [photoheads]
    }

    /// The one full read (§2.1.1 rule 2: never two at once on an account); callers join the one in flight.
    @discardableResult
    private func fullReadTask() -> Task<Void, Never> {
        if let running = fullTask { return running }
        pollTask?.cancel()
        pollTask = nil
        fullToken &+= 1
        let token = fullToken
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performFull()
            guard self.fullToken == token else { return }      // stopped (and maybe restarted) meanwhile
            self.fullTask = nil
            self.isRefreshing = false
            self.schedulePoll()
        }
        fullTask = task
        isRefreshing = true
        return task
    }

    private func refreshSoon() { fullReadTask() }

    private func performFull() async {
        // A read that falls due while a chat is opening waits up to 5 s for it, unless that open is waiting for us.
        let openDeadline = ContinuousClock.now + timing.openWait
        while chatOpening, opensAwaitingRoster == 0, ContinuousClock.now < openDeadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Settle: the socket must have been open 2 s, so launch's own reads (the chat's resume, the sessions list) go
        // first on the gateway's long-handler pool. A socket still connecting is waited for, not skipped.
        if failWaitingIfDown() { return }                                  // [offline] §4.2
        if socketOpenedAt == nil { await waitForSocketOpen(bound: timing.readyWait) }
        if !Task.isCancelled, !stopped, failWaitingIfDown() { return }     // [offline] §4.2
        if let opened = socketOpenedAt, ContinuousClock.now < opened + timing.settle {
            try? await Task.sleep(until: opened + timing.settle, clock: .continuous)
        }
        guard !Task.isCancelled, !stopped else { return }
        if phase == .none, loadState != .loading { setLoadState(.loading) }
        var attempt = 0
        while !Task.isCancelled, !stopped {
            let startedAt = ContinuousClock.now
            let issued = Date()       // settings stream: the write fence compares against when the read was sent
            do {
                let result = try await client.call("profiles.list", [:], timeout: timing.fullTimeout)
                guard !Task.isCancelled, !stopped else { return }
                let snapshot = try RosterSnapshot.decode(result)
                lastReadDuration = ContinuousClock.now - startedAt
                lastAttemptEnded = .now
                AppLog.trace("bots", "full read: \(snapshot.profiles.count) bots in \(AppLog.ms(since: startedAt)) ms" +
                             (attempt > 0 ? " (attempt \(attempt + 1))" : ""))
                applyFull(snapshot, issuedAt: issued)
                return
            } catch where Task.isCancelled || stopped {
                return
            } catch {
                lastAttemptEnded = .now
                let busy = RosterRules.isGatewayBusy(error)
                // A timeout is never retried at once (the gateway keeps computing; the next poll is cheaper).
                // [offline] §6.2: nor is a gateway that cannot be reached; anything else gets the quick retries.
                let again = attempt < timing.retryDelays.count && QueryRetry.shouldRetry(failureCount: 0, error: error)
                if busy || !again || !appActive || stopped {
                    failureWords = RosterStateCopy.words(for: error)
                    AppLog.note("bots", "full read: failed after \(attempt + 1) attempt(s), shown \(RosterRules.errorText(error))")
                    setLoadState(.failed(RosterFailure(message: RosterRules.errorText(error), busy: busy, at: Date())))
                    return
                }
                AppLog.trace("bots", "full read: attempt \(attempt + 1) failed, retrying")
                try? await Task.sleep(for: timing.retryDelays[attempt])
                attempt += 1
            }
        }
    }

    /// Marks the bots whose chat moved past what this device has seen (the chat on screen is acknowledged instead).
    func reconcileUnread(_ rows: [RosterProfile]) {
        let focus = self.focus, active = appActive
        // [botunread] Where the chat's tail can be read, a bot whose chat moved waits for that read: its dot is for
        // something written to you, not for two bots talking (`settleUnread`, BotStore+BotSaid.swift).
        let reads = !stopped && timing.readsBotSaid
        let waiting = Set(device.unread.pending?.keys.map { $0 } ?? [])
        device.unread.reconcile(rows, isVisible: { profile in
            guard active, let focus, focus.profile == profile.name else { return false }
            return profile.canonicalIds.contains(focus.sessionId)
        }, holds: { profile in
            guard reads, let canonical = profile.canonicalSession, !canonical.id.isEmpty else { return false }
            return RosterRules.holdsMessages(canonical)
        })
        for name in device.unread.pending?.keys.map({ $0 }) ?? [] where !waiting.contains(name) { unreadHeldAt[name] = .now }
    }

    private func applyFull(_ snapshot: RosterSnapshot, issuedAt: Date = .distantPast) {
        // [perf] Every poll used to notify the whole app (warmer, presence, notification directory, lists…) even when
        // the answer was identical. Only a byte-identical answer in a steady full/ready state skips the forced notify;
        // rebuild still notifies on its own when the drawn rows or their details moved.
        let previousRows = rawRows, previousPhase = phase, previousLoad = loadState
        let previousDevice = device, previousMinted = mintedChats
        let forced = forceNextNotify
        forceNextNotify = false
        noteRosterMarks(snapshot.profiles)                    // [botsaid] before the activity times are moved up
        profiles = withChatActivity(snapshot.profiles)
        rawRows = snapshot.profiles.map(\.raw)
        phase = .full
        lastUpdated = Date()
        lastSuccess = .now
        rowsArrived(issuedAt: issuedAt, botModeProtocol: snapshot.botModeProtocol)       // settings stream
        // Settings stream (1x-settings §2.4): a bot written since this read was sent keeps this device's meta.
        let fenced = fencedProfiles()
        device.meta = BotMetaMerge.merge(local: device.meta, roster: profiles.filter { !fenced.contains($0.name) })
        device.sections = adoptSections(device.sections, meta: device.meta)
        reconcileUnread(profiles)
        for profile in profiles where !(profile.canonicalSession?.id.isEmpty ?? true) { mintedChats[profile.name] = nil }
        confirmedNoChat = Set(profiles.filter { $0.canonicalSession?.id.isEmpty ?? true }.map(\.name))
        let same = previousPhase == .full && previousLoad == .ready && previousRows == rawRows && previousMinted == mintedChats && !forced
        unchangedReads = same ? unchangedReads + 1 : 0
        AppLog.trace("bots", same ? "full read: unchanged, no notify" : "full read: moved (\(previousRows.count) -> \(rawRows.count) rows)")
        if !same || lastRosterWriteAt.map({ ContinuousClock.now - $0 > .seconds(600) }) ?? true {
            RosterDisk.write(RosterCacheFile(at: Date().timeIntervalSince1970 * 1000, profiles: rawRows), to: rosterURL,
                             keepNewest: (RosterDisk.rosterKind, 3))
            lastRosterWriteAt = .now
        }
        if !same || device != previousDevice { persistState() }
        loadState = .ready
        rebuild(force: !same)
        photos.rowsArrived(profiles, order: bots.map(\.id), issuedAt: issuedAt)       // [photoheads]
        reconcilePinned()             // [botslist] a desktop pin or unpin gets its agreeing section (parity §3 L147)
        refreshBotSaid()              // [botsaid] the rows' previews: the bots' own newest words
    }

    // MARK: - Cadence

    /// [offline] §6.9: one reading of Low Power Mode and heat for every poll (`PowerState`).
    private var lowPower: Bool { PowerState.shared.saving }

    /// [offline] §6.9: the power state changed: the poll is armed again with the new period (overdue runs at once).
    func powerChanged() { schedulePoll() }

    /// `max(30 s on a list / 120 s elsewhere, 10 × the last full read)`, × 3 in Low Power Mode or when hot. On the list
    /// the 30 s grows half again with each read that found nothing new, up to 60 s, and a change brings it back: the
    /// Mac's list is always on screen, so it read every 30 s all day (log study 2026-10-28: 418 reads, nearly all unchanged).
    func pollInterval() -> Duration {
        let base = listVisible ? timing.onListPoll * min(pow(1.5, Double(unchangedReads)), 2) : timing.offListPoll
        let cost = lastReadDuration * timing.pollCostFactor
        let interval = max(base, cost)
        return PowerPolls.period(interval, floor: .zero, saving: lowPower)
    }

    private func isStale(_ age: Duration) -> Bool {
        guard let last = lastSuccess else { return true }
        return ContinuousClock.now - last > age
    }

    private func schedulePoll() {
        pollTask?.cancel()
        pollTask = nil
        guard started, !stopped, appActive, fullTask == nil, loadTask == nil else { return }
        let since = lastAttemptEnded.map { ContinuousClock.now - $0 } ?? .zero
        let wait = max(.zero, pollInterval() - since)
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, self.appActive, !self.stopped else { return }
            self.pollTask = nil
            self.fullReadTask()
        }
    }

    // MARK: - Building rows

    private func setLoadState(_ state: RosterLoadState) {
        guard loadState != state else { return }
        loadState = state
        onChange?()
    }

    func persistState() {
        RosterDisk.write(device, to: stateURL)
        syncChanged?()                                  // [sync]
    }

    /// [sync] Told after every save of the device state (the gateway copy follows the tile and row orders).
    @ObservationIgnored var syncChanged: (() -> Void)?

    #if DEBUG
    /// [sessions-layout] UI tests: the device's unread marks and baselines from scratch. The fixture restamps every
    /// chat when it resets, so the last test's baselines would mark every bot unread in the next one.
    func resetUnreadForTests() {
        guard device.unread != BotUnreadState() else { return }
        device.unread = BotUnreadState()
        persistState()
        rebuild()
    }
    #endif

    func rebuild(notify: Bool = true, force: Bool = false) {
        var meta = device.meta, sections = device.sections
        // Settings stream: fenced rows draw this device's meta, saved heads draw until the roster catches up.
        let profiles = withBotSaid(effectiveProfiles())   // [botsaid]
        if phase == .slim {
            // The slim rows already carry each bot's `ui_meta`: lay sections out from it now (only the full answer is
            // stored, §2 step 4), so a first sign-in doesn't paint a flat list that jumps when the headers arrive
            // ~2.5 s later (verification round 2).
            meta = BotMetaMerge.merge(local: meta, roster: profiles)
            sections = adoptSections(sections, meta: meta, profiles: profiles)
        }
        var input = RosterBuilder.Input(profiles: profiles, meta: meta, sections: sections, pinOrder: device.pinOrder,
                                        unread: device.unread, working: workingProfiles(profiles), mintedChats: mintedChats, previews: previews)
        input.needsInput = needsInput   // [questions]
        input.presence = presence       // [presence]
        input.steps = ownSteps(profiles, working: input.working)   // [toolnow]
        input.waking = wakingBots       // [botslist]
        input.attention = attention.mapValues(\.words)
        input.rowOrder = device.rowOrder   // [manualorder]
        if let draftWords {
            for profile in profiles {
                let canonical = profile.canonicalSession
                let registryId = canonical.flatMap { $0.id.isEmpty ? nil : $0.id }
                let chatId = registryId != nil ? canonical?.openId : mintedChats[profile.name]
                if let words = draftWords(profile.name, chatId)?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty {
                    input.drafts[profile.name] = words
                }
            }
        }
        if let lostWords {
            for profile in profiles {
                var ids = profile.canonicalSession?.ids ?? []
                if let minted = mintedChats[profile.name], !ids.contains(minted) { ids.append(minted) }
                guard !ids.isEmpty else { continue }
                if let words = lostWords(profile.name, ids)?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty {
                    input.lost[profile.name] = words
                }
            }
        }
        let output = RosterBuilder.build(input, model: modelLabel)
        // [manualorder] The saved order follows the bots there are (full answers only: a partial roster drops nobody):
        // a deleted bot's name leaves it, a new bot keeps the place it folded into.
        if let saved = device.rowOrder, phase == .full {
            let next = BotRowOrder.reconciled(saved, blocks: output.layout.rowBlocks, existing: Set(profiles.map(\.name)))
            if next != saved { device.rowOrder = next; persistState() }
        }
        // A chat-lineage or model change can leave the drawn rows as they were: it still has to reach the consumers.
        let detailsChanged = output.details != details
        details = output.details
        previews = output.previews
        let changed = output.layout != layout
        if changed {
            layout = output.layout
            bots = output.layout.flat
        }
        let count = bots.filter { $0.unread && !$0.hidden }.count
        if count != unreadCount { unreadCount = count }
        if changed || detailsChanged || force {
            AppLog.trace("bots", "rebuild: \(profiles.count) bots, \(bots.count) rows shown, \(count) unread")
        }
        if notify, changed || detailsChanged || force { onChange?() }
    }

    isolated deinit {
        for task in [eventsTask, statesTask, loadTask, slimTask, fullTask, pollTask] { task?.cancel() }
        for waiter in readyWaiters.values { waiter.timeout.cancel(); waiter.continuation.resume() }
    }
}

/// One-shot resume for a bounded wait (main actor).
private final class WaitGate {
    var continuation: CheckedContinuation<Void, Never>?
    var timer: Task<Void, Never>?

    func open() {
        timer?.cancel()
        timer = nil
        continuation?.resume()
        continuation = nil
    }
}
