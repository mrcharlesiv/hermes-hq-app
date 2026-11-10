// The More pages this stream adds (docs/spec/3x-morepages.md §19): one table of rows (title, tile, section, order), a
// factory per row set by the page's own file, the context a page is built with, and the memory of rows a gateway
// lacks (D-M16: a row whose route answers 404 / -32601 is not listed; it is probed again on every `gateway.ready`).
// A row with no factory is never listed: More never shows a row that does nothing.

import UIKit

@MainActor
enum MorePages {
    /// What a More page is built with.
    struct Context {
        let services: any AppServices
        let pages: any PagesServices
        let client: any GatewayClient
        let account: GatewayAccount
        let makeChat: (any ChatSessionModel) -> UIViewController

        var bots: [Bot] { pages.bots }
        /// Default bot first, then roster order (the scope pill's order).
        var botChoices: [Bot] { PagesNames.scopeChoices(pages.bots) }
        /// A read-only gateway, or the pages' own DEBUG switch for one (`-HQPagesReadOnly YES`).
        var readOnly: Bool {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "HQPagesReadOnly") { return true }
            #endif
            return pages.readOnlyGateway
        }
        var isOnline: Bool { services.connection == .ready }
        /// Write controls show only on a writable gateway; while offline they are disabled with `offlineFooter`.
        var canWrite: Bool { !readOnly && isOnline }
        func botName(_ profile: String?) -> String { PagesNames.botName(profile, bots: pages.bots) }
    }

    static let offlineFooter = "You can change this once your gateway is back."

    struct Page {
        var id: String
        var title: String
        var symbol: String
        var tile: UInt32
        var section: String
        var header: String
        var order: Int
        /// The web's palette keywords for More search (`S/settings-ios-list.tsx:327-331`).
        var keywords: [String] = []
    }

    /// `S/ui-nav/more-model.ts:13-17,32`; tiles `S/phone-tab-bar.tsx:924-927`.
    static let pages: [Page] = [
        Page(id: "profiles", title: "Bot Profiles", symbol: "person.crop.circle", tile: 0x5E5CE6, section: "bots", header: "Bots", order: 10,
             keywords: ["profiles", "soul", "bots"]),
        Page(id: "messaging", title: "Messaging", symbol: "message.fill", tile: 0x30B94D, section: "bots", header: "Bots", order: 110,
             keywords: ["telegram", "discord", "slack", "platforms", "pairing"]),
        Page(id: "files", title: "Files", symbol: "folder", tile: 0x0A84FF, section: "workspace", header: "Workspace", order: 10,
             keywords: ["files", "browse", "folder", "documents"]),
        // Mac polish #65 (owner's call 2026-11-07): Changes is the +/− everywhere, as in the chat's ⋯ › More; the forked
        // branch there means Branch in New Chat.
        Page(id: "review", title: "Changes", symbol: "plus.forwardslash.minus", tile: 0x30B94D, section: "workspace", header: "Workspace", order: 20,
             keywords: ["review", "changes", "diff", "git"]),
        // [tasks] The shared task list (docs/tasks.md): first in Workspace.
        Page(id: "tasks", title: "Tasks", symbol: "checklist", tile: 0xFF9F0A, section: "workspace", header: "Workspace", order: 5,
             keywords: ["tasks", "to do", "todo", "reminders", "checklist", "list"]),
        Page(id: "terminal", title: "Terminal", symbol: "apple.terminal.fill", tile: 0x48484A, section: "workspace", header: "Workspace",
             order: 30, keywords: ["terminal", "shell", "command line", "console", "ssh", "bash", "zsh"]),   // [terminal]
        Page(id: "command-center", title: CommandCenterNames.page, symbol: "gauge.with.dots.needle.67percent", tile: 0x636366,
             section: "insights", header: "Insights", order: 10, keywords: ["command center", "system", "status", "maintenance", "logs", "doctor"]),
        // [status-page] Its Usage tab, a row of its own under it (owner 2026-11-03: one home per page).
        Page(id: "usage", title: CommandCenterNames.usage, symbol: "chart.bar.fill", tile: 0x0A84FF, section: "insights", header: "Insights",
             order: 15, keywords: ["usage", "tokens", "cost", "spend", "analytics"]),
        Page(id: "spawn-tree", title: "Spawn Tree", symbol: "point.3.connected.trianglepath.dotted", tile: 0x00A2B8,
             section: "insights", header: "Insights", order: 20, keywords: ["subagents", "agents", "helpers", "delegation"]),
        // [mac] Mac polish #64: a star on the Mac, where its place is a sidebar Tool (sparkles there is Skills and making
        // tiles); the iPhone's More tile keeps its sparkles.
        Page(id: "star-map", title: "Star Map", symbol: DeviceWord.isMac ? "star" : "sparkles", tile: 0x8E5CD9, section: "insights",
             header: "Insights", order: 30, keywords: ["memory", "graph", "skills", "learning"]),
        Page(id: "webhooks", title: "Webhooks", symbol: "arrow.triangle.turn.up.right.diamond.fill", tile: 0xE5446D,
             section: "integrations", header: "Integrations", order: 110, keywords: ["webhooks", "hooks", "triggers"]),
        Page(id: "import-sessions", title: "Import Sessions", symbol: "square.and.arrow.down.on.square", tile: 0xA2845E,
             section: "integrations", header: "Integrations", order: 120, keywords: ["import", "claude", "codex", "conversation", "sessions"]),
    ]

    /// A More page's search words (More search), by its row id.
    static func keywords(for id: String) -> [String] { pages.first { $0.id == id }?.keywords ?? [] }

    /// Set by each page's own file (`MorePages.installProfiles()` …): builds the page pushed on More's stack.
    static var factories: [String: (Context) -> UIViewController?] = [:]
    private(set) static var context: Context?
    private static var installed = false
    private static var probeTask: Task<Void, Never>?

    /// Once at launch (M2Wiring): every page registers its factory, then the rows are appended to More's sections.
    static func install() {
        guard !installed else { return }
        installed = true
        // Each page's install, one per line (kept apart so separate branches merge cleanly).
        installProfiles()   // [profiles]

        installFilesReview()

        installMessaging()   // [messaging]

        installWebhooks()   // [webhooks]

        installImportSessions()

        installCommandCenter()   // [command-center]

        installUsage()   // [status-page]

        installSpawnTree()   // [spawn-tree]

        installStarMap()   // [star-map]

        installTerminal()   // [terminal]

        installTasks()   // [tasks]

        for page in pages {
            PagesTabs.appendMoreRows(key: "morepages." + page.id, section: page.section, header: page.header, order: page.order) {
                row(page).map { [$0] } ?? []
            }
        }
    }

    /// The row for `page`, nil while it has no factory, no gateway, or its route is missing on this gateway.
    /// [mac-audit] Owner 2026-11-02 (#21): on the Mac a missing page's row stays, dimmed, with "Update Hermes" at its
    /// end, so a Mac's source list doesn't change shape between gateways and says why the page isn't there. It still
    /// opens the page, which explains. The iPhone leaves it out (D-M16).
    static func row(_ page: Page) -> MoreRow? {
        guard let context, let factory = factories[page.id] else { return nil }
        if page.id == "tasks", TasksHub.isOff(context.account) { return nil }   // [tasks] Settings › Tasks is off
        let missing = MoreAvailability.unavailable(context.account).contains(page.id)
        if missing && !DeviceWord.isMac { return nil }
        var row = MoreRow(id: page.id, title: page.title, symbol: page.symbol, image: nil, tile: color(page.tile)) {
            guard let context = MorePages.context else { return nil }
            let controller = factory(context)
            controller?.navigationItem.largeTitleDisplayMode = .never
            return controller
        }
        if missing {
            row.dimmed = true
            row.status = { MoreRowStatus(text: "Update Hermes", isIssue: false, spoken: MoreWire.notAvailableBody(page.title)) }
            return row
        }
        // [update-flow] Status & Maintenance says "Update" when the gateway in use has one (and "Updating…" while it runs).
        if page.id == "command-center" {
            let account = context.account.id
            row.status = { HermesUpdateCenter.shared.moreStatus(account) }
        }
        // UX study #118: a failing messaging app shows on the row ("1 Issue" in red), not only inside the page.
        if page.id == "messaging" {
            let account = context.account.id
            row.status = {
                guard let words = messagingIssues[account] else { return nil }
                return MoreRowStatus(text: words.text, isIssue: true, spoken: words.spoken)
            }
        }
        return row
    }

    /// The default bot's failing messaging apps, per account, from the last read of its platforms (the row's probe or
    /// the Messaging page).
    private static var messagingIssues: [String: MessagingIssues.RowWords] = [:]

    static func noteMessaging(_ platforms: [MessagingPlatform], account: GatewayAccount) {
        let words = MessagingIssues.rowWords(platforms)
        guard messagingIssues[account.id] != words else { return }
        messagingIssues[account.id] = words
        PagesTabs.moreRowsChanged()
    }

    static func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// The pages listed right now, in More's order (More search's Go To).
    static var shown: [Page] { pages.filter { row($0) != nil } }

    // MARK: Context

    /// PagesTabs built this account's tabs.
    static func attach(_ tabs: PagesTabs, services: any AppServices, client: any GatewayClient, account: GatewayAccount,
                       makeChat: @escaping (any ChatSessionModel) -> UIViewController) {
        guard let pages = services as? PagesServices else { return }
        context = Context(services: services, pages: pages, client: client, account: account, makeChat: makeChat)
        PagesTabs.moreRowsChanged()
        // [update-flow] The gateway's version and whether an update is out (More's row, Settings' rows), read once.
        if !pages.readOnlyGateway { HermesUpdateCenter.shared.refresh(account) }
        probe(onlyHidden: false)
        PluginPagesMore.refresh()   // [plugin-pages-more]
    }

    // MARK: Availability (D-M16)

    /// A page's first read failed: when the gateway has no such route the row goes (and the page says "older Hermes").
    /// Returns true when the error means the route is missing.
    @discardableResult
    static func noteRead(_ row: String, error: Error?) -> Bool {
        guard let context else { return false }
        let missing = error.map(MoreWire.isNotAvailable) ?? false   // [mac-audit] #21: the page's own "Not Available" too
        if error == nil || missing, MoreAvailability.set(row, available: !missing, account: context.account) {
            AppLog.trace("pages", "more row \(row) now \(missing ? "hidden (route missing)" : "shown")")
            PagesTabs.moreRowsChanged()
        }
        return missing
    }

    /// Cheap first reads, one per row that has one. Star Map's graph is large, so it is asked only while its row is hidden.
    private static let probes: [String: @Sendable (any GatewayClient) async throws -> Void] = [
        "messaging": { try await present($0, "/api/messaging/platforms") },
        "webhooks": { try await present($0, "/api/webhooks") },
        "files": { try await present($0, "/api/fs/default-cwd") },
        "review": { try await present($0, "/api/fs/default-cwd") },
        "spawn-tree": { _ = try await $0.call("delegation.status", .object([:]), timeout: .seconds(15)) },
        "import-sessions": { _ = try await $0.call("session.foreign.list", .object(["limit": 1]), timeout: .seconds(60)) },
        "star-map": { try await present($0, "/api/learning/graph") },
    ]

    /// A probe's GET: an empty answer (`{}`, as a Hermes without the route may give) is the page not being there, as the
    /// page itself reads it ([mac-audit] owner 2026-11-02, #21).
    nonisolated private static func present(_ client: any GatewayClient, _ path: String) async throws {
        let data = try await client.rest("GET", path, query: [], body: nil)
        if MoreWire.isEmptyAnswer(data) { throw PagesMessageError(MoreWire.olderHermes) }
    }
    private static let probedOnlyWhenHidden: Set<String> = ["star-map"]

    static func gatewayReady() {
        probe(onlyHidden: true)
        PluginPagesMore.refresh()   // [plugin-pages-more]
    }

    private static func probe(onlyHidden: Bool) {
        guard let context else { return }
        let hidden = MoreAvailability.unavailable(context.account)
        let asked = probes.filter { id, _ in
            factories[id] != nil && (hidden.contains(id) || (!onlyHidden && !probedOnlyWhenHidden.contains(id)))
        }
        guard !asked.isEmpty else { return }
        let client = context.client, account = context.account
        probeTask?.cancel()
        probeTask = Task {
            for (id, read) in asked.sorted(by: { $0.key < $1.key }) {
                var missing: Bool?
                do {
                    if id == "messaging" {
                        // The same read, kept: the default bot's failing apps go on the row.
                        let rows = try await MessagingAPI(client: client).platforms(profile: nil)
                        if !Task.isCancelled, MorePages.context?.account.id == account.id { noteMessaging(rows, account: account) }
                    } else {
                        try await read(client)
                    }
                    missing = false
                } catch { if MoreWire.isNotAvailable(error) { missing = true } }   // [mac-audit] #21: an empty answer too
                guard !Task.isCancelled, MorePages.context?.account.id == account.id, let missing else { continue }
                if MoreAvailability.set(id, available: !missing, account: account) { PagesTabs.moreRowsChanged() }
            }
        }
    }

    // MARK: Opening a chat over More

    /// Pushes `session`'s chat on `navigation` (More's stack), as Artifacts' Show in Chat does.
    static func openChat(_ session: SessionSummary, on navigation: UINavigationController?) {
        guard let context, let navigation else { return }
        Haptics.play(.soft)
        let chat = context.makeChat(context.pages.chat(for: session))
        chat.hidesBottomBarWhenPushed = true
        chat.navigationItem.largeTitleDisplayMode = .never
        ChatViewController.push(chat, on: navigation) {}
    }

    static func openChat(sessionId: String, profile: String?, title: String, on navigation: UINavigationController?) {
        openChat(SessionSummary(id: sessionId, profile: profile ?? "default", title: title, preview: nil, lastActive: nil,
                                source: nil, unread: false, isRunning: false), on: navigation)
    }
}
