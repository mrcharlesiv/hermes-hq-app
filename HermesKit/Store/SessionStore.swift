// The Sessions tab's data (spec 02 §9; refresh rules spec 03 §7.7): `GET /api/profiles/sessions/sidebar`, painted from
// the device cache at once, refreshed on `sessions.changed` through a leading/trailing throttle (10 s on screen,
// 45 s off screen with a limit-1 probe first), on reconnect (probe, then a short top page merged in with the full
// read owed until the list is on screen, docs/spec/3x-sessions.md §11.5), and by pull to refresh. Background runs and Bot Chats
// are hidden; unread follows the web's rules, and the only write is the open-time `unread:false` PATCH (refused while
// `readOnlyGateway` is on). An older gateway without the batched route gets the three per-slice reads instead.

import Foundation
import Observation

nonisolated struct SessionStoreTiming: Sendable {
    var onScreenGap: Duration = .seconds(10)
    var offScreenGap: Duration = .seconds(45)
    /// [perf] Off screen while a chat is on screen: that chat's own turn sends `sessions.changed` every few seconds, and
    /// each 45 s pass then read the list again for a row the owner is already looking at.
    var focusedChatGap: Duration = .seconds(150)
    /// A full read older than this is redone on a reconnect whatever the probe says.
    var probeMaxAge: Duration = .seconds(600)
    /// [perf] A probe that matched this recently says the list is quiet: the next reconnect's probe goes alone, without
    /// the top page beside it (the gateway answers a cancelled read all the same; a reconnect storm sent one per socket).
    var quietAfterMatch: Duration = .seconds(60)
    /// Polls used only when the gateway does not broadcast `sessions.changed`.
    var fallbackOnScreenPoll: Duration = .seconds(30)
    var fallbackOffScreenPoll: Duration = .seconds(120)
    /// Read each shown chat's newest message for its row (SessionStore+Latest.swift).
    var readsLatest = true
    static let standard = SessionStoreTiming()
}

nonisolated enum SessionsLoadState: Sendable, Equatable {
    case idle
    case loading
    case ready
    /// The read failed, or the gateway's scan of the chats failed (`retry`): show Retry, never "No sessions".
    case failed(message: String, busy: Bool)
}

/// A labelled block of the Sessions list: "Pinned", then date ranges ("Earlier today", "Yesterday", …).
nonisolated struct SessionListSection: Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    var sessions: [SessionSummary]
}

/// Device-local Sessions state, persisted per gateway account.
nonisolated struct SessionsDeviceState: Codable, Sendable, Hashable {
    var unread = SessionUnreadState()
    /// Filter › Show › Background Runs (`dispatch.sessions.showRuns`).
    var showBackgroundRuns = false
    /// Filter › Show › Outside Chats: Telegram, Discord, API and other chats that started outside the app (off until
    /// turned on).
    var showOutsideChats = false
    /// More › Color by the chat's durable id (lineage root, else its id) → `SessionColors` index (device-local, as
    /// the web's `hermes.desktop.sessionColors`).
    var colors: [String: Int] = [:]
    // [sessions-m9] Filter & Sort's choices (docs/spec/3x-sessions.md §3.2), and each bot's projects as last read, so a
    // project filter left on names itself (the strip) at the first paint of the next launch.
    var view = SessionsViewPrefs()
    var projects: [String: [SessionProject]] = [:]
    // [/sessions-m9]
    /// Each chat's newest message by write key (SessionStore+Latest.swift).
    var latest: [String: SessionLatestMessage] = [:]
    /// Pin / Unpin by write key that the gateway refused while another process owned the profile (SessionWrite's
    /// maintenance refusal, Hermes before 0.22.3): kept here and laid over every page until the gateway agrees.
    var pins: [String: Bool] = [:]
    /// The Sessions list's closed groups (`SessionListPipeline.folded`) by the chip's bot ("*" for All): group ids.
    var collapsedGroups: [String: [String]] = [:]
    /// [sessions-layout] The projects the user opened (Group By Project starts each one folded to its summary row), by
    /// the chip's bot ("*" for All): group ids.
    var openGroups: [String: [String]] = [:]
    /// [manual-order] Sort By Manual: the chats in the order they were dragged into (row keys, `SessionListPipeline.key`).
    /// Kept when another sort is picked, so Manual brings it back.
    var chatOrder: [String] = []
    /// [manual-order] Group By Project: the projects (keys, Home's too) and Group By Bot: the bots (profiles), in the
    /// order the user put them in. Empty: newest chat first (Home last).
    var projectOrder: [String] = []
    var botGroupOrder: [String] = []
    /// [manual-order] Projects marked Favorite: always first under Group By Project (owner, 2026-10-29).
    var favoriteProjects: [String] = []

    init() {}

    // Fields added later decode as absent, so an older file keeps its unread state.
    private enum CodingKeys: String, CodingKey {
        case unread, showBackgroundRuns, showOutsideChats, colors, view, projects, latest, pins, collapsedGroups
        case chatOrder, projectOrder, botGroupOrder, favoriteProjects, openGroups
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unread = try c.decodeIfPresent(SessionUnreadState.self, forKey: .unread) ?? SessionUnreadState()
        showBackgroundRuns = try c.decodeIfPresent(Bool.self, forKey: .showBackgroundRuns) ?? false
        showOutsideChats = try c.decodeIfPresent(Bool.self, forKey: .showOutsideChats) ?? false
        colors = try c.decodeIfPresent([String: Int].self, forKey: .colors) ?? [:]
        view = (try? c.decodeIfPresent(SessionsViewPrefs.self, forKey: .view)) ?? SessionsViewPrefs()      // [sessions-m9]
        projects = (try? c.decodeIfPresent([String: [SessionProject]].self, forKey: .projects)) ?? [:]     // [sessions-m9]
        latest = (try? c.decodeIfPresent([String: SessionLatestMessage].self, forKey: .latest)) ?? [:]
        pins = (try? c.decodeIfPresent([String: Bool].self, forKey: .pins)) ?? [:]
        collapsedGroups = (try? c.decodeIfPresent([String: [String]].self, forKey: .collapsedGroups)) ?? [:]
        chatOrder = (try? c.decodeIfPresent([String].self, forKey: .chatOrder)) ?? []
        projectOrder = (try? c.decodeIfPresent([String].self, forKey: .projectOrder)) ?? []
        botGroupOrder = (try? c.decodeIfPresent([String].self, forKey: .botGroupOrder)) ?? []
        favoriteProjects = (try? c.decodeIfPresent([String].self, forKey: .favoriteProjects)) ?? []
        openGroups = (try? c.decodeIfPresent([String: [String]].self, forKey: .openGroups)) ?? [:]
    }
}

nonisolated struct SessionsCacheFile: Codable, Sendable {
    var at: Double                   // ms since the epoch
    var recents: [SidebarSessionRow]
    var cron: [SidebarSessionRow]
    var messaging: [SidebarSessionRow]
}

/// "Leading edge if its gap has passed, else one trailing run at lastRun + gap; never stack" (spec 03 §7.7).
@MainActor
final class ChangeThrottle {
    private let action: () async -> Void
    private let gap: () -> Duration
    private let allowed: () -> Bool
    private(set) var dirty = false
    private var running = false
    private var lastRun: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?

    init(gap: @escaping () -> Duration, allowed: @escaping () -> Bool, action: @escaping () async -> Void) {
        self.gap = gap; self.allowed = allowed; self.action = action
    }

    func mark() {
        dirty = true
        pump()
    }

    /// Run a pending pass if it may run now (call when the gap or the permission changed).
    func pump() {
        guard dirty, !running, allowed() else { return }
        let now = ContinuousClock.now
        if let last = lastRun, now < last + gap() {
            timer?.cancel()
            let due = last + gap()
            timer = Task { [weak self] in
                try? await Task.sleep(until: due, clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                self.timer = nil
                self.pump()
            }
            return
        }
        timer?.cancel()
        timer = nil
        dirty = false
        running = true
        lastRun = now
        Task { [weak self] in
            await self?.action()
            guard let self else { return }
            self.running = false
            self.pump()
        }
    }

    /// Note a pass that ran outside the throttle (a pull to refresh): the gap counts from it.
    func noteRan() { lastRun = .now }

    func cancel() {
        timer?.cancel()
        timer = nil
        dirty = false
    }
}

@MainActor @Observable
final class SessionStore {
    static let sidebarPath = "/api/profiles/sessions/sidebar"
    /// The per-slice route older gateways have instead of the batched sidebar (spec 02 §9.1).
    static let legacyPath = "/api/profiles/sessions"
    static let recentsExclude = "acp,cron,kanban,oneshot,subagent,telegram,discord,slack,mattermost,matrix,signal,whatsapp,bluebubbles,photon,homeassistant,email,sms,webhook,api_server,weixin,wecom,qqbot,yuanbao,dingtalk,feishu"
    static let messagingExclude = "cron,acp,cli,codex,desktop,gateway,kanban,local,tui"
    /// The sources the recents leave out: an archived chat from one of them is an outside chat.
    static let recentsExcluded = Set(recentsExclude.split(separator: ",").map(String.init))

    let account: GatewayAccount

    /// The dated list: pinned chats first, then newest first. Background runs (unless shown) and Bot Chats left out.
    private(set) var sessions: [SessionSummary] = []
    /// Scheduled job runs ("Cron jobs" folder).
    private(set) var cronSessions: [SessionSummary] = []
    /// Messaging-platform threads and one-off runs.
    private(set) var messagingSessions: [SessionSummary] = []
    /// Filter › Show › Archived: the archived chats (`GET /api/profiles/sessions?archived=only`), read when it comes on
    /// (SessionStore+Actions.swift) and listed with the rest; runs and outside chats only as Show's other checks allow.
    internal(set) var archivedSessions: [SessionSummary] = []
    internal(set) var archivedLoadState: SessionsLoadState = .idle
    private(set) var loadState: SessionsLoadState = .idle
    /// Any chat on hand, read or cached, hidden ones included: with none, an empty list is not known to be empty yet
    /// (`SessionsEmptyState`).
    var holdsRows: Bool { !(recents.isEmpty && cron.isEmpty && messaging.isEmpty) }
    /// When the shown list was read (the cache's own time for a cached paint).
    private(set) var lastUpdated: Date?
    /// Sessions tab badge: unread rows the list shows.
    private(set) var unreadCount = 0
    private(set) var isRefreshing = false

    /// Filter › Show › Background Runs (persisted per account).
    var showBackgroundRuns = false {
        didSet {
            guard showBackgroundRuns != oldValue else { return }
            device.showBackgroundRuns = showBackgroundRuns
            persistState()
            rebuild()
        }
    }

    /// Posted when Outside Chats turns on or off: the push registration asks for those chats' alerts with it.
    nonisolated static let outsideChatsChanged = Notification.Name("SessionStore.outsideChatsChanged")

    /// Filter › Show › Outside Chats (persisted per account).
    var showOutsideChats = false {
        didSet {
            guard showOutsideChats != oldValue else { return }
            device.showOutsideChats = showOutsideChats
            persistState()
            rebuild()
            NotificationCenter.default.post(name: Self.outsideChatsChanged, object: self)
        }
    }

    // [sessions-m9] Filter & Sort (docs/spec/3x-sessions.md §3.2, §3.6, §9.4, §11); the work is in SessionStore+View.swift.
    /// What the user chose in the Filter & Sort menu (kept per account on the device).
    var view = SessionsViewPrefs()
    /// The chip's bot. In memory only: every launch opens on All.
    var botFilter: String?
    /// [sessions-fresh] The New or Working chip. In memory only, as the bot chip.
    var statusChip: SessionStatusChip?
    /// The reconnect probe's counters: limit-1 probes sent, full reads they saved, full reads made.
    private(set) var probeStats = SidebarProbeStats() {
        didSet { if probeStats != oldValue { onProbeStats?(probeStats) } }
    }
    @ObservationIgnored var onProbeStats: ((SidebarProbeStats) -> Void)?
    /// The row's pending line (a send that may not have arrived, else words waiting in the field), wired by the app.
    /// [sessions-m9] A chat was deleted on the gateway: what the device kept for it alone (its lost sends) can go.
    @ObservationIgnored var onDeleted: ((_ profile: String, _ storedId: String) -> Void)?
    @ObservationIgnored var pendingLine: ((_ profile: String, _ storedId: String) -> SessionPending?)?
    /// Stored ids of chats where a prompt waits for the user.
    @ObservationIgnored var needsInput: Set<String> = []
    /// When each bot's projects were last asked for, and the asks in the air.
    @ObservationIgnored var projectsReadAt: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored var projectReads: Set<String> = []
    /// Bots whose projects wait their turn (at most `projectsWindow` asks in the air).
    @ObservationIgnored var projectQueue: [String] = []
    /// The recents limit the last full read asked for (50, or 300 while a filter is on), and a deeper read owed.
    @ObservationIgnored private(set) var lastFullLimit = 0
    @ObservationIgnored var deepReadOwed = false
    // [/sessions-m9]

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var modelLabel: (String) -> String = { $0 } {
        didSet { words = [:]; rebuild() }
    }
    /// "All Bots": the recents come from every profile (the phone's default once ≥2 profiles exist).
    @ObservationIgnored var allBots = true
    /// Testing switch for the owner's real gateway (spec 02 §12.5): refuse every write and clear dots locally instead.
    /// Set together with `BotStore.readOnlyGateway` from one app-wide flag.
    @ObservationIgnored var readOnlyGateway = false
    /// Owner names by profile (from the Bots roster); a profile missing here reads "Hermes" / its readable name.
    @ObservationIgnored var profileDisplayNames: [String: String] = [:]

    @ObservationIgnored let client: any GatewayClient
    @ObservationIgnored let timing: SessionStoreTiming
    @ObservationIgnored private let routingProfile: String
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let stateURL: URL
    /// [sync] No device state on disk at launch (signed out and back in, or never saved): `GatewaySync` takes the
    /// gateway's orders instead of sending this empty copy.
    @ObservationIgnored private(set) var syncStartedEmpty = false
    // Internal for the row actions (SessionStore+Actions.swift).
    @ObservationIgnored var recents: [SidebarSessionRow] = []
    @ObservationIgnored var cron: [SidebarSessionRow] = []
    @ObservationIgnored var messaging: [SidebarSessionRow] = []
    @ObservationIgnored private(set) var rowsById: [String: SidebarSessionRow] = [:]
    /// The newest-message reads waiting and in the air, and answers not yet drawn (SessionStore+Latest.swift).
    @ObservationIgnored var latestQueue: [SidebarSessionRow] = []
    @ObservationIgnored var latestReads: Set<String> = []
    @ObservationIgnored var latestDirty = 0
    @ObservationIgnored var device = SessionsDeviceState()
    /// Archived rows as read (the Archived view), and rows whose Archive or Delete is in the air (left out of the
    /// list until the gateway answers; a failure brings them back).
    @ObservationIgnored var archivedRows: [SidebarSessionRow] = []
    @ObservationIgnored var leaving: Set<String> = []
    /// Projects opened with Show More, by the chip's bot ("*" for All); not kept across launches.
    @ObservationIgnored var expandedGroups: [String: Set<String>] = [:]
    /// [sessions-layout] Chats kept in New for You until the page is left (row keys), read or not (`holdNew`).
    @ObservationIgnored var keepNew: Set<String> = []
    /// Projects per profile (Move to Project ›), as last read.
    @ObservationIgnored var projectsByProfile: [String: [SessionProject]] = [:] {
        didSet { if projectsByProfile != oldValue { projectsChanged() } }      // [sessions-m9] kept for the next launch; the list regroups
    }
    @ObservationIgnored private var running: Set<String> = []
    /// [toolnow] Stored id → the running turn's newest step in a few words (LiveSteps).
    @ObservationIgnored private var steps: [String: String] = [:]
    /// The selected chat (the web's `$selectedStoredSessionId`): set when a chat is focused and kept after the user
    /// leaves it, until another chat is focused. Its stored count is absorbed on every read and its local dot is
    /// skipped, so the chat the user just used does not come back unread (the server's own flag still shows).
    @ObservationIgnored private var selectedSessionId: String?
    /// Our own `unread` writes not yet answered by a list page read after the gateway acknowledged them.
    @ObservationIgnored private var unreadWrites: [String: UnreadWrite] = [:]
    @ObservationIgnored private var unreadWriteTokens = 0
    /// Title and preview per row, reused while the row is unchanged (rebuilds for running/unread changes are cheap).
    @ObservationIgnored private var words: [String: RowWords] = [:]

    @ObservationIgnored private var started = false
    @ObservationIgnored private(set) var stopped = false
    @ObservationIgnored private var appActive = true
    @ObservationIgnored private var listVisible = false
    @ObservationIgnored private var changeEvents: Bool?
    @ObservationIgnored var lastFingerprint: String?
    @ObservationIgnored private var lastFullAt: ContinuousClock.Instant?
    /// [perf-returns] When `lastFingerprint` was read (a full read or a top page, §11.5): the probe's own age.
    @ObservationIgnored private var lastFingerprintAt: ContinuousClock.Instant?
    /// [perf] When a reconnect's probe last matched (cleared when one differs): see `SessionStoreTiming.quietAfterMatch`.
    @ObservationIgnored private var lastProbeMatchAt: ContinuousClock.Instant?
    /// [perf-returns] A top page stood in for a full read: the full list is read once the list is on screen and the
    /// last full read is older than `probeMaxAge` (or on pull to refresh, or when a filter needs the deep page).
    @ObservationIgnored private(set) var fullReadOwed = false
    @ObservationIgnored private var lastReadDuration: Duration = .zero
    /// The gateway 404s the batched route: read the three slices instead (remembered for this store's life).
    @ObservationIgnored private var sidebarRouteMissing = false
    @ObservationIgnored private var throttle: ChangeThrottle?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var readInFlight: Task<Void, Never>?
    /// The read in flight may end at the probe without a full read.
    @ObservationIgnored private var readInFlightProbes = false
    @ObservationIgnored private var readToken = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// [reliability] Bumped on every trip to the background and every return; `readInFlightEpoch` is the one the read
    /// in flight began in. A reconnect after a trip away doesn't join a read from before it (that read was suspended with
    /// the app), even one a network change started during the background grace.
    @ObservationIgnored private var backgroundEpoch = 0
    @ObservationIgnored private var readInFlightEpoch = 0
    /// [phone-logs] The app went to the background since it was last active (a cold launch's first active is no return).
    @ObservationIgnored private var wentToBackground = false
    /// [perf] A chat is on screen (the throttle's off-screen gap stretches to `focusedChatGap`).
    @ObservationIgnored private var chatFocused = false
    /// [perf] When the device cache was last written: an unchanged answer rewrites it at most every 10 minutes.
    @ObservationIgnored private var lastCacheWriteAt: ContinuousClock.Instant?
    /// [perf] A pull always ends with a notify (it ends the spinner), even when the answer matches the last one; a
    /// reconnect, poll or event read with the same answer stays quiet.
    @ObservationIgnored private var forceNextNotify = false

    private struct UnreadWrite {
        var token: Int
        var value: Bool
        /// The last confirmed value before this write: what a failure rolls back to.
        var prior: Bool?
        /// When the gateway acknowledged the write; nil while it is in the air.
        var ackAt: ContinuousClock.Instant?
    }

    private struct RowWords {
        var row: SidebarSessionRow
        var latest: String?
        var title: String
        var preview: String?
    }

    init(client: any GatewayClient, account: GatewayAccount, cacheDirectory: URL, routingProfile: String = "default",
         timing: SessionStoreTiming = .standard, autoStart: Bool = true) {
        self.client = client
        self.account = account
        self.timing = timing
        self.routingProfile = routingProfile
        cacheURL = RosterDisk.url(cacheDirectory, RosterDisk.sessionsKind, account)
        stateURL = RosterDisk.url(cacheDirectory, RosterDisk.sessionStateKind, account)
        if let state = RosterDisk.read(SessionsDeviceState.self, from: stateURL) { device = state } else { syncStartedEmpty = true }
        showBackgroundRuns = device.showBackgroundRuns
        showOutsideChats = device.showOutsideChats
        view = device.view                              // [sessions-m9]
        projectsByProfile = device.projects             // [sessions-m9]
        if let cached = RosterDisk.read(SessionsCacheFile.self, from: cacheURL) {
            recents = cached.recents; cron = cached.cron; messaging = cached.messaging
            lastUpdated = Date(timeIntervalSince1970: cached.at / 1000)
        }
        changeEvents = client.latestReady?["change_events"]?.bool
        rebuild(notify: false)
        throttle = ChangeThrottle(
            gap: { [weak self] in self?.currentGap ?? .seconds(45) },
            allowed: { [weak self] in self.map { $0.appActive && !$0.stopped } ?? false },
            action: { [weak self] in await self?.throttledPass() })
        if autoStart { start() }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        stopped = false
        AppLog.trace("sessions", "store start: \(recents.count) recents, \(cron.count) cron, \(messaging.count) messaging from cache")
        let client = self.client
        eventsTask = Task { [weak self] in
            for await event in client.events() {
                guard let self else { return }
                self.handle(event)
            }
        }
        readTask(probeFirst: false)
    }

    func stop() {
        AppLog.trace("sessions", "store stop")
        stopped = true
        started = false
        throttle?.cancel()
        for task in [eventsTask, readInFlight, pollTask] { task?.cancel() }
        eventsTask = nil; readInFlight = nil; pollTask = nil
        readInFlightProbes = false
        readToken &+= 1
        isRefreshing = false
        forceNextNotify = false
        chatFocused = false
        lastProbeMatchAt = nil
        latestQueue = []
    }

    func removeCachedData() {
        RosterDiskWriter.shared.remove(cacheURL)
        RosterDiskWriter.shared.remove(stateURL)
    }

    func appDidBecomeActive() {
        appActive = true
        // [reliability] Any read still out began before this return (maybe frozen mid-flight in the grace).
        // [phone-logs] Only a return from the background counts: on a cold launch the first active comes after the
        // launch's own read started, and the connect's refresh cancelled that read every launch (logged as a failed
        // read, 1–3 s of work thrown away while the gateway was busiest).
        if wentToBackground { backgroundEpoch &+= 1 }
        wentToBackground = false
        throttle?.pump()
        schedulePoll()
    }

    func appDidEnterBackground() {
        appActive = false
        wentToBackground = true
        backgroundEpoch &+= 1
        pollTask?.cancel()
        pollTask = nil
    }

    /// The Sessions list is on screen: changes refresh within 10 s with a full read; off screen within 45 s, probe first.
    func setListVisible(_ visible: Bool) {
        if listVisible != visible { AppLog.trace("sessions", "list \(visible ? "visible" : "hidden")") }
        listVisible = visible
        throttle?.pump()
        schedulePoll()
        readOwedFullList()                              // [perf-returns]
    }

    /// [perf] A chat came on (true) or left (false) the screen: while one is on, an off-screen pass waits
    /// `focusedChatGap`. Leaving pumps the throttle, so a pass held back by the longer gap runs at the shorter one.
    func setChatFocused(_ focused: Bool) {
        guard chatFocused != focused else { return }
        chatFocused = focused
        throttle?.pump()
    }

    /// [diagnostics] The reconnect's read is out (for timing a chat's catch-up against it).
    var isReconnectReadInFlight: Bool { readInFlight != nil && reconnectReadOut }

    /// The chat on screen (its stored id; pass bot chats too), or nil when it leaves. The selection sticks after the
    /// chat leaves until another chat is focused (web parity): its stored count is absorbed into the seen watermark on
    /// every refresh and it shows no local dot.
    func setFocusedSession(_ id: String?) {
        guard let id else { return }
        selectedSessionId = id
        absorbSelected()
        persistState()
        rebuild()
    }

    /// Sessions running a turn right now (fed by the chat engine / live statuses).
    func setRunning(_ ids: Set<String>) {
        guard ids != running else { return }
        running = ids
        rebuild()
    }

    /// [toolnow] The running chats' newest steps by stored id: a row names its step instead of "Working…".
    func setSteps(_ next: [String: String]) {
        guard next != steps else { return }
        steps = next
        rebuild()
    }

    /// Pull to refresh: always ends in a full read. Joins a full read in flight; after a probe-first read in flight
    /// (which may stop at an unchanged fingerprint) it reads in full.
    func refresh() async {
        guard started, !stopped else { return }
        AppLog.trace("sessions", "pull to refresh: started")
        forceNextNotify = true
        throttle?.noteRan()
        var waits = 0
        while let running = readInFlight, readInFlightProbes, waits < 3 {
            await running.value
            waits += 1
        }
        await readTask(probeFirst: false).value
    }

    // MARK: - Reads for the UI

    func row(for id: String) -> SidebarSessionRow? { rowsById[id] }

    /// "Hermes", the bot's display name, or its readable profile name.
    func ownerName(for session: SessionSummary) -> String {
        SessionRules.ownerName(profile: session.profile, displayNames: profileDisplayNames)
    }

    /// The second line: "<Owner> · <preview>", "<Owner> · Working…" (or its step), or the owner alone.
    func detailLine(for session: SessionSummary) -> String {
        let owner = ownerName(for: session)
        if session.isRunning { return "\(owner) · \(session.step.map(LiveSteps.line) ?? "Working…")" }
        return session.preview.map { "\(owner) · \($0)" } ?? owner
    }

    /// The list grouped for drawing: "Pinned" first, then every date range labelled (the newest too, r6-41).
    func sections(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> [SessionListSection] {
        let pinned = sessions.filter { rowsById[$0.id]?.pinned == true }
        let rest = sessions.filter { rowsById[$0.id]?.pinned != true }
        var out: [SessionListSection] = []
        if !pinned.isEmpty { out.append(SessionListSection(id: "pinned", title: "Pinned", sessions: pinned)) }
        let groups = SessionDateGroups.group(rest, seconds: { $0.lastActive?.timeIntervalSince1970 ?? 0 },
                                             now: now, calendar: calendar, locale: locale)
        out += groups.map { SessionListSection(id: $0.bucket.key, title: $0.bucket.label, sessions: $0.items) }
        return out
    }

    // MARK: - Opening a row

    /// A user opened a listed row: select it, clear its local unread state, and when the server says it is unread send
    /// `PATCH /api/sessions/{id} {"unread":false,"profile":p}` (spec 02 §9.3): the row is rewritten optimistically, a
    /// list page read before the gateway acknowledged the write cannot bring the dot back, and a failure restores the
    /// last confirmed value if this write still owns the row. Read-only gateway: no write, the dot clears locally.
    func markOpened(_ session: SessionSummary) {
        guard let row = listedRow(id: session.id, profile: session.profile) else { return }
        selectedSessionId = row.id
        let serverUnread = row.unread == true
        device.unread.opened(row, clearServerLocally: serverUnread && readOnlyGateway)
        persistState()
        if serverUnread && !readOnlyGateway { writeUnread(false, row: row) }
        rebuild()
    }

    func writeUnread(_ unread: Bool, row: SidebarSessionRow) {
        let ticket = beginUnreadWrite(unread, row: row)
        writeCache()
        let client = self.client
        Task { [weak self] in
            let error = await Self.sendUnread(ticket, client: client)
            self?.settleUnreadWrite(ticket, error: error)
        }
    }

    // [sessions-m9] The write in three steps, so Mark All as Read (SessionStore+View.swift) can run many of them four
    // at a time and hear which failed. An unread-only write keeps the last read's fingerprint (§11.2: the store's own
    // value is on screen and fenced; a differing newest or pinned row still changes the probe's answer).
    struct UnreadWriteTicket: Sendable {
        var key: String
        var token: Int
        var id: String
        var profile: String
        var value: Bool
        /// The last confirmed value before this write: what a failure rolls back to.
        var prior: Bool?
    }

    /// The optimistic half: the row shows the value at once and the write owns the row until it is answered.
    func beginUnreadWrite(_ unread: Bool, row: SidebarSessionRow) -> UnreadWriteTicket {
        let key = Self.writeKey(id: row.id, profile: row.profile)
        unreadWriteTokens &+= 1
        let token = unreadWriteTokens
        // An earlier write still in the air has confirmed nothing: its own prior is the last confirmed value.
        let prior = unreadWrites[key].map { $0.ackAt == nil ? $0.prior : $0.value } ?? row.unread
        unreadWrites[key] = UnreadWrite(token: token, value: unread, prior: prior, ackAt: nil)
        setServerUnread(unread, id: row.id, profile: row.profile)
        return UnreadWriteTicket(key: key, token: token, id: row.id, profile: row.profile, value: unread, prior: prior)
    }

    /// `PATCH /api/sessions/{id}?profile=p {"unread": v, "profile": p}`; the error when it failed.
    static func sendUnread(_ ticket: UnreadWriteTicket, client: any GatewayClient) async -> (any Error)? {
        do {
            try await SessionWrite.patch(client, id: ticket.id, profile: ticket.profile, ["unread": .bool(ticket.value)])
            return nil
        } catch {
            return error
        }
    }

    /// The gateway answered. A failure rolls back only while this write still owns the row; otherwise it is "healed
    /// by the next honest refresh".
    func settleUnreadWrite(_ ticket: UnreadWriteTicket, error: (any Error)?) {
        guard unreadWrites[ticket.key]?.token == ticket.token else { return }
        guard error != nil else {
            unreadWrites[ticket.key]?.ackAt = .now
            return
        }
        unreadWrites[ticket.key] = nil
        if let error = error as? HTTPError, SessionWrite.isMaintenanceRefusal(error) {
            keepUnreadOnDevice(ticket.value, id: ticket.id, profile: ticket.profile)
        }
        if let prior = ticket.prior {
            setServerUnread(prior, id: ticket.id, profile: ticket.profile)
            writeCache()
        }
        rebuild()
    }
    // [/sessions-m9]

    static func writeKey(id: String, profile: String) -> String { profile + "\u{0}" + id }

    /// A scheduled job's run (`source = "cron"` or an id starting `cron_`, spec 02 §6): shown, as the background runs,
    /// only with Show › Background Runs.
    static func isScheduledRun(_ row: SidebarSessionRow) -> Bool {
        ChatSource.id(row.source) == ChatSource.scheduled || row.id.hasPrefix("cron_")
    }

    /// MENUS (spec 1x §4.5): a rename shows on the row at once (optimistic; a rollback passes the old title). Every list
    /// that holds the chat's row is rewritten; the next read brings the gateway's own title.
    func applyTitle(id: String, title: String?) {
        let value = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = false
        func update(_ rows: inout [SidebarSessionRow]) {
            for index in rows.indices where rows[index].id == id && rows[index].title != value {
                rows[index].title = value
                changed = true
            }
        }
        update(&recents); update(&cron); update(&messaging)
        guard changed else { return }
        lastFingerprint = nil
        writeCache()
        rebuild()
    }

    /// MENUS (⋯ › Pin, Mark as Read/Unread): the chat's row as the gateway took the write, at once (the next read brings
    /// the gateway's own). Every list that holds the row is rewritten.
    /// [sessions-m9] `forgetsRead: false` for a write that only sets `unread` (§11.2): the last read's fingerprint stays.
    func updateRow(id: String, profile: String, forgetsRead: Bool = true, _ change: (inout SidebarSessionRow) -> Void) {
        var changed = false
        func update(_ rows: inout [SidebarSessionRow]) {
            for index in rows.indices where rows[index].id == id && rows[index].profile == profile {
                let before = rows[index]
                change(&rows[index])
                if rows[index] != before { changed = true }
            }
        }
        update(&recents); update(&cron); update(&messaging)
        guard changed else { return }
        if forgetsRead { lastFingerprint = nil }
        writeCache()
        rebuild()
    }

    /// MENUS (⋯ › Archive, Delete Chat): the chat leaves every list at once.
    func forget(id: String, profile: String) {
        let before = recents.count + cron.count + messaging.count
        recents.removeAll { $0.id == id && $0.profile == profile }
        cron.removeAll { $0.id == id && $0.profile == profile }
        messaging.removeAll { $0.id == id && $0.profile == profile }
        guard recents.count + cron.count + messaging.count != before else { return }
        if selectedSessionId == id { selectedSessionId = nil }
        lastFingerprint = nil
        writeCache()
        rebuild()
    }

    /// Rewrite the stored rows' server flag (every list that holds this profile's row, the Archived view's included: an
    /// archived chat's Mark as Read, or opening it, kept its dot until the next archived read).
    private func setServerUnread(_ unread: Bool, id: String, profile: String) {
        func update(_ rows: inout [SidebarSessionRow]) {
            for index in rows.indices where rows[index].id == id && rows[index].profile == profile { rows[index].unread = unread }
        }
        update(&recents); update(&cron); update(&messaging); update(&archivedRows)
    }

    /// The gateway refused the write (SessionWrite's maintenance refusal, Hermes before 0.22.3) and has no other way to
    /// take it: this device keeps the value: a marker for unread, a local read (as a read-only gateway's) for read.
    func keepUnreadOnDevice(_ unread: Bool, id: String, profile: String) {
        var bucket = device.unread.markers[profile] ?? []
        bucket.removeAll { $0 == id }
        if unread { bucket.append(id) }
        device.unread.markers[profile] = bucket.isEmpty ? nil : bucket
        if !unread, let row = listedRow(id: id, profile: profile) { device.unread.opened(row, clearServerLocally: true) }
        persistState()
        rebuild(force: true)
    }

    /// The same for Pin / Unpin: kept here and laid over every page until the gateway agrees (`SessionsDeviceState.pins`).
    func keepPinOnDevice(_ pinned: Bool, id: String, profile: String) {
        device.pins[Self.writeKey(id: id, profile: profile)] = pinned
        persistState()
    }

    func listedRow(id: String, profile: String) -> SidebarSessionRow? {
        (recents + cron + messaging).first { $0.id == id && $0.profile == profile } ?? rowsById[id]
    }

    /// [sessions-m9] Either unread source says this listed chat is unread (the row's own rule, §5.6 `anyUnread`).
    func isUnreadNow(_ row: SidebarSessionRow) -> Bool {
        device.unread.isUnread(row, messaging: false, selected: row.id == selectedSessionId)
    }

    // MARK: - Pipeline

    private var currentGap: Duration {
        listVisible ? timing.onScreenGap : chatFocused ? timing.focusedChatGap : timing.offScreenGap
    }

    /// [offline] §6.4: the last reconnect refresh (HermesKit/Store/ReconnectShare.swift).
    /// Not private: a unit test that reconnects several times in a row starts each one with a fresh share.
    @ObservationIgnored var reconnectShare = ReconnectShare()
    @ObservationIgnored private var reconnectReadOut = false

    private func handle(_ event: GatewayEvent) {
        guard !stopped else { return }
        switch event.type {
        case "sessions.changed":
            throttle?.mark()
        case "gateway.ready":
            changeEvents = event.payload["change_events"]?.bool ?? false
            // A reconnect: probe first while the last full read is fresh, else read in full.
            // [offline] §6.4: reconnects within 3 s of each other share one refresh (a failed one is not shared).
            guard reconnectShare.begin() else { break }
            // (review) Whatever read covers this reconnect, one in flight included, answers for it: if that read
            // does not end in a list or an unchanged probe, the share is given back and the next open reads again.
            reconnectReadOut = true
            refreshAfterReconnect()                   // [sessions-m9] the one probe (§11.2), inside the share
        default:
            break
        }
    }

    private func throttledPass() async {
        await readTask(probeFirst: !listVisible).value
    }

    /// [sessions-m9] The one reconnect read (§11.2; the offline stream's "shared within 3 s" rule wraps this call): a
    /// limit-1 probe first while the last read is fresh and nothing but read marks was written since; then (the probe
    /// differs, or the last read is old) the short top page merged in, with the full read owed (§11.5); else the full
    /// read. Joins a read already in flight.
    @discardableResult
    func refreshAfterReconnect() -> Task<Void, Never> {
        // [reliability] A read that began before the app last went to the background was suspended with it: joining it
        // timed the time away as read time and could apply a pre-background answer, or fail on its idle timeout right
        // after the return. Start a fresh one instead.
        if readInFlight != nil, readInFlightEpoch != backgroundEpoch { supersedeRead() }
        return readTask(probeFirst: true)
    }

    /// [reliability] Drops the read in flight; its late end changes nothing (`readToken`).
    private func supersedeRead() {
        readInFlight?.cancel()
        readInFlight = nil
        readInFlightProbes = false
        readToken &+= 1
        AppLog.note("sessions", "reconnect refresh: superseded a read from before the background")
    }

    /// [sessions-m9] A full read now (a filter came on and the loaded page is the short one, §3.6). Never a probe.
    func readInFull() {
        guard started, !stopped else { return }
        if readInFlight != nil { deepReadOwed = true; return }
        AppLog.trace("sessions", "deep read: a filter needs the full page")
        readTask(probeFirst: false)
    }

    @discardableResult
    private func readTask(probeFirst: Bool) -> Task<Void, Never> {
        if let running = readInFlight { return running }
        pollTask?.cancel()
        pollTask = nil
        readToken &+= 1
        let token = readToken
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRead(probeFirst: probeFirst, token: token)
            guard self.readToken == token else { return }      // stopped (and maybe restarted) meanwhile
            self.readInFlight = nil
            self.readInFlightProbes = false
            self.isRefreshing = false
            self.schedulePoll()
            if self.deepReadOwed {                          // [sessions-m9] the read that just ended asked for the short page
                self.deepReadOwed = false
                if self.wantsDeepRead, self.lastFullLimit < Self.deepRecentsLimit { self.readTask(probeFirst: false) }
            }
            // [perf-returns] The list came on screen meanwhile. Not after a full read: that was the owed read, and when it
            // failed (gateway down: each one fails at once) chasing it again spun ~15,000 reads a second until iOS
            // killed the app (build 483, 2026-10-30). The poll or the list's next appearance tries again.
            if probeFirst { self.readOwedFullList() }
        }
        readInFlight = task
        readInFlightProbes = probeFirst
        readInFlightEpoch = backgroundEpoch
        isRefreshing = true
        return task
    }

    private func query(limits: (Int, Int, Int)) -> [URLQueryItem] {
        [URLQueryItem(name: "recents_profile", value: recentsProfile),
         URLQueryItem(name: "recents_limit", value: String(limits.0)),
         URLQueryItem(name: "cron_limit", value: String(limits.1)),
         URLQueryItem(name: "messaging_limit", value: String(limits.2)),
         URLQueryItem(name: "recents_exclude", value: Self.recentsExclude),
         URLQueryItem(name: "messaging_exclude", value: Self.messagingExclude),
         URLQueryItem(name: "profile", value: routingProfile)]
    }

    private var recentsProfile: String { allBots ? "all" : routingProfile }

    /// The sidebar answer: the batched route, or (an older gateway that 404s it, remembered) three per-slice reads
    /// assembled into the same shape (`V/api/sessions.ts:247-293`). [perf-returns] With the answer's size in bytes.
    private func fetchSidebar(limits: (Int, Int, Int)) async throws -> (payload: SidebarPayload, bytes: Int) {
        if !sidebarRouteMissing {
            do {
                let data = try await client.rest("GET", Self.sidebarPath, query: query(limits: limits), body: nil)
                return (try await SidebarPayload.decode(data: data), data.count)
            } catch let error as HTTPError where error.status == 404 {
                sidebarRouteMissing = true
            }
        }
        let profile = recentsProfile, client = self.client, path = Self.legacyPath
        // `profile` here is the list's own filter ("all" or one profile); it doubles as the routing param.
        func slice(_ limit: Int, _ filter: URLQueryItem) -> [URLQueryItem] {
            [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: "0"),
             URLQueryItem(name: "min_messages", value: "1"), URLQueryItem(name: "archived", value: "exclude"),
             URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "profile", value: profile), filter]
        }
        let recentsQuery = slice(limits.0, URLQueryItem(name: "exclude_sources", value: Self.recentsExclude))
        let cronQuery = slice(limits.1, URLQueryItem(name: "source", value: "cron"))
        let messagingQuery = slice(limits.2, URLQueryItem(name: "exclude_sources", value: Self.messagingExclude))
        async let recents = client.rest("GET", path, query: recentsQuery, body: nil)
        async let cron = client.rest("GET", path, query: cronQuery, body: nil)
        async let messaging = client.rest("GET", path, query: messagingQuery, body: nil)
        let (r, c, m) = try await (recents, cron, messaging)
        return (try await SidebarPayload.decodeLegacy(recents: r, cron: c, messaging: m), r.count + c.count + m.count)
    }

    /// [perf-returns] "N rows, M KB" for the performance log.
    private static func sizeText(_ payload: SidebarPayload, bytes: Int) -> String {
        let rows = [payload.recents, payload.cron, payload.messaging].reduce(0) { $0 + ($1.rows?.count ?? 0) }
        return "\(rows) rows, \((bytes + 512) / 1024) KB"
    }

    /// [perf-returns] §11.5: a probe-first read may stand in a top page for the full read while there is a full list
    /// to merge into (a full read this run, rows on hand, the last read's fingerprint kept), the batched route answers,
    /// a filter is not waiting on the deep page, and the list on screen is not showing an old full read.
    private func topPageFits(at now: ContinuousClock.Instant) -> Bool {
        guard !sidebarRouteMissing, lastFingerprint != nil, let last = lastFullAt,
              !(recents.isEmpty && cron.isEmpty && messaging.isEmpty) else { return false }
        if wantsDeepRead, lastFullLimit < Self.deepRecentsLimit { return false }
        if listVisible, now - last >= timing.probeMaxAge { return false }
        return true
    }

    /// [perf-returns] §11.5: the full read a top page left owed, once the list is on screen and the last full read is
    /// older than `probeMaxAge`. A read in flight calls this again when it ends.
    private func readOwedFullList() {
        guard fullReadOwed, listVisible, started, !stopped, appActive, readInFlight == nil else { return }
        if let last = lastFullAt, ContinuousClock.now - last < timing.probeMaxAge { return }
        readTask(probeFirst: false)
    }

    private func performRead(probeFirst: Bool, token: Int) async {
        // [offline] §6.4: what a reconnect's refresh cost, for the performance log.
        // (review) Read when the read ends, not when it starts: a reconnect that arrived while this read was in flight
        // is covered by it too.
        let began = ContinuousClock.now
        var probeMs: Int?
        // [diagnostics] Every read's outcome, win the reconnect share or not: why it ran (probe-first vs full, the
        // list on screen or not) and what it ended in, so a refresh can be followed without reproducing it.
        func noteOutcome(_ outcome: String) {
            let ms = Int((ContinuousClock.now - began) / .milliseconds(1))
            let split = probeMs.map { " (probe \($0) ms + \(ms - $0) ms)" } ?? ""
            AppLog.trace("sessions", "read (\(probeFirst ? "probe-first" : "full"), visible=\(listVisible)): \(outcome) in \(ms) ms\(split)")
            // [reliability] A read a reconnect superseded ends after the new one began: it must not take its share.
            guard readToken == token, reconnectReadOut else { return }
            reconnectReadOut = false
            if outcome == "failed" { reconnectShare.failed() }
            AppLog.note("sessions", "reconnect refresh: \(outcome) in \(ms) ms\(split)")
        }
        var probeHealthy = true
        // [perf] The top page starts with the probe instead of after it: a differing probe (most returns after a busy
        // stretch) used to cost one more round trip before the list moved. A matching probe cancels it unread, but the
        // gateway still answers it, so it waits for the probe again while the last one matched within `quietAfterMatch`.
        var early: (task: Task<(payload: SidebarPayload, bytes: Int), Error>, startedAt: ContinuousClock.Instant)?
        defer { early?.task.cancel() }
        if probeFirst, let fingerprint = lastFingerprint, let last = lastFingerprintAt, began - last < timing.probeMaxAge {
            probeStats.probes += 1                                                  // [sessions-m9] §11.2 counters
            let quiet = lastProbeMatchAt.map { began - $0 < timing.quietAfterMatch } ?? false
            if !quiet, topPageFits(at: began) {
                let limits = Self.topLimits
                early = (Task { try await QueryRetry.read { try await self.fetchSidebar(limits: limits) } }, .now)
            }
            let probe = try? await fetchSidebar(limits: (1, 1, 1)).payload
            probeMs = Int((ContinuousClock.now - began) / .milliseconds(1))
            if let probe {
                if probe.fingerprint == fingerprint {
                    if !stopped, readToken == token { lastProbeMatchAt = .now }
                    if !stopped { probeStats.skipped += 1 }
                    return noteOutcome("probe skipped")
                }
                lastProbeMatchAt = nil
                probeHealthy = probe.fingerprint != nil
            } else {
                lastProbeMatchAt = nil          // a failed probe says nothing quiet: the next one has its top page beside it
            }
            guard !stopped, !Task.isCancelled else { return noteOutcome("failed") }
        }
        // [perf-returns] §11.5: the probe differs (or the last read is old): the newest rows only, merged in.
        if probeFirst, probeHealthy, topPageFits(at: began) {
            let limits = Self.topLimits
            let read = early ?? (Task { try await QueryRetry.read { try await self.fetchSidebar(limits: limits) } }, .now)
            early = read
            probeStats.top += 1
            do {
                let (payload, bytes) = try await withTaskCancellationHandler { try await read.task.value } onCancel: { read.task.cancel() }
                guard !stopped, !Task.isCancelled else { return noteOutcome("failed") }
                // A partial answer (no fingerprint) or a gateway that turned out to lack the batched route: read in full.
                if payload.fingerprint != nil, !sidebarRouteMissing {
                    apply(payload, readStartedAt: read.startedAt, topLimits: limits)
                    return noteOutcome("top page (\(Self.sizeText(payload, bytes: bytes)))")
                }
            } catch where Task.isCancelled || stopped {
                return noteOutcome("failed")
            } catch {
                noteOutcome("failed")
                guard readToken == token else { return }
                return setLoadState(.failed(message: SessionsLoadWords.reason(for: error), busy: RosterRules.isGatewayBusy(error)))
            }
        }
        early?.task.cancel()
        if recents.isEmpty, loadState == .idle { setLoadState(.loading) }
        let startedAt = ContinuousClock.now
        // [sessions-m9] "A filter searches the loaded page, so switching one on has to deepen the page" (§3.6).
        let recentsLimit = wantsDeepRead ? Self.deepRecentsLimit : Self.recentsLimit
        let owed = fullReadOwed
        probeStats.full += 1
        do {
            // [offline] §6.2: one quick retry, none after a timeout or while the gateway cannot be reached.
            let (payload, bytes) = try await QueryRetry.read { try await self.fetchSidebar(limits: (recentsLimit, 50, 100)) }
            guard !stopped, !Task.isCancelled else { return noteOutcome("failed") }
            lastReadDuration = ContinuousClock.now - startedAt
            lastFullLimit = recentsLimit
            apply(payload, readStartedAt: startedAt)
            let size = Self.sizeText(payload, bytes: bytes)
            if owed, !reconnectReadOut {                                            // [perf-returns]
                AppLog.note("sessions", "owed full read (\(size)) in \(Int(lastReadDuration / .milliseconds(1))) ms")
            }
            noteOutcome("full (\(size))")
        } catch where Task.isCancelled || stopped {
            return noteOutcome("failed")
        } catch {
            noteOutcome("failed")
            guard readToken == token else { return }
            setLoadState(.failed(message: SessionsLoadWords.reason(for: error), busy: RosterRules.isGatewayBusy(error)))
        }
    }

    /// A read's answer onto the lists. [perf-returns] `topLimits`: a top page (§11.5), merged into the loaded rows
    /// (`SidebarTopPage.merge`) instead of replacing them; the full read stays owed.
    private func apply(_ payload: SidebarPayload, readStartedAt: ContinuousClock.Instant, topLimits: (Int, Int, Int)? = nil) {
        // Our own unread writes: a page whose read started after the gateway acknowledged a write is its honest
        // answer (the write is settled); an earlier page may predate the write and keeps our value instead.
        unreadWrites = unreadWrites.filter { _, write in write.ackAt.map { readStartedAt < $0 } ?? true }
        // [perf] An answer that matches the rows on hand writes nothing and notifies nobody (unless the state moved).
        let prior = (recents: recents, cron: cron, messaging: messaging, device: device, loadState: loadState)
        func fenced(_ rows: [SidebarSessionRow]?) -> [SidebarSessionRow]? {
            guard var rows, !unreadWrites.isEmpty || !device.pins.isEmpty else { return rows }
            for index in rows.indices {
                let key = Self.writeKey(id: rows[index].id, profile: rows[index].profile)
                if let write = unreadWrites[key] { rows[index].unread = write.value }
                if let pinned = device.pins[key] {
                    // The gateway agrees now (it took a later write, or another client's): the device copy is done.
                    if (rows[index].pinned == true) == pinned { device.pins[key] = nil } else { rows[index].pinned = pinned }
                }
            }
            return rows
        }
        func placed(_ rows: [SidebarSessionRow]?, into old: [SidebarSessionRow], limit: Int?) -> [SidebarSessionRow]? {
            guard let rows = fenced(rows) else { return nil }
            return limit.map { SidebarTopPage.merge(old, page: rows, limit: $0) } ?? rows
        }
        if let rows = placed(payload.recents.rows, into: recents, limit: topLimits?.0) { recents = rows }
        if let rows = placed(payload.cron.rows, into: cron, limit: topLimits?.1) { cron = rows }
        if let rows = placed(payload.messaging.rows, into: messaging, limit: topLimits?.2) { messaging = rows }
        // [sessions-m9] The page's fingerprint is kept even while our own read marks are in the air (§11.2).
        // [perf-returns] A top page's fingerprint compares with a probe's as a full read's does: the same newest rows,
        // every pinned row and the usage totals.
        // [perf] A read that found the list moved ends the quiet (a `sessions.changed` tick alone does not: gateways send
        // one around a reconnect, §6.5).
        if payload.fingerprint != lastFingerprint { lastProbeMatchAt = nil }
        lastFingerprint = payload.fingerprint
        lastFingerprintAt = .now
        if topLimits == nil {
            lastFullAt = .now
            fullReadOwed = false
        } else {
            fullReadOwed = true
        }
        lastUpdated = Date()
        device.unread.observe(recents + cron)
        absorbSelected()
        let rowsMoved = recents != prior.recents || cron != prior.cron || messaging != prior.messaging
        // [diagnostics] Added/removed/changed per list, keyed by (id, profile): what the read actually moved.
        func diff(_ old: [SidebarSessionRow], _ new: [SidebarSessionRow]) -> String {
            let oldKeys = Set(old.map { Self.writeKey(id: $0.id, profile: $0.profile) })
            let newKeys = Set(new.map { Self.writeKey(id: $0.id, profile: $0.profile) })
            let oldByKey = Dictionary(uniqueKeysWithValues: old.map { (Self.writeKey(id: $0.id, profile: $0.profile), $0) })
            let added = newKeys.subtracting(oldKeys).count
            let removed = oldKeys.subtracting(newKeys).count
            let changed = new.filter { row in oldByKey[Self.writeKey(id: row.id, profile: row.profile)].map { $0 != row } ?? false }.count
            return "\(new.count) (+\(added)/-\(removed)/~\(changed))"
        }
        AppLog.trace("sessions", "\(topLimits == nil ? "full" : "top page") applied: recents \(diff(prior.recents, recents)), " +
                     "cron \(diff(prior.cron, cron)), messaging \(diff(prior.messaging, messaging))")
        if rowsMoved || lastCacheWriteAt.map({ ContinuousClock.now - $0 > .seconds(600) }) ?? true { writeCache() }
        if device != prior.device { persistState() }
        if payload.recents.failed {
            loadState = .failed(message: SessionsLoadWords.defaultReason, busy: false)
            AppLog.note("sessions", "recents scan failed: shown as a failed list")
        } else {
            loadState = .ready
        }
        let forced = forceNextNotify
        forceNextNotify = false
        rebuild(force: rowsMoved || loadState != prior.loadState || forced)
        refreshLatest()
        // [sessions-m9] Group By Project or a project filter kept from the last launch needs the projects without the
        // Filter menu ever being opened (§3.4); asked at most once a minute per bot.
        if view.groupBy == .project || !view.projectFilter.isEmpty { loadProjects() }
    }

    /// The selected chat is on screen or was just read: what it holds is seen.
    private func absorbSelected() {
        guard let id = selectedSessionId else { return }
        for row in recents + cron + messaging where row.id == id { device.unread.opened(row, clearServerLocally: false) }
    }

    func writeCache() {
        lastCacheWriteAt = .now
        RosterDisk.write(SessionsCacheFile(at: Date().timeIntervalSince1970 * 1000, recents: recents, cron: cron, messaging: messaging),
                         to: cacheURL, keepNewest: (RosterDisk.sessionsKind, 3))
    }

    /// [offline] §6.9: the power state changed: the fallback poll is armed again with the new period.
    func powerChanged() { schedulePoll() }

    private func schedulePoll() {
        pollTask?.cancel()
        pollTask = nil
        // Polls only stand in for a gateway that does not broadcast changes.
        guard started, !stopped, appActive, readInFlight == nil, changeEvents == false else { return }
        let base = listVisible ? timing.fallbackOnScreenPoll : timing.fallbackOffScreenPoll
        // [offline] §6.9: stretched in Low Power Mode or when the phone is hot.
        let wait = PowerPolls.period(max(base, lastReadDuration * 10), floor: .zero, saving: PowerState.shared.saving)
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, self.appActive, !self.stopped else { return }
            self.pollTask = nil
            self.readTask(probeFirst: !self.listVisible)
        }
    }

    // MARK: - Building rows

    private func summary(_ row: SidebarSessionRow, messaging: Bool, words: inout [String: RowWords]) -> SessionSummary {
        var summary = baseSummary(row, messaging: messaging, words: &words)
        summary.pinned = row.pinned == true
        summary.archived = row.archived == true
        summary.color = device.colors[Self.durableId(row)]
        summary.outside = messaging
        summary.origin = ChatSource.origin(source: row.source, handoffPlatform: row.handoffPlatform, handoffState: row.handoffState)
        return summary
    }

    /// The key More › Color keeps a chat's colour under: its lineage root, else its id (`sessionPinId`).
    static func durableId(_ row: SidebarSessionRow) -> String { row.lineageRootId ?? row.id }

    private func baseSummary(_ row: SidebarSessionRow, messaging: Bool, words: inout [String: RowWords]) -> SessionSummary {
        let key = Self.writeKey(id: row.id, profile: row.profile)
        let shown: RowWords
        let latest = latestText(row)
        if let cached = self.words[key], cached.row.title == row.title, cached.row.preview == row.preview, cached.latest == latest {
            shown = cached
        } else {
            // The title falls back on the first message; the second line is the newest one when it has been read.
            var newest = row
            if let latest { newest.preview = latest }
            shown = RowWords(row: row, latest: latest, title: SessionRules.title(row, model: modelLabel),
                             preview: SessionRules.preview(newest, model: modelLabel))
        }
        words[key] = shown
        let selected = row.id == selectedSessionId
        var summary = SessionSummary(id: row.id, profile: row.profile, title: shown.title, preview: shown.preview,
                                     lastActive: row.recency > 0 ? Date(timeIntervalSince1970: row.recency) : nil,
                                     source: row.source,
                                     unread: device.unread.isUnread(row, messaging: messaging, selected: selected),
                                     isRunning: running.contains(row.id))
        // [sessions-m9] Sort By, Row Detail, the status and the pending line (docs/spec/3x-sessions.md §3.1, §3.3, §9).
        summary.startedAt = (row.startedAt ?? 0) > 0 ? Date(timeIntervalSince1970: row.startedAt ?? 0) : nil
        summary.tokens = row.totalTokens
        summary.cost = row.costUsd
        summary.cwd = row.cwd
        summary.owner = row.userId
        summary.metadata = SessionRowWords.metadata(branch: row.gitBranch, model: row.model, messages: row.messageCount,
                                                    toolCalls: row.toolCallCount)
        summary.pending = pendingLine?(row.profile, row.id)
        summary.status = needsInput.contains(row.id) ? .needsInput : summary.isRunning ? .working : summary.unread ? .unread
            : summary.pending.map { !$0.failed } == true ? .draft : .idle
        if summary.isRunning { summary.step = steps[row.id] }   // [toolnow]
        // [/sessions-m9]
        return summary
    }

    private func setLoadState(_ state: SessionsLoadState) {
        guard loadState != state else { return }
        loadState = state
        onChange?()
    }

    func persistState() {
        RosterDisk.write(device, to: stateURL)
        syncChanged?()                                  // [sync]
    }

    /// [sync] Told after every save of the device state (the gateway copy follows the parts that travel).
    @ObservationIgnored var syncChanged: (() -> Void)?

    func rebuild(notify: Bool = true, force: Bool = false) {
        var byId: [String: SidebarSessionRow] = [:]
        for row in recents + cron + messaging + archivedRows where byId[row.id] == nil { byId[row.id] = row }
        rowsById = byId
        let showRuns = device.showBackgroundRuns
        var nextWords: [String: RowWords] = [:]
        // Pinned resolves from the unfiltered rows: a pinned run stays.
        let visible = recents.filter { !SessionRules.isBotChat($0) && (showRuns || $0.pinned == true || !SessionRules.isBackgroundRun($0))
            && !leaving.contains(Self.writeKey(id: $0.id, profile: $0.profile)) }
        let ordered = visible.enumerated().sorted { a, b in
            let pa = a.element.pinned == true, pb = b.element.pinned == true
            if pa != pb { return pa }
            if a.element.recency != b.element.recency { return a.element.recency > b.element.recency }
            return a.offset < b.offset
        }.map(\.element)
        let nextSessions = ordered.map { summary($0, messaging: false, words: &nextWords) }
        // The scheduled runs' section (Other Apps, with Show › Background Runs): a section of a run's own, so its rows
        // are never unread, as the platforms' and the one-off runs' (spec 02 §9.3). An id-only cron row is named a cron row.
        let nextCron = cron.filter { !SessionRules.isBotChat($0) }.sorted { $0.recency > $1.recency }
            .map { row -> SessionSummary in
                var summary = summary(row, messaging: true, words: &nextWords)
                if !ChatSource.hasFolder(summary.source) { summary.source = ChatSource.scheduled }
                return summary
            }
        let nextMessaging = messaging.filter { !SessionRules.isBotChat($0) && (showRuns || !SessionRules.isBackgroundRun($0)) }
            .sorted { $0.recency > $1.recency }.map { summary($0, messaging: true, words: &nextWords) }
        // Show › Archived adds these to the list, so they keep its rules: a run only with Background Runs (or pinned),
        // a chat from outside the recents (Telegram, a cron job, …) only with Outside Chats.
        let showOutside = device.showOutsideChats
        let nextArchived = archivedRows.filter { !SessionRules.isBotChat($0) && !leaving.contains(Self.writeKey(id: $0.id, profile: $0.profile))
            && (showRuns || $0.pinned == true || !(SessionRules.isBackgroundRun($0) || Self.isScheduledRun($0)))
            && (showOutside || SessionRules.isBackgroundRun($0) || Self.isScheduledRun($0) || !Self.recentsExcluded.contains($0.source ?? "")) }
            .sorted { $0.recency > $1.recency }
            .map { row -> SessionSummary in
                var summary = summary(row, messaging: !SessionRules.isBackgroundRun(row) && Self.recentsExcluded.contains(row.source ?? ""),
                                      words: &nextWords)
                summary.archived = true
                return summary
            }
        words = nextWords
        let changed = nextSessions != sessions || nextCron != cronSessions || nextMessaging != messagingSessions
            || nextArchived != archivedSessions
        if changed {
            sessions = nextSessions
            cronSessions = nextCron
            messagingSessions = nextMessaging
            archivedSessions = nextArchived
        }
        let count = sessions.filter(\.unread).count
        if count != unreadCount { unreadCount = count }
        if changed || force {
            AppLog.trace("sessions", "rebuild: \(nextSessions.count) recents, \(nextCron.count) cron, \(nextMessaging.count) messaging, " +
                         "\(nextArchived.count) archived shown (showRuns=\(showRuns), showOutside=\(showOutside)), \(count) unread")
        }
        if notify, changed || force { onChange?() }
    }

    isolated deinit {
        for task in [eventsTask, readInFlight, pollTask] { task?.cancel() }
    }
}
