// Capabilities for one bot (spec 1x-settings §9): its skills (switches, the official catalog's installs) and its
// connectors (MCP servers with live status and a switch). Each list keeps its last answer painted while it refreshes;
// writes are optimistic and flip back on failure.

import Observation
import UIKit

enum CapabilitiesTab: String, CaseIterable, Identifiable {
    case skills, tools, connectors, plugins   // [capabilities] four tabs (3x §2)
    var id: String { rawValue }
    var title: String {
        switch self {
        case .skills: "Skills"
        case .tools: "Tools"
        case .connectors: "Connectors"
        case .plugins: "Plugins"
        }
    }
    var prompt: String { "Search \(title)" }
}

@MainActor @Observable
final class CapabilitiesModel {
    var profile: String { didSet { if profile != oldValue { profileChanged() } } }
    /// [connectors] The managed half of the Connectors tab: apps reached through the bot's Nous account.
    let managed: ManagedAppsModel?
    /// [cap-pages] The one list this page shows (each list is its own page now, so it never changes).
    let tab: CapabilitiesTab
    /// The search field filters the list of the tab showing (skills: name, description, category; connectors: name,
    /// plugin, transport). Its prompt follows the tab.
    var query = ""
    /// Opens the bar's search (the empty Skills state's button).
    @ObservationIgnored var openSearch: (() -> Void)?

    // Skills
    var skills: [SkillInfo]?
    var official: [OfficialSkill]?
    var skillsError: String?
    var skillsLoading = false
    var toggling: Set<String> = []
    /// Official identifiers (or skill names, for an uninstall) whose action is running.
    var running: Set<String> = []
    /// [hub] The Skills Hub search (the desktop's `HubSkillsSection`): the query it answered, its results, the hub
    /// identifiers already installed. `hubUnsupported`: this gateway has no hub search (an older Hermes), so no row.
    var hubQuery: String?
    var hubResults: [HubSkill]?
    var hubInstalled: Set<String> = []
    var hubSearching = false
    var hubError: String?
    var hubUnsupported = false

    // Connectors
    var servers: [McpServer]?
    var serversError: String?
    var serversLoading = false
    var mcpToggling: Set<String> = []
    /// [directory] Hermes' own app catalog (`GET /api/mcp/catalog`): nil until read, and when the gateway has none.
    var catalog: [McpCatalogEntry]?
    var catalogUnsupported = false
    @ObservationIgnored var catalogCache: [String: [McpCatalogEntry]] = [:]

    // [capabilities] 3x: notices, tools, plugins (methods live in CapabilitiesModel+*.swift)
    var installNotices: [InstallNotice] = []
    var skillsNotice: String?
    var refreshFailed: CapabilitiesTab?
    var disabling: (done: Int, total: Int)?
    var toolsets: [Toolset]?
    var toolsError: String?
    var toolsTooOld = false
    var toolUsage: [String: Int]?
    var toolToggling: Set<String> = []
    var toolSort: ToolSort = ToolSort.saved { didSet { UserDefaults.standard.set(toolSort.rawValue, forKey: "capabilities.tools.sort") } }
    var serversNotice: String?
    var plugins: [PluginInfo]?
    var pluginsError: String?
    var pluginsUnavailable = false
    var pluginBusy: Set<String> = []
    var pluginNotice: String?
    var pluginNeedsKeys = false
    var pluginWarnings: [String: [String]] = [:]
    var pluginNoticeAction: PluginNoticeAction?
    var kanbanTick = 0
    /// [plugin-pages] The pages this bot's plugins add (`GET /api/dashboard/plugins`): nil until read, and on a
    /// gateway that doesn't list them.
    var dashboardPages: [PluginDashboardPage]?
    /// [plugin-pages] Plugins a rescan was already asked for, by bot (one rescan per plugin while the app runs).
    @ObservationIgnored var pagesRescanned: [String: Set<String>] = [:]
    /// The connector row to scroll to when the page was opened from an issue (§8.5).
    var focusServer: String?
    /// The connector VoiceOver should land on after that scroll (§17.5 e).
    var spokenServer: String?
    @ObservationIgnored var toolCache: [String: [Toolset]] = [:]
    @ObservationIgnored var usageCache: [String: (at: Date, counts: [String: Int])] = [:]
    @ObservationIgnored var pluginCache: [String: [PluginInfo]] = [:]
    @ObservationIgnored var loadedAt: [String: Date] = [:]

    @ObservationIgnored let services: any AppServices
    @ObservationIgnored weak var presenter: UIViewController?
    @ObservationIgnored private var skillCache: [String: (skills: [SkillInfo], official: [OfficialSkill]?)] = [:]
    @ObservationIgnored private var serverCache: [String: [McpServer]] = [:]
    @ObservationIgnored var skillsRefreshFailed = false
    @ObservationIgnored private var statusTimer: Task<Void, Never>?
    @ObservationIgnored private var waitTimer: Timer?

    init(services: any AppServices, profile: String?, tab: CapabilitiesTab) {
        self.services = services
        self.profile = profile ?? "default"
        self.tab = tab
        let store = (services as? SettingsServices)?.capabilities as? CapabilitiesStore
        managed = store.map { ManagedAppsModel(client: $0.client, profile: profile ?? "default") }   // [connectors]
        managed?.readOnly = store?.readOnlyGateway ?? false
        managed?.connectorsShowing = tab == .connectors
        seedFromWarmUp()                               // [offline] §6.10: rows in the first frame
    }

    /// [offline] §6.10: what the launch warm-up (or this page: [load-cache] up to a week ago, kept on disk) read for this
    /// bot fills the first frame; `load()` refreshes behind it as before.
    private func seedFromWarmUp() {
        guard skillCache[profile] == nil, let account = (services as? AppModel)?.account?.id,
              let warm = CapabilitiesWarmCache.shared.seed(account: account, profile: profile) else { return }
        skillCache[profile] = (warm.skills, warm.official)
        skills = warm.skills
        official = warm.official
    }

    var service: (any CapabilitiesService)? { (services as? SettingsServices)?.capabilities }
    /// The concrete store: the 3x calls (tools, connectors, plugins) are not on the protocol.
    var store: CapabilitiesStore? { service as? CapabilitiesStore }
    var readOnly: Bool { store?.readOnlyGateway ?? false }
    var isConnected: Bool { services.connection == .ready }

    /// The visible bots for the picker ("Hermes" = `default` first).
    var bots: [Bot] {
        let visible = services.bots.filter { !$0.hidden }
        return visible.sorted { a, b in a.id == "default" ? true : b.id == "default" ? false : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
    }

    var botName: String { services.bots.first { $0.id == profile }?.name ?? (profile == "default" ? "Hermes" : RosterRules.titleCase(profile)) }
    var botHead: JSONValue? { services.bots.first { $0.id == profile }?.head }

    /// The Bot picker's list: `bots`, plus a stand-in for this page's bot when it isn't among them (roster not loaded
    /// yet, or a hidden bot), so the row still says which bot the page covers (UX study #49).
    var pickerBots: [Bot] {
        let visible = bots
        guard !visible.contains(where: { $0.id == profile }) else { return visible }
        let current = Bot(id: profile, name: botName, role: nil, preview: nil, lastActive: nil, isWorking: false,
                          unread: false, pinned: false, pinOrder: nil, sectionName: nil, hidden: false,
                          canonicalSessionId: nil, head: botHead)
        return [current] + visible
    }

    // MARK: Lifecycle

    func appear() {
        load()
        startStatusTimer()
    }

    func disappear() {
        statusTimer?.cancel(); statusTimer = nil
        waitTimer?.invalidate(); waitTimer = nil
    }

    private func profileChanged() {
        seedFromWarmUp()                               // [offline] §6.10
        skills = skillCache[profile]?.skills
        official = skillCache[profile]?.official
        servers = serverCache[profile]
        catalog = catalogCache[profile]   // [directory]
        skillsError = nil
        serversError = nil
        toolsets = toolCache[profile]; toolsError = nil; toolUsage = usageCache[profile]?.counts
        plugins = pluginCache[profile]; pluginsError = nil
        skillsNotice = nil; serversNotice = nil; pluginNotice = nil; refreshFailed = nil
        hubQuery = nil; hubResults = nil; hubError = nil; hubInstalled = []   // [hub] results belong to one bot
        hubUnsupported = false   // [hub] one bot's older Hermes doesn't speak for another bot's gateway
        managed?.profile = profile   // [connectors] reads that bot's managed apps (when the tab shows)
        load()
    }

    func load() {
        switch tab {
        case .skills: if fresh("skills") { return }; Task { await reloadSkills() }
        case .tools: if fresh("tools") { return }; Task { await reloadTools() }
        case .connectors:   // [connectors] [directory]
            // [perf] Like the other tabs: a pop back from a connector page does not read everything again (§2).
            if !fresh("servers") { Task { await reloadServers() } }
            if !fresh("catalog") { Task { await reloadCatalog() } }
            managed?.load()
        case .plugins:
            Task { await PluginCatalogStore.shared.load() }   // [find-plugins] the kept copy, read again when stale
            if fresh("plugins") { return }; Task { await reloadPlugins() }
        }
    }

    /// A tab whose list was read under 30 s ago is not read again by a tab switch (§2).
    func fresh(_ kind: String) -> Bool {
        guard let at = loadedAt["\(kind)|\(profile)"] else { return false }
        return Date().timeIntervalSince(at) < 30
    }
    func stamp(_ kind: String, _ profile: String) { loadedAt["\(kind)|\(profile)"] = Date() }

    /// "Refresh" in the menu and pull-to-refresh: the showing tab, past every cache.
    func refresh() async {
        refreshFailed = nil
        switch tab {
        case .skills:
            await reloadSkills()
            if skillsRefreshFailed { refreshFailed = .skills }
        case .tools: usageCache[profile] = nil; await reloadTools()
        case .connectors:
            // [perf] The three reads together: the refresh waits for the slowest, not their sum.
            async let s: Void = reloadServers()
            async let c: Void = reloadCatalog()      // [directory]
            async let m: Void = managed?.reload() ?? ()   // [connectors]
            _ = await (s, c, m)
        case .plugins:
            async let p: Void = reloadPlugins()
            async let c: Void = PluginCatalogStore.shared.load(force: true)   // [find-plugins]
            _ = await (p, c)
        }
    }

    /// Retried when the gateway link returns.
    func waitForLink() {
        guard waitTimer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isConnected else { return }
                self.waitTimer?.invalidate(); self.waitTimer = nil
                self.load()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        waitTimer = timer
    }

    // MARK: Skills

    func reloadSkills() async {
        guard let service else { return }
        guard isConnected else {
            if skills == nil { skillsError = nil }
            waitForLink()
            return
        }
        let profile = self.profile
        skillsLoading = true
        defer { skillsLoading = false }
        // [perf] The hub catalog is read alongside the installed list, which shows as soon as it lands.
        let catalogRead = Task { try? await service.officialSkills(profile) }
        let start = ContinuousClock.now
        do {
            // [offline] §6.2: one quick retry, none after a timeout or while the gateway cannot be reached.
            let installed = try await QueryRetry.read { try await service.skills(profile) }
            guard profile == self.profile else { catalogRead.cancel(); return }
            skills = installed
            skillCache[profile] = (installed, official)
            skillsError = nil
            skillsRefreshFailed = false
            stamp("skills", profile)
            let catalog = await catalogRead.value
            guard profile == self.profile else { return }
            if let catalog { official = catalog }
            skillCache[profile] = (installed, catalog ?? official)
            // [load-cache] The next launch's first frame (and its warm-up, which skips a bot read under 30 min ago).
            if let account = (services as? AppModel)?.account?.id {
                CapabilitiesWarmCache.shared.store(skills: installed, official: catalog ?? official, account: account, profile: profile)
            }
            AppLog.trace("plugins", "skills load \(AppLog.tag(profile)) in \(AppLog.ms(since: start)) ms: \(installed.count) installed, \(catalog?.count ?? 0) official")
        } catch {
            catalogRead.cancel()
            guard profile == self.profile else { return }
            if skills == nil { skillsError = CapabilitiesStore.detail(error) } else { skillsRefreshFailed = true }
            AppLog.note("plugins", "skills load \(AppLog.tag(profile)) failed after \(AppLog.ms(since: start)) ms: \(CapabilitiesStore.detail(error))")
            if !isConnected { waitForLink() }
        }
    }

    /// Installed, by usage then name, matching the search.
    var shownSkills: [SkillInfo] {
        (skills ?? []).filter(matches).sorted { a, b in (a.usage ?? 0) != (b.usage ?? 0) ? (a.usage ?? 0) > (b.usage ?? 0) : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
    }

    /// The row to scroll to once the Connectors list is there: the connector the issue named, else the first one
    /// with an issue. Nil until then, and nil again once used.
    var focusTarget: String? {
        guard let wanted = focusServer, tab == .connectors, let servers, !servers.isEmpty else { return nil }
        if servers.contains(where: { $0.name == wanted }) { return wanted }
        return servers.first { ServerIssues.kind(of: $0) != nil }?.name
    }

    /// Connectors matching the search, in the gateway's order.
    var shownServers: [McpServer] {
        (servers ?? []).filter { matches(name: $0.name, description: $0.plugin ?? "", category: $0.transport) }
    }

    /// Official skills not installed (and with no installed skill of that name), A–Z.
    var available: [OfficialSkill] {
        let names = Set((skills ?? []).map(\.name))
        return (official ?? []).filter { !$0.installed && !names.contains($0.name) }
            .filter { matches(name: $0.name, description: $0.description, category: $0.category) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func matches(_ skill: SkillInfo) -> Bool { matches(name: skill.name, description: skill.description, category: skill.category) }

    private func matches(name: String, description: String, category: String?) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return [name, description, category ?? ""].contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    func setSkill(_ skill: SkillInfo, enabled: Bool) {
        guard let service, !toggling.contains(skill.name) else { return }
        Haptics.play(.selection)
        flip(skill.name, enabled)
        toggling.insert(skill.name)
        let profile = self.profile
        Task {
            defer { toggling.remove(skill.name) }
            do {
                try await service.setSkill(skill.name, enabled: enabled, profile: profile)
                AppLog.trace("plugins", "skill \(skill.name) set enabled \(enabled)")
            } catch {
                if profile == self.profile { flip(skill.name, !enabled) }
                let reason = CapabilitiesStore.detail(error)
                AppLog.note("plugins", "skill \(skill.name) set enabled \(enabled) failed: \(reason)")
                FailureAlert.present(title: "Couldn’t Change \(skill.name)", reason: reason, detail: "\(error)",
                                     from: presenter) { self.setSkill(skill, enabled: enabled) }
            }
            if profile == self.profile { await reloadSkills() }
        }
    }

    func flip(_ name: String, _ enabled: Bool) {
        guard let index = skills?.firstIndex(where: { $0.name == name }) else { return }
        skills?[index].enabled = enabled
    }

    /// [capabilities] §3.1: "Get" asks first, then an inline progress row follows the action.
    func install(_ skill: OfficialSkill) {
        guard !running.contains(skill.identifier) else { return }
        let bot = botName
        TextPrompt.confirmPlain(title: "Install \(skill.name) for \(bot)?",
                                message: "\(bot) can use it in new chats. The gateway downloads it and checks it before it is installed.",
                                action: "Install", from: presenter) { [weak self] in self?.runInstall(skill) }
    }

    // MARK: [hub] The Skills Hub

    /// The search field's words, trimmed.
    var hubTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Results for what the field holds now: hub skills that aren't already offered under "Available from Hermes".
    var shownHub: [HubSkill]? {
        guard let hubResults, hubQuery == hubTerm else { return nil }
        let offered = Set((official ?? []).map(\.identifier))
        return hubResults.filter { !offered.contains($0.identifier) }
    }

    func hubIsInstalled(_ skill: HubSkill) -> Bool {
        hubInstalled.contains(skill.identifier) || (skills ?? []).contains { $0.name == skill.name }
    }

    func searchHub() {
        let term = hubTerm
        guard let service, !term.isEmpty, !hubSearching else { return }
        let profile = self.profile
        hubSearching = true
        hubError = nil
        Task {
            defer { if profile == self.profile { hubSearching = false } }
            do {
                let found = try await service.searchHub(term, profile: profile)
                guard profile == self.profile else { return }
                hubResults = found.results
                hubInstalled = found.installed
                hubQuery = term
                HQAnnounce.say(found.results.isEmpty ? "No matching skills found in the hub." : Self.plural(found.results.count, "result", "results"))
                AppLog.trace("plugins", "hub search: \(found.results.count) results")
            } catch {
                guard profile == self.profile else { return }
                if case let http as HTTPError = error, http.status == 404 || http.status == 405 { hubUnsupported = true; return }
                hubError = CapabilitiesStore.detail(error)
                AppLog.note("plugins", "hub search failed: \(hubError ?? "")")
            }
        }
    }

    /// "Get" on a hub result: asks first (saying so when the skill comes from the community), then installs it
    /// for this bot the way an official skill installs.
    func install(_ skill: HubSkill) {
        guard !running.contains(skill.identifier) else { return }
        let bot = botName
        let source = skill.isCommunity
            ? "It comes from the community (\(skill.sourceWord)), not from Nous. Read it before you trust the author. "
            : "It comes from \(skill.sourceWord). "
        TextPrompt.confirmPlain(title: "Install \(skill.name) for \(bot)?",
                                message: source + "The gateway downloads it and checks it before it is installed. \(bot) can use it in new chats.",
                                action: "Install", from: presenter) { [weak self] in
            self?.runInstall(OfficialSkill(name: skill.name, description: skill.description, identifier: skill.identifier, category: nil,
                                           installed: false)) { [weak self] in self?.hubInstalled.insert(skill.identifier) }
        }
    }

    func runInstall(_ skill: OfficialSkill, installed: (() -> Void)? = nil) {
        guard let service, !running.contains(skill.identifier) else { return }
        running.insert(skill.identifier)
        let profile = self.profile, bot = botName
        let notice = InstallNotice(profile: profile, identifier: skill.identifier, name: skill.name, bot: bot, done: false)
        installNotices.removeAll { $0.id == notice.id }
        installNotices.append(notice)
        HQAnnounce.say("\(notice.title). \(notice.message)")
        let start = ContinuousClock.now
        AppLog.trace("plugins", "skill install \(skill.name) for \(AppLog.tag(profile)) started")
        Task {
            defer { running.remove(skill.identifier) }
            var last: ActionStatus?
            do {
                for try await status in service.install(skill.identifier, profile: profile) { last = status }
            } catch {
                // The gateway dropped mid-install: never report a failure that did not happen. Wait for the link, then
                // decide from whether the skill is installed now.
                if PagesREST.transportReason(error) != nil || !isConnected {
                    for _ in 0..<120 where !isConnected { try? await Task.sleep(for: .milliseconds(500)) }
                    for _ in 0..<40 {
                        if let list = try? await service.skills(profile), list.contains(where: { $0.name == skill.name }) {
                            AppLog.trace("plugins", "skill install \(skill.name) ok after reconnect, in \(AppLog.ms(since: start)) ms")
                            finishInstall(notice, profile: profile); await reloadSkills(); return
                        }
                        try? await Task.sleep(for: .seconds(3))
                        if !isConnected { break }
                    }
                }
                installNotices.removeAll { $0.id == notice.id }
                if case let http as HTTPError = error, http.status == 404, presenter?.view.window == nil { return }   // abandoned
                let reason = CapabilitiesStore.detail(error)
                AppLog.note("plugins", "skill install \(skill.name) failed after \(AppLog.ms(since: start)) ms: \(reason)")
                FailureAlert.present(title: "Couldn’t Install \(skill.name)", reason: reason, detail: "\(error)",
                                     from: presenter)
                return
            }
            if let last, last.exitCode == 0 {
                AppLog.trace("plugins", "skill install \(skill.name) ok in \(AppLog.ms(since: start)) ms")
                finishInstall(notice, profile: profile)
                if profile == self.profile { installed?() }
            } else if let last {
                installNotices.removeAll { $0.id == notice.id }
                if let blocked = CapabilitiesStore.installBlocked(last.lines) {
                    let reason = CapabilitiesStore.blockedMessage(findings: blocked.findings, unverified: blocked.unverified)
                    AppLog.note("plugins", "skill install \(skill.name) blocked after \(AppLog.ms(since: start)) ms: \(reason)")
                    FailureAlert.present(title: "Couldn’t Install \(skill.name)", reason: reason,
                                         detail: last.lines.suffix(20).joined(separator: "\n"), from: presenter)
                } else {
                    let tail = last.lines.suffix(3).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    let reason = tail.isEmpty ? "The install ended with code \(last.exitCode ?? -1)." : tail
                    AppLog.note("plugins", "skill install \(skill.name) failed after \(AppLog.ms(since: start)) ms, exit \(last.exitCode ?? -1): \(reason)")
                    FailureAlert.present(title: "Couldn’t Install \(skill.name)", reason: reason,
                                         detail: last.lines.suffix(40).joined(separator: "\n"), from: presenter)
                }
            } else {
                installNotices.removeAll { $0.id == notice.id }
                AppLog.note("plugins", "skill install \(skill.name) ended with no status after \(AppLog.ms(since: start)) ms")
            }
            if profile == self.profile { await reloadSkills() }
        }
    }

    private func finishInstall(_ notice: InstallNotice, profile: String) {
        Haptics.play(.success)
        guard let index = installNotices.firstIndex(where: { $0.id == notice.id }) else { return }
        installNotices[index].done = true
        let done = installNotices[index]
        HQAnnounce.say("\(done.title). \(done.message)")
    }

    /// The "Installed" row leaves 4 s after it was first on screen, or on a tap.
    func seen(_ notice: InstallNotice) {
        guard notice.done else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            installNotices.removeAll { $0.id == notice.id && $0.done }
        }
    }

    func uninstall(_ name: String, done: @escaping () -> Void) {
        guard let service, !running.contains(name) else { return }
        running.insert(name)
        let profile = self.profile
        let start = ContinuousClock.now
        Task {
            defer { running.remove(name) }
            var last: ActionStatus?
            do {
                for try await status in service.uninstall(name, profile: profile) { last = status }
            } catch {
                let reason = CapabilitiesStore.detail(error)
                AppLog.note("plugins", "skill uninstall \(name) failed after \(AppLog.ms(since: start)) ms: \(reason)")
                FailureAlert.present(title: "Couldn’t Uninstall \(name)", reason: reason, detail: "\(error)", from: presenter)
                return
            }
            if last?.exitCode == 0 {
                AppLog.trace("plugins", "skill uninstall \(name) ok in \(AppLog.ms(since: start)) ms")
                Haptics.play(.success)
                done()
            } else {
                let tail = (last?.lines ?? []).suffix(3).joined(separator: "\n")
                let reason = tail.isEmpty ? "The uninstall didn’t finish." : tail
                AppLog.note("plugins", "skill uninstall \(name) failed after \(AppLog.ms(since: start)) ms: \(reason)")
                FailureAlert.present(title: "Couldn’t Uninstall \(name)", reason: reason,
                                     detail: (last?.lines ?? []).joined(separator: "\n"), from: presenter)
            }
            if profile == self.profile { await reloadSkills() }
        }
    }

    // MARK: Connectors

    func reloadServers() async {
        guard let service else { return }
        guard isConnected else { waitForLink(); return }
        let profile = self.profile
        serversLoading = true
        defer { serversLoading = false }
        // [perf] Status is asked for alongside the list (recovery still runs ahead of the list, inside mcpServers).
        let statusRead = Task { try? await service.mcpStatus(profile) }
        do {
            var list = try await QueryRetry.read { try await service.mcpServers(profile) }      // [offline] §6.2
            var status = await statusRead.value
            if let early = status, list.contains(where: { early[$0.name] == nil }) {
                status = (try? await service.mcpStatus(profile)) ?? early   // recovery re-added a server after the early read
            }
            if let status {
                for i in list.indices {
                    if let row = status[list[i].name] { list[i].status = row.status; list[i].tools = row.tools }
                }
            }
            guard profile == self.profile else { return }
            ServerIssues.shared.report(profile: profile, servers: list)   // [capabilities] §8.2
            servers = list
            serverCache[profile] = list
            serversError = nil
            stamp("servers", profile)
            AppLog.trace("connect", "connectors load \(AppLog.tag(profile)): \(list.count), \(list.filter { ServerIssues.kind(of: $0) != nil }.count) with issues")
        } catch {
            statusRead.cancel()
            guard profile == self.profile else { return }
            if servers == nil { serversError = CapabilitiesStore.detail(error) }
            AppLog.note("connect", "connectors load \(AppLog.tag(profile)) failed: \(CapabilitiesStore.detail(error))")
        }
    }

    /// On screen: status every 10 s (cached on the gateway; it never probes).
    private func startStatusTimer() {
        statusTimer?.cancel()
        // [offline] §6.9: every 30 s in Low Power Mode or when the phone is hot, re-armed when that changes.
        statusTimer = PowerPolls.loop(every: .seconds(10), floor: .zero) { [weak self] in
            guard let self, self.tab == .connectors, self.isConnected else { return }
            await self.refreshStatus()
        }
    }

    func refreshStatus() async {
        guard let service, var list = servers else { return }
        let profile = self.profile
        guard let status = try? await service.mcpStatus(profile), profile == self.profile else { return }
        for i in list.indices {
            if let row = status[list[i].name] { list[i].status = row.status; list[i].tools = row.tools }
        }
        ServerIssues.shared.report(profile: profile, servers: list)   // [capabilities] §8.2 (every poll: it holds the failure debounce)
        // [perf] An unchanged poll leaves the list alone, so the Connectors section is not diffed again every 10 s.
        if list != servers {
            servers = list
            serverCache[profile] = list
        }
    }

    func setMcp(_ server: McpServer, enabled: Bool) {
        guard let service, server.source != "plugin", !mcpToggling.contains(server.name) else { return }
        if !enabled { ServerIssues.shared.clear(profile: profile, name: server.name) }
        Haptics.play(.selection)
        setServer(server.name, enabled)
        mcpToggling.insert(server.name)
        let profile = self.profile
        Task {
            defer { mcpToggling.remove(server.name) }
            do {
                try await service.setMcp(server.name, enabled: enabled, profile: profile)
                AppLog.trace("connect", "connector \(server.name) set enabled \(enabled)")
            } catch {
                if profile == self.profile { setServer(server.name, !enabled) }
                let reason = CapabilitiesStore.detail(error)
                AppLog.note("connect", "connector \(server.name) set enabled \(enabled) failed: \(reason)")
                FailureAlert.present(title: "Couldn’t Change \(server.name)", reason: reason, detail: "\(error)",
                                     from: presenter) { self.setMcp(server, enabled: enabled) }
                return
            }
            if profile == self.profile { await reloadServers() }
        }
    }

    private func setServer(_ name: String, _ enabled: Bool) {
        guard let index = servers?.firstIndex(where: { $0.name == name }) else { return }
        servers?[index].enabled = enabled
    }

    /// "Connected · 31 tools", "Connecting…", "Couldn’t connect", "Off", "Starts when needed", "Not started", plus the plugin.
    static func statusLine(_ server: McpServer) -> String {
        var words: String
        switch server.status ?? (server.enabled ? "configured" : "disabled") {
        case "connected": words = "Connected · \(server.tools ?? 0) \(server.tools == 1 ? "tool" : "tools")"
        case "connecting": words = "Connecting…"
        case "failed": words = "Couldn’t connect"
        case "disabled": words = "Off"
        case "lazy": words = "Starts when needed"
        default: words = "Not started"
        }
        if server.enabled, ServerIssues.kind(of: server) == .needsAuth { words = "Needs sign-in" }
        if !server.enabled { words = "Off" }
        if server.source == "plugin", let plugin = server.plugin { words += " · Added by the \(DisplayName.title(plugin)) plugin" }
        return words
    }
}
