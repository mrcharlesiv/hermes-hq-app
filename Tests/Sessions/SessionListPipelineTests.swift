import Foundation
import Testing
@testable import HermesHQNative

/// [sessions-m9] The Sessions list's one pipeline (docs/spec/3x-sessions.md §3.5): pool, filter, pinned, sort, group.
@Suite struct SessionListPipelineTests {
    private static let now = Date(timeIntervalSince1970: 1_791_590_400)       // a fixed "today"
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private static func chat(_ id: String, profile: String = "default", ago: Double = 60, started: Double? = nil, tokens: Int = 0,
                             cost: Double = 0, status: SessionStatus = .idle, pinned: Bool = false, cwd: String? = nil) -> SessionSummary {
        var s = SessionSummary(id: id, profile: profile, title: id, preview: "words", lastActive: now.addingTimeInterval(-ago),
                               source: "desktop", unread: status == .unread, isRunning: status == .working)
        s.startedAt = started.map { now.addingTimeInterval(-$0) }
        s.tokens = tokens; s.cost = cost; s.status = status; s.pinned = pinned; s.cwd = cwd
        return s
    }

    private static func run(_ live: [SessionSummary], archived: [SessionSummary] = [], _ edit: (inout SessionListInput) -> Void = { _ in }) -> [SessionGroup] {
        var input = SessionListInput(live: live, archived: archived, now: now, calendar: calendar)
        edit(&input)
        return SessionListPipeline.groups(input)
    }

    private static func ids(_ groups: [SessionGroup]) -> [String] { groups.flatMap(\.sessions).map(\.id) }

    @Test func defaultIsPinnedThenDateGroupsNewestFirst() {
        let groups = Self.run([Self.chat("old", ago: 86_400 * 40), Self.chat("new", ago: 60), Self.chat("pin", ago: 86_400 * 3, pinned: true),
                               Self.chat("mid", ago: 3_600)])
        #expect(groups.first?.id == "pinned" && groups.first?.title == "Pinned")
        #expect(Self.ids(groups) == ["pin", "new", "mid", "old"])
        #expect(groups.dropFirst().allSatisfy { !$0.title.isEmpty })
        #expect(!SessionListPipeline.isFlat(SessionsViewPrefs()))
    }

    private static func outside(_ id: String, _ source: String, ago: Double, profile: String = "default", pinned: Bool = false) -> SessionSummary {
        var s = chat(id, profile: profile, ago: ago, pinned: pinned)
        s.source = source; s.outside = true; s.origin = source
        return s
    }

    @Test func otherAppsRowSitsUnderPinnedAndItsPageHasASectionPerPlatform() {
        let outside = [Self.outside("tg1", "telegram", ago: 500), Self.outside("dc1", "discord", ago: 100),
                       Self.outside("tg2", "telegram", ago: 50), Self.outside("pin", "discord", ago: 900, pinned: true)]
        var groups = Self.run([Self.chat("a")]) { $0.outside = outside }
        #expect(groups.map(\.id).prefix(2) == ["pinned", SessionListPipeline.otherAppsId])
        #expect(groups.first?.sessions.map(\.id) == ["pin"])                                       // a pinned one sits in Pinned
        let apps = groups[1]
        #expect(apps.platforms == ["telegram", "discord"] && apps.total == 3 && apps.sessions.isEmpty)
        #expect(apps.newest == Self.now.addingTimeInterval(-50))
        #expect(groups.allSatisfy { $0.source == nil })

        let sections = SessionListPipeline.appSections(SessionListInput(outside: outside, now: Self.now, calendar: Self.calendar))
        #expect(sections.map(\.title) == ["Telegram", "Discord"])
        #expect(sections.map { $0.sessions.map(\.id) } == [["tg2", "tg1"], ["dc1", "pin"]])         // pinned ones listed too

        // Nothing pinned: the row comes first. The chip filters it; it stays under Group By Project and with Show › Archived; a project filter leaves it out.
        #expect(Self.run([Self.chat("a")]) { $0.outside = [Self.outside("x", "slack", ago: 5)] }.first?.id == SessionListPipeline.otherAppsId)
        groups = Self.run([Self.chat("a")]) { $0.outside = [Self.outside("x", "telegram", ago: 5, profile: "other")]; $0.botFilter = "default" }
        #expect(!groups.contains { $0.id == SessionListPipeline.otherAppsId })
        groups = Self.run([Self.chat("a")]) { $0.outside = outside; $0.prefs.groupBy = .project }
        #expect(groups.first?.id == "pinned" && groups.dropFirst().first?.id == SessionListPipeline.otherAppsId,
                "under Pinned, above the projects (the owner groups by project)")
        groups = Self.run([Self.chat("a")]) { $0.outside = outside; $0.projects = [SessionProjectEntry(key: "p", label: "P")]; $0.prefs.projectFilter = ["p"] }
        #expect(!groups.contains { $0.id == SessionListPipeline.otherAppsId })
        groups = Self.run([], archived: [Self.chat("z")]) { $0.outside = outside; $0.prefs.showArchived = true }
        #expect(groups.contains { $0.id == SessionListPipeline.otherAppsId })
        #expect(Self.run([]) { $0.outside = [Self.outside("only", "slack", ago: 5)] }.map(\.id) == [SessionListPipeline.otherAppsId])
    }

    /// Show › Archived: an archived Telegram chat goes to Other Apps (marked there), not among the dated rows; and the
    /// row wears the needs-you dot while any of its chats waits on the user.
    @Test func archivedPlatformChatsGoToOtherAppsAndTheRowSaysWhenOneWaits() {
        var gone = Self.outside("tgold", "telegram", ago: 9_000)
        gone.archived = true
        let live = [Self.outside("tg1", "telegram", ago: 500)]
        var groups = Self.run([Self.chat("a")], archived: [Self.chat("z"), gone]) { $0.outside = live; $0.prefs.showArchived = true }
        #expect(!Self.ids(groups).contains("tgold"), "not a dated row")
        #expect(Self.ids(groups).contains("z"))
        let apps = groups.first { $0.id == SessionListPipeline.otherAppsId }
        #expect(apps?.total == 2 && apps?.waiting == false)
        let sections = SessionListPipeline.appSections(SessionListInput(live: [], archived: [gone], prefs: { var p = SessionsViewPrefs(); p.showArchived = true; return p }(),
                                                                        outside: live, now: Self.now, calendar: Self.calendar))
        #expect(sections.first?.sessions.map(\.id) == ["tg1", "tgold"])
        // Archived off: neither the list nor the page has it.
        groups = Self.run([Self.chat("a")], archived: [gone]) { $0.outside = live }
        #expect(groups.first { $0.id == SessionListPipeline.otherAppsId }?.total == 1)
        #expect(SessionListPipeline.appSections(SessionListInput(archived: [gone], outside: live)).flatMap(\.sessions).map(\.id) == ["tg1"])

        var asking = Self.outside("dc", "discord", ago: 50)
        asking.status = .needsInput
        groups = Self.run([Self.chat("a")]) { $0.outside = live + [asking] }
        #expect(groups.first { $0.id == SessionListPipeline.otherAppsId }?.waiting == true)
    }

    @Test func chatSourceNamesMarksAndOrigins() {
        #expect(ChatSource.label("api_server") == "API" && ChatSource.label("bluebubbles") == "iMessage")
        #expect(ChatSource.label("home_lab-bot") == "Home Lab Bot")
        #expect(ChatSource.mark("telegram").mark == .brand("telegram") && ChatSource.mark("telegram").color == 0x26A5E4)
        #expect(ChatSource.mark("slack").mark == .letter("S") && ChatSource.mark("zulip").mark == .letter("Z"))
        #expect(ChatSource.folderLabel("oneshot") == "One-off Runs" && ChatSource.folderLabel("telegram") == "Telegram")
        #expect(ChatSource.hasFolder("oneshot") && ChatSource.hasFolder("telegram") && !ChatSource.hasFolder("tool"))
        #expect(ChatSource.folderLabel("cron") == "Scheduled Runs" && ChatSource.hasFolder("cron") && ChatSource.origin(source: "cron", handoffPlatform: nil, handoffState: nil) == nil)
        #expect(ChatSource.origin(source: "oneshot", handoffPlatform: nil, handoffState: nil) == nil)
        #expect(ChatSource.origin(source: "Telegram", handoffPlatform: nil, handoffState: nil) == "telegram")
        #expect(ChatSource.origin(source: "desktop", handoffPlatform: "discord", handoffState: "completed") == "discord")
        #expect(ChatSource.origin(source: "desktop", handoffPlatform: "discord", handoffState: "pending") == nil)
        #expect(ChatSource.origin(source: "tui", handoffPlatform: "cli", handoffState: "completed") == nil)
        #expect(ChatSource.origin(source: "desktop", handoffPlatform: nil, handoffState: nil) == nil)
    }

    @Test func sortByCreatedUsesStartedAt() {
        // "a" was touched last but started long ago; "b" started just now.
        let a = Self.chat("a", ago: 30, started: 86_400 * 2), b = Self.chat("b", ago: 600, started: 700)
        #expect(Self.ids(Self.run([a, b])) == ["a", "b"])
        let created = Self.run([a, b]) { $0.prefs.sortBy = .created }
        #expect(Self.ids(created) == ["b", "a"])
        // [sessions-fresh] One Recent run, no date headers.
        #expect(created.map(\.id) == [SessionListPipeline.recentId] && created.map(\.title) == ["Recent"])
    }

    /// [sessions-fresh] Sort By Status under Group By Recent ranks the one Recent run by status, then recency (date
    /// headers are gone, so nothing can pull an old group up).
    @Test func sortByStatusRanksRecent() {
        let day = 86_400.0
        let rows = [Self.chat("idle-now", ago: 60), Self.chat("idle-now2", ago: 120),
                    Self.chat("working-old", ago: day * 9 + 500, status: .working), Self.chat("idle-old", ago: day * 9),
                    Self.chat("working-now", ago: 300, status: .working)]
        let updated = Self.run(rows)
        #expect(updated.map(\.id) == [SessionListPipeline.recentId])
        #expect(Self.ids(updated) == ["idle-now", "idle-now2", "working-now", "idle-old", "working-old"])
        let status = Self.run(rows) { $0.prefs.sortBy = .status }
        #expect(status.map(\.id) == [SessionListPipeline.recentId])
        #expect(Self.ids(status) == ["working-now", "working-old", "idle-now", "idle-now2", "idle-old"])
        // Pinned still comes first, ranked by status too.
        let pinned = Self.run(rows + [Self.chat("pin-idle", ago: 10, pinned: true), Self.chat("pin-working", ago: day * 20, status: .working, pinned: true)]) {
            $0.prefs.sortBy = .status
        }
        #expect(pinned.map(\.title) == ["Pinned", "Recent"])
        #expect(pinned[0].sessions.map(\.id) == ["pin-working", "pin-idle"])
    }

    @Test func tokensAndCostAreOneUntitledRunWithPinnedFirst() {
        let rows = [Self.chat("small", tokens: 900, cost: 0.004), Self.chat("big", ago: 9_000, tokens: 1_500_000, cost: 12.5),
                    Self.chat("none", ago: 10), Self.chat("pin", ago: 99_000, tokens: 5, pinned: true)]
        let tokens = Self.run(rows) { $0.prefs.sortBy = .tokens }
        #expect(tokens.map(\.id) == ["pinned", SessionListPipeline.flatId] && tokens[1].title.isEmpty)
        #expect(Self.ids(tokens) == ["pin", "big", "small", "none"])
        let cost = Self.run(rows) { $0.prefs.sortBy = .cost; $0.prefs.groupBy = .status }
        #expect(cost.map(\.title) == ["Pinned", ""])                                   // Group By is ignored under a ranked sort
        #expect(Self.ids(cost) == ["pin", "big", "small", "none"])
        var prefs = SessionsViewPrefs()
        prefs.sortBy = .cost
        #expect(SessionListPipeline.isFlat(prefs))
    }

    @Test func sortByStatusRanksThenRecency() {
        let rows = [Self.chat("idle", ago: 1), Self.chat("draft", ago: 2, status: .draft), Self.chat("unread", ago: 3, status: .unread),
                    Self.chat("working", ago: 4, status: .working), Self.chat("needs", ago: 5, status: .needsInput),
                    Self.chat("working-newer", ago: 2, status: .working)]
        let sorted = SessionListPipeline.sort(rows, by: .status).map(\.id)
        #expect(sorted == ["needs", "working-newer", "working", "unread", "draft", "idle"])
    }

    @Test func groupByStatusIsWorkingThenDone() {
        let rows = [Self.chat("a"), Self.chat("b", ago: 500, status: .working), Self.chat("c", ago: 900, status: .needsInput),
                    Self.chat("d", ago: 20, status: .unread)]
        let groups = Self.run(rows) { $0.prefs.groupBy = .status }
        // [sessions-layout] The unread chat and the one waiting on you sit in New for You, above the status groups.
        #expect(groups.map(\.title) == [SessionListPipeline.newTitle, "Working", "Done"])
        #expect(groups.map(\.id) == [SessionListPipeline.newId, "status-working", "status-done"])
        #expect(groups.map { $0.sessions.map(\.id) } == [["d", "c"], ["b"], ["a"]])
        #expect(Self.run([Self.chat("a")]) { $0.prefs.groupBy = .status }.map(\.title) == ["Done"])
    }

    private static let projects: [String: [SessionProject]] = [
        "default": [SessionProject(id: "p1", label: "Reading", root: "/home/hermes/reading", paths: ["/home/hermes/reading"]),
                    SessionProject(id: "p2", label: "Site", root: "/home/hermes/site/", paths: ["/home/hermes/site"])],
        "research": [SessionProject(id: "r1", label: "Reading (research)", root: "/home/hermes/reading", paths: ["/home/hermes/reading"])],
    ]

    @Test func groupByProjectOrdersByNewestChatWithHomeLast() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default", "research"])
        #expect(entries.map(\.label) == ["Reading", "Site", "Home"])                    // one entry per folder, named by the first bot
        #expect(entries.map(\.key) == ["/home/hermes/reading", "/home/hermes/site", SessionProjects.homeKey])
        let rows = [Self.chat("home-new", ago: 5), Self.chat("site", ago: 100, cwd: "/home/hermes/site/src"),
                    Self.chat("reading", ago: 50, cwd: "/home/hermes/reading"),
                    Self.chat("reading-r", profile: "research", ago: 700, cwd: "/home/hermes/reading/notes")]
        let groups = Self.run(rows) {
            $0.prefs.groupBy = .project; $0.projectsByProfile = Self.projects; $0.projects = entries
            $0.openGroups = Set(entries.map { SessionListPipeline.projectPrefix + $0.key })
        }
        #expect(groups.map(\.title) == ["Reading", "Site", "Home"])
        #expect(groups[0].sessions.map(\.id) == ["reading", "reading-r"])
        #expect(groups.last?.sessions.map(\.id) == ["home-new"])
    }

    /// [sessions-fresh] Recent's Projects shows two, or every favorite when there are more (owner: three favorites,
    /// two shown); See All for the rest.
    @Test func recentProjectsShowEveryFavorite() {
        let three: [String: [SessionProject]] = ["default": ["a", "b", "c"].map {
            SessionProject(id: $0, label: $0.uppercased(), root: "/p/\($0)", paths: ["/p/\($0)"])
        }]
        let entries = SessionProjects.menuEntries(three, order: ["default"])
        let rows = ["a", "b", "c"].enumerated().map { Self.chat($1, ago: Double($0 + 1) * 60, cwd: "/p/\($1)") }
        func projects(_ favorites: Set<String>) -> [SessionGroup] {
            Self.run(rows) { $0.projectsByProfile = three; $0.projects = entries; $0.favoriteProjects = favorites }
                .filter { SessionListPipeline.isProject($0.id) }
        }
        #expect(projects([]).count == 2 && projects([])[0].projectsTotal == 3)
        #expect(projects(["/p/c"]).count == 2)
        let all = projects(["/p/a", "/p/b", "/p/c"])
        #expect(all.count == 3 && all[0].projectsAll)
    }

    /// Show › Project Chats in Recent off (tester, 2026-11-08): a project's chats stay on its card, Recent
    /// keeps Home's; with no Home chats Recent goes.
    @Test func projectChatsInRecentOffLeavesThemOnTheirCard() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default"])
        let rows = [Self.chat("site", ago: 60, cwd: "/home/hermes/site"), Self.chat("home", ago: 120)]
        func groups(_ inRecent: Bool, _ rows: [SessionSummary]) -> [SessionGroup] {
            Self.run(rows) { $0.projectsByProfile = Self.projects; $0.projects = entries; $0.prefs.projectChatsInRecent = inRecent }
        }
        func recent(_ groups: [SessionGroup]) -> [String]? { groups.first { $0.id == SessionListPipeline.recentId }?.sessions.map(\.id) }
        #expect(recent(groups(true, rows)) == ["site", "home"])
        let off = groups(false, rows)
        #expect(recent(off) == ["home"])
        #expect(off.first { SessionListPipeline.isProject($0.id) }?.total == 1)                // the card folds to its summary
        #expect(recent(groups(false, [rows[0]])) == nil)
        // Group By Project has no Recent; its groups don't change.
        let byProject = Self.run(rows) {
            $0.projectsByProfile = Self.projects; $0.projects = entries; $0.prefs.groupBy = .project; $0.prefs.projectChatsInRecent = false
        }
        #expect(byProject.map(\.total) == [1, 1])
    }

    @Test func filtersAreAndedAndUnknownProjectsNarrowNothing() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default"])
        let rows = [Self.chat("a", status: .unread, cwd: "/home/hermes/site"), Self.chat("b", profile: "research", status: .unread),
                    Self.chat("c", status: .working, cwd: "/home/hermes/site"), Self.chat("d", cwd: "/home/hermes/reading")]
        // [sessions-fresh] Recent lists every match once (the projects above it are shortcuts to some of them).
        func run(_ edit: @escaping (inout SessionListInput) -> Void) -> [String] {
            let groups = Self.run(rows) { $0.projectsByProfile = Self.projects; $0.projects = entries; edit(&$0) }
            return (groups.first { $0.id == SessionListPipeline.recentId }?.sessions.map(\.id) ?? []).sorted()
        }
        #expect(run { $0.prefs.statusFilter = [.unread] } == ["a", "b"])
        #expect(run { $0.prefs.statusFilter = [.unread, .working] } == ["a", "b", "c"])
        #expect(run { $0.prefs.statusFilter = [.unread]; $0.botFilter = "default" } == ["a"])
        #expect(run { $0.prefs.projectFilter = ["/home/hermes/site"] } == ["a", "c"])
        #expect(run { $0.prefs.projectFilter = [SessionProjects.homeKey] } == ["b"])
        #expect(run { $0.prefs.projectFilter = ["/home/hermes/site"]; $0.prefs.statusFilter = [.working] } == ["c"])
        #expect(run { $0.prefs.projectFilter = ["/gone"] } == ["a", "b", "c", "d"])       // C-07
        #expect(run { $0.botFilter = "nobody" }.isEmpty)
    }

    /// Show › Archived adds the archived chats to the list (2026-10-24: a tester read the Show checks as additive):
    /// they are sorted, grouped, pinned and filtered with the rest, and a chat in both is listed once.
    @Test func archivedJoinsTheList() {
        let live = [Self.chat("live"), Self.chat("both", ago: 120)]
        let archived = [Self.chat("old", ago: 86_400 * 90), Self.chat("older", ago: 86_400 * 200, pinned: true), Self.chat("both", ago: 120)]
        #expect(Self.ids(Self.run(live, archived: archived)) == ["live", "both"])
        let groups = Self.run(live, archived: archived) { $0.prefs.showArchived = true }
        #expect(groups.first?.id == "pinned" && groups.first?.sessions.map(\.id) == ["older"])
        #expect(groups.dropFirst().allSatisfy { !$0.title.isEmpty })                        // dated, not one flat run
        #expect(Self.ids(groups) == ["older", "live", "both", "old"])
        #expect(Self.ids(Self.run(live, archived: archived) { $0.prefs.showArchived = true; $0.botFilter = "nobody" }).isEmpty)
        var prefs = SessionsViewPrefs()
        prefs.showArchived = true
        #expect(!SessionListPipeline.isFlat(prefs))
    }

    @Test func twinsKeepBothRowsAndDuplicatesCollapse() {
        let rows = [Self.chat("same", profile: "a"), Self.chat("same", profile: "b", ago: 120), Self.chat("same", profile: "a", ago: 999)]
        #expect(Self.run(rows).flatMap(\.sessions).map(\.profile) == ["a", "b"])
    }

    @Test func badNumbersNeverBreakTheOrder() {
        var nan = Self.chat("nan", ago: 5); nan.cost = .nan
        var inf = Self.chat("inf", ago: 6); inf.cost = .infinity
        var none = Self.chat("none"); none.lastActive = nil
        let sorted = SessionListPipeline.sort([nan, inf, Self.chat("real", ago: 7, cost: 2), none], by: .cost).map(\.id)
        #expect(sorted.first == "real" && Set(sorted) == ["nan", "inf", "real", "none"])
        #expect(SessionListPipeline.sort([none, Self.chat("a")], by: .updated).map(\.id) == ["a", "none"])
    }

    // MARK: Folding groups (tester ivy, 2026-10-26)

    /// Every third chat unread unless `unread` is false.
    private static func projectRows(_ count: Int, cwd: String = "/home/hermes/site", from offset: Int = 0, unread: Bool = true) -> [SessionSummary] {
        (0..<count).map { chat("s\($0 + offset)", ago: Double($0 + offset + 1) * 60, status: unread && $0 % 3 == 0 ? .unread : .idle, cwd: cwd) }
    }

    @Test func aProjectDrawsItsNewestFiveThenShowMore() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default"])
        let rows = Self.projectRows(12, unread: false) + [Self.chat("home", ago: 30)]
        let site = "project-/home/hermes/site"
        let opened: Set<String> = [site, "project-home"]
        var groups = Self.run(rows) { $0.prefs.groupBy = .project; $0.projectsByProfile = Self.projects; $0.projects = entries; $0.openGroups = opened }
        let capped = groups.first { $0.id == site }!
        #expect(capped.sessions.map(\.id) == ["s0", "s1", "s2", "s3", "s4"])            // the newest five
        #expect(capped.total == 12 && capped.more == 7 && !capped.expanded && !capped.collapsed)
        let home = groups.first { $0.id == "project-home" }!
        #expect(home.sessions.map(\.id) == ["home"] && home.more == 0)                   // five or fewer: no Show More

        // Show More: every chat, in order, and the group says it can go back (Show Less).
        groups = Self.run(rows) {
            $0.prefs.groupBy = .project; $0.projectsByProfile = Self.projects; $0.projects = entries; $0.openGroups = opened; $0.expandedGroups = [site]
        }
        let open = groups.first { $0.id == site }!
        #expect(open.sessions.count == 12 && open.more == 0 && open.expanded)
        #expect(open.sessions.map(\.id) == (0..<12).map { "s\($0)" })
    }

    @Test func homeIsCappedLikeAnyProject() {
        let rows = (0..<8).map { Self.chat("h\($0)", ago: Double($0 + 1) * 60) }
        let groups = Self.run(rows) { $0.prefs.groupBy = .project; $0.openGroups = ["project-home"] }
        #expect(groups.map(\.id) == ["project-home"])
        #expect(groups[0].sessions.count == 5 && groups[0].more == 3)
    }

    @Test func aClosedGroupDrawsItsHeaderAloneWithItsCount() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default"])
        let rows = Self.projectRows(3, unread: false) + [Self.chat("pin", ago: 10, pinned: true)]
        let groups = Self.run(rows) {
            $0.prefs.groupBy = .project; $0.projectsByProfile = Self.projects; $0.projects = entries
            $0.collapsedGroups = ["pinned"]
        }
        #expect(groups.map(\.id) == ["pinned", "project-/home/hermes/site"])           // still listed, in place
        #expect(groups.allSatisfy { $0.collapsed && $0.sessions.isEmpty && $0.more == 0 })
        #expect(groups.map(\.total) == [1, 3])
        // A closed project that was opened with Show More stays closed (no Show Less row under a closed header).
        let both = Self.run(Self.projectRows(9, unread: false)) {
            $0.prefs.groupBy = .project; $0.projectsByProfile = Self.projects; $0.projects = entries
            $0.expandedGroups = ["project-/home/hermes/site"]
        }
        #expect(both[0].collapsed && both[0].sessions.isEmpty && !both[0].expanded)
    }

    /// [sessionsminimal] A status group folds; Recent doesn't ([sessions-fresh], as the date groups before it); neither
    /// is capped.
    @Test func statusGroupsFoldRecentDoesntAndNeitherIsCapped() {
        let rows = (0..<9).map { Self.chat("d\($0)", ago: Double($0 + 1) * 60, status: $0 < 7 ? .working : .idle) }
        var groups = Self.run(rows)
        #expect(groups.map(\.id) == [SessionListPipeline.recentId] && groups[0].sessions.count == 9 && groups[0].more == 0)
        #expect(!SessionListPipeline.folds(groups[0]))
        groups = Self.run(rows) { $0.collapsedGroups = [SessionListPipeline.recentId] }
        #expect(!groups[0].collapsed && groups[0].sessions.count == 9)
        groups = Self.run(rows) { $0.prefs.groupBy = .status; $0.collapsedGroups = ["status-done"] }
        #expect(groups.map(\.id) == ["status-working", "status-done"])
        #expect(groups[0].sessions.count == 7 && !groups[0].collapsed && groups[1].collapsed && groups[1].total == 2)
        // The untitled run (Sort By Tokens or Cost) has no header to fold.
        groups = Self.run(rows) { $0.prefs.sortBy = .tokens; $0.collapsedGroups = [SessionListPipeline.flatId] }
        #expect(groups.map(\.id) == [SessionListPipeline.flatId] && groups[0].sessions.count == 9 && !groups[0].collapsed)
        #expect(!SessionListPipeline.folds(groups[0]))
    }

    @Test func anActiveFilterShowsEveryMatchInClosedAndCappedGroups() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default"])
        let rows = Self.projectRows(9) + [Self.chat("pin", ago: 10, status: .unread, pinned: true)]
        func run(_ edit: (inout SessionListInput) -> Void) -> [SessionGroup] {
            Self.run(rows) {
                $0.prefs.groupBy = .project; $0.projectsByProfile = Self.projects; $0.projects = entries
                $0.collapsedGroups = ["pinned", "project-/home/hermes/site"]
                edit(&$0)
            }
        }
        // Status › Unread: the closed groups open to show their matches, uncapped.
        var groups = run { $0.prefs.statusFilter = [.unread] }
        #expect(groups.allSatisfy { !$0.collapsed && $0.more == 0 })
        #expect(Self.ids(groups) == ["pin", "s0", "s3", "s6"])
        // Project › Site: all nine, though the project is closed and has more than five ([sessions-layout] the three
        // unread ones in New for You above it; [project-cards] drawn in the project too).
        groups = run { $0.prefs.projectFilter = ["/home/hermes/site"] }
        #expect(groups.first { $0.id == SessionListPipeline.newId }?.sessions.map(\.id) == ["s0", "s3", "s6"])
        let site = groups.first { $0.id == "project-/home/hermes/site" }
        #expect(site?.sessions.count == 9 && site?.total == 9 && site?.unread == 3 && site?.more == 0)
        // A project filter naming no listed project narrows nothing, so it opens nothing either (C-07).
        groups = run { $0.prefs.projectFilter = ["/gone"] }
        #expect(groups.filter { $0.id != SessionListPipeline.newId }.allSatisfy { $0.collapsed })
    }

    // MARK: New for You and folded projects (owner, 2026-10-31)

    /// [sessions-layout] New for You: every unread chat and every chat waiting on the user, newest first, out of
    /// Pinned and the groups below; its newest three, then Show More. Not under a status filter or a flat sort, and
    /// [sessions-fresh] not under Group By Recent (its New chip lists them instead).
    @Test func newForYouLiftsUnreadAndWaitingChatsAboveEverything() {
        let rows = [Self.chat("idle", ago: 10), Self.chat("unread", ago: 60, status: .unread),
                    Self.chat("waits", ago: 30, status: .needsInput), Self.chat("pin-unread", ago: 90, status: .unread, pinned: true),
                    Self.chat("pin", ago: 20, pinned: true), Self.chat("old-unread", ago: 86_400 * 9, status: .unread)]
        #expect(Self.run(rows).map(\.id) == ["pinned", SessionListPipeline.recentId])
        func run(_ rows: [SessionSummary], _ edit: (inout SessionListInput) -> Void = { _ in }) -> [SessionGroup] {
            Self.run(rows) { $0.prefs.groupBy = .status; edit(&$0) }
        }
        let groups = run(rows)
        #expect(groups.map(\.id) == [SessionListPipeline.newId, "pinned", "status-done"])
        #expect(groups[0].title == SessionListPipeline.newTitle)
        #expect(groups[0].sessions.map(\.id) == ["waits", "unread", "pin-unread"] && groups[0].total == 4 && groups[0].more == 1)
        #expect(groups[1].sessions.map(\.id) == ["pin"] && groups[2].sessions.map(\.id) == ["idle"])
        // Show More draws all four.
        let open = run(rows) { $0.expandedGroups = [SessionListPipeline.newId] }
        #expect(open[0].sessions.map(\.id) == ["waits", "unread", "pin-unread", "old-unread"] && open[0].expanded)
        // A chat read since the page was last left stays where it was; then it goes back to its own group.
        var read = rows
        read[1].unread = false; read[1].status = .idle
        let kept = run(read) { $0.keepNew = [SessionListPipeline.key(read[1])]; $0.expandedGroups = [SessionListPipeline.newId] }
        #expect(kept[0].sessions.map(\.id) == ["waits", "unread", "pin-unread", "old-unread"])
        #expect(run(read)[0].sessions.map(\.id) == ["waits", "pin-unread", "old-unread"])
        // The Other Apps row comes after New for You and Pinned.
        let apps = run(rows) { $0.outside = [Self.outside("tg", "telegram", ago: 40)] }
        #expect(Array(apps.map(\.id).prefix(3)) == [SessionListPipeline.newId, "pinned", SessionListPipeline.otherAppsId])
        // A status filter or a flat sort lists them in place.
        #expect(!run(rows) { $0.prefs.statusFilter = [.unread] }.contains { $0.id == SessionListPipeline.newId })
        #expect(run(rows) { $0.prefs.sortBy = .tokens }.map(\.id) == ["pinned", SessionListPipeline.flatId])
        // Closed, it is its header alone with its count.
        let closed = run(rows) { $0.collapsedGroups = [SessionListPipeline.newId] }
        #expect(closed[0].collapsed && closed[0].sessions.isEmpty && closed[0].total == 4)
    }

    /// [sessions-layout] Group By Project: a project starts folded to its summary row (its count, its unread, its
    /// newest chat, its bots newest first) until opened; `collapsedGroups` no longer folds a project. A project counts
    /// its new chats, so it never vanishes while they are unread, and [project-cards] opened it draws them among its
    /// own as well (they are in New for You too).
    @Test func projectsStartFoldedToASummaryUntilOpened() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default", "research"])
        var newest = Self.chat("reading-r", profile: "research", ago: 100, cwd: "/home/hermes/reading/notes")
        newest.title = "Fix the header"
        let rows = [newest, Self.chat("reading-new", ago: 300, cwd: "/home/hermes/reading"),
                    Self.chat("reading-old", ago: 900, status: .unread, cwd: "/home/hermes/reading"), Self.chat("home", ago: 5)]
        let reading = SessionListPipeline.projectPrefix + "/home/hermes/reading"
        func run(_ edit: (inout SessionListInput) -> Void = { _ in }) -> [SessionGroup] {
            Self.run(rows) { $0.prefs.groupBy = .project; $0.projectsByProfile = Self.projects; $0.projects = entries; edit(&$0) }
        }
        let folded = run()
        #expect(folded.map(\.id) == [SessionListPipeline.newId, reading, "project-home"])
        #expect(folded[0].sessions.map(\.id) == ["reading-old"])
        let projects = Array(folded.dropFirst())
        #expect(projects.allSatisfy { $0.collapsed && $0.sessions.isEmpty && $0.more == 0 })
        let summary = projects[0]
        #expect(summary.total == 3 && summary.unread == 1 && summary.latestTitle == "Fix the header")
        #expect(summary.profiles == ["research", "default"] && summary.newest == Self.now.addingTimeInterval(-100))
        let open = run { $0.openGroups = [reading] }
        #expect(open[1].sessions.map(\.id) == ["reading-r", "reading-new", "reading-old"] && !open[1].collapsed)
        #expect(open[1].total == 3 && open[1].unread == 1 && open[1].more == 0 && !open[1].working)
        // Every chat in New for You: the project still draws all of them.
        let allNew = Self.run(rows.map { var s = $0; s.unread = true; return s }) {
            $0.prefs.groupBy = .project; $0.projectsByProfile = Self.projects; $0.projects = entries; $0.openGroups = [reading]
        }
        let kept = allNew.first { $0.id == reading }
        #expect(kept?.sessions.count == 3 && kept?.collapsed == false && kept?.total == 3 && kept?.unread == 3)
        let new = allNew.first { $0.id == SessionListPipeline.newId }
        #expect(new?.sessions.count == 3 && new?.more == 1)        // and New for You has all four, three then Show More
        #expect(open[2].collapsed)
        #expect(run { $0.openGroups = [reading]; $0.collapsedGroups = [reading] }[1].collapsed == false)
        // Under Group By Date the new chat moves out of its group instead.
        #expect(Self.run(rows).flatMap(\.sessions).filter { $0.id == "reading-old" }.count == 1)
        #expect(SessionListPipeline.isProject(reading) && !SessionListPipeline.isProject("pinned"))
        // [project-cards] A bot at work in a chat shows on the closed card.
        var busy = rows
        busy[1].isRunning = true
        let working = Self.run(busy) { $0.prefs.groupBy = .project; $0.projectsByProfile = Self.projects; $0.projects = entries }
        #expect(working.first { $0.id == reading }?.working == true && working.first { $0.id == "project-home" }?.working == false)
        // [project-cards] Under a bot chip the project says how many chats it holds under every bot.
        let chip = run { $0.botFilter = "default"; $0.openGroups = [reading] }
        let mine = chip.first { $0.id == reading }
        #expect(mine?.total == 2 && mine?.whole == 3 && mine?.profiles == ["default"])
        #expect(run().first { $0.id == reading }?.whole == nil)
    }

    @Test func closedGroupsAreKeptPerBotAndDecodeFromOlderFiles() throws {
        var state = SessionsDeviceState()
        state.collapsedGroups = ["*": ["pinned"], "research": ["project-home", "today"]]
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(SessionsDeviceState.self, from: data)
        #expect(back.collapsedGroups == state.collapsedGroups)
        let old = try JSONDecoder().decode(SessionsDeviceState.self, from: Data(#"{"showBackgroundRuns":true}"#.utf8))
        #expect(old.collapsedGroups.isEmpty && old.showBackgroundRuns)
    }

    /// STRESS (§14): 2,000 chats, 12 bots, 40 projects, every sort and grouping, repeatedly: stable and quick.
    @Test func twoThousandChatsSortAndGroupQuickly() {
        var rows: [SessionSummary] = []
        var projects: [String: [SessionProject]] = [:]
        for p in 0..<40 {
            projects["bot\(p % 12)", default: []].append(SessionProject(id: "p\(p)", label: "Project \(p)", root: "/w/p\(p)", paths: ["/w/p\(p)"]))
        }
        for i in 0..<2_000 {
            rows.append(Self.chat("c\(i)", profile: "bot\(i % 12)", ago: Double(i) * 977, started: Double(i) * 1_013 + 5, tokens: (i * 7_919) % 90_000,
                                  cost: Double((i * 31) % 500) / 100, status: SessionStatus.allCases[i % 5], pinned: i % 67 == 0,
                                  cwd: i % 3 == 0 ? nil : "/w/p\(i % 40)/src"))
        }
        let entries = SessionProjects.menuEntries(projects, order: (0..<12).map { "bot\($0)" })
        #expect(entries.count == 41)
        let clock = ContinuousClock()
        var first: [[String]] = []
        // [project-cards] Group By Project lists New for You's chats in their projects too.
        let twice = rows.filter { SessionListPipeline.isNew($0) && !$0.pinned }.count
        var again: [Int] = []
        let took = clock.measure {
            for round in 0..<3 {
                var out: [[String]] = []
                for sort in SessionSortBy.allCases {
                    for group in SessionGroupBy.allCases {
                        let groups = Self.run(rows) {
                            $0.prefs.sortBy = sort; $0.prefs.groupBy = group; $0.projectsByProfile = projects; $0.projects = entries
                            // Every project opened with Show More, so every chat is drawn.
                            $0.openGroups = Set(entries.map { SessionListPipeline.projectPrefix + $0.key })
                            $0.expandedGroups = Set(entries.map { SessionListPipeline.projectPrefix + $0.key }
                                + (0..<12).map { SessionListPipeline.botPrefix + "bot\($0)" }     // [manual-order] Group By Bot
                                + [SessionListPipeline.newId, "pinned", SessionListPipeline.projectsId])   // [sessions-fresh]
                        }
                        out.append(Self.ids(groups))
                        // [sessions-fresh] Group By Recent's projects are shortcuts to chats Recent lists too.
                        let shortcuts = group == .date ? groups.filter { SessionListPipeline.isProject($0.id) }.reduce(0) { $0 + $1.sessions.count } : 0
                        if round == 0 { again.append(group == .project && sort != .tokens && sort != .cost ? twice : shortcuts) }
                    }
                }
                if round == 0 { first = out } else { #expect(out == first) }           // the same order every time
            }
        }
        #expect(zip(first, again).allSatisfy { $0.count == 2_000 + $1 && Set($0).count == 2_000 })
        #expect(took < .seconds(20), "45 passes over 2,000 chats took \(took)")       // a hang guard only; the budget is below
    }

    /// The spec's budget (§3.5): 5,000 rows through the whole pipeline in under 50 ms on a phone. Here: one pass over
    /// 5,000 rows for each sort and grouping, the best of five (the Mac is shared and busy, so the best pass is the
    /// code's own cost), under 150 ms in a debug build on the simulator.
    @Test func fiveThousandChatsOnePassWithinBudget() {
        var rows: [SessionSummary] = []
        var projects: [String: [SessionProject]] = [:]
        for p in 0..<40 {
            projects["bot\(p % 12)", default: []].append(SessionProject(id: "p\(p)", label: "Project \(p)", root: "/w/p\(p)", paths: ["/w/p\(p)"]))
        }
        for i in 0..<5_000 {
            rows.append(Self.chat("c\(i)", profile: "bot\(i % 12)", ago: Double(i) * 977, started: Double(i) * 1_013 + 5, tokens: (i * 7_919) % 90_000,
                                  cost: Double((i * 31) % 500) / 100, status: SessionStatus.allCases[i % 5], pinned: i % 67 == 0,
                                  cwd: i % 3 == 0 ? nil : "/w/p\(i % 40)/src"))
        }
        let entries = SessionProjects.menuEntries(projects, order: (0..<12).map { "bot\($0)" })
        let clock = ContinuousClock()
        for sort in SessionSortBy.allCases {
            for group in SessionGroupBy.allCases {
                var best = Duration.seconds(3_600)
                var groups: [SessionGroup] = []
                for _ in 0..<5 {
                    let took = clock.measure {
                        groups = Self.run(rows) {
                            $0.prefs.sortBy = sort; $0.prefs.groupBy = group; $0.projectsByProfile = projects; $0.projects = entries
                        }
                    }
                    best = min(best, took)
                }
                // [sessions-fresh] Group By Recent's projects are shortcuts to chats Recent lists too.
                let counted = group == .date ? groups.filter { !SessionListPipeline.isProject($0.id) } : groups
                let count = counted.reduce(0) { $0 + max($1.total, $1.sessions.count) }      // a capped project counts its all
                // [sessions-layout] A project counts its chats in New for You as well (it draws them there only).
                let flat = sort == .tokens || sort == .cost
                let twice = group == .project && !flat ? rows.filter { SessionListPipeline.isNew($0) && !$0.pinned }.count : 0
                #expect(count - twice == 5_000)
                #expect(best < .milliseconds(150), "5,000 chats, Sort By \(sort), Group By \(group): best of five \(best)")
            }
        }
    }
}
