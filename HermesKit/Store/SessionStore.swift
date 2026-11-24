// The Sessions tab's data (spec 02 §9; refresh rules spec 03 §7.7): `GET /api/profiles/sessions/sidebar`, painted from
// the device cache at once, refreshed on `sessions.changed` through a leading/trailing throttle (10 s on screen,
// 45 s off screen with a limit-1 probe first), on reconnect (probe, then a short top page merged in with the full
// read owed until the list is on screen, docs/spec/3x-sessions.md §11.5), and by pull to refresh. Background runs and Bot Chats
// are hidden; unread follows the web's rules, and the only write is the `unread` PATCH (refused while
// `readOnlyGateway` is on). An older gateway without the batched route gets the three per-slice reads instead.
//
// [read-sync] Read state is shared between this person's devices through the gateway's own watermark
// (`sessions.last_read_at`, which every list row carries beside `unread`): a device that reads a chat writes
// `unread:false` whenever the watermark doesn't already cover what was seen (`sharesRead`), not only when the gateway
// already called the chat unread, and a device drops its own dot when a page says the chat was read at or after its
// newest activity (`SessionUnreadState.absorbGatewayReads`). A read that couldn't be sent is owed (`sendOwedReads`).

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
    /// [#440] How long a chat started here keeps its own row while no page lists it (`SessionStore.listStartedChat`).
    var startedRowLife: Duration = .seconds(600)
    /// [#440] A page read this long after that chat's first turn ended which still leaves it out is believed.
    var startedRowSettle: Duration = .seconds(5)
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
    /// Device-only rail order; never included in gateway sync. Empty preserves tiered defaults.
    var projectPillOrder: [String] = []
    var botGroupOrder: [String] = []
    /// [manual-order] Projects marked Favorite: always first under Group By Project (owner, 2026-10-29).
    var favoriteProjects: [String] = []
    /// [project-pills] Projects the owner archived (keys): out of the project pills and the list until Show › Archived.
    var archivedProjects: [String] = []
    /// [own-folder] Each bot's own folder (profile → the folder its own chat runs in), as last learned
    /// (SessionStore+OwnFolder.swift).
    var botFolders: [String: String] = [:]
    /// [own-folder-everywhere] Each bot's `terminal.cwd` as last read (profile → folder), the other way its own folder is
    /// known.
    var botConfigFolders: [String: String] = [:]
    /// [project-default-bot] The bot each project's New Chat starts with (project key → profile, or
    /// `ProjectDefaultBot.ask`); a project not named has nothing chosen.
    var projectBots: [String: String] = [:]
    /// Explicit project designation; false is retained so sync can propagate turning it off.
    var codingProjects: [String: Bool] = [:]
    /// [project-pins] Projects whose page pins stay on the page (key → on; false kept so sync carries turning it off):
    /// Pin there marks the chat in that project only, not the gateway's Pinned every list shows.
    var projectPinsLocal: [String: Bool] = [:]
    /// [project-pins] The chats pinned on a project's page alone: project key → row keys (`SessionListPipeline.key`).
    var projectPins: [String: [String]] = [:]
    /// Explicit shortcuts, newest choice first. Not a gateway pin or a project pin.
    var botChatShortcuts: [BotChatShortcut] = []
    /// [threads] Durable links between bot threads and their parent Bot Chat (persisted locally + synced via GatewaySync).
    var botThreads: [BotThreadLink] = []
    /// [project-sort] Each project page's Sort (key → `ProjectPageSort` raw); absent: Needs Me First.
    var projectSorts: [String: String] = [:]
    /// [project-keep] Projects whose chats stay on their own page (key → on; false kept so sync carries turning it off).
    var projectKeep: [String: Bool] = [:]
    /// [project-auto-done] Move Quiet Chats to Done (key → `ProjectAutoDone.raw`); absent: Never.
    var projectAutoDone: [String: String] = [:]
    /// [project-mute] Each project's Notifications (key → `ProjectNotify` raw); absent: All.
    var projectNotify: [String: String] = [:]
    /// [project-new-chat-model] The model and reasoning a project's New Chat starts with; an empty one is kept so sync
    /// carries going back to the bot's default.
    var projectNewChat: [String: ProjectNewChat] = [:]
    /// [project-look] Each project's emoji and colour; an empty one is kept so sync carries clearing it.
    var projectLooks: [String: ProjectLook] = [:]
    /// [project-branch-rows] Coding projects whose rows start with the chat's branch (key → on).
    var projectBranchRows: [String: Bool] = [:]

    init() {}

    // Fields added later decode as absent, so an older file keeps its unread state.
    private enum CodingKeys: String, CodingKey {
        case unread, showBackgroundRuns, showOutsideChats, colors, view, projects, latest, pins, collapsedGroups
        case chatOrder, projectOrder, projectPillOrder, botGroupOrder, favoriteProjects, openGroups, archivedProjects, botFolders
        case botConfigFolders, projectBots, codingProjects, projectPinsLocal, projectPins, projectSorts
        case botChatShortcuts, botThreads
        case projectKeep, projectAutoDone, projectNotify, projectNewChat, projectLooks, projectBranchRows
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
        projectPillOrder = (try? c.decodeIfPresent([String].self, forKey: .projectPillOrder)) ?? []
        botGroupOrder = (try? c.decodeIfPresent([String].self, forKey: .botGroupOrder)) ?? []
        favoriteProjects = (try? c.decodeIfPresent([String].self, forKey: .favoriteProjects)) ?? []
        openGroups = (try? c.decodeIfPresent([String: [String]].self, forKey: .openGroups)) ?? [:]
        archivedProjects = (try? c.decodeIfPresent([String].self, forKey: .archivedProjects)) ?? []
        botFolders = (try? c.decodeIfPresent([String: String].self, forKey: .botFolders)) ?? [:]
        botConfigFolders = (try? c.decodeIfPresent([String: String].self, forKey: .botConfigFolders)) ?? [:]
        projectBots = (try? c.decodeIfPresent([String: String].self, forKey: .projectBots)) ?? [:]
        codingProjects = (try? c.decodeIfPresent([String: Bool].self, forKey: .codingProjects)) ?? [:]
        projectPinsLocal = (try? c.decodeIfPresent([String: Bool].self, forKey: .projectPinsLocal)) ?? [:]
        projectPins = (try? c.decodeIfPresent([String: [String]].self, forKey: .projectPins)) ?? [:]
        botChatShortcuts = (try? c.decodeIfPresent([BotChatShortcut].self, forKey: .botChatShortcuts)) ?? []
        botThreads = (try? c.decodeIfPresent([BotThreadLink].self, forKey: .botThreads)) ?? []
        projectSorts = (try? c.decodeIfPresent([String: String].self, forKey: .projectSorts)) ?? [:]
        projectKeep = (try? c.decodeIfPresent([String: Bool].self, forKey: .projectKeep)) ?? [:]
        projectAutoDone = (try? c.decodeIfPresent([String: String].self, forKey: .projectAutoDone)) ?? [:]
        projectNotify = (try? c.decodeIfPresent([String: String].self, forKey: .projectNotify)) ?? [:]
        projectNewChat = (try? c.decodeIfPresent([String: ProjectNewChat].self, forKey: .projectNewChat)) ?? [:]
        projectLooks = (try? c.decodeIfPresent([String: ProjectLook].self, forKey: .projectLooks)) ?? [:]
        projectBranchRows = (try? c.decodeIfPresent([String: Bool].self, forKey: .projectBranchRows)) ?? [:]
    }
}

/// [pr-instant] The last answer the gateway gave for each chat's code changes, kept so a coding project's marks are
/// there the moment the app opens (owner 2026-11-19: "It took probably thirty seconds or more before they all loaded.
/// That needs to just be instantly correct."). Answers only: a chat whose status wasn't known isn't kept.
nonisolated struct SessionMarksCacheFile: Codable, Sendable {
    struct Mark: Codable, Sendable {
        var state: String
        var repo: String?
        var branch: String?
        var number: Int?
        var url: String?
        var manual: Bool?
        /// [pr-multi] nil: an add-on that lists none (or a file from before 0.9.75).
        var items: [Item]?
        /// [pr-review-facts] nil: not known, or a file from before them. Never files or check runs.
        var size: SessionPRSize?
        var checks: Checks?
        var title: String?
        var base: String?
        struct Item: Codable, Sendable {
            var state: String
            var repo: String?
            var branch: String?
            var number: Int?
            var url: String?
            var source: String?
            var size: SessionPRSize?
            var checks: Checks?
            var title: String?
            var base: String?
        }
        /// [pr-review-facts] The counts of a checks answer, without its runs.
        struct Checks: Codable, Sendable {
            var state: String
            var passed: Int
            var failed: Int
            var running: Int

            init(_ checks: SessionPRChecks) {
                state = checks.state.rawValue; passed = checks.passed; failed = checks.failed; running = checks.running
            }

            /// Read back as the wire's rules read it: an unknown state or a negative count is no answer.
            var checks: SessionPRChecks? {
                guard let state = SessionPRChecks.State(rawValue: state), passed >= 0, failed >= 0, running >= 0,
                      passed + failed + running > 0 else { return nil }
                return SessionPRChecks(state: state, passed: passed, failed: failed, running: running)
            }
        }
    }
    var at: Double                   // ms since the epoch
    var marks: [String: Mark]
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
    /// Ephemeral, scoped to the project whose header selected it.
    var projectPRFilter: (key: String, state: SessionPRStatus.State)?
    /// [sessions-ux] Where the pills are the projects (iPhone, iPad), a project's row opens its page as its pill does,
    /// so under Group By Project no project is drawn open in the list. The Mac, which has no pills, leaves this off:
    /// its rows open and close in place.
    var projectRowsOpenPages = false
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
    @ObservationIgnored var inputDetails: [String: String] = [:]
    /// [tile-chats] Tile chats this run has asked the gateway to hide (write keys): each is asked once.
    @ObservationIgnored var tileChatsHiding: Set<String> = []
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
    /// [own-folder] The stored id of a bot's own chat (its Bot Chat), from the Bots list: where its own folder is read.
    @ObservationIgnored var botChatId: ((_ profile: String) -> String?)?
    /// [own-folder] When each bot's own folder was last asked for, this run.
    @ObservationIgnored var botFolderAskedAt: [String: ContinuousClock.Instant] = [:]
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
    /// [projects-all-bots] The roster's shown bots (profiles): each one's projects are read, chats listed or not.
    @ObservationIgnored var projectBots: [String] = []

    @ObservationIgnored let client: any GatewayClient
    // Per-store (and therefore per gateway) cache; a profile and stored id form the identity.
    private var pullRequests: [String: SessionPRStatus] = [:]
    /// [repo-pickers] The GitHub repositories (owner/repo) chats' pull requests and branches were read against, for the
    /// Repository… page's Public Repository choices.
    var pullRequestRepos: [String] {
        pullRequests.values.flatMap { status in [status.repo] + (status.items ?? []).map(\.repo) }.compactMap { $0 }
    }
    @ObservationIgnored private var prInFlight: Set<String> = []
    @ObservationIgnored private var prCheckedAt: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var prGeneration = 0
    /// Per-key version bumped by explicit/forced refreshes so a slower background poll chunk never overwrites them.
    @ObservationIgnored private var prKeyVersion: [String: Int] = [:]
    /// Live `message.complete` replies waiting for the sidebar's `recency` to catch up without flickering the subtitle.
    @ObservationIgnored var confirmedReplyRecency: [String: Double] = [:]
    /// The gateway answered 404 for PR status (an add-on without the route). Not forever: the add-on can be
    /// updated while the app runs, so the route is tried again after `prRouteRetry` (and immediately on reconnect).
    @ObservationIgnored private var prRouteMissingSince: ContinuousClock.Instant?
    /// [pr-manage] The repositories chats' branches are looked for in; nil until a gateway that takes links said
    /// (SessionStore+PRManage.swift).
    @ObservationIgnored var prRepos: [SessionPRRepo]?
    @ObservationIgnored var prReposState: SessionPRReposState = .unknown
    /// Projects whose folder failed auto-linking (`not_a_repository`) when Coding Project turned on.
    @ObservationIgnored var prAutoLinkFailed: Set<String> = []
    @ObservationIgnored var prRouteRetry: Duration = .seconds(600)
    var prRouteMissing: Bool {
        guard let since = prRouteMissingSince else { return false }
        if ContinuousClock.now - since >= prRouteRetry { prRouteMissingSince = nil; return false }
        return true
    }
    var isPRRouteUnsupported: Bool { prRouteMissing }
    @ObservationIgnored private var prPollTask: Task<Void, Never>?
    @ObservationIgnored private var prFocusedRow: SessionSummary?
    @ObservationIgnored let timing: SessionStoreTiming
    @ObservationIgnored private let routingProfile: String
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let marksURL: URL
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
    @ObservationIgnored var latestStale: Set<String> = []
    @ObservationIgnored var latestDirty = 0
    @ObservationIgnored var latestFlushTask: Task<Void, Never>?
    @ObservationIgnored var device = SessionsDeviceState()
    /// Only for explicitly chosen chats outside the recents window. Never inserted into `sessions`.
    @ObservationIgnored var offPageShortcuts: [BotChatShortcut: SidebarSessionRow] = [:]
    @ObservationIgnored var shortcutCheckedAt: [BotChatShortcut: ContinuousClock.Instant] = [:]
    @ObservationIgnored var shortcutRead: Task<Void, Never>?
    /// Archived rows as read (the Archived view), and rows whose Archive or Delete is in the air (left out of the
    /// list until the gateway answers; a failure brings them back).
    @ObservationIgnored var archivedRows: [SidebarSessionRow] = []
    /// [read-sync] The archived read a list page asked for (`refreshArchivedIfMoved`), one at a time.
    @ObservationIgnored private var archivedRefresh: Task<Void, Never>?
    @ObservationIgnored var leaving: Set<String> = []
    /// [#440] Chats started here whose row no page has listed yet, by write key, and when each was listed here
    /// (`listStartedChat`).
    @ObservationIgnored var startedRows: [String: StartedRow] = [:]

    /// [#440] A started chat's own row (`listStartedChat`).
    struct StartedRow {
        var row: SidebarSessionRow
        var at: ContinuousClock.Instant
        /// When its first turn ended (sent, answered or refused): a page read after that which still leaves it out says
        /// the gateway doesn't list it (a send it refused, or an id it doesn't list by).
        var settledAt: ContinuousClock.Instant?
    }
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
    /// Runtime-to-stored bindings learned from session.info, scoped to this account and connection.
    @ObservationIgnored private var resultBindings: [String: (profile: String, id: String)] = [:]
    /// The selected chat (the web's `$selectedStoredSessionId`): set when a chat is focused and kept after the user
    /// leaves it, until another chat is focused. Its stored count is absorbed on every read and its local dot is
    /// skipped, so the chat the user just used does not come back unread (the server's own flag still shows).
    @ObservationIgnored private var selectedSessionId: String?
    /// [unread-working] The selected chat's lineage (`durableId`), learnt from its listed row. The gateway lists a
    /// chat it compacted under its newest part's id, so the id alone would lose the chat on screen mid-turn.
    @ObservationIgnored private var selectedLineage: String?
    /// [read-sync] The chat in front of the person now (nil when none is, or it has no stored id yet): it shows no dot
    /// while the app is in front, and what the gateway calls unread in it is written back as read (`shareOnScreenRead`).
    @ObservationIgnored private var onScreenSessionId: String?
    /// [read-sync] Read writes the gateway answered with a refusal, by write key: the activity they were for. The
    /// chat on screen isn't written again for the same activity (a refusing gateway was asked on every page).
    @ObservationIgnored private var readRefused: [String: Double] = [:]
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
        /// [read-sync] The watermark the write leaves, as this device reckons it (0 for unread; the activity read
        /// through for read): what the row says of `last_read_at` until an honest page brings the gateway's own.
        var readAt: Double = 0
        /// The watermark before the write (a failure puts it back).
        var priorReadAt: Double?
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
        marksURL = RosterDisk.url(cacheDirectory, RosterDisk.sessionMarksKind, account)
        stateURL = RosterDisk.url(cacheDirectory, RosterDisk.sessionStateKind, account)
        if let state = RosterDisk.read(SessionsDeviceState.self, from: stateURL) { device = state } else { syncStartedEmpty = true }
        showBackgroundRuns = device.showBackgroundRuns
        showOutsideChats = device.showOutsideChats
        view = device.view                              // [sessions-m9]
        // [sessions-m9] [own-folder-everywhere] As kept, less any group now known to be a bot's own folder.
        projectsByProfile = SessionProjects.droppingOwnFolders(device.projects, ownFolders: ownFolders)
        // [pr-instant] The marks as last known, drawn at once; each is asked for again as its row shows.
        for (key, mark) in RosterDisk.read(SessionMarksCacheFile.self, from: marksURL)?.marks ?? [:] {
            guard let state = SessionPRStatus.State(rawValue: mark.state), state != .unknown else { continue }
            pullRequests[key] = SessionPRStatus(state: state, repo: mark.repo, branch: mark.branch, number: mark.number,
                                                url: mark.url.flatMap(Self.validPRURL), manual: mark.manual ?? false,
                                                items: mark.items.map { $0.compactMap(Self.prItem) },
                                                size: Self.validSize(mark.size), checks: mark.checks?.checks,
                                                title: Self.cachedWord(mark.title, limit: PRFacts.titleLimit), base: Self.cachedWord(mark.base))
        }
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
        schedulePRPoll()
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
        prPollTask?.cancel(); prPollTask = nil
        prGeneration &+= 1
        prInFlight.removeAll()
        prKeyVersion.removeAll()
        prAutoLinkFailed.removeAll()
        confirmedReplyRecency.removeAll()
        prFocusedRow = nil
        started = false
        throttle?.cancel()
        for task in [eventsTask, readInFlight, pollTask, archivedRefresh, latestFlushTask] { task?.cancel() }
        eventsTask = nil; readInFlight = nil; pollTask = nil; archivedRefresh = nil; latestFlushTask = nil
        shortcutRead?.cancel(); shortcutRead = nil
        shortcutCheckedAt.removeAll(); offPageShortcuts.removeAll()
        readInFlightProbes = false
        readToken &+= 1
        isRefreshing = false
        forceNextNotify = false
        chatFocused = false
        startedRows.removeAll()                         // [#440]
        lastProbeMatchAt = nil
        latestQueue = []
        latestStale.removeAll()
        resultBindings.removeAll()
    }

    func removeCachedData() {
        RosterDiskWriter.shared.remove(cacheURL)
        RosterDiskWriter.shared.remove(marksURL)
        RosterDiskWriter.shared.remove(stateURL)
    }

    func appDidBecomeActive() {
        appActive = true
        schedulePRPoll()
        if onScreenSessionId != nil { shareOnScreenRead(); rebuild() }       // [read-sync] the chat in front is seen again
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
        schedulePRPoll()
        if onScreenSessionId != nil { rebuild() }       // [read-sync] nobody is looking: the gateway's flag counts again
        wentToBackground = true
        backgroundEpoch &+= 1
        pollTask?.cancel()
        pollTask = nil
    }

    /// The Sessions list is on screen: changes refresh within 10 s with a full read; off screen within 45 s, probe first.
    func setListVisible(_ visible: Bool) {
        if listVisible != visible { AppLog.trace("sessions", "list \(visible ? "visible" : "hidden")") }
        listVisible = visible
        schedulePRPoll()
        throttle?.pump()
        schedulePoll()
        readOwedFullList()                              // [perf-returns]
    }

    /// [perf] A chat came on (true) or left (false) the screen: while one is on, an off-screen pass waits
    /// `focusedChatGap`. Leaving pumps the throttle, so a pass held back by the longer gap runs at the shorter one.
    func setChatFocused(_ focused: Bool) {
        guard chatFocused != focused else { return }
        chatFocused = focused
        schedulePRPoll()
        throttle?.pump()
    }

    /// [diagnostics] The reconnect's read is out (for timing a chat's catch-up against it).
    var isReconnectReadInFlight: Bool { readInFlight != nil && reconnectReadOut }

    /// The chat on screen (its stored id; pass bot chats too), or nil when it leaves. The selection sticks after the
    /// chat leaves until another chat is focused (web parity): its stored count is absorbed into the seen watermark on
    /// every refresh and it shows no local dot.
    func setFocusedSession(_ id: String?) {
        guard let id else { return }
        if prFocusedRow?.id != id { prFocusedRow = nil }
        if id != selectedSessionId { selectedLineage = nil }
        selectedSessionId = id
        schedulePRDiscovery()
        absorbSelected()
        persistState()
        rebuild()
    }

    /// Sessions running a turn right now (fed by the chat engine / live statuses).
    func setRunning(_ ids: Set<String>) {
        guard ids != running else { return }
        let stoppedRunning = running.subtracting(ids)
        running = ids
        shareOnScreenRead()                 // [read-sync] a turn that ended in front of the person is read
        rebuild()
        if !stoppedRunning.isEmpty, !stopped, timing.readsLatest {
            rereadLatest(for: stoppedRunning)
        }
    }

    // MARK: - Shared read state [read-sync]

    /// The chat in front of the person (its stored id), or nil when none is. Unlike the selection this doesn't stick.
    func setSessionOnScreen(_ id: String?) {
        guard id != onScreenSessionId else { return }
        onScreenSessionId = id
        if let id, prFocusedRow?.id != id { prFocusedRow = nil }
        schedulePRDiscovery()
        if let id { refreshOpenedChatPullRequest(id) }
        shareOnScreenRead()
        rebuild()
    }

    /// The chat on screen, while the app is in front.
    var seenSessionId: String? { appActive ? onScreenSessionId : nil }

    /// A read of `row` through `through` (server seconds; the row's own activity when nil) would tell another device
    /// something: the gateway keeps read state, and its watermark doesn't yet cover that activity.
    func sharesRead(_ row: SidebarSessionRow, through: Double? = nil) -> Bool {
        guard !readOnlyGateway, row.sharesReads else { return false }
        guard let read = row.lastReadAt, read > 0 else { return true }
        return read < max(row.recency, through ?? 0)
    }

    /// The person saw this chat through `through` (server seconds: the newest stored message it showed): a turn ended
    /// in front of them, or they left it. Written to the gateway when its watermark is behind that, once per activity
    /// (the row then carries the new watermark), so the other device's dot goes. A chat the lists don't hold is left
    /// alone. A chat left mid-turn is read up to there: what its turn stores afterwards is past the watermark, and
    /// unread once the turn ends. A chat someone marked unread stays so: only opening it, or Mark as Read, undoes that.
    func shareRead(id: String, profile: String, through: Double) {
        guard through.isFinite, through > 0, !stopped, let row = listedRow(id: id, profile: profile), row.profile == profile,
              !markedUnread(row), sharesRead(row, through: through) else { return }
        if let refused = readRefused[Self.writeKey(id: row.id, profile: row.profile)], refused >= max(row.recency, through) { return }
        device.unread.opened(row, clearServerLocally: false)
        persistState()
        writeUnread(false, row: row, through: through)
        rebuild()
    }

    /// [read-sync] A chat started on this device (New Chat, a new tile, a memo): read on the gateway as soon as its id
    /// is known. Owner 2026-11-18 ("the sessions aren't showing the same as they are on my iPhone"): a chat nobody has
    /// ever marked read has no watermark (`last_read_at` NULL), so each device decides its dot from its own count, seeded
    /// when it first lists the chat. The device that started it, seeded early, showed every later reply as unread; the
    /// other, seeded after them, showed none; and a read on either never reached the other (no watermark to move). With
    /// the watermark from the start the gateway's flag decides on every device, and a read anywhere clears it everywhere.
    /// The chat isn't in the lists yet (its first page comes later), so this writes without a row. A gateway without
    /// read state (no row says `unread`) or a read-only one gets nothing; a chat already read on the gateway neither.
    func trackStartedChat(id: String, profile: String) {
        guard !id.isEmpty, started, !stopped, !readOnlyGateway,
              (recents + cron + messaging).contains(where: \.sharesReads) else { return }
        if let row = listedRow(id: id, profile: profile), row.profile == profile, row.lastReadAt != nil { return }
        AppLog.trace("sessions", "read sync: new chat \(AppLog.tag(id)) is read from the start")
        let client = self.client
        Task {
            do {
                try await SessionWrite.patch(client, id: id, profile: profile, ["unread": .bool(false)])
            } catch {
                AppLog.note("sessions", "read sync: new chat \(AppLog.tag(id)) not marked read (\(error.localizedDescription))")
            }
        }
    }

    /// [#440] A chat started on this device (New Chat, a project's New Chat) whose first message just went out: its row
    /// is on the lists now (Sessions, and the chats under its bot on the Bots page and the Mac's sidebar), not with the
    /// next list read, which waits up to 150 s while a chat is on screen beside a list other than Sessions. It is named
    /// by that message until the gateway names it (the chat's title event reaches the row through `applyTitle`). Pages
    /// that don't list it yet keep it and the first that does takes over (`keepStartedRows`). Hidden chats (a task's, a
    /// tile's) never come here.
    func listStartedChat(id: String, profile: String, title: String? = nil, firstMessage: String?, cwd: String? = nil,
                         now: Date = Date()) {
        let key = Self.writeKey(id: id, profile: profile)
        if startedRows[key] != nil { startedRows[key]?.settledAt = nil; return }   // another turn: wait for it too
        guard !id.isEmpty, started, !stopped, allBots || profile == routingProfile,
              listedRow(id: id, profile: profile) == nil else { return }
        let seconds = now.timeIntervalSince1970
        var row = SidebarSessionRow(id: id, profile: profile, title: RosterText.nonBlank(title), preview: firstMessage,
                                    source: "desktop", lastActive: seconds, unread: false)
        row.startedAt = seconds
        row.cwd = cwd
        startedRows[key] = StartedRow(row: row, at: .now)
        recents.insert(row, at: 0)
        AppLog.trace("sessions", "new chat \(AppLog.tag(id)) listed before the gateway's page")
        rebuild()
    }

    /// [#440] The started chat's first turn ended (`StartedRow.settledAt`).
    func startedChatSettled(id: String, profile: String) {
        let key = Self.writeKey(id: id, profile: profile)
        guard startedRows[key]?.settledAt == nil else { return }
        startedRows[key]?.settledAt = .now
    }

    /// [#440] After a page: a started chat it lists is the gateway's row from now on. One it doesn't list yet stays on (a
    /// read that began before the first message was stored can't know it), unless the read began after the first turn
    /// had ended, or `startedRowLife` has passed.
    private func keepStartedRows(_ payload: SidebarPayload, readStartedAt: ContinuousClock.Instant) {
        guard !startedRows.isEmpty else { return }
        let paged = [payload.recents.rows, payload.cron.rows, payload.messaging.rows].compactMap { $0 }.joined()
        let listed = Set(paged.map { Self.writeKey(id: $0.id, profile: $0.profile) })
        let now = ContinuousClock.now
        for (key, held) in startedRows {
            let believed = held.settledAt.map { readStartedAt > $0 + timing.startedRowSettle } ?? false
            if listed.contains(key) || leaving.contains(key) || now - held.at > timing.startedRowLife {
                startedRows[key] = nil
            } else if believed, payload.recents.rows != nil {
                startedRows[key] = nil
                recents.removeAll { $0.id == held.row.id && $0.profile == held.row.profile }
                AppLog.note("sessions", "new chat \(AppLog.tag(held.row.id)) not on the gateway's page after its turn: its row goes")
            } else if !recents.contains(where: { $0.id == held.row.id && $0.profile == held.row.profile }) {
                recents.insert(held.row, at: 0)
            }
        }
    }

    /// Mark as Unread, here (the marker) or on any device (the watermark at 0).
    private func markedUnread(_ row: SidebarSessionRow) -> Bool {
        row.lastReadAt == 0 || device.unread.markers[row.profile]?.contains(row.id) == true
    }

    /// What the gateway calls unread in the chat in front of the person is read: once a watermark exists every row a
    /// turn stores sets the flag again, the open chat's too. Not while its turn runs (one write when it ends, not one
    /// per page), nor for activity a write was already refused for.
    private func shareOnScreenRead() {
        guard let id = seenSessionId, !stopped,
              let row = (recents + cron + messaging).first(where: { $0.id == id }), row.unread == true, !isRunning(row),
              (row.lastReadAt ?? 0) > 0, !markedUnread(row), sharesRead(row) else { return }
        let key = Self.writeKey(id: row.id, profile: row.profile)
        if let refused = readRefused[key], refused >= row.recency { return }
        if let write = unreadWrites[key], write.ackAt == nil { return }
        AppLog.trace("sessions", "read sync: the chat on screen \(AppLog.tag(id)) is read")
        writeUnread(false, row: row)
    }

    /// Reads (and Mark as Unread) the gateway hasn't taken because it couldn't be reached go again: after a reconnect
    /// and after every page. A read is only still true while the chat hasn't moved since (`through`, 2 s of slack for
    /// the gap between a message's time and the chat's activity): newer rows were never seen, and "read now" would
    /// cover them.
    private func sendOwedReads() {
        guard let owed = device.unread.owed, !owed.isEmpty, !readOnlyGateway, !stopped else { return }
        for (key, through) in owed {
            if let write = unreadWrites[key], write.ackAt == nil { continue }
            let parts = key.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let row = parts.count == 2
                ? (recents + cron + messaging + archivedRows).first { $0.id == parts[1] && $0.profile == parts[0] } : nil
            // `writeUnread` takes the entry over (and owes it again if it fails again); anything else is dropped: the
            // chat left the lists, was read elsewhere, lost its mark, or moved on since it was read.
            if let row, through < 0, device.unread.markers[row.profile]?.contains(row.id) == true {
                writeUnread(true, row: row)
            } else if let row, through >= 0, row.recency <= through + 2, sharesRead(row) {
                writeUnread(false, row: row, through: through)
            } else {
                device.unread.owed?[key] = nil
            }
        }
        if device.unread.owed?.isEmpty == true { device.unread.owed = nil }
        if device.unread.owed != owed { persistState() }
    }

    /// [tile-chats] Tile chats the gateway still lists (an older app made them in the open): each is hidden there once
    /// (`PATCH {hidden: true}`, as Hermes's own hide does), so no other device, the desktop app or search shows it
    /// either. The lists here already leave them out (`SessionRules.isBotChat`). A refused write is asked again next run.
    private func hideTileChats(_ rows: [SidebarSessionRow]) {
        guard !readOnlyGateway, !stopped else { return }
        let owed = TileChats.toHide(rows).filter { tileChatsHiding.insert(Self.writeKey(id: $0.id, profile: $0.profile)).inserted }
        guard !owed.isEmpty else { return }
        AppLog.note("sessions", "hiding \(owed.count) tile chat(s) the gateway still lists")
        let client = self.client
        Task {
            var failed = 0
            for row in owed {
                let outcome = await Result.of { try await SessionWrite.patch(client, id: row.id, profile: row.profile, ["hidden": .bool(true)]) }
                if case .failure = outcome { failed += 1 }
            }
            if failed > 0 { AppLog.note("sessions", "\(failed) of \(owed.count) tile chat(s) couldn’t be hidden") }
        }
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
        // [projects-all-bots] A project made elsewhere (the desktop, another phone) shows on the pull, not a minute on.
        if !projectsByProfile.isEmpty { loadProjects(force: true) }
        if device.codingProjects.values.contains(true) {
            let pageProject = view.projectFilter.count == 1 ? view.projectFilter.first : nil
            await refreshCodingProjectPRs(projectKey: pageProject)
        }
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

    /// A user opened a listed row: select it, clear its local unread state, and send
    /// `PATCH /api/sessions/{id} {"unread":false,"profile":p}` (spec 02 §9.3) when the server says it is unread, or
    /// ([read-sync]) when its watermark doesn't yet say the chat was read through its newest activity, so the person's
    /// other device learns of the read. The row is rewritten optimistically, a list page read before the gateway
    /// acknowledged the write cannot bring the dot back, and a failure restores the last confirmed value if this write
    /// still owns the row. Read-only gateway: no write, the dot clears locally.
    func markOpened(_ session: SessionSummary) {
        guard let row = listedRow(id: session.id, profile: session.profile) else { return }
        selectedSessionId = row.id
        selectedLineage = Self.durableId(row)
        let serverUnread = row.unread == true
        device.unread.opened(row, clearServerLocally: serverUnread && readOnlyGateway)
        persistState()
        if sharesRead(row) { writeUnread(false, row: row) }
        rebuild()
    }

    /// [read-sync] The chat came on screen with fresh history, by whatever way in: a tapped alert, a bot's list of its
    /// chats, search, the Mac's sidebar. Only a tap on its Sessions row marked it read (`markOpened`), so a chat opened
    /// any other way kept the gateway's unread flag, or a Mark as Unread from another device, and showed its dot again
    /// as soon as it was left. Nothing is written while the gateway already has the read, or a write is in the air.
    func readOpened(id: String, profile: String) {
        guard !stopped, let row = listedRow(id: id, profile: profile), row.profile == profile else { return }
        device.unread.opened(row, clearServerLocally: row.unread == true && readOnlyGateway)
        persistState()
        let key = Self.writeKey(id: row.id, profile: row.profile)
        let inAir = unreadWrites[key].map { $0.ackAt == nil } ?? false
        let refused = readRefused[key].map { $0 >= row.recency } ?? false
        if !inAir, !refused, sharesRead(row) { writeUnread(false, row: row) }
        rebuild()
    }

    /// [threads] A thread's reply was read where the thread is drawn, in its bot's chat: its own row is read too (on
    /// this device and, where reads are shared, on the gateway), without becoming the selected chat.
    func markReadInPlace(id: String, profile: String) {
        guard let row = listedRow(id: id, profile: profile), isUnreadNow(row) else { return }
        device.unread.opened(row, clearServerLocally: row.unread == true && readOnlyGateway)
        persistState()
        if sharesRead(row) { writeUnread(false, row: row) }
        rebuild()
    }

    /// `through` ([read-sync]): the activity a read covers (server seconds), when it is newer than the row's own.
    func writeUnread(_ unread: Bool, row: SidebarSessionRow, through: Double? = nil) {
        let ticket = beginUnreadWrite(unread, row: row, through: through)
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
        /// [read-sync] The activity a read covers (server seconds); 0 for a Mark as Unread.
        var through: Double = 0
    }

    /// The optimistic half: the row shows the value at once and the write owns the row until it is answered.
    /// [read-sync] The row's watermark follows: 0 for unread, the activity read through for read (the row's own, or
    /// the caller's `through`), until a page read after the gateway's answer brings the gateway's own stamp.
    func beginUnreadWrite(_ unread: Bool, row: SidebarSessionRow, through: Double? = nil) -> UnreadWriteTicket {
        let key = Self.writeKey(id: row.id, profile: row.profile)
        unreadWriteTokens &+= 1
        let token = unreadWriteTokens
        // An earlier write still in the air has confirmed nothing: its own prior is the last confirmed value.
        let earlier = unreadWrites[key].flatMap { $0.ackAt == nil ? $0 : nil }
        let prior = unreadWrites[key].map { $0.ackAt == nil ? $0.prior : $0.value } ?? row.unread
        let readAt = unread ? 0 : max(row.recency, through ?? 0)
        unreadWrites[key] = UnreadWrite(token: token, value: unread, prior: prior, ackAt: nil, readAt: readAt,
                                        priorReadAt: earlier != nil ? earlier?.priorReadAt : row.lastReadAt)
        setServerUnread(unread, readAt: readAt, id: row.id, profile: row.profile)
        if device.unread.owed?[key] != nil {            // this write stands in for the one owed
            device.unread.owed?[key] = nil
            persistState()
        }
        return UnreadWriteTicket(key: key, token: token, id: row.id, profile: row.profile, value: unread, prior: prior,
                                 through: readAt)
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
    /// [read-sync] A write the gateway never answered (offline, a timeout) is owed, not undone: the dot this device
    /// cleared stays cleared here (`localReads`, as a read-only gateway's) and the write goes again (`sendOwedReads`).
    func settleUnreadWrite(_ ticket: UnreadWriteTicket, error: (any Error)?) {
        guard let write = unreadWrites[ticket.key], write.token == ticket.token else { return }
        guard let error else {
            unreadWrites[ticket.key]?.ackAt = .now
            readRefused[ticket.key] = nil
            return
        }
        unreadWrites[ticket.key] = nil
        if let error = error as? HTTPError, SessionWrite.isMaintenanceRefusal(error) {
            keepUnreadOnDevice(ticket.value, id: ticket.id, profile: ticket.profile)
        }
        if error is CancellationError {
            // Nothing learnt: the row goes back to what the gateway last said.
        } else if !(error is HTTPError) {
            AppLog.note("sessions", "read sync: \(ticket.value ? "unread" : "read") of \(AppLog.tag(ticket.id)) not sent, owed")
            var owed = device.unread.owed ?? [:]
            if owed.count >= SessionUnreadState.maxOwed, let oldest = owed.keys.sorted().first { owed[oldest] = nil }
            owed[ticket.key] = ticket.value ? -1 : ticket.through
            device.unread.owed = owed
            if !ticket.value { device.unread.localReads[ticket.id] = ticket.through }
            persistState()
        } else if !ticket.value {
            readRefused[ticket.key] = ticket.through
        }
        if let prior = ticket.prior {
            setServerUnread(prior, readAt: write.priorReadAt, id: ticket.id, profile: ticket.profile)
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
        for (key, held) in startedRows where held.row.id == id { startedRows[key]?.row.title = value }   // [#440]
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

    /// [threads] Durable links between bot threads and their parent Bot Chats, newest first.
    var botThreads: [BotThreadLink] { device.botThreads }

    /// [threads] Records a thread's link to its parent Bot Chat so it survives app relaunches and syncs across devices.
    func recordBotThread(_ link: BotThreadLink) {
        device.botThreads.removeAll { $0.profile == link.profile && $0.storedId == link.storedId }
        device.botThreads.insert(link, at: 0)
        if device.botThreads.count > BotThreadLink.maxKept {
            device.botThreads = Array(device.botThreads.prefix(BotThreadLink.maxKept))
        }
        persistState()
    }

    /// [threads] Drops a deleted thread's stored parent link.
    @discardableResult func forgetBotThread(id: String, profile: String) -> Bool {
        let before = device.botThreads.count
        device.botThreads.removeAll { $0.profile == profile && $0.storedId == id }
        guard device.botThreads.count != before else { return false }
        persistState()
        return true
    }

    /// MENUS (⋯ › Archive, Delete Chat): the chat leaves every list at once.
    func forget(id: String, profile: String, deleting: Bool = false) {
        let shortcutChanged = forgetBotShortcutRow(id: id, profile: profile, deleting: deleting)
        let threadChanged = deleting ? forgetBotThread(id: id, profile: profile) : false
        startedRows[Self.writeKey(id: id, profile: profile)] = nil   // [#440]
        let before = recents.count + cron.count + messaging.count
        recents.removeAll { $0.id == id && $0.profile == profile }
        cron.removeAll { $0.id == id && $0.profile == profile }
        messaging.removeAll { $0.id == id && $0.profile == profile }
        guard recents.count + cron.count + messaging.count != before || shortcutChanged || threadChanged else { return }
        if selectedSessionId == id { selectedSessionId = nil; selectedLineage = nil }
        if onScreenSessionId == id { onScreenSessionId = nil }
        lastFingerprint = nil
        writeCache()
        rebuild(force: shortcutChanged)
    }

    /// Rewrite the stored rows' server flag (every list that holds this profile's row, the Archived view's included: an
    /// archived chat's Mark as Read, or opening it, kept its dot until the next archived read).
    private func setServerUnread(_ unread: Bool, readAt: Double?, id: String, profile: String) {
        func update(_ rows: inout [SidebarSessionRow]) {
            for index in rows.indices where rows[index].id == id && rows[index].profile == profile {
                rows[index].unread = unread
                rows[index].lastReadAt = readAt                       // [read-sync]
            }
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
        device.unread.isUnread(row, messaging: false, selected: row.id == selectedSessionId, running: isRunning(row),
                               onScreen: row.id == seenSessionId)
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
        case "session.info":
            guard !event.replayed, !event.sessionId.isEmpty else { break }
            // Never guess a runtime's owner, particularly where two profiles share a stored id.
            if let id = event.payload["session_key"]?.nonEmptyString ?? event.payload["stored_session_id"]?.nonEmptyString {
                let profile = event.payload["profile"]?.nonEmptyString
                let candidates = (recents + cron + messaging + archivedRows).filter {
                    $0.id == id && (profile == nil || $0.profile == profile)
                }
                resultBindings[event.sessionId] = candidates.count == 1 ? (candidates[0].profile, id) : nil
            }
        case "message.complete":
            guard !event.replayed, let binding = resultBindings[event.sessionId],
                  event.payload["status"]?.string == "complete", !event.payload["error"].isTruthy,
                  let text = event.payload["text"]?.string else { break }
            noteConfirmedReply(profile: binding.profile, sessionId: binding.id, text: text)
            if device.codingProjects.values.contains(true), !prRouteMissing,
               let row = (sessions + cronSessions + messagingSessions + archivedSessions).first(where: { $0.id == binding.id && $0.profile == binding.profile }),
               isCodingSession(profile: row.profile, cwd: row.cwd) {
                Task { [weak self] in await self?.refreshPullRequests(for: [row], force: true) }
            }
        case "gateway.ready":
            resultBindings.removeAll()
            changeEvents = event.payload["change_events"]?.bool ?? false
            // A gateway reconnect may bring an updated add-on or newly reachable GitHub state.
            prRouteMissingSince = nil
            if device.codingProjects.values.contains(true) {
                if prReposState != .loaded { Task { [weak self] in await self?.loadPRRepos() } }
                schedulePRDiscovery()
            }
            // A reconnect: probe first while the last full read is fresh, else read in full.
            // [offline] §6.4: reconnects within 3 s of each other share one refresh (a failed one is not shared).
            guard reconnectShare.begin() else { break }
            // (review) Whatever read covers this reconnect, one in flight included, answers for it: if that read
            // does not end in a list or an unchanged probe, the share is given back and the next open reads again.
            reconnectReadOut = true
            refreshAfterReconnect()                   // [sessions-m9] the one probe (§11.2), inside the share
            sendOwedReads()                           // [read-sync] what couldn't be sent while the link was down
        default:
            break
        }
    }

    /// [log review 2026-11-18] Probe-first on screen too: the list up (always, in the Mac's sidebar) read all of it on
    /// every pass, 260 rows and half a megabyte every ten seconds while any chat was working. Now a pass costs the
    /// limit-1 probe, the top page when that differs, and the full list only once the last full read is older than
    /// `probeMaxAge` (`topPageFits`). A row far down that another device deleted or renamed shows up to that late.
    private func throttledPass() async {
        await readTask(probeFirst: true).value
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
                if let write = unreadWrites[key] {
                    rows[index].unread = write.value
                    rows[index].lastReadAt = write.readAt             // [read-sync]
                }
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
        keepStartedRows(payload, readStartedAt: readStartedAt)   // [#440]
        refreshArchivedIfMoved(from: prior.recents)
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
        // [read-sync] What another device read (the gateway's watermark covers the chat's newest activity) is read here.
        let earlier = Dictionary((prior.recents + prior.cron + prior.messaging).map { (Self.writeKey(id: $0.id, profile: $0.profile), $0) },
                                 uniquingKeysWith: { first, _ in first })
        device.unread.absorbGatewayReads(recents + cron + messaging, previous: earlier)
        absorbSelected()
        shareOnScreenRead()
        sendOwedReads()
        hideTileChats(recents + messaging)
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
        refreshOffPageShortcuts()
        schedulePRDiscovery()
        refreshLatest()
        // [sessions-m9] Group By Project or a project filter kept from the last launch needs the projects without the
        // Filter menu ever being opened (§3.4); asked at most once a minute per bot.
        if view.groupBy == .project || !view.projectFilter.isEmpty { loadProjects() }
    }

    /// [read-sync] The archived chats were read once (Show › Archived, or a project's Done pile) and nothing reads them
    /// again but a pull. A chat another device archived left the list with this page (it did not age off the bottom),
    /// or one it unarchived is back on it: the archived chats are read again, so Done gains or loses the chat now.
    /// This device's own Archive and Delete move their rows themselves and never pass here.
    private func refreshArchivedIfMoved(from before: [SidebarSessionRow]) {
        guard archivedLoadState == .ready, archivedRefresh == nil, !before.isEmpty else { return }
        let now = Set(recents.map { Self.writeKey(id: $0.id, profile: $0.profile) })
        // The page's oldest row that is there by age (a pin comes with every page, however old).
        let floor = recents.filter { $0.pinned != true }.map(\.recency).min() ?? 0
        let left = before.contains { !now.contains(Self.writeKey(id: $0.id, profile: $0.profile)) && $0.recency >= floor }
        // (Only a row that says archived: the archived read also answers with the pinned chats that are not.)
        let back = !left && archivedRows.contains { $0.archived == true && now.contains(Self.writeKey(id: $0.id, profile: $0.profile)) }
        guard left || back else { return }
        AppLog.trace("sessions", "archived list: read again, a chat \(left ? "left" : "came back to") the list")
        archivedRefresh = Task { [weak self] in
            await self?.loadArchived()
            self?.archivedRefresh = nil
        }
    }

    /// The selected chat is on screen or was just read: what it holds is seen.
    /// [unread-working] A selected chat the gateway compacted is listed under a new id with the same lineage: the
    /// selection follows it, or the chat on screen would count as one never opened and take a dot at its next row.
    private func absorbSelected() {
        guard let id = selectedSessionId else { return }
        let rows = recents + cron + messaging
        if let row = rows.first(where: { $0.id == id }) {
            selectedLineage = Self.durableId(row)
        } else if let lineage = selectedLineage, let moved = rows.first(where: { $0.lineageRootId == lineage }) {
            if onScreenSessionId == id { onScreenSessionId = moved.id }       // [read-sync]
            selectedSessionId = moved.id
        }
        guard let now = selectedSessionId else { return }
        for row in rows where row.id == now { device.unread.opened(row, clearServerLocally: false) }
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

    /// Live lookup also works for a chat which is not currently in the sidebar.
    func pullRequest(profile: String, id: String) -> SessionPRStatus? {
        pullRequests[Self.writeKey(id: id, profile: profile)]
    }

    /// Linked repositories paired with their owning project key, for multi-bot folder resolution.
    private var linkedPRRepoPairs: [(project: String, path: String)] {
        (prRepos ?? []).compactMap { repo in repo.project.map { ($0, repo.path) } }
    }

    /// Resolve a chat's project key against its profile first, falling back across other profiles' projects and linked
    /// repos so a second bot working in the same repository still joins the coding project.
    func projectKeyFor(cwd: String?, profile: String) -> String {
        SessionProjects.keyAcrossProfiles(cwd: cwd, profile: profile, projectsByProfile: projectsByProfile,
                                          linkedRepos: linkedPRRepoPairs)
    }

    /// Resolve against the owning profile's real project tree, including worktree paths and shared repos.
    func isCodingSession(profile: String, cwd: String?) -> Bool {
        let key = projectKeyFor(cwd: cwd, profile: profile)
        return key != SessionProjects.homeKey && isCodingProject(key)
    }

    func isCodingSession(profile: String, id: String, fallbackCwd: String? = nil) -> Bool {
        let row = (sessions + cronSessions + messagingSessions + archivedSessions)
            .first { $0.profile == profile && $0.id == id }
        return isCodingSession(profile: profile, cwd: row?.cwd ?? fallbackCwd)
    }

    /// UI discovery is opt-in; the unscoped refresh remains available to explicit callers and tests.
    func refreshCodingPullRequest(for row: SessionSummary) async {
        guard isCodingSession(profile: row.profile, cwd: row.cwd) else { return }
        await refreshPullRequests(for: [row])
    }

    /// [pr-multi] A coding chat came on screen: where its code stands is asked again at once, fresh from GitHub, so a
    /// pull request merged a minute ago shows merged in the chat (the list's own pass may be up to a minute away).
    private func refreshOpenedChatPullRequest(_ id: String) {
        guard started, !stopped, appActive, !prRouteMissing, device.codingProjects.values.contains(true),
              let row = (sessions + cronSessions + messagingSessions + archivedSessions).first(where: { $0.id == id }),
              isCodingSession(profile: row.profile, cwd: row.cwd) else { return }
        Task { [weak self] in await self?.refreshPullRequests(for: [row], force: true) }
    }

    /// Scoped, stale-while-revalidate invalidation when coding project eligibility or repository links change.
    /// Keeps existing marks for unrelated coding projects visible instead of wiping every project back to `?`.
    func codingProjectsChanged(scopeProject: String? = nil, projectsTreeUpdated: Bool = false) {
        let anyCoding = device.codingProjects.values.contains(true)
        if !anyCoding {
            prGeneration &+= 1
            prInFlight.removeAll()
            prCheckedAt.removeAll()
            pullRequests.removeAll()
            prFocusedRow = nil
            rebuild()
            schedulePRPoll()
            return
        }
        let allRows = sessions + cronSessions + messagingSessions + archivedSessions
        let rowsByKey = Dictionary(allRows.map { (Self.writeKey(id: $0.id, profile: $0.profile), $0) },
                                   uniquingKeysWith: { first, _ in first })
        if let scopeProject {
            let enabled = isCodingProject(scopeProject)
            if !enabled {
                prGeneration &+= 1
                prInFlight.removeAll()
                for (key, row) in rowsByKey where projectKeyFor(cwd: row.cwd, profile: row.profile) == scopeProject {
                    pullRequests[key] = nil
                    prCheckedAt[key] = nil
                }
                if let focused = prFocusedRow, projectKeyFor(cwd: focused.cwd, profile: focused.profile) == scopeProject {
                    prFocusedRow = nil
                }
            } else {
                // Keep existing marks on screen (stale-while-revalidate) while clearing cooldowns for this project.
                for (key, row) in rowsByKey where projectKeyFor(cwd: row.cwd, profile: row.profile) == scopeProject {
                    prCheckedAt[key] = nil
                }
            }
        } else if projectsTreeUpdated {
            // Drop cached marks only for rows that no longer belong to any coding project.
            for (key, row) in rowsByKey where !isCodingSession(profile: row.profile, cwd: row.cwd) {
                pullRequests[key] = nil
                prCheckedAt[key] = nil
            }
        } else {
            // Sync changed `codingProjects`: drop marks for sessions no longer coding, revalidate the rest.
            prGeneration &+= 1
            prInFlight.removeAll()
            for (key, row) in rowsByKey where !isCodingSession(profile: row.profile, cwd: row.cwd) {
                pullRequests[key] = nil
                prCheckedAt[key] = nil
            }
        }
        rebuild()
        if projectsTreeUpdated { schedulePRDiscovery() } else { schedulePRPoll() }
    }

    /// Explicit pull-to-refresh for coding projects: retries `pr-repos` if needed, clears the 60s client cooldown,
    /// asks fresh for up to 4 active open/draft PRs, and refreshes the rest of the project's chats.
    func refreshCodingProjectPRs(projectKey: String?) async {
        guard !stopped, device.codingProjects.values.contains(true) else { return }
        prRouteMissingSince = nil
        if prReposState != .loaded { _ = await loadPRRepos() }
        let all = sessions + cronSessions + messagingSessions + archivedSessions
        let targets = all.filter { row in
            guard isCodingSession(profile: row.profile, cwd: row.cwd) else { return false }
            guard let projectKey else { return true }
            return projectKeyFor(cwd: row.cwd, profile: row.profile) == projectKey
        }
        guard !targets.isEmpty else { return }
        for row in targets {
            prCheckedAt[Self.writeKey(id: row.id, profile: row.profile)] = nil
        }
        let activeWaiting = targets.filter { row in
            let state = pullRequests[Self.writeKey(id: row.id, profile: row.profile)]?.state
            return state == .open || state == .draft || state == .unknown
        }
        let hot = Array(activeWaiting.prefix(4))
        let hotKeys = Set(hot.map { Self.writeKey(id: $0.id, profile: $0.profile) })
        let rest = targets.filter { !hotKeys.contains(Self.writeKey(id: $0.id, profile: $0.profile)) }
        if !hot.isEmpty { await refreshPullRequests(for: hot, force: true) }
        if !rest.isEmpty { await refreshPullRequests(for: rest, force: true) }
    }

    /// Explicit chat requests can include an unlisted row; automatic discovery is visibility-gated.
    func refreshPullRequests(for rows: [SessionSummary], force: Bool = false) async {
        guard !stopped, !prRouteMissing else { return }
        if chatFocused, let focused = onScreenSessionId ?? selectedSessionId,
           let row = rows.first(where: { $0.id == focused }) { prFocusedRow = row }
        let now = ContinuousClock.now
        var seen = Set<String>()
        // A targeted forced ask (e.g. Mark as Closed, chat open, turn complete) is never silently dropped just
        // because a slow 32-chat background poll happens to be in flight for the same key.
        let bypassInFlight = force && rows.count <= 4
        let unique = rows.filter { row in
            let key = Self.writeKey(id: row.id, profile: row.profile)
            return seen.insert(key).inserted
                && (bypassInFlight || !prInFlight.contains(key))
                && (force || prCheckedAt[key].map { now - $0 >= .seconds(60) } ?? true)
        }
        let reserved = Set(unique.map { Self.writeKey(id: $0.id, profile: $0.profile) })
        guard !reserved.isEmpty else { return }
        let newlyReserved = reserved.subtracting(prInFlight)
        prInFlight.formUnion(newlyReserved)
        let generation = prGeneration
        var versions: [String: Int] = [:]
        for key in reserved {
            if bypassInFlight { prKeyVersion[key, default: 0] &+= 1 }
            versions[key] = prKeyVersion[key] ?? 0
        }
        defer { if generation == prGeneration { prInFlight.subtract(newlyReserved) } }
        // [pr-multi] Asked for by hand (a chat opened, a mark set, a turn completed): its waiting pull requests are
        // asked of GitHub again rather than read from the add-on's three-minute cache, so a merge shows in seconds.
        let fresh = force && unique.count <= 4
        // [pr-instant] The chunks are asked for together (three at a time) and each is drawn as it answers: a
        // project of 80 chats took three answers one after another (owner's phone 2026-11-19: 6.6 s, 5.7 s, 1.8 s).
        var changed = false
        let chunks = stride(from: 0, to: unique.count, by: 32).map { Array(unique[$0..<min($0 + 32, unique.count)]) }
        await withChildTasks(of: PRChunkAnswer.self) { group in
            var waiting = chunks.makeIterator()
            for _ in 0..<3 {
                guard let chunk = waiting.next() else { break }
                group.addTask { [weak self] in await self?.askPullRequests(chunk, fresh: fresh) ?? PRChunkAnswer(keys: [], answers: nil, missing: false) }
            }
            while let answer = await group.next() {
                if answer.missing { prRouteMissingSince = .now }
                guard !Task.isCancelled, !stopped, generation == prGeneration else { continue }
                for key in answer.keys {
                    // Never let an older background chunk overwrite a newer forced/detail answer for this key.
                    guard (prKeyVersion[key] ?? 0) == (versions[key] ?? 0) else { continue }
                    let previous = pullRequests[key]
                    let now: SessionPRStatus?
                    if let answers = answer.answers {
                        // Omission cannot establish absence of a PR. The client may know
                        // a row belongs to a coding project even when the gateway doesn't.
                        if var found = answers[key] {
                            if found.state == .unknown { found.unknownReason = .unmatched }
                            now = found
                        } else {
                            now = SessionPRStatus(state: .unknown, unknownReason: .unmatched)
                        }
                        prCheckedAt[key] = .now
                    } else if answer.missing {
                        now = SessionPRStatus(state: .unknown, unknownReason: .unsupported)   // a gateway that can't say: not evidence of absence
                        prCheckedAt[key] = .now
                    } else {
                        // [pr-instant] No answer this time (offline, Hermes restarting): what it last said stays,
                        // rather than every mark turning to ? and back. Never known: unavailable. Do NOT stamp
                        // `prCheckedAt` so reconnect or retry can recover immediately instead of waiting 60 s.
                        now = previous ?? SessionPRStatus(state: .unknown, unknownReason: .unavailable)
                    }
                    if now != previous {
                        pullRequests[key] = now
                        changed = true
                    }
                }
                if changed { rebuild() }
                if !answer.missing, !prRouteMissing, let chunk = waiting.next() {
                    group.addTask { [weak self] in await self?.askPullRequests(chunk) ?? PRChunkAnswer(keys: [], answers: nil, missing: false) }
                }
            }
        }
        // Bound both positive and negative entries, preferring to evict unlisted chats before active ones.
        if prCheckedAt.count > 512 {
            let liveKeys = Set((sessions + archivedSessions).map { Self.writeKey(id: $0.id, profile: $0.profile) })
            let evictOrder = prCheckedAt.sorted { a, b in
                let la = liveKeys.contains(a.key), lb = liveKeys.contains(b.key)
                if la != lb { return !la }
                return a.value < b.value
            }
            for (key, _) in evictOrder.prefix(prCheckedAt.count - 512) {
                prCheckedAt[key] = nil
                if pullRequests[key] != nil { pullRequests[key] = nil; changed = true }
            }
        }
        if changed {
            rebuild()
            saveMarks()
        }
    }

    /// [pr-card-detail] The PR card's own ask: this one chat, fresh, with its files and check runs (`detail: true`).
    /// The answer's facts, without files and runs, also update the chat's mark. nil: no answer for it.
    func pullRequestDetail(profile: String, id: String) async -> SessionPRStatus? {
        try? await pullRequestDetailResult(profile: profile, id: id)
    }

    /// Throwing variant for the PR card so network/gateway errors surface a clear inline retry state instead of
    /// silently disappearing when the spinner stops.
    func pullRequestDetailResult(profile: String, id: String, manualRetry: Bool = false) async throws -> SessionPRStatus? {
        if manualRetry { prRouteMissingSince = nil }
        guard !prRouteMissing else { throw PRDetailError.unsupported }
        let chat = SessionSummary(id: id, profile: profile, title: "", preview: nil, lastActive: nil, source: nil,
                                  unread: false, isRunning: false)
        let answer = await askPullRequests([chat], fresh: true, detail: true)
        if answer.missing {
            prRouteMissingSince = .now
            throw PRDetailError.unsupported
        }
        guard let answers = answer.answers else { throw PRDetailError.unavailable }
        let key = Self.writeKey(id: id, profile: profile)
        guard var status = answers[key] else {
            let unmatched = SessionPRStatus(state: .unknown, unknownReason: .unmatched)
            prKeyVersion[key, default: 0] &+= 1
            prCheckedAt[key] = .now
            if pullRequests[key] != unmatched {
                pullRequests[key] = unmatched
                rebuild()
            }
            return unmatched
        }
        if status.state == .unknown { status.unknownReason = .unmatched }
        var kept = status
        kept.items = status.items?.map { item in
            var item = item
            item.files = nil
            item.checks?.runs = nil
            return item
        }
        prKeyVersion[key, default: 0] &+= 1
        prCheckedAt[key] = .now
        if pullRequests[key] != kept {
            pullRequests[key] = kept
            rebuild()
            saveMarks()
        }
        return status
    }

    nonisolated enum PRDetailError: Error, Equatable {
        case unavailable
        case unsupported
    }

    private struct PRChunkAnswer: Sendable {
        var keys: Set<String>
        /// nil: no answer (the request failed).
        var answers: [String: SessionPRStatus]?
        /// The gateway has no such route (404).
        var missing: Bool
    }

    private func askPullRequests(_ chunk: [SessionSummary], fresh: Bool = false, detail: Bool = false) async -> PRChunkAnswer {
        let keys = Set(chunk.map { Self.writeKey(id: $0.id, profile: $0.profile) })
        var fields: [String: JSONValue] = ["sessions": .array(chunk.map { ["profile": .string($0.profile), "id": .string($0.id)] })]
        if fresh { fields["fresh"] = .bool(true) }   // an add-on before 0.9.75 ignores it
        // [pr-review-facts] Files and check runs: only for the one chat whose PR card is open (the add-on honours it for
        // 4 chats or fewer; an older one ignores it).
        if detail && chunk.count <= 4 { fields["detail"] = .bool(true) }
        let body = JSONValue.object(fields)
        // The outcome is bound first and the answer built from it after (ChildTasks.swift: a value returned from
        // inside a `do` around `try await` can be lost in an optimized build).
        let client = self.client
        let read: Result<[JSONValue], any Error> = await .of {
            let data = try await client.rest("POST", "/api/plugins/hermes-hq-push/sessions/pr-status", query: [], body: body.encoded())
            guard let results = try JSONValue.parse(data)["sessions"]?.array else { throw PRPayloadError.invalid }
            return results
        }
        var answer = PRChunkAnswer(keys: keys, answers: nil, missing: false)
        switch read {
        case .failure(let error):
            answer.missing = (error as? HTTPError)?.status == 404
        case .success(let results):
            var answers: [String: SessionPRStatus] = [:]
            for item in results {
                guard let profile = item["profile"]?.string, let id = item["id"]?.string else { continue }
                let key = Self.writeKey(id: id, profile: profile)
                guard keys.contains(key) else { continue }
                let state = item["state"]?.string.flatMap(SessionPRStatus.State.init(rawValue:)) ?? .unknown
                answers[key] = Self.prStatus(item, state: state, detail: detail)
            }
            answer.answers = answers
        }
        return answer
    }

    /// One answer of `pr-status` (the wire contract: docs/spec/3x-sessions.md [pr-review-facts]). `detail`: a `detail: true`
    /// answer, whose items' `files` and `checks.runs` are read too.
    static func prStatus(_ item: JSONValue, state: SessionPRStatus.State, detail: Bool) -> SessionPRStatus {
        SessionPRStatus(state: state, repo: item["repo"]?.string, branch: item["branch"]?.string,
                        number: item["number"]?.int, url: item["url"]?.string.flatMap(Self.validPRURL),
                        manual: item["manual"]?.bool ?? false,
                        items: Self.prItems(item["items"], detail: detail),
                        size: PRFacts.size(item["size"]), checks: PRFacts.checks(item["checks"], runs: false),
                        title: PRFacts.title(item["title"]), base: PRFacts.base(item["base"]))
    }

    /// [pr-instant] The answers as they stand, for the next launch. [pr-review-facts] With their size, checks (no
    /// runs), title and base; never files.
    private func saveMarks() {
        let marks = pullRequests.filter { $0.value.state != .unknown }.mapValues {
            SessionMarksCacheFile.Mark(state: $0.state.rawValue, repo: $0.repo, branch: $0.branch, number: $0.number,
                                       url: $0.url?.absoluteString, manual: $0.manual ? true : nil,
                                       items: $0.items?.map {
                                           .init(state: $0.state.rawValue, repo: $0.repo, branch: $0.branch, number: $0.number,
                                                 url: $0.url?.absoluteString, source: $0.source.rawValue,
                                                 size: $0.size, checks: $0.checks.map(SessionMarksCacheFile.Mark.Checks.init),
                                                 title: $0.title, base: $0.base)
                                       },
                                       size: $0.size, checks: $0.checks.map(SessionMarksCacheFile.Mark.Checks.init),
                                       title: $0.title, base: $0.base)
        }
        RosterDisk.write(SessionMarksCacheFile(at: Date().timeIntervalSince1970 * 1000, marks: marks), to: marksURL,
                         keepNewest: (RosterDisk.sessionMarksKind, 3))
    }

    private enum PRPayloadError: Error { case invalid }

    private static func validPRURL(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == "github.com", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil else { return nil }
        let path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 5, path[0].isEmpty, !path[1].isEmpty, !path[2].isEmpty, path[3] == "pull",
              !path[4].isEmpty, path[4].allSatisfy({ $0 >= "0" && $0 <= "9" }),
              path[4].contains(where: { $0 != "0" }),
              path[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              path[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }),
              path[2] != ".", path[2] != ".." else { return nil }
        return parts.url
    }

    /// [pr-multi] The add-on's list (0.9.75), at most 12, each checked like the one answer. No list: nil (an add-on
    /// that names only the one answer, or a chat with nothing of its own to list).
    /// [pr-review-facts] Each entry's size, checks, title and base too; with `detail`, its files and check runs.
    static func prItems(_ value: JSONValue?, detail: Bool = false) -> [SessionPRItem]? {
        guard let rows = value?.array else { return nil }
        return rows.prefix(12).compactMap { row in
            guard var item = Self.prItem(.init(state: row["state"]?.string ?? "", repo: row["repo"]?.string, branch: row["branch"]?.string,
                                               number: row["number"]?.int, url: row["url"]?.string, source: row["source"]?.string))
            else { return nil }
            item.size = PRFacts.size(row["size"])
            item.checks = PRFacts.checks(row["checks"], runs: detail)
            item.title = PRFacts.title(row["title"])
            item.base = PRFacts.base(row["base"])
            if detail { item.files = PRFacts.files(row["files"]) }
            return item
        }
    }

    static func prItem(_ item: SessionMarksCacheFile.Mark.Item) -> SessionPRItem? {
        guard let state = SessionPRStatus.State(rawValue: item.state) else { return nil }
        return SessionPRItem(state: state, repo: item.repo, branch: item.branch, number: item.number.flatMap { $0 > 0 ? $0 : nil },
                             url: item.url.flatMap(validPRURL), source: item.source.flatMap(SessionPRItem.Source.init(rawValue:)) ?? .git,
                             size: validSize(item.size), checks: item.checks?.checks,
                             title: cachedWord(item.title, limit: PRFacts.titleLimit), base: cachedWord(item.base))
    }

    /// [pr-review-facts] A cached size read back as the wire's rule reads it: no negative count.
    static func validSize(_ size: SessionPRSize?) -> SessionPRSize? {
        guard let size, size.files >= 0, size.additions >= 0, size.deletions >= 0 else { return nil }
        return size
    }

    /// [pr-review-facts] A cached title or base read back: trimmed, empty is none.
    static func cachedWord(_ text: String?, limit: Int = 200) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(limit))
    }

    func schedulePRDiscovery() {
        guard started, !stopped, appActive, (listVisible || chatFocused), !prRouteMissing,
              device.codingProjects.values.contains(true) else { return }
        loadProjects()
        Task { [weak self] in
            guard let self, self.started, !self.stopped, self.appActive,
                  self.listVisible || self.chatFocused, self.device.codingProjects.values.contains(true) else { return }
            let all = self.sessions + self.cronSessions + self.messagingSessions + self.archivedSessions
                + (self.prFocusedRow.map { [$0] } ?? [])
            let visible = self.listVisible ? all : all.filter { $0.id == (self.onScreenSessionId ?? self.selectedSessionId) }
            let rows = visible.filter { self.isCodingSession(profile: $0.profile, cwd: $0.cwd) }
            await self.refreshPullRequests(for: rows)
        }
    }

    private func schedulePRPoll() {
        prPollTask?.cancel()
        prPollTask = nil
        guard started, !stopped, appActive, listVisible || chatFocused, !prRouteMissing,
              device.codingProjects.values.contains(true) else { return }
        // [pr-manage] With a coding project on screen: whether this gateway takes links and marks (retry transient failures).
        if prReposState == .unknown || prReposState == .failed { Task { [weak self] in await self?.loadPRRepos() } }
        schedulePRDiscovery()
        prPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.appActive, !self.stopped, self.listVisible || self.chatFocused else { return }
                if self.prReposState == .failed { _ = await self.loadPRRepos() }
                self.schedulePRDiscovery()
            }
        }
    }

    private func summary(_ row: SidebarSessionRow, messaging: Bool, words: inout [String: RowWords]) -> SessionSummary {
        var summary = baseSummary(row, messaging: messaging, words: &words)
        summary.pinned = row.pinned == true
        summary.archived = row.archived == true
        summary.color = device.colors[Self.durableId(row)]
        summary.outside = messaging
        summary.origin = ChatSource.origin(source: row.source, handoffPlatform: row.handoffPlatform, handoffState: row.handoffState)
        return summary
    }

    func shortcutSummary(_ row: SidebarSessionRow) -> SessionSummary {
        var words: [String: RowWords] = [:]
        return summary(row, messaging: false, words: &words)
    }

    /// The key More › Color keeps a chat's colour under: its lineage root, else its id (`sessionPinId`).
    static func durableId(_ row: SidebarSessionRow) -> String { row.lineageRootId ?? row.id }

    private func isRunning(_ row: SidebarSessionRow) -> Bool { row.liveId(where: running.contains) != nil }

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
        let busy = isRunning(row)
        var summary = SessionSummary(id: row.id, profile: row.profile, title: shown.title, preview: shown.preview,
                                     lastActive: row.recency > 0 ? Date(timeIntervalSince1970: row.recency) : nil,
                                     source: row.source,
                                     unread: device.unread.isUnread(row, messaging: messaging, selected: selected,
                                                                    running: busy,
                                                                    onScreen: row.id == seenSessionId),
                                     isRunning: busy)
        // [sessions-m9] Sort By, Row Detail, the status and the pending line (docs/spec/3x-sessions.md §3.1, §3.3, §9).
        summary.startedAt = (row.startedAt ?? 0) > 0 ? Date(timeIntervalSince1970: row.startedAt ?? 0) : nil
        summary.tokens = row.totalTokens
        summary.cost = row.costUsd
        summary.cwd = row.cwd
        summary.owner = row.userId
        // Only the message read for this exact list revision can describe its latest outcome.
        // A live `message.complete` reply bridges the short gap while `refreshLatest` catches up to the new `recency`.
        if let message = device.latest[key],
           (message.at == row.recency
            || (confirmedReplyRecency[key] == message.at && row.recency >= message.at && row.recency - message.at <= 15)),
           (message.count == nil || row.messageCount == nil || message.count == row.messageCount || confirmedReplyRecency[key] == message.at),
           !TimelineNotes.isTaskSnapshot(message.text) {
            summary.lastResult = message.codingResult
        } else if row.messageCount == 0 { summary.lastResult = "No activity yet" }
        summary.pullRequest = isCodingSession(profile: row.profile, cwd: row.cwd)
            ? (pullRequests[key] ?? SessionPRStatus(state: .unknown, unknownReason: prRouteMissing ? .unsupported : .checking)) : nil
        summary.branch = row.gitBranch.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        summary.metadata = SessionRowWords.metadata(branch: row.gitBranch, model: row.model, messages: row.messageCount,
                                                    toolCalls: row.toolCallCount)
        summary.pending = pendingLine?(row.profile, row.id)
        summary.inputDetail = inputDetails[key]
        summary.status = row.liveId(where: needsInput.contains) != nil ? .needsInput : summary.isRunning ? .working : summary.unread ? .unread
            : summary.pending.map { !$0.failed } == true ? .draft : .idle
        if busy, let stepId = row.liveId(where: { steps[$0] != nil }) { summary.step = steps[stepId] }
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
        // [archived-pins] Owner 2026-11-23 ("chats that I have archived in a project are showing here"): the gateway's
        // recents back-fill every pinned chat, archived ones too (a pin is a keep there). An archived chat is not a live
        // one, pinned or not: it is listed with the archived (Show › Archived, a project's Done), never in the list.
        let visible = recents.filter { !SessionRules.isBotChat($0) && $0.archived != true
            && (showRuns || $0.pinned == true || !SessionRules.isBackgroundRun($0))
            && !leaving.contains(Self.writeKey(id: $0.id, profile: $0.profile)) }
        let archivedPool: [SidebarSessionRow] = {
            let pinnedArchived = recents.filter { $0.archived == true }
            guard !pinnedArchived.isEmpty else { return archivedRows }
            let known = Set(archivedRows.map { Self.writeKey(id: $0.id, profile: $0.profile) })
            return archivedRows + pinnedArchived.filter { !known.contains(Self.writeKey(id: $0.id, profile: $0.profile)) }
        }()
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
        let nextArchived = archivedPool.filter { !SessionRules.isBotChat($0) && !leaving.contains(Self.writeKey(id: $0.id, profile: $0.profile))
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
        for task in [eventsTask, readInFlight, pollTask, latestFlushTask] { task?.cancel() }
    }
}
