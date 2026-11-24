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
        input.openGroups = [SessionListPipeline.recentOlderId]     // [sessions-shape] Older starts closed: open here
        edit(&input)
        return SessionListPipeline.groups(input)
    }

    private static func ids(_ groups: [SessionGroup]) -> [String] { groups.flatMap(\.sessions).map(\.id) }
    /// [sessions-shape] Recent's chats, whichever days they are split into.
    private static func recent(_ groups: [SessionGroup]) -> [String] { ids(groups.filter { SessionListPipeline.isRecent($0.id) }) }
    /// The day a chat minutes old is under: the fixed "today" here is midnight, so that is Yesterday's.
    private static let today = SessionListPipeline.recentId + "-yesterday"

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
        // [three-piles] Group By Project: the projects, then the row; the pinned Discord chat is no project's.
        #expect(groups.map(\.id) == ["project-home", SessionListPipeline.otherAppsId] && groups[0].total == 1)
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
        // [sessions-shape] Recent by the day it was started.
        #expect(created.map(\.id) == [Self.today, "recent-week"] && created.map(\.title) == ["Yesterday", "This Week"])
    }

    /// [sessions-fresh] Sort By Status under Group By Recent ranks the one Recent run by status, then recency (date
    /// headers are gone, so nothing can pull an old group up).
    @Test func sortByStatusRanksRecent() {
        let day = 86_400.0
        let rows = [Self.chat("idle-now", ago: 60), Self.chat("idle-now2", ago: 120),
                    Self.chat("working-old", ago: day * 9 + 500, status: .working), Self.chat("idle-old", ago: day * 9),
                    Self.chat("working-now", ago: 300, status: .working)]
        let updated = Self.run(rows)
        #expect(updated.map(\.id) == [Self.today, SessionListPipeline.recentOlderId])
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

    /// [projects-all-bots] Owner 2026-11-22: a project with no chat yet (made a moment ago, on any bot) is on the
    /// Projects side too, after the ones with chats and before Home; a status filter or a picked project leaves it out,
    /// an archived one stays hidden, and a folder Hermes found on the disk by itself waits for a chat.
    @Test func groupByProjectListsAProjectWithNoChatYet() {
        var projects = Self.projects
        projects["atlas"] = [SessionProject(id: "a1", label: "Side Gig", root: "/home/hermes/sidegig", paths: ["/home/hermes/sidegig"])]
        let entries = SessionProjects.menuEntries(projects, order: ["default", "research", "atlas"])
        let rows = [Self.chat("home-new", ago: 5), Self.chat("site", ago: 100, cwd: "/home/hermes/site/src")]
        func run(_ change: (inout SessionListInput) -> Void = { _ in }) -> [SessionGroup] {
            Self.run(rows) {
                $0.prefs.groupBy = .project; $0.projectsByProfile = projects; $0.projects = entries
                change(&$0)
            }
        }
        let groups = run()
        #expect(groups.map(\.title) == ["Site", "Reading", "Side Gig", "Home"])
        #expect(groups.first { $0.title == "Side Gig" }.map { $0.sessions.isEmpty && $0.total == 0 } == true)
        #expect(!run { $0.prefs.statusFilter = [.unread] }.contains { $0.title == "Side Gig" })
        #expect(!run { $0.prefs.projectFilter = ["/home/hermes/site"] }.contains { $0.title == "Side Gig" })
        #expect(!run { $0.archivedProjects = ["/home/hermes/sidegig"]; $0.prefs.pills = .projects }.contains { $0.title == "Side Gig" })
        // A folder Hermes found by itself is no saved project: it shows once a chat is in it.
        var found = projects
        found["atlas"]?[0].isAuto = true
        #expect(!Self.run(rows) {
            $0.prefs.groupBy = .project; $0.projectsByProfile = found; $0.projects = entries
        }.contains { $0.title == "Side Gig" })
    }

    /// [sessions-shape] Group By Recent's Projects is a shortcut: the starred projects (the newest two while none is
    /// starred), no See All; a filter narrowing the list shows every project it finds. Recent lists every chat.
    /// [chats-projects] All of it with Show › Projects on (`theChatsSideHasNoProjectsUnlessShown`).
    @Test func recentShowsTheStarredProjects() {
        let three: [String: [SessionProject]] = ["default": ["a", "b", "c"].map {
            SessionProject(id: $0, label: $0.uppercased(), root: "/p/\($0)", paths: ["/p/\($0)"])
        }]
        let entries = SessionProjects.menuEntries(three, order: ["default"])
        let rows = ["a", "b", "c"].enumerated().map { Self.chat($1, ago: Double($0 + 1) * 60, status: $1 == "c" ? .unread : .idle, cwd: "/p/\($1)") }
            + [Self.chat("home", ago: 600)]
        func groups(_ edit: (inout SessionListInput) -> Void = { _ in }) -> [SessionGroup] {
            Self.run(rows) { $0.projectsByProfile = three; $0.projects = entries; $0.prefs.showProjects = true; edit(&$0) }
        }
        // [bot-home] Home ends the block (`aBotsHomeEndsItsProjects`); the projects themselves:
        func projects(_ groups: [SessionGroup]) -> [String] {
            groups.compactMap { SessionListPipeline.projectKey($0.id) }.filter { $0 != SessionProjects.homeKey }
        }
        #expect(groups().compactMap { SessionListPipeline.projectKey($0.id) } == ["/p/a", "/p/b", SessionProjects.homeKey])
        #expect(projects(groups()) == ["/p/a", "/p/b"])                                         // none starred: the newest two
        #expect(projects(groups { $0.favoriteProjects = ["/p/c"] }) == ["/p/c"])
        #expect(projects(groups { $0.favoriteProjects = ["/p/a", "/p/b", "/p/c"] }) == ["/p/a", "/p/b", "/p/c"])
        #expect(groups().allSatisfy { $0.projectsTotal == nil })                                 // no See All
        #expect(projects(groups { $0.favoriteProjects = ["/p/a"]; $0.prefs.statusFilter = [.unread] }) == ["/p/c"])
        #expect(Self.recent(groups { $0.favoriteProjects = ["/p/c"] }) == ["a", "b", "c", "home"])
        // Show › Project Chats in Recent off: the shown projects' chats stay on their rows; the others' are listed.
        #expect(Self.recent(groups { $0.favoriteProjects = ["/p/c"]; $0.prefs.projectChatsInRecent = false }) == ["a", "b", "home"])
        // A closed project here draws no chat under its row (that is the Projects side's).
        #expect(groups { $0.liveUnderProjects = true }.filter { SessionListPipeline.isProject($0.id) }.allSatisfy { $0.collapsed && $0.sessions.isEmpty })
    }

    /// [bot-home] "Projects" ends with Home: the chats in no project (pinned ones counted), closed to its row, which
    /// opens their page. Under a bot's pill it is that bot's, under All every bot's. Its chats stay in the days below.
    /// Not with no project shown, nor under a filter.
    @Test func aBotsHomeEndsItsProjects() {
        let pinned = Self.chat("loose-pin", ago: 180, status: .unread, pinned: true)
        let rows = [Self.chat("site", ago: 60, cwd: "/home/hermes/site"), Self.chat("loose", ago: 120), pinned,
                    Self.chat("theirs", profile: "research", ago: 30),
                    Self.chat("reading-r", profile: "research", ago: 90, cwd: "/home/hermes/reading")]
        func run(_ bot: String?, _ live: [SessionSummary] = rows, _ edit: (inout SessionListInput) -> Void = { _ in }) -> [SessionGroup] {
            Self.run(live) {
                $0.projectsByProfile = Self.projects; $0.botFilter = bot; $0.prefs.showProjects = true   // [chats-projects]
                // The store's list: the picked bot's projects alone, every bot's under All.
                $0.projects = SessionProjects.menuEntries(bot.flatMap { bot in Self.projects[bot].map { [bot: $0] } } ?? Self.projects,
                                                          order: ["default", "research"])
                edit(&$0)
            }
        }
        let homeId = SessionListPipeline.projectPrefix + SessionProjects.homeKey
        let mine = run("default")
        #expect(mine.map(\.id) == ["pinned", "project-/home/hermes/site", homeId, Self.today])
        let home = mine[2]
        #expect(home.title == "Home" && home.collapsed && home.sessions.isEmpty)
        #expect(home.total == 2 && home.unread == 1 && home.profiles == ["default"] && home.whole == nil)   // the pinned one counts; no "of N"
        #expect(home.latestTitle == "loose" && !home.favorite)
        #expect(mine[1].whole == 1)                                                              // a project still says its whole
        // Home's chats stay in the days below, with Project Chats in Recent off too.
        #expect(Self.recent(mine) == ["site", "loose"])
        #expect(Self.recent(run("default") { $0.prefs.projectChatsInRecent = false }) == ["loose"])
        // The other bot's Home is its own.
        let theirs = run("research")
        #expect(theirs.map(\.id) == ["project-/home/hermes/reading", homeId, Self.today] && theirs[1].total == 1 && theirs[1].profiles == ["research"])
        // Under All it is every bot's, one bucket.
        let everyones = run(nil)
        #expect(everyones.map(\.id) == ["pinned", "project-/home/hermes/site", "project-/home/hermes/reading", homeId, Self.today])
        #expect(everyones[3].total == 3 && everyones[3].profiles == ["research", "default"] && everyones[3].whole == nil && everyones[3].collapsed)
        // No project shown: the days are Home alone, and no row repeats them.
        #expect(run("default", [Self.chat("loose", ago: 120)]).map(\.id) == [Self.today])
        // A bot with projects and no chat outside them has no Home row.
        #expect(!run("default", [Self.chat("site", ago: 60, cwd: "/home/hermes/site")]).contains { $0.id == homeId })
        // "Projects" closed counts it with the projects, as Group By Project does.
        let closed = run("default") { $0.collapsedGroups = [SessionListPipeline.projectsId] }
        #expect(closed.map(\.id) == ["pinned", SessionListPipeline.projectsId, Self.today] && closed[1].total == 2 && closed[1].unread == 1)
        // A filter narrowing the list: no Home row (it would open and list every match again over the days, which
        // list them already); the projects it finds show as before.
        let unread = run("default", rows + [Self.chat("site-new", ago: 45, status: .unread, cwd: "/home/hermes/site"),
                                            Self.chat("loose-new", ago: 50, status: .unread)]) { $0.prefs.statusFilter = [.unread] }
        #expect(unread.map(\.id) == ["pinned", "project-/home/hermes/site", Self.today])
        #expect(Self.recent(unread) == ["site-new", "loose-new"])
        #expect(run("default") { $0.prefs.statusFilter = [.unread] }.map(\.id) == ["pinned"])
        #expect(!run("default") { $0.prefs.projectFilter = ["/home/hermes/site"] }.contains { $0.id == homeId })
        // The row's page: Home kept to the bot (the Projects side with the bot still picked).
        let page = run("default") { $0.prefs.pills = .projects; $0.prefs.projectFilter = [SessionProjects.homeKey] }
        #expect(page.map(\.id) == ["page", "state-pinned", "state-active"])
        #expect(page[0].pageKey == SessionProjects.homeKey && page[0].latestTitle == "Home" && page[0].total == 2 && page[0].profiles == ["default"])
        #expect(page[1].sessions.map(\.id) == ["loose-pin"] && page[2].sessions.map(\.id) == ["loose"])
        // Without the bot it is every bot's, as the Projects side's Home has been.
        let whole = run(nil) { $0.prefs.pills = .projects; $0.prefs.projectFilter = [SessionProjects.homeKey] }
        #expect(Set(Self.ids(whole)) == ["loose", "loose-pin", "theirs"])
        // Home's line on its page: what it is and whose, never its key as a folder nor a stray branch.
        #expect(ProjectPageHeader.meta(folder: SessionProjects.homeKey, branch: "main", bots: ["Otto"]) == "No project · Otto")
        #expect(ProjectPageHeader.meta(folder: SessionProjects.homeKey, branch: nil, bots: []) == "No project")
        // The Mac's pop-up button over that page says Home (it had no pill to name, so it said All Projects).
        let labels = [(key: "/home/hermes/site", label: "Site")]
        #expect(SessionsHeaderModel.scopeTitle(projects: true, pickedProjects: [SessionProjects.homeKey], labels: labels, bot: "Otto") == "Home")
        #expect(SessionsHeaderModel.scopeTitle(projects: true, pickedProjects: ["/home/hermes/site"], labels: labels, bot: nil) == "Site")
        #expect(SessionsHeaderModel.scopeTitle(projects: true, pickedProjects: [], labels: labels, bot: nil) == "All Projects")
        #expect(SessionsHeaderModel.scopeTitle(projects: true, pickedProjects: ["/gone"], labels: labels, bot: nil) == "All Projects")
        #expect(SessionsHeaderModel.scopeTitle(projects: false, pickedProjects: [], labels: labels, bot: "Otto") == "Otto")
        #expect(SessionsHeaderModel.scopeTitle(projects: false, pickedProjects: [], labels: labels, bot: nil) == "All Bots")
    }

    /// [chats-projects] A tester, 2026-11-20: projects on both sides of the switch confused. Off by default, the Chats side
    /// (Group By Recent) draws no project, starred, newest or found by a filter: Pinned, then every chat in Recent's
    /// days (Project Chats in Recent off changes nothing then). Show › Projects brings the shortcut back; the Projects
    /// side is the same either way.
    @Test func theChatsSideHasNoProjectsUnlessShown() {
        let three: [String: [SessionProject]] = ["default": ["a", "b", "c"].map {
            SessionProject(id: $0, label: $0.uppercased(), root: "/p/\($0)", paths: ["/p/\($0)"])
        }]
        let entries = SessionProjects.menuEntries(three, order: ["default"])
        let rows = [Self.chat("a", ago: 60, pinned: true, cwd: "/p/a"), Self.chat("b", ago: 120, status: .unread, cwd: "/p/b"),
                    Self.chat("c", ago: 180, cwd: "/p/c"), Self.chat("home", ago: 300)]
        func run(_ edit: (inout SessionListInput) -> Void = { _ in }) -> [SessionGroup] {
            Self.run(rows) { $0.projectsByProfile = three; $0.projects = entries; edit(&$0) }
        }
        func projects(_ groups: [SessionGroup]) -> [SessionGroup] { groups.filter { SessionListPipeline.isProject($0.id) } }
        #expect(!SessionsViewPrefs().showProjects)
        let plain = run()
        #expect(plain.map(\.id) == ["pinned", Self.today])
        #expect(plain[0].sessions.map(\.id) == ["a"] && Self.recent(plain) == ["b", "c", "home"])
        #expect(projects(run { $0.favoriteProjects = ["/p/c"] }).isEmpty)                       // starred: still none
        #expect(projects(run { $0.prefs.statusFilter = [.unread] }).isEmpty)                   // a filter finds none
        #expect(Self.recent(run { $0.prefs.statusFilter = [.unread] }) == ["b"])
        #expect(Self.recent(run { $0.prefs.projectFilter = ["/p/c"] }) == ["c"] && projects(run { $0.prefs.projectFilter = ["/p/c"] }).isEmpty)
        #expect(Self.recent(run { $0.prefs.projectChatsInRecent = false }) == ["b", "c", "home"])  // nothing above to keep them
        #expect(!run { $0.collapsedGroups = [SessionListPipeline.projectsId] }.contains { $0.id == SessionListPipeline.projectsId })
        // Shown: the newest two again, above Recent.
        let shown = run { $0.prefs.showProjects = true }
        #expect(shown.map(\.id) == ["pinned", "project-/p/a", "project-/p/b",
                                     SessionListPipeline.projectPrefix + SessionProjects.homeKey, Self.today])   // [bot-home] Home ends them
        #expect(Self.recent(shown) == ["b", "c", "home"])
        // The Projects side does not read it.
        let side = run { $0.prefs.groupBy = .project }.map(\.id)
        #expect(side == run { $0.prefs.groupBy = .project; $0.prefs.showProjects = true }.map(\.id) && side.contains("project-/p/a"))
    }

    /// [sessions-shape] Recent, sorted by a date, is split by the day: Today, Yesterday, This Week, Older. Older starts
    /// closed under the newer days (never as the only one) and opens; each day folds. Any other sort keeps one Recent.
    @Test func recentIsSplitByTheDay() {
        let day = 86_400.0
        // It is noon (twelve hours after the fixed midnight): two chats this morning, one late last night, and so on.
        // The days are the calendar's, as a row's own time says them.
        let rows = [Self.chat("now", ago: -39_600), Self.chat("earlier", ago: -3_600), Self.chat("yesterday", ago: 60),
                    Self.chat("week", ago: 2 * day + 60), Self.chat("week2", ago: 5 * day + 60), Self.chat("old", ago: 6 * day + 60),
                    Self.chat("older", ago: 90 * day)]
        func run(_ live: [SessionSummary] = rows, _ edit: (inout SessionListInput) -> Void = { _ in }) -> [SessionGroup] {
            Self.run(live) { $0.openGroups = []; $0.now = Self.now.addingTimeInterval(43_200); edit(&$0) }
        }
        var groups = run()
        #expect(groups.map(\.id) == ["recent-today", "recent-yesterday", "recent-week", "recent-older"])
        #expect(groups.map(\.title) == ["Today", "Yesterday", "This Week", "Older"])
        #expect(groups.map { $0.sessions.map(\.id) } == [["now", "earlier"], ["yesterday"], ["week", "week2"], []])
        #expect(groups[3].collapsed && groups[3].total == 2 && groups.allSatisfy { SessionListPipeline.folds($0) })
        groups = run { $0.openGroups = [SessionListPipeline.recentOlderId]; $0.collapsedGroups = ["recent-today"] }
        #expect(groups[3].sessions.map(\.id) == ["old", "older"] && !groups[3].collapsed)
        #expect(groups[0].collapsed && groups[0].total == 2)
        // Older alone is open; closed by hand it closes.
        #expect(run(Array(rows.suffix(2))).map(\.collapsed) == [false])
        #expect(run(Array(rows.suffix(2))) { $0.collapsedGroups = [SessionListPipeline.recentOlderId] }.map(\.collapsed) == [true])
        // A status filter shows every match.
        #expect(run { $0.prefs.statusFilter = [.idle] }.allSatisfy { !$0.collapsed })
        // Sort By Status, or Manual: one Recent.
        #expect(run { $0.prefs.sortBy = .status }.map(\.id) == [SessionListPipeline.recentId])
        #expect(run { $0.prefs.sortBy = .manual }.map(\.title) == ["Recent"])
    }

    /// [sessions-shape] On the Projects side (a project's row opens its page) a closed project keeps its live chats
    /// under its row: waiting on the owner first, then a reply not read, then at work, three at most. Its counts are
    /// of every chat. Not while a project opens in place.
    @Test func aClosedProjectKeepsItsLiveChatsUnderItsRow() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default"])
        let site = "/home/hermes/site"
        let rows = [Self.chat("quiet", ago: 10, cwd: site), Self.chat("working", ago: 20, status: .working, cwd: site),
                    Self.chat("new", ago: 300, status: .unread, cwd: site), Self.chat("needs", ago: 900, status: .needsInput, cwd: site),
                    Self.chat("working2", ago: 30, status: .working, cwd: site), Self.chat("calm", ago: 5, cwd: "/home/hermes/reading"),
                    Self.chat("loose", ago: 40, status: .unread)]
        func run(_ edit: (inout SessionListInput) -> Void = { _ in }) -> [SessionGroup] {
            Self.run(rows) {
                $0.projectsByProfile = Self.projects; $0.projects = entries; $0.prefs.groupBy = .project; $0.liveUnderProjects = true; edit(&$0)
            }
        }
        let groups = run()
        #expect(groups.map(\.id) == ["project-" + site, "project-/home/hermes/reading", "project-home"])
        #expect(groups.allSatisfy { $0.collapsed })
        #expect(groups[0].sessions.map(\.id) == ["needs", "new", "working"] && groups[0].total == 5 && groups[0].unread == 1)
        #expect(groups[1].sessions.isEmpty && groups[2].sessions.map(\.id) == ["loose"])
        // Opened in place (the tests' way), or without the switch: as before.
        #expect(run { $0.openGroups = ["project-" + site] }[0].sessions.count == 5)
        #expect(run { $0.liveUnderProjects = false }.allSatisfy { $0.sessions.isEmpty })
    }

    /// [pinned-in-project] A pinned chat stays inside its project, so pinning a project's only chat keeps the project.
    /// [three-piles] Group By Project is the projects alone: no Pinned above them, and Home's pinned chats are in
    /// Home. Group By Recent: Pinned, the projects' shortcut, then every other chat by the day.
    @Test func aPinnedChatStaysInItsProject() {
        let three: [String: [SessionProject]] = ["default": ["a", "b", "c"].map {
            SessionProject(id: $0, label: $0.uppercased(), root: "/p/\($0)", paths: ["/p/\($0)"])
        }]
        let entries = SessionProjects.menuEntries(three, order: ["default"])
        // Project A's only chat is pinned; so is one of Home's.
        let rows = [Self.chat("a", ago: 60, pinned: true, cwd: "/p/a"), Self.chat("b", ago: 120, cwd: "/p/b"),
                    Self.chat("c", ago: 180, cwd: "/p/c"), Self.chat("home-pin", ago: 30, pinned: true), Self.chat("home", ago: 300)]
        func run(_ group: SessionGroupBy? = nil, _ live: [SessionSummary] = rows) -> [SessionGroup] {
            Self.run(live) {
                $0.projectsByProfile = three; $0.projects = entries; $0.prefs.showProjects = true    // [chats-projects]
                $0.openGroups = Set(entries.map { SessionListPipeline.projectPrefix + $0.key })
                if let group { $0.prefs.groupBy = group }
            }
        }
        let recent = run()
        // A is still there. [bot-home] Home ends the block, its pinned chat in it (and in Pinned), as a project's.
        #expect(recent.map(\.id) == ["pinned", "project-/p/a", "project-/p/b", "project-home", Self.today])
        #expect(recent[0].sessions.map(\.id) == ["home-pin", "a"] && recent[1].sessions.map(\.id) == ["a"])
        #expect(recent[3].sessions.map(\.id) == ["home-pin", "home"])
        #expect(recent[4].sessions.map(\.id) == ["b", "c", "home"])

        let byProject = run(.project)
        #expect(byProject.map(\.title) == ["A", "B", "C", "Home"])
        #expect(byProject[0].sessions.map(\.id) == ["a"] && byProject.last?.sessions.map(\.id) == ["home-pin", "home"])

        // Every chat pinned: the project is still listed, and Home with its pinned chat alone under Group By Project.
        // [projects-all-bots] B and C, with no chat here, are listed too (after the ones with chats, before Home).
        #expect(run(.project, [Self.chat("a", ago: 60, pinned: true, cwd: "/p/a")]).map(\.id) == ["project-/p/a", "project-/p/b", "project-/p/c"])
        #expect(run(.project, [Self.chat("home-pin", pinned: true)]).map(\.id) == ["project-/p/a", "project-/p/b", "project-/p/c", "project-home"])
        #expect(run(nil, [Self.chat("a", ago: 60, pinned: true, cwd: "/p/a")]).map(\.id) == ["pinned", "project-/p/a"])
    }

    /// [sessions-collapse] Group By Recent: Pinned closes (no See All under a closed header), and "Projects" closes
    /// the projects shown to one closed header counting them and their unread chats; a filter opens them again.
    @Test func recentPinnedAndProjectsClose() {
        let three: [String: [SessionProject]] = ["default": ["a", "b", "c"].map {
            SessionProject(id: $0, label: $0.uppercased(), root: "/p/\($0)", paths: ["/p/\($0)"])
        }]
        let entries = SessionProjects.menuEntries(three, order: ["default"])
        var rows = ["a", "b", "c"].enumerated().map { Self.chat($1, ago: Double($0 + 1) * 60, status: $1 == "b" ? .unread : .idle, cwd: "/p/\($1)") }
        rows += (0..<5).map { Self.chat("pin\($0)", ago: Double($0 + 10) * 60, pinned: true) }
        rows.append(Self.chat("home", ago: 3_600))
        func run(_ closed: Set<String>, _ edit: (inout SessionListInput) -> Void = { _ in }) -> [SessionGroup] {
            Self.run(rows) {
                $0.projectsByProfile = three; $0.projects = entries; $0.collapsedGroups = closed
                $0.prefs.showProjects = true                                       // [chats-projects]
                edit(&$0)
            }
        }
        let open = run([])
        #expect(open.map(\.id) == ["pinned", "project-/p/a", "project-/p/b", "project-home", Self.today])   // [bot-home] Home ends them
        #expect(open[0].more == 2)
        let closed = run(["pinned", SessionListPipeline.projectsId])
        #expect(closed.map(\.id) == ["pinned", SessionListPipeline.projectsId, Self.today])
        #expect(closed[0].collapsed && closed[0].sessions.isEmpty && closed[0].more == 0 && closed[0].total == 5)
        let projects = closed[1]
        // [bot-home] Home is counted with them, as under Group By Project below.
        #expect(projects.collapsed && projects.title == "Projects" && projects.total == 3 && projects.unread == 1)
        #expect(SessionListPipeline.folds(projects))
        #expect(!closed[2].collapsed)
        // Group By Project: every project (Home's too) under the one closed header.
        let byProject = run([SessionListPipeline.projectsId]) { $0.prefs.groupBy = .project }
        #expect(byProject.map(\.id) == [SessionListPipeline.projectsId] && byProject[0].total == 4)
        // A status filter shows every match.
        let filtered = run(["pinned", SessionListPipeline.projectsId]) { $0.prefs.statusFilter = [.unread] }
        #expect(!filtered.contains { $0.id == SessionListPipeline.projectsId || $0.collapsed })
    }

    @Test func filtersAreAndedAndUnknownProjectsNarrowNothing() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default"])
        let rows = [Self.chat("a", status: .unread, cwd: "/home/hermes/site"), Self.chat("b", profile: "research", status: .unread),
                    Self.chat("c", status: .working, cwd: "/home/hermes/site"), Self.chat("d", cwd: "/home/hermes/reading")]
        // [sessions-fresh] Recent lists every match once (the projects above it are shortcuts to some of them).
        func run(_ edit: @escaping (inout SessionListInput) -> Void) -> [String] {
            let groups = Self.run(rows) { $0.projectsByProfile = Self.projects; $0.projects = entries; edit(&$0) }
            return Self.recent(groups).sorted()
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

    /// [project-pills] New and Working count the project pill's project, and only while the pills are the projects.
    @Test func statusChipsCountTheProjectPill() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default"])
        let rows = [Self.chat("a", status: .working, cwd: "/home/hermes/site"), Self.chat("b", status: .working),
                    Self.chat("c", status: .unread, cwd: "/home/hermes/site")]
        func counts(_ pills: SessionPills) -> [SessionStatusChip: Int] {
            var input = SessionListInput(live: rows, now: Self.now, calendar: Self.calendar)
            input.projectsByProfile = Self.projects; input.projects = entries
            input.prefs.pills = pills; input.prefs.projectFilter = ["/home/hermes/site"]
            return SessionListPipeline.chipCounts(input)
        }
        #expect(counts(.projects) == [.working: 1, .new: 1])
        #expect(counts(.bots) == [.working: 2, .new: 1])
        // A picked project pill opens its page (`aProjectPillOpensTheProjectPage`): each chat once, in its section.
        func groups(_ pills: SessionPills) -> [String: [String]] {
            let out = Self.run(rows) {
                $0.projectsByProfile = Self.projects; $0.projects = entries
                $0.prefs.pills = pills; $0.prefs.projectFilter = ["/home/hermes/site"]
            }
            return Dictionary(out.map { ($0.id, $0.sessions.map(\.id).sorted()) }, uniquingKeysWith: { a, _ in a })
        }
        #expect(groups(.projects)[Self.today] == nil)
        #expect(groups(.projects)["state-active"] == ["a", "c"])
        #expect(groups(.bots)[Self.today] == ["a", "c"])
    }

    /// [project-pills] A project's state comes from its chats; an archived project's chats leave the list (any
    /// pills, Show › Archived off) and its counts, unless it is the picked pill.
    @Test func projectStatesAndArchivedProjects() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default"])
        let rows = [Self.chat("a", status: .working, cwd: "/home/hermes/site"), Self.chat("b", status: .needsInput, cwd: "/home/hermes/site"),
                    Self.chat("c", status: .unread, cwd: "/home/hermes/reading"), Self.chat("d")]
        let states = SessionProjects.states(rows, projectsByProfile: Self.projects)
        #expect(states["/home/hermes/site"] == [.working, .needsYou] && states["/home/hermes/reading"] == [.ready] && states[SessionProjects.homeKey] == nil)
        func listed(_ edit: (inout SessionListInput) -> Void) -> [String] {
            Self.ids(Self.run(rows) {
                $0.projectsByProfile = Self.projects; $0.projects = entries; $0.prefs.pills = .projects
                $0.archivedProjects = ["/home/hermes/site"]
                $0.openGroups = ["project-/home/hermes/site", "project-/home/hermes/reading", "project-home"]; edit(&$0)
            }).sorted()
        }
        #expect(Set(listed { _ in }) == ["c", "d"])
        #expect(Set(listed { $0.prefs.showArchived = true }) == ["a", "b", "c", "d"])
        #expect(Set(listed { $0.prefs.projectFilter = ["/home/hermes/site"] }) == ["a", "b"])
        #expect(Set(listed { $0.prefs.pills = .bots }) == ["c", "d"])                 // bot pills too (owner 2026-11-23)
        // Group By Project's cards in the pills' order: what needs the owner first, Home last.
        let cards = Self.run(rows) {
            $0.projectsByProfile = Self.projects; $0.projects = entries; $0.prefs.groupBy = .project
        }.filter { SessionListPipeline.isProject($0.id) }.map(\.id)
        #expect(cards == ["project-/home/hermes/site", "project-/home/hermes/reading", "project-home"])
        // [three-piles] Home is last even when a chat of its own waits on the owner, until it is given a place (Reorder).
        func homePlace(_ order: [String]) -> Int? {
            Self.run(rows + [Self.chat("e", status: .needsInput)]) {
                $0.projectsByProfile = Self.projects; $0.projects = entries; $0.prefs.groupBy = .project; $0.projectOrder = order
            }.firstIndex { $0.id == "project-home" }
        }
        #expect(homePlace([]) == 2 && homePlace([SessionProjects.homeKey, "/home/hermes/site", "/home/hermes/reading"]) == 0)
        var input = SessionListInput(live: rows, now: Self.now, calendar: Self.calendar)
        input.projectsByProfile = Self.projects; input.projects = entries; input.prefs.pills = .projects
        input.archivedProjects = ["/home/hermes/site"]
        #expect(SessionListPipeline.chipCounts(input)[.working] == nil)
    }

    /// [three-piles] Owner 2026-11-17 (picked from pictures): a project's page is three piles. Pinned draws every
    /// pinned chat; Active is one run, what needs the owner first, and a long one draws `pageFirstRows` then Show More
    /// (never to hide one chat); each pile closes.
    @Test func aProjectPageIsThreePiles() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default"])
        let site = "/home/hermes/site", day = 86_400.0
        var rows = (0..<3).map { Self.chat("q\($0)", ago: Double($0 + 1) * 60, cwd: site) }
        rows += [Self.chat("w", ago: 5 * 60, status: .working, cwd: site), Self.chat("n", ago: 2 * day, status: .needsInput, cwd: site),
                 Self.chat("r", ago: 9 * 60, status: .unread, cwd: site), Self.chat("old", ago: 90 * day, cwd: site),
                 Self.chat("p0", ago: 30 * day, pinned: true, cwd: site), Self.chat("p1", ago: 60, status: .working, pinned: true, cwd: site)]
        func run(_ live: [SessionSummary], _ edit: (inout SessionListInput) -> Void = { _ in }) -> [String: SessionGroup] {
            let groups = Self.run(live) {
                $0.projectsByProfile = Self.projects; $0.projects = entries; $0.prefs.pills = .projects
                $0.prefs.projectFilter = [site]; edit(&$0)
            }
            return Dictionary(uniqueKeysWithValues: groups.map { ($0.id.replacingOccurrences(of: "state-", with: ""), $0) })
        }
        func shape(_ group: SessionGroup?) -> [Int] { group.map { [$0.sessions.count, $0.more, $0.total, $0.collapsed ? 1 : 0] } ?? [] }
        var page = run(rows)
        #expect(Set(page.keys) == ["page", "pinned", "active"])
        // Pinned: every pinned chat, the one at work first. Active: needs you, new, working, then the quiet ones by time.
        #expect(page["pinned"]?.sessions.map(\.id) == ["p1", "p0"])
        #expect(page["active"]?.sessions.map(\.id) == ["n", "r", "w", "q0", "q1", "q2", "old"])
        #expect(page["page"]?.needs == 1 && page["page"]?.ready == 1 && page["page"]?.busy == 2 && page["page"]?.total == 9)
        // A pile closes; a status filter shows every match.
        #expect(shape(run(rows) { $0.collapsedGroups = ["state-active"] }["active"]) == [0, 0, 7, 1])
        #expect(shape(run(rows) { $0.collapsedGroups = ["state-active"]; $0.prefs.statusFilter = [.working] }["active"]) == [1, 0, 1, 0])
        #expect(SessionListPipeline.folds(SessionGroup(id: "state-active", title: "Active", sessions: [])))
        // A long Active draws its first rows, then Show More; one chat past the cap is drawn (no row spent hiding it).
        let cap = SessionListPipeline.pageFirstRows
        let many = (0..<(cap + 5)).map { Self.chat("m\($0)", ago: Double($0 + 1) * 60, cwd: site) }
        #expect(shape(run(many)["active"]) == [cap, 5, cap + 5, 0])
        page = run(many) { $0.expandedGroups = ["state-active"] }
        #expect(shape(page["active"]) == [cap + 5, 0, cap + 5, 0] && page["active"]?.expanded == true)
        #expect(shape(run(Array(many.prefix(cap + 1)))["active"]) == [cap + 1, 0, cap + 1, 0])
        // Pinned is never cut.
        let pins = (0..<(cap + 5)).map { Self.chat("p\($0)", ago: Double($0 + 1) * 60, pinned: true, cwd: site) }
        #expect(shape(run(pins)["pinned"]) == [cap + 5, 0, cap + 5, 0])
    }

    /// [three-piles] Done is the project's archived chats, read for the page whether or not Show › Archived is on:
    /// closed to its count until opened, off the header's counts. One with a reply not read yet is back in Active.
    /// Another project's archived chats, and the lists outside the page, are as before.
    @Test func aProjectPagesDonePile() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default"])
        let site = "/home/hermes/site"
        func archived(_ id: String, ago: Double, status: SessionStatus = .idle, cwd: String? = site) -> SessionSummary {
            var s = Self.chat(id, ago: ago, status: status, cwd: cwd); s.archived = true; return s
        }
        let live = [Self.chat("a", ago: 60, cwd: site), Self.chat("b", ago: 120, cwd: "/home/hermes/reading")]
        let put = [archived("d0", ago: 600), archived("d1", ago: 300), archived("back", ago: 30, status: .unread),
                   archived("other", ago: 40, cwd: "/home/hermes/reading")]
        func run(_ edit: (inout SessionListInput) -> Void = { _ in }) -> [SessionGroup] {
            Self.run(live, archived: put) {
                $0.projectsByProfile = Self.projects; $0.projects = entries; $0.prefs.pills = .projects
                $0.prefs.projectFilter = [site]; edit(&$0)
            }
        }
        var page = run()
        #expect(page.map(\.id) == ["page", "state-active", "state-done"] && page.map(\.title) == ["", "Active", "Done"])
        #expect(page[1].sessions.map(\.id) == ["back", "a"])
        #expect(page[2].collapsed && page[2].sessions.isEmpty && page[2].total == 2)
        #expect(run { $0.statusChip = .new }.map(\.id) == ["page", "state-active"])     // [page-count-chips] narrowed: no Done
        #expect(page[0].total == 2 && page[0].ready == 1)
        page = run { $0.openGroups = ["state-done"] }
        #expect(!page[2].collapsed && page[2].sessions.map(\.id) == ["d1", "d0"])
        // Show › Archived on: the same page.
        #expect(run { $0.prefs.showArchived = true }.map(\.id) == ["page", "state-active", "state-done"])
        // Only Done chats: the page is its header and the closed pile.
        let only = Self.run([], archived: [put[0]]) {
            $0.projectsByProfile = Self.projects; $0.projects = entries; $0.prefs.pills = .projects; $0.prefs.projectFilter = [site]
        }
        #expect(only.map(\.id) == ["page", "state-done"] && only[0].total == 0)
        // Off the page nothing archived is listed.
        #expect(run { $0.prefs.projectFilter = []; $0.prefs.groupBy = .project }.map(\.total).reduce(0, +) == 2)
        #expect(Self.ids(run { $0.prefs.pills = .bots; $0.prefs.projectFilter = [] }).sorted() == ["a", "b"])
    }

    /// [project-pills] A project pill opens the project page: its header, then its piles. Not with bot pills, two
    /// projects, or a status pill.
    @Test func aProjectPillOpensTheProjectPage() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default"])
        var both = Self.chat("b", ago: 30, status: .needsInput, cwd: "/home/hermes/site"); both.unread = true
        var branch = Self.chat("e", ago: 10, cwd: "/home/hermes/site"); branch.branch = "fix/checkout"
        let rows = [Self.chat("a", ago: 20, status: .working, cwd: "/home/hermes/site"), both,
                    Self.chat("c", ago: 40, status: .unread, cwd: "/home/hermes/site"), branch,
                    Self.chat("f", ago: 90, pinned: true, cwd: "/home/hermes/site"), Self.chat("d", cwd: "/home/hermes/reading"),
                    Self.chat("g", profile: "research", ago: 50, cwd: "/home/hermes/site")]
        func run(_ edit: (inout SessionListInput) -> Void = { _ in }) -> [SessionGroup] {
            Self.run(rows) {
                $0.projectsByProfile = Self.projects; $0.projects = entries; $0.prefs.pills = .projects
                $0.prefs.projectFilter = ["/home/hermes/site"]; edit(&$0)
            }
        }
        let page = run()
        #expect(page.map(\.id) == ["page", "state-pinned", "state-active"])
        #expect(page.map(\.title) == ["", "Pinned", "Active"])
        #expect(page[1].sessions.map(\.id) == ["f"] && page[2].sessions.map(\.id) == ["b", "c", "a", "e"])   // "g": research has no Site project
        #expect(page.dropFirst().map(\.total) == [1, 4])
        let head = page[0]
        #expect(head.pageKey == "/home/hermes/site" && head.latestTitle == "Site" && head.branch == "fix/checkout")
        #expect(head.needs == 1 && head.ready == 1 && head.busy == 1 && head.total == 5 && head.profiles == ["default"])
        #expect(!run { $0.prefs.pills = .bots }.contains { $0.id == "page" })
        #expect(!run { $0.prefs.projectFilter = ["/home/hermes/site", "/home/hermes/reading"] }.contains { $0.id == "page" })
        // [page-count-chips] A status pill (the rail's, or a count on the page) keeps the page and narrows its piles:
        // Working to the chat at work; New to the ones waiting on the owner or not read, and one read since the page
        // was last left. The header's counts stay, and Done is left out.
        let working = run { $0.statusChip = .working }
        #expect(working.map(\.id) == ["page", "state-active"] && working[1].sessions.map(\.id) == ["a"])
        #expect(working[0].needs == 1 && working[0].ready == 1 && working[0].busy == 1 && working[0].total == 5)
        #expect(run { $0.statusChip = .new }.dropFirst().flatMap(\.sessions).map(\.id) == ["b", "c"])
        let kept = run { $0.statusChip = .new; $0.keepNew = [SessionListPipeline.key(branch)] }
        // [read-holds] Owner 2026-11-21: a chat read since the page was last left keeps New's place (among the New
        // chats by time, "e" newer than "c"), no longer sinking to the end (before: ["b", "c", "e"]).
        #expect(kept.dropFirst().flatMap(\.sessions).map(\.id) == ["b", "e", "c"])
        // A closed pile opens for its matches; a pill with no match leaves the header alone.
        #expect(run { $0.statusChip = .working; $0.collapsedGroups = ["state-active"] }[1].sessions.map(\.id) == ["a"])
        let quiet = Self.run([branch]) {
            $0.projectsByProfile = Self.projects; $0.projects = entries; $0.prefs.pills = .projects
            $0.prefs.projectFilter = ["/home/hermes/site"]; $0.statusChip = .working
        }
        #expect(quiet.map(\.id) == ["page"] && quiet[0].total == 1)
        // A project with no chats yet still opens: its header (and New Chat) alone.
        let empty = Self.run([]) {
            $0.projectsByProfile = Self.projects; $0.projects = entries; $0.prefs.pills = .projects; $0.prefs.projectFilter = ["/home/hermes/site"]
        }
        #expect(empty.map(\.id) == ["page"] && empty[0].total == 0)
        #expect(ProjectPageHeader.shortFolder("/Users/me/code/site") == "~/code/site" && ProjectPageHeader.shortFolder("/srv/site") == "/srv/site")
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
        // [three-piles] the pinned chat is in Home; [projects-all-bots] Reading, with no chat, is listed too
        #expect(groups.map(\.id) == ["project-/home/hermes/site", "project-/home/hermes/reading", "project-home"])
        #expect(groups.allSatisfy { $0.collapsed && $0.sessions.isEmpty && $0.more == 0 })
        #expect(groups.map(\.total) == [3, 0, 1])
        // A closed project that was opened with Show More stays closed (no Show Less row under a closed header).
        let both = Self.run(Self.projectRows(9, unread: false)) {
            $0.prefs.groupBy = .project; $0.projectsByProfile = Self.projects; $0.projects = entries
            $0.expandedGroups = ["project-/home/hermes/site"]
        }
        #expect(both[0].collapsed && both[0].sessions.isEmpty && !both[0].expanded)
    }

    /// [sessionsminimal] A status group folds; [sessions-collapse] so does Recent (owner 2026-11-11: every section, in
    /// every view); neither is capped.
    @Test func statusGroupsAndRecentFoldAndNeitherIsCapped() {
        let rows = (0..<9).map { Self.chat("d\($0)", ago: Double($0 + 1) * 60, status: $0 < 7 ? .working : .idle) }
        var groups = Self.run(rows)
        #expect(groups.map(\.id) == [Self.today] && groups[0].sessions.count == 9 && groups[0].more == 0)
        #expect(SessionListPipeline.folds(groups[0]))
        groups = Self.run(rows) { $0.collapsedGroups = [Self.today] }
        #expect(groups[0].collapsed && groups[0].sessions.isEmpty && groups[0].total == 9)
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
        #expect(Self.ids(groups) == ["s0", "s3", "s6", "pin"])
        // Project › Site alone: [project-pills] Group By Project opens the project's page: all nine, uncapped, the
        // three unread ones first in Active.
        groups = run { $0.prefs.projectFilter = ["/home/hermes/site"] }
        #expect(groups.first { $0.id == SessionListPipeline.pageId }?.total == 9)
        let active = groups.first { $0.id == "state-active" }
        #expect(active?.sessions.prefix(3).map(\.id) == ["s0", "s3", "s6"])
        #expect(active.map { [$0.sessions.count, $0.more, $0.total] } == [9, 0, 9])
        #expect(groups.allSatisfy { !$0.collapsed })
        // A project filter naming no listed project narrows nothing, so it opens nothing either (C-07).
        groups = run { $0.prefs.projectFilter = ["/gone"] }
        #expect(groups.filter { $0.id != SessionListPipeline.newId }.allSatisfy { $0.collapsed })
    }

    /// [project-pins] Owner 2026-11-20: a chat pinned on a project's page alone is in that page's Pinned pile and in no
    /// other list's Pinned (Recent, Group By Status, another project's page).
    @Test func aProjectOnlyPinStaysOnItsProjectsPage() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default"])
        let rows = Self.projectRows(4) + [Self.chat("pin", ago: 10, pinned: true)]
        let local = "default\u{1F}s2"
        func page(_ edit: (inout SessionListInput) -> Void = { _ in }) -> [SessionGroup] {
            Self.run(rows) {
                $0.prefs.groupBy = .project; $0.projectsByProfile = Self.projects; $0.projects = entries
                $0.prefs.projectFilter = ["/home/hermes/site"]
                edit(&$0)
            }
        }
        let before = page()
        #expect(before.first { $0.id == "state-pinned" } == nil)
        let pinned = page { $0.projectPins = ["/home/hermes/site": [local]] }
        let pile = pinned.first { $0.id == "state-pinned" }
        #expect(pile?.sessions.map(\.id) == ["s2"] && pile?.sessions.first?.projectPinned == true)
        let active = pinned.first { $0.id == "state-active" }
        #expect(active?.sessions.contains { $0.id == "s2" } == false && active?.sessions.allSatisfy { !$0.projectPinned } == true)
        // Another project's pins leave this page alone.
        #expect(page { $0.projectPins = ["/elsewhere": [local]] }.first { $0.id == "state-pinned" } == nil)
        // Every other list: the global Pinned holds only the chat pinned everywhere.
        for grouping in [SessionGroupBy.date, .status] {
            let list = Self.run(rows) { $0.prefs.groupBy = grouping; $0.projectPins = ["/home/hermes/site": [local]] }
            #expect(list.first { $0.id == "pinned" }?.sessions.map(\.id) == ["pin"])
            #expect(list.flatMap(\.sessions).allSatisfy { !$0.projectPinned })
        }
    }

    /// [read-holds] Owner 2026-11-21: opening a New chat on a project's page leaves it where it was until the page is
    /// left (`keepNew`); [project-sort] Sort › Newest lists by time alone, so reading moves nothing.
    @Test func readingAChatOnAProjectPageDoesNotMoveIt() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default"])
        var rows = Self.projectRows(4)   // s0 and s3 unread
        func active(_ edit: (inout SessionListInput) -> Void = { _ in }) -> [String] {
            Self.run(rows) {
                $0.prefs.groupBy = .project; $0.projectsByProfile = Self.projects; $0.projects = entries
                $0.prefs.projectFilter = ["/home/hermes/site"]
                edit(&$0)
            }.first { $0.id == "state-active" }?.sessions.map(\.id) ?? []
        }
        #expect(active() == ["s0", "s3", "s1", "s2"])
        rows[3].unread = false; rows[3].status = .idle            // s3 opened and read
        #expect(active { $0.keepNew = ["default\u{1F}s3"] } == ["s0", "s3", "s1", "s2"], "held while the page is on show")
        #expect(active() == ["s0", "s1", "s2", "s3"], "the page left: back among the quiet ones")
        #expect(active { $0.projectsByNewest = ["/home/hermes/site"] } == ["s0", "s1", "s2", "s3"])
        rows[3].unread = true
        #expect(active { $0.projectsByNewest = ["/home/hermes/site"] } == ["s0", "s1", "s2", "s3"], "Newest ignores New")
        #expect(active { $0.projectsByNewest = ["/elsewhere"] } == ["s0", "s3", "s1", "s2"])
    }

    /// [project-by-status] Owner 2026-11-22 (T3 Code's sidebar): Sort › By Status splits Active into Needs You, New,
    /// Working and Earlier, each section only when it has a chat; a chat read since the page was last left stays under
    /// New; another project's page keeps its one Active run.
    @Test func byStatusSplitsAProjectPageIntoStateSections() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default"])
        var rows = Self.projectRows(5)   // s0 and s3 unread
        rows[1].status = .needsInput
        rows[2].status = .working
        func page(_ edit: (inout SessionListInput) -> Void = { _ in }) -> [SessionGroup] {
            Self.run(rows) {
                $0.prefs.groupBy = .project; $0.projectsByProfile = Self.projects; $0.projects = entries
                $0.prefs.projectFilter = ["/home/hermes/site"]
                $0.projectsByStatus = ["/home/hermes/site"]
                edit(&$0)
            }
        }
        func ids(_ groups: [SessionGroup]) -> [String: [String]] {
            Dictionary(groups.filter { $0.id != SessionListPipeline.pageId }.map { ($0.id, $0.sessions.map(\.id)) },
                       uniquingKeysWith: { a, _ in a })
        }
        let split = page()
        #expect(split.map(\.id).filter { $0 != SessionListPipeline.pageId } ==
                ["state-needs", "state-new", "state-working", "state-earlier"])
        #expect(ids(split) == ["state-needs": ["s1"], "state-new": ["s0", "s3"], "state-working": ["s2"],
                               "state-earlier": ["s4"]])
        #expect(split.first { $0.id == "state-new" }?.title == "New")
        #expect(SessionListPipeline.pageSectionState("state-needs") == .needsYou)
        #expect(SessionListPipeline.pageSectionState("state-new") == .ready)
        #expect(SessionListPipeline.pageSectionState("state-working") == .working)
        #expect(SessionListPipeline.pageSectionState("state-earlier") == nil)
        #expect(SessionListPipeline.pageSectionState("state-active") == nil)
        // Read on the page: held under New until the page is left, then Earlier.
        rows[3].unread = false; rows[3].status = .idle
        #expect(ids(page { $0.keepNew = ["default\u{1F}s3"] })["state-new"] == ["s0", "s3"])
        #expect(ids(page())["state-new"] == ["s0"] && ids(page())["state-earlier"]?.contains("s3") == true)
        // An empty state draws no section.
        rows[2].status = .idle
        #expect(page().contains { $0.id == "state-working" } == false)
        // Not this project's choice: one Active run, as before.
        #expect(ids(page { $0.projectsByStatus = ["/elsewhere"] }).keys.sorted() == ["state-active"])
    }

    // MARK: New for You and folded projects (owner, 2026-10-31)

    /// [sessions-layout] New for You: every unread chat and every chat waiting on the user, newest first, out of
    /// Pinned and the groups below; its newest three, then Show More. Not under a status filter or a flat sort, and
    /// [sessions-fresh] not under Group By Recent (its New chip lists them instead).
    @Test func newForYouLiftsUnreadAndWaitingChatsAboveEverything() {
        let rows = [Self.chat("idle", ago: 10), Self.chat("unread", ago: 60, status: .unread),
                    Self.chat("waits", ago: 30, status: .needsInput), Self.chat("pin-unread", ago: 90, status: .unread, pinned: true),
                    Self.chat("pin", ago: 20, pinned: true), Self.chat("old-unread", ago: 86_400 * 9, status: .unread)]
        #expect(Self.run(rows).map(\.id) == ["pinned", Self.today, SessionListPipeline.recentOlderId])
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
        // [three-piles] the projects alone; [projects-all-bots] Site, with no chat, too
        #expect(folded.map(\.id) == [reading, SessionListPipeline.projectPrefix + "/home/hermes/site", "project-home"])
        let projects = folded
        #expect(projects.allSatisfy { $0.collapsed && $0.sessions.isEmpty && $0.more == 0 })
        let summary = projects[0]
        #expect(summary.total == 3 && summary.unread == 1 && summary.latestTitle == "Fix the header")
        #expect(summary.profiles == ["research", "default"] && summary.newest == Self.now.addingTimeInterval(-100))
        let open = run { $0.openGroups = [reading] }
        #expect(open[0].sessions.map(\.id) == ["reading-r", "reading-new", "reading-old"] && !open[0].collapsed)
        #expect(open[0].total == 3 && open[0].unread == 1 && open[0].more == 0 && !open[0].working)
        // Every chat unread: the project draws all of them, and nothing stands above the projects.
        let allNew = Self.run(rows.map { var s = $0; s.unread = true; return s }) {
            $0.prefs.groupBy = .project; $0.projectsByProfile = Self.projects; $0.projects = entries; $0.openGroups = [reading]
        }
        let kept = allNew.first { $0.id == reading }
        #expect(kept?.sessions.count == 3 && kept?.collapsed == false && kept?.total == 3 && kept?.unread == 3)
        #expect(!allNew.contains { $0.id == SessionListPipeline.newId || $0.id == "pinned" })
        #expect(open[1].collapsed)
        #expect(run { $0.openGroups = [reading]; $0.collapsedGroups = [reading] }[0].collapsed == false)
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
        // [three-piles] Group By Project is the projects alone (no New for You or Pinned above them to list a chat a
        // second time). [sessions-shape] Group By Recent's projects are shortcuts to chats Recent lists too.
        var again: [Int] = []
        let took = clock.measure {
            for round in 0..<3 {
                var out: [[String]] = []
                for sort in SessionSortBy.allCases {
                    for group in SessionGroupBy.allCases {
                        let groups = Self.run(rows) {
                            $0.prefs.sortBy = sort; $0.prefs.groupBy = group; $0.projectsByProfile = projects; $0.projects = entries
                            $0.prefs.showProjects = true                               // [chats-projects] the shortcut drawn
                            // Every project opened with Show More, so every chat is drawn.
                            $0.openGroups = Set(entries.map { SessionListPipeline.projectPrefix + $0.key } + [SessionListPipeline.recentOlderId])
                            $0.expandedGroups = Set(entries.map { SessionListPipeline.projectPrefix + $0.key }
                                + (0..<12).map { SessionListPipeline.botPrefix + "bot\($0)" }     // [manual-order] Group By Bot
                                + [SessionListPipeline.newId, "pinned", SessionListPipeline.projectsId])   // [sessions-fresh]
                        }
                        out.append(Self.ids(groups))
                        if round == 0 { again.append(group == .date ? groups.filter { SessionListPipeline.isProject($0.id) }.reduce(0) { $0 + $1.sessions.count } : 0) }
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
                // [three-piles] Each chat is counted once (a capped project counts its all). [sessions-shape] Group By
                // Recent's projects are shortcuts to chats Recent lists too.
                let counted = group == .date ? groups.filter { !SessionListPipeline.isProject($0.id) } : groups
                let count = counted.reduce(0) { $0 + max($1.total, $1.sessions.count) }
                #expect(count == 5_000)
                #expect(best < .milliseconds(150), "5,000 chats, Sort By \(sort), Group By \(group): best of five \(best)")
            }
        }
    }
}

// MARK: - Project Settings [project-settings]

extension SessionListPipelineTests {
    private static let site = "/home/hermes/site"

    /// [project-keep] Owner 2026-11-22 ("I don't believe the keep chats in this project feature is working"): the bots'
    /// rows, the strip over a chat and the Mac's Chats tab listed a kept project's chats too. They leave those as they
    /// leave Recent: still shown while waiting on the owner. Owner 2026-11-23: pinned everywhere no longer brings one out.
    @Test func aKeptProjectsChatsLeaveTheBotsRows() {
        var asks = Self.chat("asks", ago: 50, status: .needsInput, cwd: Self.site)
        asks.unread = false
        let rows = [Self.chat("quiet", ago: 10, cwd: Self.site), Self.chat("unread", ago: 20, status: .unread, cwd: Self.site),
                    Self.chat("busy", ago: 30, status: .working, cwd: Self.site), asks,
                    Self.chat("pin", ago: 70, pinned: true, cwd: Self.site), Self.chat("home", ago: 60)]
        let away = Set(rows.filter { SessionListPipeline.isKeptAway($0, kept: [Self.site], projectsByProfile: Self.projects) }.map(\.id))
        #expect(away == ["quiet", "unread", "busy", "pin"])
        #expect(!rows.contains { SessionListPipeline.isKeptAway($0, kept: [], projectsByProfile: Self.projects) })
        #expect(!rows.contains { SessionListPipeline.isKeptAway($0, kept: ["/elsewhere"], projectsByProfile: Self.projects) })

        // Under the bot's row (Pinned + 2 Recent): before, the pin and the project's newest two; kept, the asking one and
        // Home's chat (the pin stays on the project's page).
        let before = BotChatsUnder.pick(rows, bot: "default", choice: BotChatsChoice(mode: .recent, count: 2))
        #expect(before.shown.map(\.id) == ["pin", "quiet", "unread"])
        let listed = rows.filter { !away.contains($0.id) }
        let after = BotChatsUnder.pick(listed, bot: "default", choice: BotChatsChoice(mode: .recent, count: 2))
        #expect(after.shown.map(\.id) == ["asks", "home"] && after.more == 0)
    }

    /// [project-keep] Owner 2026-11-20: a kept project's chats leave Recent, the days, Group By Status, Group By Bot,
    /// a flat sort and the status chips; they stay in their project (page, row, counts), and in New for You and under
    /// the New chip only while they wait on the owner. Owner 2026-11-23 ("chats hidden outside that project … are still
    /// showing"): Pinned leaves them out too, unless one waits on the owner.
    @Test func aKeptProjectsChatsStayOnItsPage() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default"])
        var asks = Self.chat("asks", ago: 50, status: .needsInput, cwd: Self.site)
        asks.unread = false
        let rows = [Self.chat("quiet", ago: 100, cwd: Self.site), Self.chat("unread", ago: 90, status: .unread, cwd: Self.site),
                    Self.chat("busy", ago: 80, status: .working, cwd: Self.site), asks,
                    Self.chat("pin", ago: 70, pinned: true, cwd: Self.site), Self.chat("home", ago: 60),
                    Self.chat("homeNew", ago: 40, status: .unread)]
        func run(_ kept: Bool, _ edit: (inout SessionListInput) -> Void = { _ in }) -> [SessionGroup] {
            Self.run(rows) {
                $0.projectsByProfile = Self.projects; $0.projects = entries
                $0.keptProjects = kept ? [Self.site] : []
                edit(&$0)
            }
        }
        func sessions(_ groups: [SessionGroup], _ id: String) -> [String] { groups.first { $0.id == id }?.sessions.map(\.id) ?? [] }

        // Group By Recent: the days hold Home's chats alone; Pinned leaves the project's pin on its page.
        #expect(Set(Self.recent(run(false))) == ["quiet", "unread", "busy", "asks", "home", "homeNew"])
        let fresh = run(true)
        #expect(Self.recent(fresh) == ["homeNew", "home"])
        #expect(sessions(fresh, "pinned").isEmpty && sessions(run(false), "pinned") == ["pin"])
        // A pinned chat of the project that waits on the owner still shows (New for You lifts it above Pinned).
        var pinAsks = Self.chat("pinAsks", ago: 30, status: .needsInput, pinned: true, cwd: Self.site)
        pinAsks.unread = false
        let asking = Self.run(rows + [pinAsks]) {
            $0.projectsByProfile = Self.projects; $0.projects = entries; $0.keptProjects = [Self.site]; $0.prefs.groupBy = .bot
        }
        #expect(sessions(asking, SessionListPipeline.newId).contains("pinAsks") && sessions(asking, "pinned").isEmpty)
        // With Show › Projects the project's own row still counts every one of its chats.
        let shown = run(true) { $0.prefs.showProjects = true }
        #expect(shown.first { $0.id == "project-" + Self.site }?.total == 5)
        #expect(Self.recent(shown) == ["homeNew", "home"])

        // Group By Status: New for You keeps the chat that waits on the owner, not the unread one; the groups hold
        // Home's.
        let status = run(true) { $0.prefs.groupBy = .status }
        #expect(sessions(status, SessionListPipeline.newId) == ["homeNew", "asks"])
        #expect(sessions(status, "status-working").isEmpty && sessions(status, "status-done") == ["home"])
        #expect(sessions(status, "pinned").isEmpty)
        #expect(Set(sessions(run(false) { $0.prefs.groupBy = .status }, SessionListPipeline.newId)) == ["homeNew", "asks", "unread"])

        // Group By Bot and a flat sort: Home's alone (and Pinned).
        let bots = run(true) { $0.prefs.groupBy = .bot }
        #expect(sessions(bots, "bot-default") == ["home"])
        let flat = run(true) { $0.prefs.sortBy = .tokens }
        #expect(sessions(flat, SessionListPipeline.flatId) == ["homeNew", "home"] && sessions(flat, "pinned").isEmpty)

        // The chips: New lists the asking chat, not the unread one; Working lists none of the project's. The counts
        // say the same.
        #expect(Self.ids(run(true) { $0.statusChip = .new }) == ["homeNew", "asks"])
        #expect(Self.ids(run(true) { $0.statusChip = .working }).isEmpty)
        #expect(Self.ids(run(false) { $0.statusChip = .working }) == ["busy"])
        var counted = SessionListInput(live: rows, projectsByProfile: Self.projects, projects: entries)
        #expect(SessionListPipeline.chipCounts(counted) == [.new: 3, .working: 1])
        counted.keptProjects = [Self.site]
        #expect(SessionListPipeline.chipCounts(counted) == [.new: 2])

        // Its own page, and its card under Group By Project: every chat, as before.
        let page = run(true) { $0.prefs.groupBy = .project; $0.prefs.projectFilter = [Self.site] }
        #expect(page.first { $0.id == SessionListPipeline.pageId }?.total == 5)
        #expect(Set(Self.ids(page)) == ["quiet", "unread", "busy", "asks", "pin"])
        counted.prefs.groupBy = .project
        counted.prefs.projectFilter = [Self.site]
        #expect(SessionListPipeline.chipCounts(counted) == [.new: 2, .working: 1], "on the page the chips count its chats")
        let cards = run(true) { $0.prefs.groupBy = .project; $0.openGroups = ["project-" + Self.site] }
        #expect(cards.first { $0.id == "project-" + Self.site }?.total == 5)
        // Another project kept: nothing here changes.
        #expect(Set(Self.recent(run(false) { $0.keptProjects = ["/elsewhere"] })) == ["quiet", "unread", "busy", "asks", "home", "homeNew"])
    }

    /// [project-auto-done] Owner 2026-11-20: on a project's page a quiet live chat older than the chosen age (or whose
    /// pull request merged) is listed in Done with the archived ones. Pinned chats, chats that are not quiet, and a
    /// chat read since the page was last left stay in Active. Display only: the rows are still live.
    @Test func quietChatsMoveToDoneOnTheirProjectsPage() {
        let entries = SessionProjects.menuEntries(Self.projects, order: ["default"])
        let day = 86_400.0
        var merged = Self.chat("merged", ago: 60, cwd: Self.site)
        merged.pullRequest = SessionPRStatus(state: .merged)
        var open = Self.chat("open", ago: 120, cwd: Self.site)
        open.pullRequest = SessionPRStatus(state: .open)
        var archived = Self.chat("archived", ago: day, cwd: Self.site)
        archived.archived = true
        let rows = [Self.chat("fresh", ago: day * 2, cwd: Self.site), Self.chat("week", ago: day * 8, cwd: Self.site),
                    Self.chat("old", ago: day * 20, cwd: Self.site), Self.chat("oldUnread", ago: day * 20, status: .unread, cwd: Self.site),
                    Self.chat("oldPinned", ago: day * 20, pinned: true, cwd: Self.site),
                    Self.chat("oldLocal", ago: day * 21, cwd: Self.site), Self.chat("oldHeld", ago: day * 22, cwd: Self.site), merged, open]
        func page(_ rule: ProjectAutoDone?, key: String = Self.site) -> [SessionGroup] {
            Self.run(rows, archived: [archived]) {
                $0.projectsByProfile = Self.projects; $0.projects = entries
                $0.prefs.groupBy = .project
                $0.prefs.projectFilter = [Self.site]
                $0.openGroups = ["state-done"]
                $0.projectPins = [Self.site: ["default\u{1F}oldLocal"]]
                $0.keepNew = ["default\u{1F}oldHeld"]
                if let rule { $0.projectAutoDone = [key: rule] }
            }
        }
        func done(_ groups: [SessionGroup]) -> [String] { groups.first { $0.id == "state-done" }?.sessions.map(\.id) ?? [] }
        func active(_ groups: [SessionGroup]) -> Set<String> { Set(groups.first { $0.id == "state-active" }?.sessions.map(\.id) ?? []) }

        // Never: Done is the archived chat alone.
        #expect(done(page(nil)) == ["archived"])
        #expect(page(nil).first { $0.id == SessionListPipeline.pageId }?.total == 9)
        // After 7 Days: the quiet chats older than that join it, newest first; the unread, pinned, pinned-here and
        // just-read ones stay.
        let seven = page(ProjectAutoDone(days: 7))
        #expect(done(seven) == ["archived", "week", "old"])
        #expect(active(seven) == ["fresh", "oldUnread", "oldHeld", "merged", "open"])
        #expect(seven.first { $0.id == "state-pinned" }?.sessions.map(\.id) == ["oldPinned", "oldLocal"])
        #expect(seven.first { $0.id == SessionListPipeline.pageId }?.total == 7, "the header counts what is not in Done")
        #expect(seven.flatMap(\.sessions).first { $0.id == "week" }?.archived == false, "nothing is archived")
        // After 3 Days and After 14 Days draw the line elsewhere.
        #expect(done(page(ProjectAutoDone(days: 14))) == ["archived", "old"])
        #expect(done(page(ProjectAutoDone(days: 3))) == ["archived", "week", "old"])
        // When the Pull Request Merges: the merged chat, whatever its age; an open one stays.
        #expect(done(page(ProjectAutoDone(onMerge: true))) == ["merged", "archived"])
        #expect(done(page(ProjectAutoDone(days: 14, onMerge: true))) == ["merged", "archived", "old"])
        // Another project's rule moves nothing here; and no other list reads it.
        #expect(done(page(ProjectAutoDone(days: 3), key: "/elsewhere")) == ["archived"])
        let list = Self.run(rows) { $0.projectsByProfile = Self.projects; $0.projects = entries; $0.projectAutoDone = [Self.site: ProjectAutoDone(days: 3)] }
        #expect(Self.recent(list).contains("old"))
    }

    @Test func autoDoneReadsItsStoredWords() {
        #expect(ProjectAutoDone(raw: nil).isOff && ProjectAutoDone(raw: "never").isOff && ProjectAutoDone(raw: "junk").isOff)
        #expect(ProjectAutoDone(raw: "7") == ProjectAutoDone(days: 7))
        #expect(ProjectAutoDone(raw: "5").days == nil, "only the offered ages")
        #expect(ProjectAutoDone(raw: "14+merged") == ProjectAutoDone(days: 14, onMerge: true))
        #expect(ProjectAutoDone(raw: "never+merged") == ProjectAutoDone(onMerge: true))
        for rule in [ProjectAutoDone(), ProjectAutoDone(days: 3), ProjectAutoDone(onMerge: true), ProjectAutoDone(days: 14, onMerge: true)] {
            #expect(ProjectAutoDone(raw: rule.raw) == rule)
        }
        #expect(ProjectAutoDone.title(days: nil) == "Never" && ProjectAutoDone.title(days: 7) == "After 7 Days")
    }
}
