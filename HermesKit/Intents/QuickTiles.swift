// [quick-actions] The Favorites page (was Quick Actions; docs/spec/3x-morepages.md §25; docs/spec/3x-intents.md DECISION I22).
// Pure: what a tile is (actions, live native widgets, Dashboard tiles, deeper shortcuts, routines, sections), multi-page
// spaces (`FavoritePage`), responsive 2D Bento layout (`QuickTileLayout`), presets, storage (`hqn.quickActions`), missing
// checks, and routes (`QuickTileRoute`).

import CoreGraphics
import Foundation

/// What a tile does or shows. Stored by its raw value; a kind this build doesn't know is kept and drawn switched off.
nonisolated enum QuickTileKind: String, CaseIterable, Sendable {
    // Original 10 kinds (raw values preserved for stored lists & shortcuts)
    case newChat = "new-chat"
    case memo
    case talk
    case send
    case openChat = "open-chat"
    case addTask = "add-task"
    case runJob = "run-job"
    case page
    case search
    /// [favorites-live-tiles] A Dashboard tile itself, drawn as the Dashboard draws it (its picture, or its page live).
    case dashboardTile = "dashboard-tile"

    // Live native cards
    /// Live Tasks card (Today, Upcoming, Inbox, Bots, or a custom list) with inline check-off.
    case tasks
    /// Live Goal progress card with ring, pace, team faces, and inline next-task check-off.
    case goal
    /// Dynamic "Needs You / Active Now" attention card aggregating waiting bots, tasks, subagents, and jobs.
    case needsYou = "needs-you"
    /// Live Bot status card with head avatar, working/waiting status, unread badge, and quick actions.
    case botCard = "bot-card"
    /// Live Group Chat card with group avatar, status, and unread badge.
    case groupChat = "group-chat"
    /// Pinned specific chat/session card with live status and unread indicator.
    case chatSession = "chat-session"
    /// Live Job status card (one job with Run button, or Upcoming Jobs overview when `job == nil`).
    case jobCard = "job-card"
    /// Live Kanban board or column card with counts and top items.
    case kanban
    /// Live Gateway Status & Maintenance glance card.
    case gatewayStatus = "gateway-status"
    /// Live Usage tokens/cost + daily sparkline card.
    case usage
    /// Live Approvals & Clarify Questions card with inline Allow / Deny & answer taps.
    case approvals
    /// Live Active Runs & Subagents (`SpawnTree`) ticker card.
    case activeRuns = "active-runs"
    /// Live Inline Ask card: type a prompt right on Favorites and stream the reply in place.
    case inlineAsk = "inline-ask"
    /// Live Watch Browser & Bot Screen peek card.
    case livePeek = "live-peek"

    // Deeper destinations, smart actions, routines & organization
    /// Run a saved prompt from PromptLibrary against a bot.
    case prompt
    /// Run a favorite slash command against a bot.
    case slashCommand = "slash-command"
    /// Open a lightweight Quick Ask input/dictation sheet right over Favorites.
    case quickAsk = "quick-ask"
    /// Jump straight to a specific Dashboard page.
    case dashboardPage = "dashboard-page"
    /// Open Files directly at a chosen folder path.
    case filesFolder = "files-folder"
    /// Open an external web URL / bookmark.
    case link
    /// Multi-action routine that runs several steps in one tap.
    case routine
    /// Full-width collapsible section header for organizing Favorites.
    case section

    /// Done in the background: the page stays open and says what happened.
    var staysOnPage: Bool { self == .runJob || self == .section }

    var needsBot: Bool {
        [.newChat, .memo, .talk, .send, .openChat, .botCard, .prompt, .slashCommand, .quickAsk, .inlineAsk].contains(self)
    }

    /// [favorites-live-tiles] A picture, not an icon and words: Set Up has no icon grid, colour or Height, and it is
    /// never Short (3x-morepages Q16).
    var isPicture: Bool { self == .dashboardTile }

    /// Native live card rendered by `FavoriteLiveCards` (not a static icon square).
    var isLiveCard: Bool {
        [.tasks, .goal, .needsYou, .botCard, .groupChat, .chatSession, .jobCard, .kanban, .gatewayStatus, .usage,
         .approvals, .activeRuns, .inlineAsk, .livePeek].contains(self)
    }

    /// Any rich visual widget (Dashboard tile or native live card).
    var isWidget: Bool { isPicture || isLiveCard }

    /// Section divider/header row.
    var isSection: Bool { self == .section }

    /// Supports multi-row sizes (Large 2×2, Vertical 1×2, Banner, Extra Large).
    var supportsMultiRowSize: Bool { isWidget }

    /// Supports the compact 4-across Mini action strip size.
    var supportsMini: Bool { !isWidget && !isSection }

    /// Supports one-line Short action tile height.
    var supportsShort: Bool { !isWidget && !isSection }

    /// Supports custom icon + color pickers in Set Up (Dashboard tiles, live cards, and sections use their own visual design).
    var supportsCustomLook: Bool { !isWidget && !isSection }

    /// Supports toggling the bot's face avatar in place of the icon square.
    var supportsAvatarOption: Bool {
        [.newChat, .memo, .talk, .send, .openChat, .prompt, .slashCommand, .quickAsk].contains(self)
    }

    /// The name a new tile of this kind is given (the setup form's Name starts with it).
    func defaultName(bot: String?, job: String?, page: String?) -> String {
        switch self {
        case .newChat: "New Chat"
        case .memo: "Memo"
        case .talk: "Talk"
        case .send: "Message"
        case .openChat: bot.flatMap { $0.isEmpty ? nil : $0 } ?? "Open Chat"
        case .addTask: "Add Task"
        case .runJob: job.flatMap { $0.isEmpty ? nil : $0 } ?? "Run Job"
        case .page: page.flatMap { $0.isEmpty ? nil : $0 } ?? "Page"
        case .search: "Search Chats"
        case .dashboardTile: page.flatMap { $0.isEmpty ? nil : $0 } ?? "Tile"
        case .tasks: page.flatMap { $0.isEmpty ? nil : $0 } ?? "Today"
        case .goal: page.flatMap { $0.isEmpty ? nil : $0 } ?? "Goal"
        case .needsYou: "Needs You"
        case .botCard: bot.flatMap { $0.isEmpty ? nil : $0 } ?? "Bot"
        case .groupChat: page.flatMap { $0.isEmpty ? nil : $0 } ?? "Group Chat"
        case .chatSession: page.flatMap { $0.isEmpty ? nil : $0 } ?? "Chat"
        case .jobCard: job.flatMap { $0.isEmpty ? nil : $0 } ?? "Upcoming Jobs"
        case .kanban: page.flatMap { $0.isEmpty ? nil : $0 } ?? "Kanban"
        case .gatewayStatus: "Gateway"
        case .usage: "Usage"
        case .approvals: "Approvals"
        case .activeRuns: "Active Now"
        case .inlineAsk: bot.flatMap { $0.isEmpty ? nil : "Ask \($0)" } ?? "Inline Ask"
        case .livePeek: "Browser & Screen"
        case .prompt: page.flatMap { $0.isEmpty ? nil : $0 } ?? "Saved Prompt"
        case .slashCommand: page.flatMap { $0.isEmpty ? nil : $0 } ?? "Command"
        case .quickAsk: bot.flatMap { $0.isEmpty ? nil : "Ask \($0)" } ?? "Quick Ask"
        case .dashboardPage: page.flatMap { $0.isEmpty ? nil : $0 } ?? "Dashboard Page"
        case .filesFolder: page.flatMap { $0.isEmpty ? nil : $0 } ?? "Folder"
        case .link: page.flatMap { $0.isEmpty ? nil : $0 } ?? "Web Link"
        case .routine: "Routine"
        case .section: "Section"
        }
    }

    /// The icon and colour a new tile of this kind starts with.
    var defaultLook: (symbol: String, color: QuickTileColor) {
        switch self {
        case .newChat: ("square.and.pencil", .accent)
        case .memo: ("mic.fill", .red)
        case .talk: ("waveform", .green)
        case .send: ("paperplane.fill", .indigo)
        case .openChat: ("bubble.left.fill", .green)
        case .addTask: ("checklist", .teal)
        case .runJob: ("bolt.fill", .orange)
        case .page: ("square.grid.2x2.fill", .gray)
        case .search: ("magnifyingglass", .gray)
        case .dashboardTile: ("chart.xyaxis.line", .accent)
        case .tasks: ("checklist", .orange)
        case .goal: ("target", .green)
        case .needsYou: ("bell.badge.fill", .orange)
        case .botCard: ("person.crop.circle.fill", .accent)
        case .groupChat: ("person.2.fill", .teal)
        case .chatSession: ("bubble.left.and.bubble.right.fill", .indigo)
        case .jobCard: ("calendar.badge.clock", .orange)
        case .kanban: ("rectangle.split.3x1.fill", .yellow)
        case .gatewayStatus: ("gauge.with.dots.needle.67percent", .gray)
        case .usage: ("chart.bar.fill", .accent)
        case .approvals: ("checkmark.shield.fill", .orange)
        case .activeRuns: ("bolt.horizontal.circle.fill", .accent)
        case .inlineAsk: ("text.bubble.fill", .indigo)
        case .livePeek: ("display", .teal)
        case .prompt: ("text.quote", .indigo)
        case .slashCommand: ("command", .pink)
        case .quickAsk: ("sparkles", .accent)
        case .dashboardPage: ("rectangle.3.group.fill", .orange)
        case .filesFolder: ("folder.fill", .accent)
        case .link: ("globe", .teal)
        case .routine: ("wand.and.stars", .pink)
        case .section: ("line.3.horizontal", .gray)
        }
    }
}

/// The tile colours (drawn from the theme where it has one: `accent` is the theme's tint).
nonisolated enum QuickTileColor: String, CaseIterable, Sendable {
    case accent, red, orange, yellow, green, teal, indigo, pink, gray
}

/// Grid footprint of a tile. `nil` on `QuickTile.size` resolves from `wide` (`false` → `.small`, `true` → `.wide`).
nonisolated enum QuickTileSize: String, Codable, CaseIterable, Sendable {
    /// Half-column compact action button (packs 4 across on phone, up to 8 on Mac). Action/page tiles only.
    case mini
    /// 1×1 standard tile or square widget.
    case small
    /// 2×1 horizontal tile or wide widget.
    case wide
    /// 1×2 vertical card (widgets & live cards).
    case tallCard = "tall-card"
    /// 2×2 big square card (widgets & live cards).
    case large
    /// Full-width × 1 strip (wide screens; same as `.wide` on 2-column phones).
    case banner
    /// Full-width × 2 hero card (wide screens; same as `.large` on 2-column phones).
    case extraLarge = "extra-large"

    /// Human title for menus and pickers (note: avoids "Tall" for widgets so Q16's "no Tall/Short for pictures" stays distinct).
    var title: String {
        switch self {
        case .mini: "Mini"
        case .small: "Small"
        case .wide: "Wide"
        case .tallCard: "Vertical"
        case .large: "Large"
        case .banner: "Banner"
        case .extraLarge: "Extra Large"
        }
    }

    var symbol: String {
        switch self {
        case .mini: "square.grid.2x2"
        case .small: "square"
        case .wide: "rectangle"
        case .tallCard: "rectangle.portrait"
        case .large: "square.grid.2x2.fill"
        case .banner: "rectangle.split.1x2"
        case .extraLarge: "rectangle.inset.filled"
        }
    }

    var isWideSpan: Bool {
        switch self {
        case .wide, .large, .banner, .extraLarge: true
        case .mini, .small, .tallCard: false
        }
    }

    var rowSpan: Int {
        switch self {
        case .tallCard, .large, .extraLarge: 2
        case .mini, .small, .wide, .banner: 1
        }
    }

    func colSpan(in columns: Int) -> Int {
        switch self {
        case .mini, .small, .tallCard: 1
        case .wide, .large: min(2, max(1, columns))
        case .banner, .extraLarge: max(1, columns)
        }
    }

    /// Sizes offered in Set Up / menus for a tile kind (on `wideScreen` >= 3 columns, Banner & Extra Large also appear).
    static func choices(for kind: QuickTileKind, wideScreen: Bool = false) -> [QuickTileSize] {
        if kind.isSection { return [.banner] }
        if kind.isWidget {
            return wideScreen ? [.small, .wide, .tallCard, .large, .banner, .extraLarge] : [.small, .wide, .tallCard, .large]
        }
        return wideScreen ? [.mini, .small, .wide, .banner] : [.mini, .small, .wide]
    }
}

/// One step inside a `.routine` multi-action tile.
nonisolated struct QuickRoutineStep: Codable, Equatable, Identifiable, Sendable {
    enum StepKind: String, CaseIterable, Codable, Sendable {
        case runJob = "run-job"
        case send
        case slashCommand = "slash-command"
        case openPage = "open-page"
        case openChat = "open-chat"
        case openTile = "open-tile"

        var title: String {
            switch self {
            case .runJob: "Run Job"
            case .send: "Send Message"
            case .slashCommand: "Run Command"
            case .openPage: "Open Page"
            case .openChat: "Open Bot Chat"
            case .openTile: "Open Dashboard Tile"
            }
        }

        var symbol: String {
            switch self {
            case .runJob: "bolt.fill"
            case .send: "paperplane.fill"
            case .slashCommand: "command"
            case .openPage: "square.grid.2x2.fill"
            case .openChat: "bubble.left.fill"
            case .openTile: "chart.xyaxis.line"
            }
        }

        var isBackground: Bool {
            self == .runJob || self == .send
        }
    }

    var id: String
    var kind: String
    var bot: String? = nil
    var botName: String? = nil
    var message: String? = nil
    var command: String? = nil
    var job: String? = nil
    var jobName: String? = nil
    var page: String? = nil
    var pageName: String? = nil
    var pin: String? = nil
    var pinName: String? = nil

    var knownKind: StepKind? { StepKind(rawValue: kind) }

    init(id: String = UUID().uuidString, kind: StepKind, bot: String? = nil, botName: String? = nil,
         message: String? = nil, command: String? = nil, job: String? = nil, jobName: String? = nil,
         page: String? = nil, pageName: String? = nil, pin: String? = nil, pinName: String? = nil) {
        self.id = id
        self.kind = kind.rawValue
        self.bot = bot
        self.botName = botName
        self.message = message
        self.command = command
        self.job = job
        self.jobName = jobName
        self.page = page
        self.pageName = pageName
        self.pin = pin
        self.pinName = pinName
    }

    var summary: String {
        switch knownKind {
        case .runJob: return "Run \(jobName ?? job ?? "job")"
        case .send:
            let who = botName ?? bot ?? "bot"
            let words = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty ? "Send to \(who)" : "Send “\(String(words.prefix(24)))” to \(who)"
        case .slashCommand: return "\(command ?? "/command") to \(botName ?? bot ?? "bot")"
        case .openPage: return "Open \(pageName ?? page ?? "page")"
        case .openChat: return "Open \(botName ?? bot ?? "chat")"
        case .openTile: return "Open \(pinName ?? "tile")"
        case nil: return "Unknown step"
        }
    }
}

/// One Favorites page / space (like `DashboardPage` on Tiles). `main` is always present and first.
nonisolated struct FavoritePage: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var symbol: String? = nil

    static let mainId = "main"
    static let main = FavoritePage(id: mainId, name: "Home")

    static let symbolChoices: [(symbol: String, label: String)] = [
        ("star.fill", "Favorites"),
        ("house.fill", "Home"),
        ("briefcase.fill", "Work"),
        ("sun.max.fill", "Daily"),
        ("bolt.fill", "Ops"),
        ("chart.bar.fill", "Metrics"),
        ("bubble.left.and.bubble.right.fill", "Chats"),
        ("checklist", "Tasks"),
        ("chevron.left.forwardslash.chevron.right", "Code"),
        ("heart.fill", "Personal"),
        ("sparkles", "AI"),
        ("globe", "Web"),
    ]
}

/// One tile. Fields a kind doesn't use stay nil.
nonisolated struct QuickTile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    /// `QuickTileKind`'s raw value (kept as written: a newer build's kind survives an older build's edits).
    var kind: String
    var name: String
    var symbol: String
    /// `QuickTileColor`'s raw value.
    var color: String
    var wide = false
    /// [quick-actions] A Short tile is one line high: its icon beside the name and subtitle (3x-morepages Q13).
    var short = false
    /// Extended footprint (`.mini`, `.tallCard`, `.large`, `.banner`, `.extraLarge`). Nil falls back to `wide`.
    var size: QuickTileSize? = nil
    /// Which `FavoritePage` this tile belongs to (nil = `FavoritePage.mainId`).
    var pageId: String? = nil
    /// Optional gateway account id scope (nil = shown on all gateways).
    var gatewayId: String? = nil

    /// The bot's profile, and its name when the tile was set up (said when the bot isn't on this gateway).
    var bot: String? = nil
    var botName: String? = nil
    /// New Chat's project: its key (folder) and name.
    var project: String? = nil
    var projectName: String? = nil
    /// New Chat's first message, Send a Message's words, or Saved Prompt body.
    var message: String? = nil
    /// New Chat: send the first message (on) or leave it in the box. Send / Prompt / Quick Ask: open the chat (on) or background (off).
    var flag: Bool? = nil
    /// Run Job / Job Card: job key (`<owner>|<id>`) and name. Nil on `.jobCard` = Upcoming Jobs overview.
    var job: String? = nil
    var jobName: String? = nil
    /// A page's More row id, and its title.
    var page: String? = nil
    var pageName: String? = nil
    /// [favorites-live-tiles] A Dashboard tile's pin (`ArtifactPin.id`), and its name when it was added.
    var pin: String? = nil
    var pinName: String? = nil

    // Rich card & deep-target fields (omitted from JSON when nil)
    /// `.tasks` view key ("today", "upcoming", "inbox", "bots", "list:<id>") and saved display name.
    var taskView: String? = nil
    var taskViewName: String? = nil
    /// `.goal` id and saved name.
    var goalId: String? = nil
    var goalName: String? = nil
    /// `.groupChat` room key and saved name.
    var roomKey: String? = nil
    var roomName: String? = nil
    /// `.chatSession` stored session key/id and saved title.
    var sessionId: String? = nil
    var sessionTitle: String? = nil
    /// `.kanban` board slug, board name, and optional column status filter.
    var boardSlug: String? = nil
    var boardName: String? = nil
    var columnStatus: String? = nil
    /// `.prompt` linked `SavedPrompt.id` string (message holds fallback copy if edited/deleted).
    var promptId: String? = nil
    /// `.slashCommand` command string (e.g. "/usage").
    var command: String? = nil
    /// `.link` external URL string.
    var url: String? = nil
    /// `.filesFolder` folder path and display name.
    var folderPath: String? = nil
    var folderName: String? = nil
    /// `.dashboardPage` page id and name.
    var dashboardPageId: String? = nil
    var dashboardPageName: String? = nil
    /// `.usage` lookback days (7, 30, 90).
    var days: Int? = nil
    /// `.routine` ordered steps.
    var steps: [QuickRoutineStep]? = nil
    /// `.section` collapsed state (omitted when false/nil).
    var collapsed: Bool? = nil
    /// Bot action tiles: draw the bot's face avatar instead of the icon square.
    var showAvatar: Bool? = nil

    /// A stored entry this build could not read at all: kept, as written, and drawn switched off.
    var unreadable: JSONValue? = nil
    /// What a newer build stored on a tile that this build has no field for: written back as it was.
    var extra: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, kind, name, symbol, color, wide, short, size, pageId, gatewayId
        case bot, botName, project, projectName, message, flag, job, jobName, page, pageName
        case pin, pinName
        case taskView, taskViewName, goalId, goalName, roomKey, roomName, sessionId, sessionTitle
        case boardSlug, boardName, columnStatus, promptId, command, url, folderPath, folderName
        case dashboardPageId, dashboardPageName, days, steps, collapsed, showAvatar
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    var known: QuickTileKind? { unreadable == nil ? QuickTileKind(rawValue: kind) : nil }
    var tint: QuickTileColor { QuickTileColor(rawValue: color) ?? .gray }
    var resolvedPageId: String {
        guard let pageId, !pageId.isEmpty else { return FavoritePage.mainId }
        return pageId
    }

    /// Effective grid footprint, reconciling `size`, `wide`, and kind capabilities.
    var effectiveSize: QuickTileSize {
        if let known, known.isSection { return .banner }
        if let size {
            if let known {
                if size == .mini && !known.supportsMini { return .small }
                if !known.supportsMultiRowSize && (size == .large || size == .tallCard || size == .extraLarge) { return .wide }
            }
            return size
        }
        return wide ? .wide : .small
    }

    init(id: String = UUID().uuidString, kind: QuickTileKind, name: String? = nil, symbol: String? = nil,
         color: QuickTileColor? = nil, wide: Bool = false, size: QuickTileSize? = nil) {
        self.id = id
        self.kind = kind.rawValue
        self.name = name ?? kind.defaultName(bot: nil, job: nil, page: nil)
        self.symbol = symbol ?? kind.defaultLook.symbol
        self.color = (color ?? kind.defaultLook.color).rawValue
        if let size {
            self.size = (size == .small || size == .wide) ? nil : size
            self.wide = size.isWideSpan
        } else {
            self.wide = wide
        }
    }

    init(unreadable raw: JSONValue) {
        id = raw["id"]?.string ?? Self.stableID(raw)
        kind = raw["kind"]?.string ?? "unknown"
        name = raw["name"]?.string ?? "Unknown Action"
        symbol = "questionmark.square.dashed"
        color = QuickTileColor.gray.rawValue
        wide = raw["wide"]?.bool ?? false
        short = raw["short"]?.bool ?? false
        unreadable = raw
    }

    private static func stableID(_ raw: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (try? encoder.encode(raw)) ?? Data() {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "unreadable-" + String(hash, radix: 16)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "square.grid.2x2.fill"
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? QuickTileColor.gray.rawValue
        wide = try c.decodeIfPresent(Bool.self, forKey: .wide) ?? false
        short = try c.decodeIfPresent(Bool.self, forKey: .short) ?? false
        size = try c.decodeIfPresent(QuickTileSize.self, forKey: .size)
        pageId = try c.decodeIfPresent(String.self, forKey: .pageId)
        gatewayId = try c.decodeIfPresent(String.self, forKey: .gatewayId)
        bot = try c.decodeIfPresent(String.self, forKey: .bot)
        botName = try c.decodeIfPresent(String.self, forKey: .botName)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        flag = try c.decodeIfPresent(Bool.self, forKey: .flag)
        job = try c.decodeIfPresent(String.self, forKey: .job)
        jobName = try c.decodeIfPresent(String.self, forKey: .jobName)
        page = try c.decodeIfPresent(String.self, forKey: .page)
        pageName = try c.decodeIfPresent(String.self, forKey: .pageName)
        pin = try c.decodeIfPresent(String.self, forKey: .pin)
        pinName = try c.decodeIfPresent(String.self, forKey: .pinName)
        taskView = try c.decodeIfPresent(String.self, forKey: .taskView)
        taskViewName = try c.decodeIfPresent(String.self, forKey: .taskViewName)
        goalId = try c.decodeIfPresent(String.self, forKey: .goalId)
        goalName = try c.decodeIfPresent(String.self, forKey: .goalName)
        roomKey = try c.decodeIfPresent(String.self, forKey: .roomKey)
        roomName = try c.decodeIfPresent(String.self, forKey: .roomName)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        sessionTitle = try c.decodeIfPresent(String.self, forKey: .sessionTitle)
        boardSlug = try c.decodeIfPresent(String.self, forKey: .boardSlug)
        boardName = try c.decodeIfPresent(String.self, forKey: .boardName)
        columnStatus = try c.decodeIfPresent(String.self, forKey: .columnStatus)
        promptId = try c.decodeIfPresent(String.self, forKey: .promptId)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName)
        dashboardPageId = try c.decodeIfPresent(String.self, forKey: .dashboardPageId)
        dashboardPageName = try c.decodeIfPresent(String.self, forKey: .dashboardPageName)
        days = try c.decodeIfPresent(Int.self, forKey: .days)
        steps = try c.decodeIfPresent([QuickRoutineStep].self, forKey: .steps)
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed)
        showAvatar = try c.decodeIfPresent(Bool.self, forKey: .showAvatar)
        let keys = Set(CodingKeys.allCases.map(\.stringValue))
        if let all = try? JSONValue(from: decoder).object { extra = all.filter { !keys.contains($0.key) } }
    }

    func encode(to encoder: Encoder) throws {
        if let unreadable { return try unreadable.encode(to: encoder) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(color, forKey: .color)
        if wide { try c.encode(wide, forKey: .wide) }
        if short { try c.encode(short, forKey: .short) }
        if let size, !(size == .small && !wide), !(size == .wide && wide) {
            try c.encode(size, forKey: .size)
        }
        if let pageId, !pageId.isEmpty, pageId != FavoritePage.mainId { try c.encode(pageId, forKey: .pageId) }
        try c.encodeIfPresent(gatewayId?.nilIfEmpty, forKey: .gatewayId)
        try c.encodeIfPresent(bot, forKey: .bot)
        try c.encodeIfPresent(botName, forKey: .botName)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encodeIfPresent(projectName, forKey: .projectName)
        try c.encodeIfPresent(message, forKey: .message)
        try c.encodeIfPresent(flag, forKey: .flag)
        try c.encodeIfPresent(job, forKey: .job)
        try c.encodeIfPresent(jobName, forKey: .jobName)
        try c.encodeIfPresent(page, forKey: .page)
        try c.encodeIfPresent(pageName, forKey: .pageName)
        try c.encodeIfPresent(pin, forKey: .pin)
        try c.encodeIfPresent(pinName, forKey: .pinName)
        try c.encodeIfPresent(taskView, forKey: .taskView)
        try c.encodeIfPresent(taskViewName, forKey: .taskViewName)
        try c.encodeIfPresent(goalId, forKey: .goalId)
        try c.encodeIfPresent(goalName, forKey: .goalName)
        try c.encodeIfPresent(roomKey, forKey: .roomKey)
        try c.encodeIfPresent(roomName, forKey: .roomName)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(sessionTitle, forKey: .sessionTitle)
        try c.encodeIfPresent(boardSlug, forKey: .boardSlug)
        try c.encodeIfPresent(boardName, forKey: .boardName)
        try c.encodeIfPresent(columnStatus, forKey: .columnStatus)
        try c.encodeIfPresent(promptId, forKey: .promptId)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(folderPath, forKey: .folderPath)
        try c.encodeIfPresent(folderName, forKey: .folderName)
        try c.encodeIfPresent(dashboardPageId, forKey: .dashboardPageId)
        try c.encodeIfPresent(dashboardPageName, forKey: .dashboardPageName)
        try c.encodeIfPresent(days, forKey: .days)
        if let steps, !steps.isEmpty { try c.encode(steps, forKey: .steps) }
        if collapsed == true { try c.encode(true, forKey: .collapsed) }
        if showAvatar == true { try c.encode(true, forKey: .showAvatar) }
        guard !extra.isEmpty else { return }
        var more = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in extra { try more.encode(value, forKey: AnyKey(stringValue: key)) }
    }

    /// [favorites-live-tiles] A Dashboard tile's name: its own, or the pin's name now while it was never typed over.
    func shownName(currentPinName current: String?) -> String {
        guard known == .dashboardTile, let current, !current.isEmpty, name == pinName || name.isEmpty else { return name }
        return current
    }

    /// What the tile does, in a few words under its name ("to otto", "in Site", "run job").
    func subtitle(botName current: String?) -> String {
        let who = current ?? botName ?? bot ?? ""
        switch known {
        case .memo: return "to \(who)"
        case .talk: return "with \(who)"
        case .newChat:
            if let project = projectName ?? project, !project.isEmpty { return "in \(project)" }
            return "with \(who)"
        case .send: return flag == true ? "with \(who)" : "asks \(who)"
        case .openChat: return "chat with \(who)"
        case .addTask: return bot == nil ? "for me" : "for \(who)"
        case .runJob: return "run job"
        case .page: return "page"
        case .search: return "all chats"
        case .dashboardTile: return "tile"
        case .tasks: return taskViewName ?? "tasks"
        case .goal: return "goal"
        case .needsYou: return "attention"
        case .botCard: return who.isEmpty ? "bot" : who
        case .groupChat: return "group chat"
        case .chatSession: return who.isEmpty ? "chat" : "with \(who)"
        case .jobCard: return (job ?? "").isEmpty ? "upcoming jobs" : "job"
        case .kanban:
            if let col = columnStatus, !col.isEmpty { return KanbanModel.label(col) }
            return boardName ?? "board"
        case .gatewayStatus: return "status"
        case .usage: return "\(days ?? 7) days"
        case .approvals: return "approvals"
        case .activeRuns: return "running"
        case .inlineAsk: return who.isEmpty ? "ask inline" : "ask \(who)"
        case .livePeek: return "live view"
        case .prompt: return flag == true ? "with \(who)" : "asks \(who)"
        case .slashCommand:
            let cmd = command ?? "/command"
            return who.isEmpty ? cmd : "\(cmd) · \(who)"
        case .quickAsk: return who.isEmpty ? "quick ask" : "ask \(who)"
        case .dashboardPage: return "dashboard"
        case .filesFolder: return folderName ?? "files"
        case .link:
            if let raw = url, let host = URL(string: raw)?.host, !host.isEmpty {
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
            return "link"
        case .routine:
            let count = steps?.count ?? 0
            return count == 1 ? "1 step" : "\(count) steps"
        case .section: return "section"
        case nil: return "needs a newer app"
        }
    }
}

/// What is around when a tile is drawn or tapped: the CURRENT gateway's roster, jobs, pages, pins, groups, goals, etc.
/// nil: not known yet, which is never "missing".
nonisolated struct QuickTileWorld: Sendable {
    /// profile → shown name.
    var bots: [String: String]?
    var jobs: Set<String>?
    var pages: [String: String]?
    /// [favorites-live-tiles] The pins on this account's Dashboard: id → name.
    var pins: [String: String]?
    /// Group chat rooms: roomKey → name.
    var rooms: [String: String]?
    /// Loaded sessions: key/sessionId → title.
    var sessions: [String: String]?
    /// Goals: id → title.
    var goals: [String: String]?
    /// Custom task lists: id → name.
    var taskLists: [String: String]?
    /// Dashboard pages: id → name.
    var dashboardPages: [String: String]?
    /// Kanban boards: slug → title.
    var boards: [String: String]?
    /// Whether Tasks is enabled on this gateway (nil = unknown).
    var tasksEnabled: Bool?
    /// Current signed-in gateway account id (nil = unknown / signed out).
    var currentGatewayId: String?

    init(bots: [String: String]? = nil, jobs: Set<String>? = nil, pages: [String: String]? = nil,
         pins: [String: String]? = nil, rooms: [String: String]? = nil, sessions: [String: String]? = nil,
         goals: [String: String]? = nil, taskLists: [String: String]? = nil, dashboardPages: [String: String]? = nil,
         boards: [String: String]? = nil, tasksEnabled: Bool? = nil, currentGatewayId: String? = nil) {
        self.bots = bots
        self.jobs = jobs
        self.pages = pages
        self.pins = pins
        self.rooms = rooms
        self.sessions = sessions
        self.goals = goals
        self.taskLists = taskLists
        self.dashboardPages = dashboardPages
        self.boards = boards
        self.tasksEnabled = tasksEnabled
        self.currentGatewayId = currentGatewayId
    }
}

/// Where a tap goes: each case is the route its Shortcuts twin or native view takes.
nonisolated enum QuickTileRoute: Equatable, Sendable {
    case newChat(NewChatLink)
    case talk(profile: String)
    case memo(profile: String)
    case openChat(profile: String)
    case sendInChat(profile: String, words: String)
    case sendInBackground(profile: String, words: String)
    case newTask(bot: String?)
    case runJob(key: String, name: String)
    case page(id: String)
    case search
    case dashboardTile(id: String)
    // Expanded routes
    case tasksView(key: String)
    case goal(id: String)
    case needsYou
    case groupChat(key: String)
    case chatSession(profile: String, sessionId: String)
    case jobDetail(key: String?)
    case kanban(board: String?, status: String?)
    case gatewayStatus
    case usage
    case approvals
    case activeRuns
    case inlineAsk(profile: String)
    case livePeek(profile: String?)
    case quickAsk(profile: String, defaultOpen: Bool)
    case slashCommand(profile: String, command: String)
    case dashboardPage(id: String)
    case filesFolder(profile: String?, path: String)
    case link(URL)
    case routine([QuickRoutineStep], name: String)
    case toggleSection(id: String)
    case unavailable(String)

    var staysOnPage: Bool {
        switch self {
        case .sendInBackground, .runJob, .unavailable, .toggleSection, .quickAsk, .inlineAsk: true
        case .routine(let steps, _):
            steps.allSatisfy { $0.knownKind?.isBackground == true }
        default: false
        }
    }

    /// The route for `tile` against what the current gateway has.
    static func make(_ tile: QuickTile, world: QuickTileWorld) -> QuickTileRoute {
        if let missing = QuickTileRules.missing(tile, world: world) { return .unavailable(missing) }
        guard let kind = tile.known else { return .unavailable(QuickTileRules.newerApp) }
        let bot = tile.bot ?? ""
        let words = tile.message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? tile.message : nil
        switch kind {
        case .newChat:
            return .newChat(NewChatLink(bot: bot, project: tile.project?.nilIfEmpty, message: words, send: tile.flag ?? true))
        case .memo: return .memo(profile: bot)
        case .talk: return .talk(profile: bot)
        case .openChat, .botCard: return .openChat(profile: bot)
        case .send:
            guard let words else { return .unavailable("Add the words to send in Edit.") }
            return tile.flag == true ? .sendInChat(profile: bot, words: words) : .sendInBackground(profile: bot, words: words)
        case .prompt:
            guard let words else { return .unavailable("Choose a prompt in Edit.") }
            return tile.flag == true ? .sendInChat(profile: bot, words: words) : .sendInBackground(profile: bot, words: words)
        case .slashCommand:
            let cmd = (tile.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty else { return .unavailable("Choose a command in Edit.") }
            return .slashCommand(profile: bot, command: cmd)
        case .quickAsk:
            return .quickAsk(profile: bot, defaultOpen: tile.flag ?? true)
        case .addTask: return .newTask(bot: tile.bot?.nilIfEmpty)
        case .runJob: return .runJob(key: tile.job ?? "", name: tile.jobName ?? tile.name)
        case .page: return .page(id: tile.page ?? "")
        case .search: return .search
        case .dashboardTile: return .dashboardTile(id: tile.pin ?? "")
        case .tasks: return .tasksView(key: tile.taskView?.nilIfEmpty ?? "today")
        case .goal: return .goal(id: tile.goalId ?? "")
        case .needsYou: return .needsYou
        case .groupChat: return .groupChat(key: tile.roomKey ?? "")
        case .chatSession: return .chatSession(profile: bot, sessionId: tile.sessionId ?? "")
        case .jobCard: return .jobDetail(key: tile.job?.nilIfEmpty)
        case .kanban: return .kanban(board: tile.boardSlug?.nilIfEmpty, status: tile.columnStatus?.nilIfEmpty)
        case .gatewayStatus: return .gatewayStatus
        case .usage: return .usage
        case .approvals: return .approvals
        case .activeRuns: return .activeRuns
        case .inlineAsk: return .inlineAsk(profile: bot)
        case .livePeek: return .livePeek(profile: tile.bot?.nilIfEmpty)
        case .dashboardPage: return .dashboardPage(id: tile.dashboardPageId?.nilIfEmpty ?? "main")
        case .filesFolder: return .filesFolder(profile: tile.bot?.nilIfEmpty, path: tile.folderPath ?? "")
        case .link:
            guard let raw = tile.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let parsed = Self.normalizedURL(raw) else {
                return .unavailable("Add a valid web address in Edit.")
            }
            return .link(parsed)
        case .routine:
            let steps = tile.steps ?? []
            guard !steps.isEmpty else { return .unavailable("Add at least one step in Edit.") }
            return .routine(steps, name: tile.name)
        case .section: return .toggleSection(id: tile.id)
        }
    }

    static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host?.isEmpty == false else { return nil }
        return url
    }
}

nonisolated enum QuickTileRules {
    static let newerApp = "This action needs a newer version of Hermes HQ."

    /// One sentence when the tile's target isn't on this gateway (nil: it is, or that isn't known yet).
    static func missing(_ tile: QuickTile, world: QuickTileWorld) -> String? {
        guard let kind = tile.known else { return newerApp }
        if kind.needsBot || (kind == .addTask && tile.bot != nil), let bot = tile.bot, let bots = world.bots {
            if bots[bot] == nil { return "\(tile.botName ?? bot) isn’t on this gateway." }
        }
        if kind.needsBot, (tile.bot ?? "").isEmpty { return "Choose a bot for this action in Edit." }
        if kind == .runJob {
            guard let job = tile.job, !job.isEmpty else { return "Choose a job for this action in Edit." }
            if let jobs = world.jobs, !jobs.contains(job) { return "“\(tile.jobName ?? tile.name)” isn’t on this gateway." }
        }
        if kind == .jobCard, let job = tile.job, !job.isEmpty, let jobs = world.jobs, !jobs.contains(job) {
            return "“\(tile.jobName ?? tile.name)” isn’t on this gateway."
        }
        if kind == .page {
            guard let page = tile.page, !page.isEmpty else { return "Choose a page for this action in Edit." }
            if let pages = world.pages, pages[page] == nil { return "\(tile.pageName ?? tile.name) isn’t on this gateway." }
        }
        if kind == .dashboardTile {
            guard let pin = tile.pin, !pin.isEmpty else { return notOnDashboard(tile) }
            if let pins = world.pins, pins[pin] == nil { return notOnDashboard(tile) }
        }
        if kind == .tasks {
            if world.tasksEnabled == false { return "Tasks is turned off in Settings." }
            if let view = tile.taskView, view.hasPrefix("list:"), let lists = world.taskLists {
                let listId = String(view.dropFirst(5))
                if lists[listId] == nil { return "“\(tile.taskViewName ?? tile.name)” isn’t on this gateway." }
            }
        }
        if kind == .goal {
            if world.tasksEnabled == false { return "Tasks is turned off in Settings." }
            guard let goalId = tile.goalId, !goalId.isEmpty else { return "Choose a goal in Edit." }
            if let goals = world.goals, goals[goalId] == nil { return "“\(tile.goalName ?? tile.name)” isn’t on this gateway." }
        }
        if kind == .groupChat {
            guard let key = tile.roomKey, !key.isEmpty else { return "Choose a group chat in Edit." }
            if let rooms = world.rooms, rooms[key] == nil { return "“\(tile.roomName ?? tile.name)” isn’t on this gateway." }
        }
        if kind == .chatSession {
            guard let sessionId = tile.sessionId, !sessionId.isEmpty else { return "Choose a chat in Edit." }
            if let bots = world.bots, let bot = tile.bot, !bot.isEmpty, bots[bot] == nil {
                return "\(tile.botName ?? bot) isn’t on this gateway."
            }
        }
        if kind == .kanban, let slug = tile.boardSlug, !slug.isEmpty, let boards = world.boards, boards[slug] == nil {
            return "“\(tile.boardName ?? tile.name)” isn’t on this gateway."
        }
        if kind == .dashboardPage, let id = tile.dashboardPageId, !id.isEmpty, id != "main",
           let dashPages = world.dashboardPages, dashPages[id] == nil {
            return "“\(tile.dashboardPageName ?? tile.name)” isn’t on your Dashboard any more."
        }
        if kind == .filesFolder, (tile.folderPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Choose a folder in Edit."
        }
        if kind == .link, QuickTileRoute.normalizedURL(tile.url ?? "") == nil {
            return "Add a valid web address in Edit."
        }
        return nil
    }

    static func notOnDashboard(_ tile: QuickTile) -> String { "“\(tile.pinName ?? tile.name)” isn’t on your Dashboard any more." }

    /// Whether a tile belongs to another gateway when "This Gateway Only" filter is on.
    static func isOtherGateway(_ tile: QuickTile, world: QuickTileWorld) -> Bool {
        if let gw = tile.gatewayId, !gw.isEmpty, let current = world.currentGatewayId, !current.isEmpty, gw != current {
            return true
        }
        if let kind = tile.known, kind.isSection || kind == .link || kind == .search || kind == .needsYou
            || kind == .gatewayStatus || kind == .usage || kind == .approvals || kind == .activeRuns || kind == .livePeek {
            return false
        }
        return missing(tile, world: world) != nil
    }
}

/// The Favorites tiles and pages.
nonisolated struct QuickTileList: Equatable, Sendable {
    var tiles: [QuickTile] = []
    /// The starter set was offered once (or the person changed the list): never seeded again.
    var seeded = false
    /// Additional pages/spaces. Empty means only the default `Home` (`main`) page exists.
    var pages: [FavoritePage] = []

    /// Always starts with `main`.
    var allPages: [FavoritePage] {
        guard !pages.isEmpty else { return [.main] }
        if pages.first?.id == FavoritePage.mainId { return pages }
        let main = pages.first { $0.id == FavoritePage.mainId } ?? .main
        return [main] + pages.filter { $0.id != FavoritePage.mainId }
    }

    var hasMultiplePages: Bool { allPages.count > 1 }

    /// Tiles belonging to `pageId` (default: `main`).
    func tiles(on pageId: String = FavoritePage.mainId) -> [QuickTile] {
        let target = pageId.isEmpty ? FavoritePage.mainId : pageId
        return tiles.filter { $0.resolvedPageId == target }
    }

    /// Tiles shown on `pageId`, hiding items inside collapsed sections unless `includeCollapsed` is true.
    func visibleTiles(on pageId: String = FavoritePage.mainId, includeCollapsed: Bool = false) -> [QuickTile] {
        let onPage = tiles(on: pageId)
        guard !includeCollapsed else { return onPage }
        var out: [QuickTile] = []
        var hiding = false
        for tile in onPage {
            if tile.known == .section {
                hiding = tile.collapsed == true
                out.append(tile)
            } else if !hiding {
                out.append(tile)
            }
        }
        return out
    }

    /// How many tiles sit under `sectionID` before the next section header on `pageId`.
    func sectionItemCount(_ sectionID: String, on pageId: String = FavoritePage.mainId) -> Int {
        let onPage = tiles(on: pageId)
        guard let start = onPage.firstIndex(where: { $0.id == sectionID }) else { return 0 }
        var count = 0
        for tile in onPage[(start + 1)...] {
            if tile.known == .section { break }
            count += 1
        }
        return count
    }

    mutating func add(_ tile: QuickTile) { tiles.append(tile) }

    mutating func replace(_ tile: QuickTile) {
        if let index = tiles.firstIndex(where: { $0.id == tile.id }) { tiles[index] = tile } else { tiles.append(tile) }
    }

    mutating func remove(_ id: String) { tiles.removeAll { $0.id == id } }

    @discardableResult
    mutating func duplicate(_ id: String) -> QuickTile? {
        guard let index = tiles.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = tiles[index]
        copy.id = UUID().uuidString
        copy.name = copy.name.isEmpty ? "Copy" : "\(copy.name) Copy"
        tiles.insert(copy, at: index + 1)
        return copy
    }

    mutating func setWide(_ id: String, _ wide: Bool) {
        guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        tiles[index].wide = wide
        if tiles[index].size != nil {
            tiles[index].size = nil
        }
    }

    /// A Dashboard tile or live card is never Short: it stays as it is.
    mutating func setShort(_ id: String, _ short: Bool) {
        guard let index = tiles.firstIndex(where: { $0.id == id }),
              tiles[index].known?.supportsShort ?? true else { return }
        tiles[index].short = short
        if short, tiles[index].size == .mini { tiles[index].size = nil }
    }

    /// Sets any size from the full `QuickTileSize` vocabulary, keeping `wide` and `short` consistent.
    mutating func setSize(_ id: String, _ next: QuickTileSize) {
        guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        let kind = tiles[index].known
        if let kind, kind.isSection { return }
        if next == .mini, kind?.supportsMini == false { return }
        if (next == .large || next == .tallCard || next == .extraLarge), kind?.supportsMultiRowSize == false { return }
        tiles[index].wide = next.isWideSpan
        tiles[index].size = (next == .small || next == .wide) ? nil : next
        if next == .mini || next.rowSpan > 1 || kind?.supportsShort == false {
            tiles[index].short = false
        }
    }

    mutating func toggleSection(_ id: String) {
        guard let index = tiles.firstIndex(where: { $0.id == id }), tiles[index].known == .section else { return }
        let next = !(tiles[index].collapsed ?? false)
        tiles[index].collapsed = next ? true : nil
    }

    mutating func moveTile(_ id: String, toPage pageId: String) {
        guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        tiles[index].pageId = (pageId.isEmpty || pageId == FavoritePage.mainId) ? nil : pageId
    }

    // MARK: Pages management

    @discardableResult
    mutating func addPage(name: String, symbol: String? = nil) -> FavoritePage {
        ensureMainPage()
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = FavoritePage(id: UUID().uuidString, name: cleaned.isEmpty ? "Page \(pages.count)" : cleaned,
                                symbol: symbol?.nilIfEmpty)
        pages.append(page)
        return page
    }

    mutating func renamePage(_ id: String, name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        ensureMainPage()
        if let index = pages.firstIndex(where: { $0.id == id }) { pages[index].name = cleaned }
    }

    mutating func setPageSymbol(_ id: String, symbol: String?) {
        ensureMainPage()
        if let index = pages.firstIndex(where: { $0.id == id }) { pages[index].symbol = symbol?.nilIfEmpty }
    }

    mutating func reorderPage(_ sourceId: String, before targetId: String) {
        guard sourceId != FavoritePage.mainId, targetId != FavoritePage.mainId, sourceId != targetId else { return }
        ensureMainPage()
        guard let from = pages.firstIndex(where: { $0.id == sourceId }),
              let to = pages.firstIndex(where: { $0.id == targetId }) else { return }
        let moving = pages.remove(at: from)
        pages.insert(moving, at: to)
    }

    /// Removes a custom page; tiles on it move back to `main` (unless `deleteTiles` is true).
    mutating func deletePage(_ id: String, deleteTiles: Bool = false) {
        guard id != FavoritePage.mainId else { return }
        pages.removeAll { $0.id == id }
        if deleteTiles {
            tiles.removeAll { $0.resolvedPageId == id }
        } else {
            for i in tiles.indices where tiles[i].resolvedPageId == id { tiles[i].pageId = nil }
        }
        if pages.count <= 1, pages.first == .main { pages = [] }
    }

    private mutating func ensureMainPage() {
        if pages.isEmpty { pages = [.main] }
        else if !pages.contains(where: { $0.id == FavoritePage.mainId }) { pages.insert(.main, at: 0) }
    }

    /// [favorites-live-tiles] The pins already on the page (Add Action leaves them out).
    var pins: Set<String> { Set(tiles.compactMap { $0.known == .dashboardTile ? $0.pin : nil }) }

    /// Moves the tile to `index` (clamped).
    mutating func move(_ id: String, to index: Int) {
        guard let from = tiles.firstIndex(where: { $0.id == id }) else { return }
        let tile = tiles.remove(at: from)
        tiles.insert(tile, at: max(0, min(index, tiles.count)))
    }

    /// One step earlier (-1) or later (+1); false at an end.
    @discardableResult mutating func step(_ id: String, by delta: Int) -> Bool {
        guard let from = tiles.firstIndex(where: { $0.id == id }), tiles.indices.contains(from + delta) else { return false }
        tiles.swapAt(from, from + delta)
        return true
    }

    /// The tiles in `order` (ids); any not named keep their place after them (none is ever dropped).
    mutating func reorder(_ order: [String]) {
        var byID = Dictionary(tiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next = order.compactMap { byID.removeValue(forKey: $0) }
        next += tiles.filter { byID[$0.id] != nil }
        tiles = next
    }

    /// Reorders only the tiles on `pageId` according to `order`, keeping other pages' tiles untouched.
    mutating func reorder(_ order: [String], on pageId: String) {
        let target = pageId.isEmpty ? FavoritePage.mainId : pageId
        var byID = Dictionary(tiles.filter { $0.resolvedPageId == target }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered = order.compactMap { byID.removeValue(forKey: $0) }
        ordered += tiles.filter { $0.resolvedPageId == target && byID[$0.id] != nil }
        var iterator = ordered.makeIterator()
        tiles = tiles.compactMap { tile in
            guard tile.resolvedPageId == target else { return tile }
            return iterator.next()
        }
    }

    /// [favorites-retired] The pages chosen on the retired Favorites page join once as page tiles.
    @discardableResult
    mutating func absorbFavorites(_ ids: [String], pages: [String: (title: String, symbol: String)]) -> Bool {
        let before = tiles
        tiles.removeAll { $0.known == .page && $0.page == FavoritePages.rowID }
        var have = Set(tiles.compactMap { $0.known == .page ? $0.page : nil })
        for id in ids where id != FavoritePages.rowID && id != QuickTileStore.rowID && !have.contains(id) {
            guard let page = pages[id] else { continue }
            var tile = QuickTile(id: "favorite-" + id, kind: .page, name: page.title, symbol: page.symbol)
            tile.page = id
            tile.pageName = page.title
            tiles.append(tile)
            have.insert(id)
        }
        return tiles != before
    }
}

nonisolated enum QuickTileStore {
    static let key = "hqn.quickActions"
    static let unreadableKey = "hqn.quickActions.unreadable"
    static let currentPageKey = "hqn.quickActions.currentPage"
    static let hideOtherGatewaysKey = "hqn.quickActions.hideOtherGateways"
    static let dismissedExploreKey = "hqn.quickActions.dismissedExplore"
    static let didChange = Notification.Name("hqn.quickActions.changed")
    static let version = 1
    static let rowID = "quick-actions"

    /// Hook notified on local saves so `FavoritesSync` pushes to `GatewaySync` without coupling the pure store.
    @MainActor static var onLocalSave: (() -> Void)?

    private struct Envelope: Codable {
        var version: Int
        var seeded: Bool?
        var tiles: [Entry]
        var pages: [FavoritePage]?
    }

    private struct Entry: Codable {
        var tile: QuickTile
        init(_ tile: QuickTile) { self.tile = tile }
        init(from decoder: Decoder) throws {
            if let tile = try? QuickTile(from: decoder) { self.tile = tile; return }
            tile = QuickTile(unreadable: try JSONValue(from: decoder))
        }
        func encode(to encoder: Encoder) throws { try tile.encode(to: encoder) }
    }

    static func decode(_ data: Data) -> QuickTileList? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        return QuickTileList(tiles: envelope.tiles.map(\.tile),
                             seeded: envelope.seeded ?? !envelope.tiles.isEmpty,
                             pages: envelope.pages ?? [])
    }

    static func encode(_ list: QuickTileList, version: Int = QuickTileStore.version) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let pages: [FavoritePage]? = list.pages.isEmpty ? nil : list.pages
        return try? encoder.encode(Envelope(version: version, seeded: list.seeded,
                                            tiles: list.tiles.map(Entry.init), pages: pages))
    }

    static func load(_ defaults: UserDefaults = .standard) -> QuickTileList {
        guard let data = defaults.data(forKey: key) else { return QuickTileList() }
        if let list = decode(data) { return list }
        if defaults.data(forKey: unreadableKey) == nil { defaults.set(data, forKey: unreadableKey) }
        return QuickTileList(tiles: [], seeded: true)
    }

    /// Stores `list` (marking it seeded: the person has a list now). Returns whether it changed.
    @discardableResult
    static func save(_ list: QuickTileList, _ defaults: UserDefaults = .standard, notifySync: Bool = true) -> Bool {
        var list = list
        list.seeded = true
        if let data = defaults.data(forKey: key), decode(data) == nil, defaults.data(forKey: unreadableKey) == nil {
            defaults.set(data, forKey: unreadableKey)
        }
        let stored = defaults.data(forKey: key).flatMap(decode)
        let version = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(VersionOnly.self, from: $0) }?.version ?? Self.version
        guard let data = encode(list, version: max(version, Self.version)) else { return false }
        if stored == list { return false }
        defaults.set(data, forKey: key)
        if defaults === UserDefaults.standard {
            NotificationCenter.default.post(name: didChange, object: nil)
            if notifySync {
                Task { @MainActor in onLocalSave?() }
            }
        }
        return true
    }

    static func currentPage(_ defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: currentPageKey) ?? FavoritePage.mainId
        return stored.isEmpty ? FavoritePage.mainId : stored
    }

    static func setCurrentPage(_ id: String, _ defaults: UserDefaults = .standard) {
        let value = id.isEmpty ? FavoritePage.mainId : id
        defaults.set(value, forKey: currentPageKey)
    }

    static func hidesOtherGateways(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: hideOtherGatewaysKey)
    }

    static func setHidesOtherGateways(_ hide: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(hide, forKey: hideOtherGatewaysKey)
        if defaults === UserDefaults.standard { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    private struct VersionOnly: Decodable { var version: Int }

    static func listToShow(_ stored: QuickTileList, firstBot: (profile: String, name: String)?) -> (list: QuickTileList, seeded: Bool) {
        guard stored.tiles.isEmpty, !stored.seeded, let bot = firstBot else { return (stored, false) }
        return (QuickTileList(tiles: starter(bot: bot.profile, name: bot.name), seeded: true), true)
    }

    /// Starter IDs, so first-contact sync can distinguish an unedited starter list from a customized one.
    static let starterIDs: Set<String> = ["starter-memo", "starter-talk", "starter-new-chat", "starter-add-task", "starter-search"]

    static func isUneditedStarter(_ list: QuickTileList) -> Bool {
        list.pages.isEmpty && !list.tiles.isEmpty && Set(list.tiles.map(\.id)) == starterIDs
    }

    /// Voice Memo, Talk, New Chat (wide), Add Task and Search Chats, for the roster's first bot.
    static func starter(bot: String, name: String) -> [QuickTile] {
        func forBot(_ tile: QuickTile) -> QuickTile {
            var tile = tile
            tile.bot = bot
            tile.botName = name
            return tile
        }
        var chat = forBot(QuickTile(id: "starter-new-chat", kind: .newChat, wide: true))
        chat.flag = true
        return [forBot(QuickTile(id: "starter-memo", kind: .memo)), forBot(QuickTile(id: "starter-talk", kind: .talk)), chat,
                QuickTile(id: "starter-add-task", kind: .addTask), QuickTile(id: "starter-search", kind: .search)]
    }
}

/// Curated starter presets users can add or apply from Favorites.
nonisolated enum FavoritePreset: String, CaseIterable, Identifiable, Sendable {
    case commandCenter
    case dailyFocus
    case voiceFirst
    case builderOps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commandCenter: "Command Center"
        case .dailyFocus: "Daily Focus"
        case .voiceFirst: "Voice & Capture"
        case .builderOps: "Builder & Ops"
        }
    }

    var subtitle: String {
        switch self {
        case .commandCenter: "Needs You, Today’s tasks, live bot, quick strip, and status."
        case .dailyFocus: "Today’s tasks, active goal, quick capture, and voice."
        case .voiceFirst: "One-tap Memo, Talk, Quick Ask, and Add Task."
        case .builderOps: "Gateway, Usage, Active Now, Upcoming Jobs, and Kanban."
        }
    }

    var symbol: String {
        switch self {
        case .commandCenter: "square.grid.2x2.fill"
        case .dailyFocus: "sun.max.fill"
        case .voiceFirst: "waveform"
        case .builderOps: "terminal.fill"
        }
    }

    func tiles(bot: (profile: String, name: String)?, goal: (id: String, title: String)? = nil,
               pageId: String = FavoritePage.mainId) -> [QuickTile] {
        let pId: String? = pageId == FavoritePage.mainId ? nil : pageId
        func stamp(_ tile: QuickTile) -> QuickTile {
            var t = tile
            t.pageId = pId
            return t
        }
        func forBot(_ tile: QuickTile) -> QuickTile {
            var t = stamp(tile)
            if let bot {
                t.bot = bot.profile
                t.botName = bot.name
            }
            return t
        }
        switch self {
        case .commandCenter:
            var out: [QuickTile] = []
            if bot != nil {
                var memo = forBot(QuickTile(kind: .memo, size: .mini))
                memo.name = "Memo"
                var talk = forBot(QuickTile(kind: .talk, size: .mini))
                talk.name = "Talk"
                var ask = forBot(QuickTile(kind: .quickAsk, name: "Ask", size: .mini))
                ask.flag = true
                var task = stamp(QuickTile(kind: .addTask, name: "Task", size: .mini))
                task.symbol = "plus.circle.fill"
                out += [memo, talk, ask, task]
            }
            out.append(stamp(QuickTile(kind: .needsYou, name: "Needs You", size: .wide)))
            var today = stamp(QuickTile(kind: .tasks, name: "Today", size: .wide))
            today.taskView = "today"
            today.taskViewName = "Today"
            out.append(today)
            if let bot {
                var botTile = forBot(QuickTile(kind: .botCard, name: bot.name, size: .wide))
                botTile.bot = bot.profile
                botTile.botName = bot.name
                out.append(botTile)
            }
            out.append(stamp(QuickTile(kind: .gatewayStatus, name: "Gateway", size: .small)))
            var usage = stamp(QuickTile(kind: .usage, name: "Usage", size: .small))
            usage.days = 7
            out.append(usage)
            return out

        case .dailyFocus:
            var out: [QuickTile] = []
            var today = stamp(QuickTile(kind: .tasks, name: "Today", size: .large))
            today.taskView = "today"
            today.taskViewName = "Today"
            out.append(today)
            if let goal {
                var goalTile = stamp(QuickTile(kind: .goal, name: goal.title, size: .wide))
                goalTile.goalId = goal.id
                goalTile.goalName = goal.title
                out.append(goalTile)
            }
            out.append(stamp(QuickTile(kind: .needsYou, name: "Needs You", size: .wide)))
            out.append(stamp(QuickTile(kind: .addTask, name: "Add Task", size: .small)))
            if bot != nil {
                out.append(forBot(QuickTile(kind: .memo, size: .small)))
            } else {
                out.append(stamp(QuickTile(kind: .search, size: .small)))
            }
            return out

        case .voiceFirst:
            var out: [QuickTile] = []
            if let bot {
                out.append(forBot(QuickTile(kind: .memo, name: "Voice Memo", size: .small)))
                out.append(forBot(QuickTile(kind: .talk, name: "Talk", size: .small)))
                var ask = forBot(QuickTile(kind: .quickAsk, name: "Quick Ask", size: .wide))
                ask.flag = true
                out.append(ask)
                var chat = forBot(QuickTile(kind: .newChat, name: "New Chat", size: .wide))
                chat.flag = true
                out.append(chat)
                out.append(forBot(QuickTile(kind: .botCard, name: bot.name, size: .wide)))
            }
            out.append(stamp(QuickTile(kind: .addTask, size: .small)))
            out.append(stamp(QuickTile(kind: .search, size: .small)))
            return out

        case .builderOps:
            var out: [QuickTile] = [
                stamp(QuickTile(kind: .gatewayStatus, name: "Gateway", size: .small)),
            ]
            var usage = stamp(QuickTile(kind: .usage, name: "Usage", size: .small))
            usage.days = 7
            out.append(usage)
            out.append(stamp(QuickTile(kind: .activeRuns, name: "Active Now", size: .wide)))
            out.append(stamp(QuickTile(kind: .jobCard, name: "Upcoming Jobs", size: .wide)))
            out.append(stamp(QuickTile(kind: .kanban, name: "Kanban", size: .wide)))
            var terminal = stamp(QuickTile(kind: .page, name: "Terminal", symbol: "apple.terminal.fill", color: .gray, size: .small))
            terminal.page = "terminal"
            terminal.pageName = "Terminal"
            var changes = stamp(QuickTile(kind: .page, name: "Changes", symbol: "plus.forwardslash.minus", color: .green, size: .small))
            changes.page = "review"
            changes.pageName = "Changes"
            out += [terminal, changes]
            return out
        }
    }
}

/// Legacy two-column row grouping helper (preserved for existing unit tests).
nonisolated enum QuickTileGrid {
    static func rows(_ tiles: [QuickTile], columns: Int) -> [[Int]] {
        guard columns > 1 else { return tiles.indices.map { [$0] } }
        var rows: [[Int]] = []
        var open: [Int] = []
        for (index, tile) in tiles.enumerated() {
            if tile.wide {
                if !open.isEmpty { rows.append(open); open = [] }
                rows.append([index])
            } else {
                open.append(index)
                if open.count == columns { rows.append(open); open = [] }
            }
        }
        if !open.isEmpty { rows.append(open) }
        return rows
    }
}

/// Responsive 2D Bento layout engine for iPhone (2 cols), iPad/Mac (3–5 cols), and AX3+ (1 col).
/// Supports section headers, 4-across Mini action strips, Short action rows, and multi-row widgets (1×2, 2×2, Banner, Extra Large)
/// while keeping standard Small/Wide sequences in exact linear order.
nonisolated enum QuickTileLayout {
    struct Metrics: Sendable {
        var width: CGFloat
        var gap: CGFloat
        var stacked: Bool
        var scale: CGFloat
        var actionTallHeight: CGFloat
        var actionShortHeight: CGFloat
        var miniHeight: CGFloat
        var sectionHeight: CGFloat
        var dashboardNameHeight: CGFloat

        var columns: Int {
            QuickTileLayout.columns(width: width, gap: gap, stacked: stacked, scale: scale)
        }

        var columnWidth: CGFloat {
            let cols = CGFloat(max(1, columns))
            return max(0, floor((width - (cols - 1) * gap) / cols))
        }

        /// Square widget cell height (matches `FavoriteTileSize.picture` on phone; capped sensibly on ultra-wide screens).
        var unitHeight: CGFloat {
            if stacked {
                return max(0, floor((width - gap) / 2))
            }
            if columns <= 2 {
                return columnWidth
            }
            return min(columnWidth, floor(220 * max(1, scale)))
        }
    }

    struct Placement: Equatable, Sendable {
        var index: Int
        var frame: CGRect
        var fillsRow: Bool
    }

    struct Result: Equatable, Sendable {
        var placements: [Placement]
        var totalHeight: CGFloat
        var columns: Int
        var columnWidth: CGFloat
        var unitHeight: CGFloat
    }

    /// Responsive column count: 1 at AX3+, 2 on phones (< 620 pt), 3–5 on iPad and Mac.
    static func columns(width: CGFloat, gap: CGFloat, stacked: Bool, scale: CGFloat = 1) -> Int {
        guard !stacked else { return 1 }
        if width < 620 { return 2 }
        let minCell = 200 * max(1, scale)
        return max(2, min(5, Int((width + gap) / (minCell + gap))))
    }

    /// Intrinsic height for a tile given `metrics` and its effective span.
    static func naturalHeight(for tile: QuickTile, metrics: Metrics) -> CGFloat {
        guard let kind = tile.known else { return tile.short ? metrics.actionShortHeight : metrics.actionTallHeight }
        if kind.isSection { return metrics.sectionHeight }
        let size = tile.effectiveSize
        if size == .mini { return metrics.miniHeight }
        if kind.isPicture {
            let rows = CGFloat(size.rowSpan)
            let picHeight = rows * metrics.unitHeight + (rows - 1) * metrics.gap
            return picHeight + metrics.dashboardNameHeight
        }
        if kind.isLiveCard {
            let rows = CGFloat(size.rowSpan)
            let base = max(metrics.unitHeight, metrics.actionTallHeight)
            // Single-control Wide/Banner cards (Inline Ask, Browser & Screen) sit extra snug (~108pt) with zero dead space.
            if Self.usesTightWideHeight(tile) {
                return min(base, ceil(108 * max(1, metrics.scale)))
            }
            // Wide/Banner 1-row horizontal cards (Bot, Goal, Approvals, single Job, Group, Session) use a tailored
            // compact height (~134pt) instead of a tall square, eliminating dead empty space inside the card.
            if Self.usesCompactWideHeight(tile) {
                return min(base, ceil(max(metrics.actionTallHeight, 134 * max(1, metrics.scale))))
            }
            // Wide/Banner 1-row multi-item list cards (Today, Needs You, Upcoming Jobs, Active Now) need room for
            // 3–4 two-line rows plus an optional "+N more" footer (~224pt) so content never overflows the card.
            if Self.usesListWideHeight(tile) {
                return max(base, ceil(224 * max(1, metrics.scale)))
            }
            return rows * base + (rows - 1) * metrics.gap
        }
        return tile.short ? metrics.actionShortHeight : metrics.actionTallHeight
    }

    /// Multi-row 1-row Wide/Banner list live cards whose items carry two lines (title + note/schedule) plus footer.
    static func usesListWideHeight(_ tile: QuickTile) -> Bool {
        let size = tile.effectiveSize
        guard size.isWideSpan, size.rowSpan == 1, let kind = tile.known else { return false }
        switch kind {
        case .tasks, .needsYou, .activeRuns:
            return true
        case .jobCard:
            return (tile.job ?? "").isEmpty
        default:
            return false
        }
    }

    /// Single-control 1-row Wide/Banner live cards (Inline Ask, Browser & Screen) that look best at ~108pt.
    static func usesTightWideHeight(_ tile: QuickTile) -> Bool {
        let size = tile.effectiveSize
        guard size.isWideSpan, size.rowSpan == 1, let kind = tile.known else { return false }
        return kind == .inlineAsk || kind == .livePeek
    }

    /// Horizontal 1-row Wide/Banner live cards whose content is 2–3 rows + action strip (snugger than a 180pt square).
    static func usesCompactWideHeight(_ tile: QuickTile) -> Bool {
        let size = tile.effectiveSize
        guard size.isWideSpan, size.rowSpan == 1, let kind = tile.known else { return false }
        switch kind {
        case .botCard, .goal, .approvals, .groupChat, .chatSession, .inlineAsk, .livePeek:
            return true
        case .jobCard:
            return !(tile.job ?? "").isEmpty
        default:
            return false
        }
    }

    /// Computes frames for `tiles` (optionally including a trailing Small slot for `+ Add Action` when `hasAddTile` is true).
    static func compute(_ tiles: [QuickTile], metrics: Metrics, hasAddTile: Bool = false) -> Result {
        var items = tiles
        if hasAddTile {
            items.append(QuickTile(id: "__add__", kind: .page))
        }
        let cols = metrics.columns
        let colW = metrics.columnWidth
        let gap = metrics.gap
        let unitH = metrics.unitHeight
        guard !items.isEmpty, metrics.width > 0 else {
            return Result(placements: [], totalHeight: 0, columns: cols, columnWidth: colW, unitHeight: unitH)
        }

        // Single-column accessibility layout: every tile spans full width.
        if cols <= 1 {
            var y: CGFloat = 0
            var out: [Placement] = []
            for (index, tile) in items.enumerated() {
                let h = naturalHeight(for: tile, metrics: metrics)
                out.append(Placement(index: index, frame: CGRect(x: 0, y: y, width: metrics.width, height: h), fillsRow: false))
                y += h + gap
            }
            return Result(placements: out, totalHeight: max(0, y - gap), columns: 1, columnWidth: metrics.width, unitHeight: unitH)
        }

        var placements: [Placement] = []
        var y: CGFloat = 0
        var i = 0

        func itemWidth(colSpan: Int) -> CGFloat {
            let clamped = min(cols, max(1, colSpan))
            if clamped == cols { return metrics.width }
            return CGFloat(clamped) * colW + CGFloat(clamped - 1) * gap
        }

        func itemX(col: Int) -> CGFloat {
            CGFloat(col) * (colW + gap)
        }

        while i < items.count {
            let first = items[i]

            // 1. Section Header: full-width divider row.
            if first.known == .section {
                let h = metrics.sectionHeight
                if y > 0 { y += 4 }   // gentle extra breathing room before a new section
                placements.append(Placement(index: i, frame: CGRect(x: 0, y: y, width: metrics.width, height: h), fillsRow: false))
                y += h + gap
                i += 1
                continue
            }

            // 2. Mini Strip: pack consecutive mini tiles into dense 2*cols rows (4 across on phone, 6–10 on iPad/Mac).
            if first.effectiveSize == .mini {
                let miniCols = cols * 2
                let miniGap = min(gap, 10)
                let miniW = floor((metrics.width - CGFloat(miniCols - 1) * miniGap) / CGFloat(miniCols))
                var col = 0
                while i < items.count, items[i].effectiveSize == .mini {
                    let x = CGFloat(col) * (miniW + miniGap)
                    placements.append(Placement(index: i, frame: CGRect(x: x, y: y, width: miniW, height: metrics.miniHeight), fillsRow: false))
                    i += 1
                    col += 1
                    if col == miniCols {
                        col = 0
                        y += metrics.miniHeight + miniGap
                    }
                }
                if col > 0 { y += metrics.miniHeight + gap } else { y += (gap - miniGap) }
                continue
            }

            // 3. Multi-row 2D band: if this item (or an item that starts in this row) has rowSpan == 2 and leaves open
            // columns beside it, pack the next row-1 items into the 2 subrows beside it!
            let firstSpan = first.effectiveSize.colSpan(in: cols)
            let firstRows = first.effectiveSize.rowSpan

            // Check whether this row needs 2-subrow band packing (a 2-row item that doesn't span the full grid).
            if firstRows == 2 && firstSpan < cols {
                // Build a 2-row occupancy grid [subrow 0..1][col 0..<cols]
                var grid = Array(repeating: Array(repeating: false, count: cols), count: 2)
                let baseUnit = max(unitH, metrics.actionTallHeight)
                let picBonus = first.known?.isPicture == true ? metrics.dashboardNameHeight : 0
                let subH = baseUnit + picBonus / 2
                let bandH = subH * 2 + gap
                var bandHasPicture = first.known?.isPicture == true

                func findSpot(cSpan: Int, rSpan: Int) -> (col: Int, row: Int)? {
                    for r in 0...(2 - rSpan) {
                        for c in 0...(cols - cSpan) {
                            var free = true
                            for rr in r..<(r + rSpan) {
                                for cc in c..<(c + cSpan) where grid[rr][cc] { free = false }
                            }
                            if free { return (c, r) }
                        }
                    }
                    return nil
                }

                var bandEntries: [(index: Int, col: Int, row: Int, cSpan: Int, rSpan: Int, isPicture: Bool)] = []
                while i < items.count {
                    let tile = items[i]
                    if tile.known == .section || tile.effectiveSize == .mini { break }
                    let cSpan = tile.effectiveSize.colSpan(in: cols)
                    let rSpan = tile.effectiveSize.rowSpan
                    guard let spot = findSpot(cSpan: cSpan, rSpan: rSpan) else { break }
                    for rr in spot.row..<(spot.row + rSpan) {
                        for cc in spot.col..<(spot.col + cSpan) { grid[rr][cc] = true }
                    }
                    if tile.known?.isPicture == true { bandHasPicture = true }
                    bandEntries.append((i, spot.col, spot.row, cSpan, rSpan, tile.known?.isPicture == true))
                    i += 1
                    if grid[0].allSatisfy({ $0 }) && grid[1].allSatisfy({ $0 }) { break }
                }

                for entry in bandEntries {
                    let w = itemWidth(colSpan: entry.cSpan)
                    let h = entry.rSpan == 2 ? bandH : subH
                    let fy = y + CGFloat(entry.row) * (subH + gap)
                    placements.append(Placement(index: entry.index,
                                                frame: CGRect(x: itemX(col: entry.col), y: fy, width: w, height: h),
                                                fillsRow: bandHasPicture && !entry.isPicture))
                }
                y += bandH + gap
                continue
            }

            // 4. Standard single-band row: fill columns left-to-right without jumping past wider items.
            var rowItems: [(index: Int, col: Int, cSpan: Int, tile: QuickTile)] = []
            var used = 0
            while i < items.count {
                let tile = items[i]
                if tile.known == .section || tile.effectiveSize == .mini { break }
                let cSpan = tile.effectiveSize.colSpan(in: cols)
                let rSpan = tile.effectiveSize.rowSpan
                // If a tall/large 2-row item would enter an already-started row and leave columns open, flush this row first.
                if !rowItems.isEmpty && rSpan == 2 { break }
                if used + cSpan > cols { break }
                rowItems.append((i, used, cSpan, tile))
                used += cSpan
                i += 1
                if rSpan == 2 || used == cols { break }
            }

            let rowHasPicture = rowItems.count > 1 && rowItems.contains { $0.tile.known?.isWidget == true }
            let rowHeight = rowItems.map { naturalHeight(for: $0.tile, metrics: metrics) }.max() ?? metrics.actionTallHeight
            for entry in rowItems {
                let isAction = entry.tile.known?.isWidget != true
                let isShortAction = isAction && entry.tile.short
                let cellHeight = isShortAction ? metrics.actionShortHeight : rowHeight
                placements.append(Placement(index: entry.index,
                                            frame: CGRect(x: itemX(col: entry.col), y: y, width: itemWidth(colSpan: entry.cSpan), height: cellHeight),
                                            fillsRow: rowHasPicture && isAction && !entry.tile.short))
            }
            y += rowHeight + gap
        }

        // Sort placements back into item-index order so indexPath.item maps 1:1 to placements[item].
        placements.sort { $0.index < $1.index }
        return Result(placements: placements, totalHeight: max(0, y - gap), columns: cols, columnWidth: colW, unitHeight: unitH)
    }
}
