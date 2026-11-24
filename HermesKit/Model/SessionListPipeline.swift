// [sessions-m9] The Sessions list as one pure pipeline (docs/spec/3x-sessions.md §3.5): pool → filter → pinned →
// sort → group. No UIKit; the view controller draws the groups it returns.
//
//   pool    the listed chats, and (Show › Archived) the archived ones with them
//   filter  the chip's bot AND the status filter AND the project filter (empty = any)
//   new     [sessions-layout] "New for You", first: every chat with a reply not read yet or waiting on the user (and
//           the ones read since the page was last left, `keepNew`), newest first; out of Pinned and the groups below,
//           as Pinned's are. Its newest `newFirstRows` then "Show More". Not under a status filter or a flat sort.
//           [project-cards] A project (Group By Project) keeps them as well: it counts them and, opened, draws them
//           among its own, so a project always holds all its chats (owner, 2026-10-31). The list gives that second row
//           an item id of its own (`SessionsViewController.copyKey`).
//   pinned  the "Pinned" group, after it
//   sort    Updated | Created | Status | Tokens | Cost; ties by recency (newest first), then id. Manual: the dragged
//           order inside each group (`SessionManualOrder`), chats it does not know folded in by recency
//   group   Sort By Tokens/Cost: one untitled run; else Date (the sort's own timestamp), Status ("Working" then
//           "Done"), Project (by its newest chat, Home last) or Bot (by its newest chat); projects and bots in the
//           user's order once put in one, favorite projects first
//   apps    Show › Outside Chats: one "Other Apps" row under Pinned standing for every messaging platform's chats
//           (and, with Show › Background Runs, the one-off runs' "One-off Runs" section, `ChatSource.hasFolder`);
//           it opens a page with a section per platform (`appSections`), the platform with the newest chat first,
//           newest first inside (the desktop's folders, `V/app/chat/sidebar/index.tsx:1320-1366`, moved where a phone
//           reaches them). In every grouping; not while a project filter is picked. A pinned one stays in Pinned.
//           With Show › Archived the archived platform chats join their page too (marked), not the dated rows.
//   fold    a titled group the user closed draws its header alone (count, chevron); a project shows its newest
//           `projectFirstRows` then "Show More (X)" until opened in place. A status or project filter folds nothing.
//           [sessions-layout] A project starts folded to its summary row (faces, count, newest chat) until opened
//           (`openGroups`), so every project shows on the first screen (owner, 2026-10-31).
//
// [sessions-fresh] Group By Recent (the default; it was Date): no New for You and no date headers. Pinned draws its
// newest `freshPinnedRows`, the projects (not Home) their first `freshProjectRows` (or every favorite, if more) under
// "Projects", and "See All" in either header draws the rest in place; then "Recent", every other chat newest first, a
// project's too (a project still holds all its chats, as under Group By Project), unless Show › Project Chats in
// Recent is off: then Recent holds Home's chats alone. A status chip (New, Working) draws
// its chats alone, newest first, in one run. [bot-home] "Projects" ends with Home, the chats in no project: the picked
// bot's under its pill (its row opens their page, kept to that bot), every bot's under All.
// [chats-projects] The projects there only with Show › Projects (off by default): else the Chats side is Pinned and
// Recent, every chat in Recent, and the projects are the switch's other side.
//
// The web: `V/store/sidebar-sort.ts`, `V/app/chat/sidebar/index.tsx:605-680,1471,1872`, `V/lib/session-date-groups.ts`.
// The web's Archived swaps the pool; here it adds to it, as Background Runs and Outside Chats do (a tester read the
// Show checks as additive, 2026-10-24).

import Foundation

nonisolated struct SessionListInput: Sendable {
    /// The listed chats: no bots' own chats, no hidden runs, no rows on their way out.
    var live: [SessionSummary] = []
    /// The archived chats under the same rules; listed with the rest while Show › Archived is on.
    var archived: [SessionSummary] = []
    var prefs = SessionsViewPrefs()
    var botFilter: String? = nil
    /// Every bot's projects (the chat's project is the longest folder match).
    var projectsByProfile: [String: [SessionProject]] = [:]
    /// Filter › Project's list (Home last): which keys exist, and their names.
    var projects: [SessionProjectEntry] = []
    /// Messaging-platform chats (Show › Outside Chats on), for the folders.
    var outside: [SessionSummary] = []
    /// The folders the user opened (platform ids).
    var openSources: Set<String> = []
    /// Rows each open folder draws (missing: `folderFirstRows`).
    var shownPerSource: [String: Int] = [:]
    /// Titled groups the user closed (group ids: "pinned", "project-home", "today"…), for the chip's bot.
    var collapsedGroups: Set<String> = []
    /// [sessions-layout] Projects the user opened (group ids); every other project is folded to its summary row.
    var openGroups: Set<String> = []
    /// [sessions-layout] Chats read since the page was last left (row keys): they stay in New for You until then, so a
    /// chat opened from there is where it was on the way back.
    var keepNew: Set<String> = []
    /// Projects whose "Show More" was tapped: every chat drawn, then "Show Less".
    var expandedGroups: Set<String> = []
    /// [manual-order] Sort By Manual's order (row keys, `SessionListPipeline.key`), the projects' (keys) and the bots'
    /// (profiles) as the user put them, and the favorite projects (first under Group By Project).
    var chatOrder: [String] = []
    var projectOrder: [String] = []
    var botOrder: [String] = []
    var favoriteProjects: Set<String> = []
    /// [project-pills] Archived projects (keys): with project pills, their chats are off the list until Show › Archived
    /// (or the project is picked).
    var archivedProjects: Set<String> = []
    /// [project-pins] The chats pinned on a project's page alone: project key → row keys.
    var projectPins: [String: Set<String>] = [:]
    /// [project-sort] Projects whose page lists Active newest first (no state order): project keys.
    var projectsByNewest: Set<String> = []
    /// [project-by-status] Projects whose page splits Active into a section per state: project keys.
    var projectsByStatus: Set<String> = []
    /// [project-keep] Projects whose chats stay on their own page (keys): out of Recent, the days, Group By Status and
    /// Group By Bot, and the status chips; still in their project (its page, row and counts), in Pinned when pinned
    /// everywhere, and in New for You and under the New chip while they wait on the owner.
    var keptProjects: Set<String> = []
    /// [project-auto-done] Move Quiet Chats to Done, per project key: on that project's page a quiet live chat past
    /// the age (or whose pull request merged) is listed in Done. Display only.
    var projectAutoDone: [String: ProjectAutoDone] = [:]
    /// Group By Bot's headers: each bot's display name by profile (missing: the profile).
    var botNames: [String: String] = [:]
    /// [sessions-fresh] The header's New or Working chip (in memory, as the bot chip).
    var statusChip: SessionStatusChip? = nil
    /// Projects with Coding Project enabled: their project page uses the 4-bucket shipping pipeline.
    var codingProjects: Set<String> = []
    /// A project-page-only PR state; the other filters still intersect it.
    var projectPRState: SessionPRStatus.State? = nil
    /// A coding project page's pipeline bucket filter (Ready / Needs You / In Flight / Shipped).
    var projectPipelineBucket: CodingPipelineBucket? = nil
    /// [sessions-shape] A project's row opens its page (the app, not the tests of a project opening in place): under
    /// Group By Project a closed project keeps its live chats under its row.
    var liveUnderProjects = false
    var now = Date()
    var calendar = Calendar.current
}

/// [sessions-fresh] The header's status chips, after All: New (a reply not read yet, or waiting on you) and Working.
nonisolated enum SessionStatusChip: String, CaseIterable, Hashable, Sendable { case new, working }

nonisolated enum SessionListPipeline {
    /// The one untitled run's id (Sort By Tokens or Cost).
    static let flatId = "all"
    /// A platform section's id on the Other Apps page: "source-telegram".
    static let folderPrefix = "source-"
    /// The Other Apps row's group id (its one item is drawn by the view controller).
    static let otherAppsId = "other-apps"
    /// `NON_SESSION_INITIAL_ROWS` and `NON_SESSION_LOAD_STEP`.
    static let folderFirstRows = 3
    static let folderStep = 10
    /// Group By Project: the chats a project draws before "Show More" (the desktop's `SIDEBAR_GROUP_PAGE`).
    static let projectFirstRows = 5
    /// [sessions-layout] "New for You": its group id, and the chats it draws before "Show More".
    static let newId = "new"
    static let newTitle = "New for You"
    static let newFirstRows = 3
    /// [sessions-fresh] Group By Recent: the last group's id and title, Pinned's and the projects' rows before "See All"
    /// (the projects' expanded state is kept under `projectsId`), and a status chip's one run.
    static let recentId = "recent"
    /// [sessions-shape] Recent by the day: "recent-today", "recent-yesterday", "recent-week", "recent-older".
    static let recentParts: [(id: String, title: String)] = [("today", "Today"), ("yesterday", "Yesterday"), ("week", "This Week"), ("older", "Older")]
    static let recentOlderId = "recent-older"
    /// Recent, whole or one of its days.
    static func isRecent(_ groupId: String) -> Bool { groupId == recentId || groupId.hasPrefix(recentId + "-") }
    /// [sessions-shape] The live chats a closed project draws under its row.
    static let projectLiveRows = 3
    static let recentTitle = "Recent"
    static let freshPinnedRows = 3
    static let freshProjectRows = 2
    static let projectsId = "projects"
    static let chipId = "chip"

    /// A row's identity in the saved orders: its profile and stored id (as the list's item ids).
    static func key(_ session: SessionSummary) -> String { session.profile + "\u{1F}" + session.id }

    /// True when the list is one run without headers.
    static func isFlat(_ prefs: SessionsViewPrefs) -> Bool {
        prefs.sortBy == .tokens || prefs.sortBy == .cost
    }

    /// [sessions-fresh] Group By Recent's layout: Pinned, Projects, Recent.
    static func isFresh(_ prefs: SessionsViewPrefs) -> Bool { prefs.groupBy == .date && !isFlat(prefs) }

    /// [project-keep] A kept project's chat that stays off the lists outside Sessions (the bots' chats under their rows,
    /// the strip over a chat, the Mac's Chats tab), as `listed` keeps it out of Recent and Pinned: shown anyway
    /// while it waits on the owner (`needsInput`).
    static func isKeptAway(_ session: SessionSummary, kept: Set<String>,
                           projectsByProfile: [String: [SessionProject]]) -> Bool {
        // [project-keep] Owner 2026-11-23 ("chats hidden outside that project … are still showing"): a chat pinned
        // everywhere is kept on its project's page too; only one waiting on the owner comes out.
        guard !kept.isEmpty, session.status != .needsInput else { return false }
        return kept.contains(SessionProjects.key(cwd: session.cwd, profile: session.profile, projectsByProfile: projectsByProfile))
    }

    /// [sessions-fresh] A chat a status chip lists. Never an archived one.
    static func matches(_ chip: SessionStatusChip, _ session: SessionSummary, keep: Set<String> = []) -> Bool {
        switch chip {
        case .new: isNew(session, keep: keep)
        case .working: !session.archived && (session.isRunning || session.status == .working)
        }
    }

    /// [sessions-fresh] The chips' counts under the bot chip (the Filter menu's filters do not narrow them).
    /// [project-pills] While the pills are the projects, under the project pill's project(s) instead.
    static func chipCounts(_ input: SessionListInput) -> [SessionStatusChip: Int] {
        var counts: [SessionStatusChip: Int] = [:]
        let picked = input.prefs.pills == .projects ? input.prefs.projectFilter.intersection(input.projects.map(\.key)) : []
        let hidden = hiddenProjects(input)
        // [project-keep] As the chip's list: a kept project's chats count under New while they wait on the owner, and
        // nowhere else (on the project's own page every one counts).
        let kept = picked.isEmpty ? input.keptProjects : []
        for session in input.live where input.botFilter == nil || session.profile == input.botFilter {
            var away = false
            if !picked.isEmpty || !hidden.isEmpty || !kept.isEmpty {
                let found = SessionProjects.key(cwd: session.cwd, profile: session.profile, projectsByProfile: input.projectsByProfile)
                if !picked.isEmpty, !picked.contains(found) { continue }
                if picked.isEmpty, hidden.contains(found) { continue }
                away = kept.contains(found)
            }
            for chip in SessionStatusChip.allCases where matches(chip, session) {
                if away, !(chip == .new && session.status == .needsInput) { continue }
                counts[chip, default: 0] += 1
            }
        }
        return counts
    }

    /// [project-pills] The archived projects the list leaves out while Show › Archived is off. Owner 2026-11-23: under
    /// the Chats (bot) pills too, not only the project pills.
    static func hiddenProjects(_ input: SessionListInput) -> Set<String> {
        !input.prefs.showArchived ? input.archivedProjects : []
    }

    static func groups(_ input: SessionListInput) -> [SessionGroup] {
        let input = withArchivedOutside(input)
        var out = foldedProjects(folded(listed(input), input), input)
        let folders = out.filter { $0.source != nil }
        out.removeAll { $0.source != nil }
        guard !folders.isEmpty else { return out }
        // One row for them all, under Pinned (first when nothing is pinned).
        // The page's order (pinned chats count there), so the row names the platforms as the page lists them.
        let listedHere = Set(folders.compactMap(\.source))
        let order = appSections(input).compactMap(\.source).filter(listedHere.contains)
        var apps = SessionGroup(id: otherAppsId, title: "", sessions: [], total: folders.map(\.total).reduce(0, +),
                                platforms: order, newest: folders.compactMap(\.newest).max())
        apps.waiting = folders.contains(where: \.waiting)
        // [three-piles] Group By Project is the projects first: the row comes after them (Home is their last).
        if input.prefs.groupBy == .project, !isFlat(input.prefs) { return out + [apps] }
        out.insert(apps, at: out.prefix { $0.id == newId || $0.id == "pinned" }.count)   // under New for You and Pinned
        return out
    }

    /// The Other Apps page: a section per platform, every chat in it, the platform with the newest chat first.
    static func appSections(_ input: SessionListInput) -> [SessionGroup] {
        var input = withArchivedOutside(input)
        input.prefs.showArchived = false
        input.prefs.groupBy = .date
        var pinned = Set<String>()
        for session in input.outside where session.pinned { pinned.insert(session.profile + "\u{1F}" + session.id) }
        input.openSources = Set(input.outside.map { ChatSource.id($0.source) })
        input.shownPerSource = Dictionary(uniqueKeysWithValues: input.openSources.map { ($0, Int.max) })
        // Here pinned ones are listed with the rest of their platform's.
        input.outside = input.outside.map { var s = $0; s.pinned = false; return s }
        return folders(input, skipping: [])
    }

    /// Show › Archived: an archived platform chat goes to Other Apps with the live ones (marked there), never among the
    /// dated rows, so archiving or unarchiving one leaves it where it was looked for. Idempotent.
    static func withArchivedOutside(_ input: SessionListInput) -> SessionListInput {
        let archivedOutside = input.archived.filter { ChatSource.hasFolder($0.source) }
        guard !archivedOutside.isEmpty else { return input }
        var input = input
        input.archived.removeAll { ChatSource.hasFolder($0.source) }
        if input.prefs.showArchived { input.outside += archivedOutside }
        return input
    }

    private static func listed(_ input: SessionListInput) -> [SessionGroup] {
        let prefs = input.prefs
        // Every grouping (Group By Project too: the row sits under Pinned, above the projects); a project filter
        // picks project chats, which these aren't.
        let picked = prefs.projectFilter.intersection(input.projects.map(\.key))
        let foldersShown = picked.isEmpty
        // A chat in both (archived a moment ago, the recents not read since) is listed once, as the live row.
        var pool = prefs.showArchived ? input.live + input.archived : input.live
        if foldersShown { pool += input.outside.filter(\.pinned) }        // a pinned platform chat sits in Pinned
        // [three-piles] A project's page lists its archived chats too, as its Done pile (live rows first: a chat in
        // both is listed once, as the live row).
        // [page-count-chips] A status pill keeps the page: it narrows the piles to the chats in that state.
        let isPage = prefs.pills == .projects && picked.count == 1 && !isFlat(prefs)
        if isPage, !prefs.showArchived { pool += input.archived }
        let hidden = picked.isEmpty ? hiddenProjects(input) : []
        // [project-keep] Owner 2026-11-20: a project's chats can stay on its page. A project picked by the filter is
        // being looked at: nothing of it is kept away.
        let kept = picked.isEmpty ? input.keptProjects : []
        let needsProject = !picked.isEmpty || !hidden.isEmpty || !kept.isEmpty || isFresh(prefs) || (prefs.groupBy == .project && !isFlat(prefs))
        var projectOf: [String: String] = [:]
        func key(_ session: SessionSummary) -> String { session.profile + "\u{1F}" + session.id }
        func project(_ session: SessionSummary) -> String { projectOf[key(session)] ?? SessionProjects.homeKey }

        var seen = Set<String>()
        var rows: [SessionSummary] = []
        rows.reserveCapacity(pool.count)
        // [project-cards] Under a bot chip a project also says how many chats it holds under every bot.
        let countsWhole = input.botFilter != nil && (prefs.groupBy == .project || isFresh(prefs)) && !isFlat(prefs)
        var wholeByProject: [String: Int] = [:]
        var wholeSeen = Set<String>()
        for session in pool {
            if countsWhole, prefs.statusFilter.isEmpty || prefs.statusFilter.contains(session.status) {
                let found = SessionProjects.key(cwd: session.cwd, profile: session.profile, projectsByProfile: input.projectsByProfile)
                // [pinned-in-project] A pinned chat counts in its project (Home's pinned chats are Pinned's alone).
                if !session.pinned || found != SessionProjects.homeKey, wholeSeen.insert(key(session)).inserted,
                   picked.isEmpty || picked.contains(found) { wholeByProject[found, default: 0] += 1 }
            }
            if let bot = input.botFilter, session.profile != bot { continue }
            if !prefs.statusFilter.isEmpty, !prefs.statusFilter.contains(session.status) { continue }
            let id = key(session)
            if needsProject {
                let found = SessionProjects.key(cwd: session.cwd, profile: session.profile, projectsByProfile: input.projectsByProfile)
                if !picked.isEmpty, !picked.contains(found) { continue }
                if hidden.contains(found) { continue }               // [project-pills] an archived project
                projectOf[id] = found
            }
            guard seen.insert(id).inserted else { continue }
            rows.append(session)
        }
        if isPage, let key = picked.first {
            return projectPage(key, rows: rows, input: input)
        }
        /// [project-keep] A kept project's chat: listed in its project alone. `asks`: it waits on the owner (an
        /// approval, a question), which never hides.
        func keptAway(_ session: SessionSummary) -> Bool { !kept.isEmpty && kept.contains(project(session)) }
        func asks(_ session: SessionSummary) -> Bool { session.status == .needsInput }
        if let chip = input.statusChip {
            // [sessions-fresh] A status chip: its chats alone, newest first, in one run (Pinned's too).
            let run = sort(rows.filter { matches(chip, $0, keep: input.keepNew) && (!keptAway($0) || (chip == .new && asks($0))) }, by: .updated)
            return run.isEmpty ? [] : [SessionGroup(id: chipId, title: "", sessions: run)]
        }
        let folders = foldersShown ? self.folders(input, skipping: seen) : []
        guard !rows.isEmpty else { return folders }

        let manual = prefs.sortBy == .manual
        // [manual-order] Manual lays each group's chats out in the dragged order (a group at a time, so the date
        // headers stay in time order and a chat stays in its project).
        func ranked(_ rows: [SessionSummary]) -> [SessionSummary] {
            manual ? SessionManualOrder.ordered(rows, id: key, by: input.chatOrder) : rows
        }
        let sorted = sort(rows, by: prefs.sortBy)
        // [sessions-layout] New for You lifts what waits on the user out of every group below it, as Pinned does.
        let lifts = !isFlat(prefs) && prefs.statusFilter.isEmpty && !isFresh(prefs)
        // [project-keep] A kept project's chat is in New for You only while it waits on the owner (not for a reply
        // not read yet).
        let fresh = lifts ? sort(rows.filter { isNew($0, keep: input.keepNew) && (!keptAway($0) || asks($0)) }, by: .updated) : []
        let lifted = Set(fresh.map(key))
        // [project-keep] A kept project's pinned chat is on its page alone (unless it waits on the owner).
        let pinned = ranked(sorted.filter { $0.pinned && !lifted.contains(key($0)) && (!keptAway($0) || asks($0)) })
        // A project keeps its new chats to count them (`folded` leaves them out of its rows).
        let keepsNew = prefs.groupBy == .project
        let rest = sorted.filter { !$0.pinned && (keepsNew || !lifted.contains(key($0))) }
        // [project-keep] Every list below but a project's own leaves the kept projects' chats out.
        let listedRest = kept.isEmpty ? rest : rest.filter { !keptAway($0) }
        var out = fresh.isEmpty ? [] : [SessionGroup(id: newId, title: newTitle, sessions: fresh)]
        if !pinned.isEmpty { out.append(SessionGroup(id: "pinned", title: "Pinned", sessions: pinned)) }
        if isFlat(prefs) {
            return out + (listedRest.isEmpty ? [] : [SessionGroup(id: flatId, title: "", sessions: listedRest)]) + folders
        }
        // [pinned-in-project] Owner 2026-11-15 ("A"): a pinned chat shows in Pinned and stays inside its project, so
        // pinning a project's only chat no longer hides the project (and "See All" counts it). Home is no project: its
        // pinned chats are Pinned's alone.
        let projectRows = sorted.filter {
            $0.pinned ? project($0) != SessionProjects.homeKey && (keepsNew || !lifted.contains(key($0)))
                      : keepsNew || !lifted.contains(key($0))
        }
        // [three-piles] Group By Project draws every chat in its project (Home's pinned ones too).
        guard !rest.isEmpty || !projectRows.isEmpty || prefs.groupBy == .project else { return out + folders }

        /// One group per project, by its newest chat (Home last), then the user's order, favorites first.
        func projectGroups(_ rows: [SessionSummary]) -> [SessionGroup] {
            let labels = Dictionary(input.projects.map { ($0.key, $0.label) }, uniquingKeysWith: { first, _ in first })
            var groups = bucketed(rows) { session in
                let key = project(session)
                return (projectPrefix + key, labels[key] ?? SessionProjects.homeLabel)
            }
            // [projects-all-bots] Owner 2026-11-22 ("I just created a new project … and I can't see it in my list"): the
            // Projects side lists every project, a new one with no chat yet too (last, as the quietest), not only the
            // projects a chat is in. Saved projects only: a folder Hermes found on the disk by itself (`isAuto`) shows
            // once a chat is in it. Not while a status filter narrows the list (an empty project matches nothing).
            if prefs.groupBy == .project, prefs.statusFilter.isEmpty, picked.isEmpty {
                let present = Set(groups.map(\.id))
                let saved = Set(input.projectsByProfile.flatMap { profile, projects in
                    projects.filter { $0.isAuto != true }.map { SessionProjects.key($0, profile: profile) }
                })
                for entry in input.projects where entry.key != SessionProjects.homeKey && saved.contains(entry.key)
                    && !hidden.contains(entry.key) && !present.contains(projectPrefix + entry.key) {
                    groups.append(SessionGroup(id: projectPrefix + entry.key, title: entry.label, sessions: []))
                }
            }
            // A project's place is its newest chat's; Home goes last.
            let home = projectPrefix + SessionProjects.homeKey
            let newest = Dictionary(groups.map { ($0.id, $0.sessions.map(recency).max() ?? -.infinity) }, uniquingKeysWith: { first, _ in first })
            let order = Dictionary(groups.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            groups.sort { a, b in
                if (a.id == home) != (b.id == home) { return b.id == home }
                let ta = newest[a.id] ?? -.infinity, tb = newest[b.id] ?? -.infinity
                return ta != tb ? ta > tb : (order[a.id] ?? 0) < (order[b.id] ?? 0)
            }
            // [manual-order] The user's order over that (Home wherever it was put), favorites first.
            groups = SessionManualOrder.groups(groups, key: { projectKey($0.id) ?? "" }, order: input.projectOrder,
                                               favorites: input.favoriteProjects)
            return groups.map { group in
                var group = group
                group.sessions = ranked(group.sessions)
                group.favorite = input.favoriteProjects.contains(projectKey(group.id) ?? "")
                if countsWhole { group.whole = wholeByProject[projectKey(group.id) ?? ""] ?? group.sessions.count }
                return group
            }
        }

        switch prefs.groupBy {
        case .date:
            // [sessions-shape] Owner 2026-11-18, of the Bots side without a Projects block (1100): "It doesn't feel like it
            // has enough organization", and of the projects a tap further: "we added an additional click". So the block
            // is back as a shortcut, not a list: the starred projects (the newest `freshProjectRows` while none is
            // starred), each one tap from its page, and no See All (the switch's Projects side is all of them). A filter
            // narrowing the list shows every project it finds.
            // [chats-projects] Only with Show › Projects: off (the default), no project here at all, filtered or not.
            var projects = prefs.showProjects
                ? projectGroups(projectRows).filter { $0.id != projectPrefix + SessionProjects.homeKey } : []
            if !projects.isEmpty {
                let narrowed = !prefs.statusFilter.isEmpty || !picked.isEmpty
                if !narrowed {
                    let starred = projects.filter(\.favorite)
                    projects = starred.isEmpty ? Array(projects.prefix(freshProjectRows)) : starred
                }
                projects[0].projectsAll = true
            }
            out += projects
            // Show › Project Chats in Recent off: the chats of the projects shown above stay on their rows; every other
            // chat is listed below (a project not shown has no other place on this side).
            let shownProjects = Set(projects.compactMap { projectKey($0.id) })
            // [bot-home] A tester 2026-11-19 (a bot picked, its projects listed, no Home among them), then the owner the
            // same day ("the main sessions page, before you click on any bot, should show a home project"): the block
            // ends with Home, the chats in no project, one tap from their page. Under a bot's pill it is that bot's;
            // under All every bot's, one bucket, as Hermes's own sidebar merges them. Its pinned chats count (the page
            // lists them); its chats stay in the days below whatever Project Chats in Recent says, and it says no
            // "of N" (every bot's Home is nobody's project). Not without a project shown (then the days below are Home
            // alone), nor while a filter narrows the list (a filter opens every group it finds: Home, open, would
            // list each match a second time over the days that already list it).
            if !projects.isEmpty, prefs.statusFilter.isEmpty, picked.isEmpty {
                let homeRows = sorted.filter { project($0) == SessionProjects.homeKey }
                if !homeRows.isEmpty {
                    out.append(SessionGroup(id: projectPrefix + SessionProjects.homeKey, title: SessionProjects.homeLabel,
                                            sessions: ranked(homeRows)))
                }
            }
            let recent = prefs.projectChatsInRecent ? listedRest : listedRest.filter { !shownProjects.contains(project($0)) }
            // [sessions-shape] One long "Recent" had no landmarks: sorted by a date (Updated, Created) it is split by
            // the day, Today, Yesterday, This Week (the five days before) and Older; any other sort keeps one Recent.
            let sortedRecent = ranked(sort(recent, by: prefs.sortBy))
            if prefs.sortBy == .updated || prefs.sortBy == .created {
                // By the calendar's day, as a row's own time says it ("Yesterday" on a row is under Yesterday).
                let today = input.calendar.startOfDay(for: input.now)
                var parts: [String: [SessionSummary]] = [:]
                for session in sortedRecent {
                    let date = (prefs.sortBy == .created ? session.startedAt ?? session.lastActive : session.lastActive ?? session.startedAt)
                    let days = date.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }.map {
                        input.calendar.dateComponents([.day], from: input.calendar.startOfDay(for: $0), to: today).day ?? .max
                    } ?? .max
                    parts[days <= 0 ? "today" : days == 1 ? "yesterday" : days < 7 ? "week" : "older", default: []].append(session)
                }
                for (part, title) in recentParts {
                    if let chats = parts[part] { out.append(SessionGroup(id: recentId + "-" + part, title: title, sessions: chats)) }
                }
            } else if !sortedRecent.isEmpty {
                out.append(SessionGroup(id: recentId, title: recentTitle, sessions: sortedRecent))
            }
        case .status:
            let working = ranked(listedRest.filter { $0.status == .working || $0.status == .needsInput })
            let done = ranked(listedRest.filter { $0.status != .working && $0.status != .needsInput })
            if !working.isEmpty { out.append(SessionGroup(id: "status-working", title: "Working", sessions: working)) }
            if !done.isEmpty { out.append(SessionGroup(id: "status-done", title: "Done", sessions: done)) }
        case .project:
            // [project-pills] In the project pills' order: what needs the owner first (Needs You, Ready, Working, then
            // the quiet ones), the order above within each (Home last by default, but it moves like any project).
            // [three-piles] The Projects side is the projects alone: no New for You and no Pinned above them (a project's
            // row counts its new replies, the New pill lists them all, and a pinned chat is on its project's page).
            // Home's pinned chats are in Home, as any project's.
            // A pinned chat from another app is no project's: it is on the Other Apps page (and in the Bots side's Pinned).
            out = []
            let outsideKeys = Set(input.outside.map(key))
            let groups = projectGroups(outsideKeys.isEmpty ? sorted : sorted.filter { !outsideKeys.contains(key($0)) })
            func rank(_ group: SessionGroup) -> Int {
                let states = group.sessions.reduce(into: Set<SessionProjectState>()) { $0.formUnion(SessionProjectState.of($1)) }
                return (SessionProjectState.allCases.first(where: states.contains) ?? .quiet).rawValue
            }
            // [three-piles] Home (the chats in no project) is the last row whatever its chats wait on, until the owner
            // gives it a place of its own (Reorder): it is not a project to keep up with.
            let home = projectPrefix + SessionProjects.homeKey
            let homeLast = !input.projectOrder.contains(SessionProjects.homeKey)
            out += groups.enumerated().sorted { a, b in
                if homeLast, (a.element.id == home) != (b.element.id == home) { return b.element.id == home }
                let ra = rank(a.element), rb = rank(b.element)
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map(\.element)
        case .bot:
            // [manual-order] One group per bot, the bot with the newest chat first, then the user's order.
            var groups = bucketed(listedRest) { session in
                (botPrefix + session.profile, input.botNames[session.profile] ?? session.profile)
            }
            let newest = Dictionary(groups.map { ($0.id, $0.sessions.map(recency).max() ?? -.infinity) }, uniquingKeysWith: { first, _ in first })
            let order = Dictionary(groups.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            groups.sort { a, b in
                let ta = newest[a.id] ?? -.infinity, tb = newest[b.id] ?? -.infinity
                return ta != tb ? ta > tb : (order[a.id] ?? 0) < (order[b.id] ?? 0)
            }
            groups = SessionManualOrder.groups(groups, key: { botProfile($0.id) ?? "" }, order: input.botOrder)
            out += groups.map { group in
                var group = group
                group.sessions = ranked(group.sessions)
                return group
            }
        }
        return out + folders
    }

    // MARK: The project page [project-pills]

    /// The project page's header group; its one item is drawn by the view controller.
    static let pageId = "page"
    /// The page's sections: `statePrefix` + needs / ready / working / earlier.
    static let statePrefix = "state-"

    /// [project-pills] Owner 2026-11-15: a project pill opens the project as a page of its own: a header (its name,
    /// folder, branch and bots; how many chats need the owner, have a new reply, are at work), then its chats in
    /// three piles (see below): Pinned, Active, Done.
    static func projectPage(_ key: String, rows: [SessionSummary], input: SessionListInput) -> [SessionGroup] {
        func state(_ session: SessionSummary) -> SessionProjectState {
            SessionProjectState.allCases.first(where: SessionProjectState.of(session).contains) ?? .quiet
        }
        // [three-piles] Done is the project's archived chats. One with a reply not read yet, or at work, is back among
        // the active ones until it is quiet again.
        // [project-pins] A chat pinned on this page alone is in its Pinned pile here and nowhere else.
        let localPins = input.projectPins[key] ?? []
        let marked = localPins.isEmpty ? rows : rows.map { row -> SessionSummary in
            var row = row
            row.projectPinned = localPins.contains(Self.key(row))
            return row
        }
        // [project-auto-done] Owner 2026-11-20: Move Quiet Chats to Done. A live chat that is quiet, not pinned (here
        // or everywhere), not read since the page was last left, and older than the chosen age (or, in a coding
        // project, whose pull request merged) is listed in Done with the archived ones. Nothing is archived or written.
        let rule = input.projectAutoDone[key]
        func movedToDone(_ session: SessionSummary) -> Bool {
            guard let rule, !session.archived, !session.pinned, !session.projectPinned,
                  !input.keepNew.contains(Self.key(session)) else { return false }
            if rule.onMerge, session.pullRequest?.state == .merged { return true }
            guard let days = rule.days, let last = session.lastActive ?? session.startedAt else { return false }
            return input.now.timeIntervalSince(last) > Double(days) * 86_400
        }
        let done = marked.filter { state($0) == .quiet && ($0.archived || movedToDone($0)) }
        let doneKeys = Set(done.map(Self.key))
        let rows = done.isEmpty ? marked : marked.filter { !doneKeys.contains(Self.key($0)) }
        var buckets: [SessionProjectState: [SessionSummary]] = [:]
        for session in rows { buckets[state(session), default: []].append(session) }
        let label = input.projects.first { $0.key == key }?.label ?? key
        var page = SessionGroup(id: pageId, title: "", sessions: [])
        page.pageKey = key
        page.latestTitle = label
        let newest = sort(rows, by: .updated)
        page.newest = newest.first.flatMap { $0.lastActive ?? $0.startedAt }
        page.branch = newest.lazy.compactMap(\.branch).first
        var seen = Set<String>()
        page.profiles = newest.map(\.profile).filter { seen.insert($0).inserted }
        page.needs = buckets[.needsYou]?.count ?? 0
        page.ready = buckets[.ready]?.count ?? 0
        page.busy = buckets[.working]?.count ?? 0
        page.total = rows.count
        var out = [page]
        // [three-piles] Owner 2026-11-17 (picked from pictures, "I like option 1"; before: a heading per state and per
        // age, seven headings for eight chats): three piles. Pinned, the chats kept close; Active, every other chat in
        // one run, what needs the owner first (Needs You, New, Working, then the quiet ones in the list's order), each
        // row saying its own state; Done, the archived ones, closed to its count until tapped.
        let byPref = input.prefs.sortBy == .manual ? SessionSortBy.updated : input.prefs.sortBy
        // [read-holds] Owner 2026-11-21 ("sessions here move when you open them"): a chat read since the page was
        // last left keeps the place its New (or Needs You) gave it, as New for You keeps it; the counts say what is.
        func rank(_ session: SessionSummary) -> Int {
            let now = state(session)
            return now == .quiet && input.keepNew.contains(Self.key(session)) ? SessionProjectState.ready.rawValue : now.rawValue
        }
        // [project-sort] ⋯ › Sort › Newest: one run by the list's sort, reading moves nothing.
        let byNewest = input.projectsByNewest.contains(key)
        let byStatus = input.projectsByStatus.contains(key) && !byNewest
        // Coding projects use the 4-bucket shipping pipeline by default (Ready to Ship / Needs You / In Flight / Shipped).
        if input.codingProjects.contains(key), !byNewest, !byStatus {
            let underPR = { (row: SessionSummary) in
                input.projectPRState.map { row.pullRequest?.countedStates.contains($0) == true } ?? true
            }
            let allMarked = marked.filter(underPR)
            var byBucket: [CodingPipelineBucket: [SessionSummary]] = [:]
            for session in allMarked {
                let b = CodingPipeline.bucket(for: session, isDone: doneKeys.contains(Self.key(session)))
                if let pickedBucket = input.projectPipelineBucket, b != pickedBucket { continue }
                byBucket[b, default: []].append(session)
            }
            let filtered = !input.prefs.statusFilter.isEmpty || input.statusChip != nil || input.projectPRState != nil || input.projectPipelineBucket != nil
            for bucket in CodingPipelineBucket.allCases {
                let raw = byBucket[bucket] ?? []
                guard !raw.isEmpty else { continue }
                let orderedBucket = sort(raw, by: byPref).enumerated().sorted { a, b in
                    let ra = CodingPipeline.subRank(a.element, in: bucket)
                    let rb = CodingPipeline.subRank(b.element, in: bucket)
                    return ra != rb ? ra < rb : a.offset < b.offset
                }.map(\.element)
                let capped = bucket == .inFlight || bucket == .shipped
                var group = SessionGroup(id: statePrefix + bucket.sectionId, title: bucket.sectionTitle, sessions: orderedBucket)
                group.total = group.sessions.count
                group.unread = group.sessions.reduce(0) { $0 + ($1.unread ? 1 : 0) }
                if !filtered {
                    let startsClosed = pageStartsClosed.contains(group.id)
                    if input.collapsedGroups.contains(group.id) || (startsClosed && !input.openGroups.contains(group.id)) {
                        group.collapsed = true
                        group.sessions = []
                    } else if capped, group.sessions.count > pageFirstRows + 1 {
                        if input.expandedGroups.contains(group.id) {
                            group.expanded = true
                        } else {
                            group.more = group.sessions.count - pageFirstRows
                            group.sessions = Array(group.sessions.prefix(pageFirstRows))
                        }
                    }
                }
                out.append(group)
            }
            return out
        }
        let ordered = byNewest ? sort(rows, by: byPref) : sort(rows, by: byPref).enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        // [page-count-chips] Owner 2026-11-18 ("Now the Needs you, new, working pills don't do anything": they went to
        // sections the piles replaced). A count's pill, like the rail's New or Working, narrows the piles to the chats
        // it counts (New: waiting on the owner or a reply not read, and one read since the page was last left); Done
        // is left out, the header and its counts stay. Tapped again, every chat is back.
        let statusShown = input.statusChip.map { chip in
            ordered.filter { session in
                switch chip {
                case .new: state(session) == .needsYou || state(session) == .ready || input.keepNew.contains(Self.key(session))
                case .working: state(session) == .working
                }
            }
        } ?? ordered
        // [pr-multi] A chat is under every state one of its pull requests or branches is in, as the counts are.
        let underPR = { (row: SessionSummary) in
            input.projectPRState.map { row.pullRequest?.countedStates.contains($0) == true } ?? true
        }
        let shown = statusShown.filter(underPR)
        let shownDone = done.filter(underPR)
        let pinnedChats = shown.filter { $0.pinned || $0.projectPinned }
        let activeChats = shown.filter { !$0.pinned && !$0.projectPinned }
        // [project-by-status] ⋯ › Sort › By Status: Active split into a section per state, in rank order (a chat read
        // since the page was last left stays under New until the page is left, as in Needs Me First). Needs You and
        // New show every chat (the ones he acts on); Working and Earlier fold past the first rows as Active does.
        let middle: [(id: String, title: String, chats: [SessionSummary], capped: Bool)] = byStatus
            ? [(statusSectionNeeds, "Needs You", activeChats.filter { rank($0) == SessionProjectState.needsYou.rawValue }, false),
               (statusSectionNew, "New", activeChats.filter { rank($0) == SessionProjectState.ready.rawValue }, false),
               (statusSectionWorking, "Working", activeChats.filter { rank($0) == SessionProjectState.working.rawValue }, true),
               (statusSectionEarlier, "Earlier", activeChats.filter { rank($0) == SessionProjectState.quiet.rawValue }, true)]
            : [("active", "Active", activeChats, true)]
        let sections: [(id: String, title: String, chats: [SessionSummary], capped: Bool)] =
            [("pinned", "Pinned", pinnedChats, false)] + middle +
            [("done", "Done", input.statusChip == nil ? sort(shownDone, by: .updated) : [], true)]
        // A status filter or pill shows every match (a closed section would hide what it was set to find).
        let filtered = !input.prefs.statusFilter.isEmpty || input.statusChip != nil || input.projectPRState != nil
        for section in sections where !section.chats.isEmpty {
            var group = SessionGroup(id: statePrefix + section.id, title: section.title, sessions: section.chats)
            group.total = group.sessions.count
            group.unread = group.sessions.reduce(0) { $0 + ($1.unread ? 1 : 0) }
            if !filtered {
                let startsClosed = pageStartsClosed.contains(group.id)
                if input.collapsedGroups.contains(group.id) || (startsClosed && !input.openGroups.contains(group.id)) {
                    group.collapsed = true
                    group.sessions = []
                } else if section.capped, group.sessions.count > pageFirstRows + 1 {
                    if input.expandedGroups.contains(group.id) {
                        group.expanded = true
                    } else {
                        group.more = group.sessions.count - pageFirstRows
                        group.sessions = Array(group.sessions.prefix(pageFirstRows))
                    }
                }
            }
            out.append(group)
        }
        return out
    }

    /// [three-piles] The project page: the chats Active (or an opened Done) draws before "Show More" (one more than
    /// this is drawn whole: no row is spent hiding a single chat), about two screens of one-line rows; and the pile
    /// that starts closed.
    static let pageFirstRows = 15
    static let pageStartsClosed: Set<String> = [statePrefix + "done", statePrefix + pipelineShipped]
    /// Coding project shipping pipeline sections (after `statePrefix`).
    static let pipelineReady = "pipeline-ready", pipelineNeeds = "pipeline-needs",
               pipelineInFlight = "pipeline-inflight", pipelineShipped = "pipeline-shipped"
    /// A section of the project page ("state-working").
    static func isPageSection(_ groupId: String) -> Bool { groupId.hasPrefix(statePrefix) }
    /// [project-by-status] By Status's sections (after `statePrefix`).
    static let statusSectionNeeds = "needs", statusSectionNew = "new", statusSectionWorking = "working",
               statusSectionEarlier = "earlier"
    /// [project-by-status] The state a By Status section stands for (its header's mark); nil for any other section.
    static func pageSectionState(_ groupId: String) -> SessionProjectState? {
        switch groupId {
        case statePrefix + statusSectionNeeds: .needsYou
        case statePrefix + statusSectionNew: .ready
        case statePrefix + statusSectionWorking: .working
        default: nil
        }
    }

    /// A titled group can fold to its header; a project draws its newest `projectFirstRows` until opened. `total` is
    /// every chat the group holds, `more` the ones past the drawn ones. A status or project filter narrowing the list
    /// shows every match (a closed group would hide what the filter was set to find); the platform folders keep their
    /// own rule.
    static func folded(_ groups: [SessionGroup], _ input: SessionListInput) -> [SessionGroup] {
        let filtered = !input.prefs.statusFilter.isEmpty || !input.prefs.projectFilter.intersection(input.projects.map(\.key)).isEmpty
        // [sessions-shape] Older starts closed under the newer days (never as Recent's only section).
        let olderStartsClosed = groups.contains { isRecent($0.id) && $0.id != recentOlderId }
        return groups.map { group in
            guard group.source == nil, !group.title.isEmpty else { return group }
            guard !isPageSection(group.id) else { return group }     // [project-sections] folded by `projectPage`
            var group = group
            group.total = group.sessions.count
            group.unread = group.sessions.reduce(0) { $0 + ($1.unread ? 1 : 0) }
            if isProject(group.id) {
                // [sessions-layout] The summary row: the newest chat and the bots, newest first.
                let newest = group.sessions.max { recency($0) < recency($1) }
                group.newest = newest?.lastActive ?? newest?.startedAt
                group.latestTitle = newest.map(title)
                var seen = Set<String>()
                group.profiles = group.sessions.sorted { recency($0) > recency($1) }.map(\.profile).filter { seen.insert($0).inserted }
                // [project-cards] Its new chats stay in it too (they are in New for You as well); a bot at work in one
                // shows on the closed card.
                group.working = group.sessions.contains { $0.isRunning || $0.status == .working }
            }
            guard !filtered else { return group }
            // [sessions-layout] A project is folded until opened; any other group until closed. [sessions-fresh] Group By
            // Recent's Pinned draws its newest few until See All. [sessions-collapse] It closes too (owner 2026-11-11:
            // "collapse all of the categories on the sessions page for every view").
            let freshPinned = isFresh(input.prefs) && group.id == "pinned"
            let closed = isProject(group.id) ? !input.openGroups.contains(group.id)
                : group.id == recentOlderId && olderStartsClosed ? !input.openGroups.contains(group.id) || input.collapsedGroups.contains(group.id)
                : input.collapsedGroups.contains(group.id)
            let first = group.id == newId ? newFirstRows : freshPinned ? freshPinnedRows : projectFirstRows
            if folds(group), closed {
                group.collapsed = true
                // [sessions-shape] Owner 2026-11-18 ("an additional click to end up to your final destination"): on the
                // Projects side a closed project keeps its live chats under its row (waiting on the owner, a reply not
                // read, at work; what needs the owner first, `projectLiveRows` at most), each one tap away. The row
                // still counts every chat, and its name opens the page.
                if input.liveUnderProjects, isProject(group.id), input.prefs.groupBy == .project {
                    func rank(_ session: SessionSummary) -> Int {
                        (SessionProjectState.allCases.first(where: SessionProjectState.of(session).contains) ?? .quiet).rawValue
                    }
                    let live = group.sessions.filter { !SessionProjectState.of($0).isEmpty }
                        .enumerated().sorted { a, b in
                            let ra = rank(a.element), rb = rank(b.element)
                            if ra != rb { return ra < rb }
                            let ta = recency(a.element), tb = recency(b.element)
                            return ta != tb ? ta > tb : a.offset < b.offset
                        }.map(\.element)
                    group.sessions = Array(live.prefix(projectLiveRows))
                    return group
                }
                group.sessions = []
            } else if group.id.hasPrefix(projectPrefix) || group.id.hasPrefix(botPrefix) || group.id == newId || freshPinned,
                      group.sessions.count > first {
                if input.expandedGroups.contains(group.id) {
                    group.expanded = true
                } else {
                    group.more = group.sessions.count - first
                    group.sessions = Array(group.sessions.prefix(first))
                }
            }
            return group
        }
    }

    /// [sessions-collapse] "Projects" closed (its caption tapped): the projects in a row draw as one closed "Projects"
    /// header, counting the projects (and their unread chats), until it is tapped open again. Not while a status or
    /// project filter narrows the list (a closed group would hide what the filter was set to find).
    static func foldedProjects(_ groups: [SessionGroup], _ input: SessionListInput) -> [SessionGroup] {
        let filtered = !input.prefs.statusFilter.isEmpty || !input.prefs.projectFilter.intersection(input.projects.map(\.key)).isEmpty
        guard !filtered, input.collapsedGroups.contains(projectsId),
              let first = groups.firstIndex(where: { isProject($0.id) }) else { return groups }
        let end = groups[first...].firstIndex { !isProject($0.id) } ?? groups.endIndex
        let projects = groups[first..<end]
        var closed = SessionGroup(id: projectsId, title: projectsTitle, sessions: [], collapsed: true,
                                  total: projects.first?.projectsTotal ?? projects.count,
                                  unread: projects.reduce(0) { $0 + $1.unread })
        closed.working = projects.contains(where: \.working)
        var out = groups
        out.replaceSubrange(first..<end, with: [closed])
        return out
    }

    /// [sessions-collapse] The projects' caption, and the closed "Projects" header's title.
    static let projectsTitle = "Projects"

    /// A project group's id: "project-" + its key ("project-home").
    static let projectPrefix = "project-"
    /// [manual-order] A bot group's id (Group By Bot): "bot-" + its profile.
    static let botPrefix = "bot-"

    /// The project key of a project group's id; nil for any other group.
    static func projectKey(_ groupId: String) -> String? {
        groupId.hasPrefix(projectPrefix) ? String(groupId.dropFirst(projectPrefix.count)) : nil
    }

    /// The profile of a bot group's id; nil for any other group.
    static func botProfile(_ groupId: String) -> String? {
        groupId.hasPrefix(botPrefix) ? String(groupId.dropFirst(botPrefix.count)) : nil
    }

    /// A header that folds: Pinned, a status and a project, not a date (nothing to put away in "Yesterday"; ivy asked for
    /// projects and Pinned) nor the Other Apps page's platforms. [sessionsminimal] A date folded before stays open.
    /// [sessions-collapse] Group By Recent's Recent and the closed "Projects" header fold too: every titled section on
    /// the page, in every view.
    static func folds(_ group: SessionGroup) -> Bool {
        guard group.source == nil, !group.title.isEmpty, group.id != otherAppsId else { return false }
        return group.id == newId || group.id == "pinned" || isRecent(group.id) || group.id == projectsId
            || isPageSection(group.id) || group.id.hasPrefix("status-") || group.id.hasPrefix(projectPrefix) || group.id.hasPrefix(botPrefix)
    }

    /// A project's group (Group By Project), Home's too.
    static func isProject(_ groupId: String) -> Bool { groupId.hasPrefix(projectPrefix) }

    /// [sessions-layout] A chat New for You lifts: a reply not read yet, or waiting on the user (an approval, a
    /// question), or read since the page was last left (`keep`). Never an archived one.
    static func isNew(_ session: SessionSummary, keep: Set<String> = []) -> Bool {
        guard !session.archived else { return false }
        return session.unread || session.status == .needsInput || keep.contains(key(session))
    }

    /// A chat's title as its row draws it (the summary row's newest chat).
    private static func title(_ session: SessionSummary) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let preview = session.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return preview.isEmpty ? "Untitled Chat" : preview
    }

    /// One folder per platform with a chat that passes the chip and status filter (pinned ones and rows already
    /// listed left out), the platform with the newest chat first.
    private static func folders(_ input: SessionListInput, skipping listed: Set<String>) -> [SessionGroup] {
        var byPlatform: [String: [SessionSummary]] = [:]
        var seen = listed
        for session in input.outside where !session.pinned && ChatSource.hasFolder(session.source) {
            if let bot = input.botFilter, session.profile != bot { continue }
            if !input.prefs.statusFilter.isEmpty, !input.prefs.statusFilter.contains(session.status) { continue }
            guard seen.insert(session.profile + "\u{1F}" + session.id).inserted else { continue }
            byPlatform[ChatSource.id(session.source), default: []].append(session)
        }
        let groups = byPlatform.map { platform, rows -> SessionGroup in
            let all = sort(rows, by: .updated)
            let open = input.openSources.contains(platform)
            let shown = open ? min(all.count, max(1, input.shownPerSource[platform] ?? folderFirstRows)) : 0
            return SessionGroup(id: folderPrefix + platform, title: ChatSource.folderLabel(platform), sessions: Array(all.prefix(shown)),
                                source: platform, collapsed: !open, total: all.count, more: open ? all.count - shown : 0,
                                newest: all.first?.lastActive ?? all.first?.startedAt,
                                waiting: all.contains { $0.status == .needsInput })
        }
        let newest = Dictionary(uniqueKeysWithValues: byPlatform.map { ($0.key, $0.value.map(recency).max() ?? -.infinity) })
        return groups.sorted { a, b in
            let ta = newest[a.source ?? ""] ?? -.infinity, tb = newest[b.source ?? ""] ?? -.infinity
            return ta != tb ? ta > tb : a.id < b.id
        }
    }

    /// Rows in their sorted order, cut into groups in the order each group first appears.
    private static func bucketed(_ rows: [SessionSummary], _ label: (SessionSummary) -> (id: String, title: String)) -> [SessionGroup] {
        var groups: [SessionGroup] = []
        var index: [String: Int] = [:]
        for session in rows {
            let (id, title) = label(session)
            if let at = index[id] { groups[at].sessions.append(session) } else {
                index[id] = groups.count
                groups.append(SessionGroup(id: id, title: title, sessions: [session]))
            }
        }
        return groups
    }

    // MARK: Sort

    /// When a chat was last touched: `last_active`, else `started_at`; none sorts last.
    static func recency(_ session: SessionSummary) -> Double {
        (session.lastActive ?? session.startedAt)?.timeIntervalSince1970 ?? -.infinity
    }

    static func created(_ session: SessionSummary) -> Double {
        (session.startedAt ?? session.lastActive)?.timeIntervalSince1970 ?? -.infinity
    }

    static func sort(_ rows: [SessionSummary], by sortBy: SessionSortBy) -> [SessionSummary] {
        nonisolated struct Keyed {
            var primary: Double       // smaller first
            var recency: Double       // larger first
            var session: SessionSummary
        }
        let keyed = rows.map { session -> Keyed in
            let primary: Double
            switch sortBy {
            case .updated, .manual: primary = 0
            case .created: primary = -created(session)
            case .status: primary = Double(session.status.rank)
            case .tokens: primary = -Double(session.tokens)
            case .cost: primary = -(session.cost.isFinite ? session.cost : 0)
            }
            return Keyed(primary: primary.isNaN ? 0 : primary, recency: recency(session), session: session)
        }
        return keyed.sorted { a, b in
            if a.primary != b.primary { return a.primary < b.primary }
            if a.recency != b.recency { return a.recency > b.recency }
            if a.session.id != b.session.id { return a.session.id < b.session.id }
            return a.session.profile < b.session.profile
        }.map(\.session)
    }
}

// MARK: - The row's words (§9.2; the web's `S/ui-lists/row-model.ts`, `V/app/chat/sidebar/session-row.tsx:186-196`)

nonisolated enum SessionRowWords {
    /// VoiceOver for a group's Show More / Show Less row: "Show 1 more chat", "Show 4 more chats" (audit 05-20).
    static func showMoreLabel(_ more: Int) -> String {
        more > 0 ? "Show \(more) more \(more == 1 ? "chat" : "chats")" : "Show fewer chats"
    }

    /// `compactNumber` (`@hermes/shared` format.ts): nothing for zero; 999 → "999"; 1,000 → "1k"; 1,230 → "1.2k";
    /// 1,500,000 → "1.5M". One decimal, a trailing ".0" dropped. The thresholds sit just under the unit so rounding
    /// never gives "1000k".
    static func compactTokens(_ value: Int) -> String? {
        guard value > 0 else { return nil }
        let n = Double(value)
        func scaled(_ v: Double, _ suffix: String) -> String {
            var text = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), v)
            if text.hasSuffix(".0") { text.removeLast(2) }
            return text + suffix
        }
        if n >= 999_950 { return scaled(n / 1_000_000, "M") }
        if n >= 999.5 { return scaled(n / 1_000, "k") }
        return String(value)
    }

    /// Below a cent the row says nothing ("sub-cent spend rounds to $0.00, which reads as a bug"); else "$0.34".
    static func cost(_ value: Double) -> String? {
        guard value.isFinite, value >= 0.01 else { return nil }
        return "$" + String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// Row Detail's figures, in the row's order: tokens, then cost.
    static func figures(_ session: SessionSummary, detail: Set<SessionRowDetail>) -> [String] {
        [detail.contains(.tokens) ? compactTokens(session.tokens) : nil, detail.contains(.cost) ? cost(session.cost) : nil].compactMap { $0 }
    }

    /// The trailing text: the figures, then the time when Time is on; nil when there is nothing to say.
    static func trailing(_ session: SessionSummary, detail: Set<SessionRowDetail>, time: String) -> String? {
        let parts = figures(session, detail: detail) + (detail.contains(.time) && !time.isEmpty ? [time] : [])
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `git_branch · model · N messages · N tool calls`, each part only when it has a value; the model is the last
    /// path part of its id (`session-row-details.ts:30-47`).
    static func metadata(branch: String?, model: String?, messages: Int?, toolCalls: Int?) -> String {
        var parts: [String] = []
        if let branch = branch?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty { parts.append(branch) }
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            let last = model.split(separator: "/").last.map(String.init) ?? model
            if !last.isEmpty { parts.append(last) }
        }
        if let messages, messages > 0 { parts.append(messages == 1 ? "1 message" : "\(messages) messages") }
        if let toolCalls, toolCalls > 0 { parts.append(toolCalls == 1 ? "1 tool call" : "\(toolCalls) tool calls") }
        return parts.joined(separator: " · ")
    }

    /// The live status words, when the chat has a live turn: the step it is on ("Reading package.json…"), if known.
    static func statusWords(_ status: SessionStatus, step: String? = nil) -> String? {
        switch status {
        case .needsInput: "Needs your input"
        case .working: step.map(LiveSteps.line) ?? "Working…"
        default: nil
        }
    }

    /// What follows the owner on the second line (without a search snippet): the status words, the pending line, the
    /// preview when Preview is on and the chat has one (and a title of its own), else the metadata. nil: the owner alone.
    static func detailText(_ session: SessionSummary, detail: Set<SessionRowDetail>) -> String? {
        if let words = statusWords(session.status, step: session.step) { return words }
        if let pending = session.pending { return pending.prefix + " " + pending.text }
        // A chat without a title of its own already shows its preview as the title: the detail is then the metadata.
        let titled = !session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // [lists] Mac pass round 6: the preview reads as words, as a bot row's does, not "[name](#media:%2F…".
        if detail.contains(.preview), titled, case let preview = RosterPreview.cleanPreviewText(session.preview),
           !preview.isEmpty { return preview }
        return session.metadata.isEmpty ? nil : session.metadata
    }

    /// One VoiceOver stop, the web's order: title · status · "<Owner>: <detail>" · figures and time · Unread · Pinned
    /// · Color · Deleting. The figures are read out ("1.2k tokens", "$0.34").
    static func accessibilityLabel(title: String, session: SessionSummary, ownerName: String, detail: Set<SessionRowDetail>,
                                   time: String, snippet: String? = nil, colorName: String? = nil, busy: Bool = false,
                                   muted: Bool = false, showPR: Bool = false) -> String {
        var parts = [title]
        let status = statusWords(session.status, step: session.step)
        if let status { parts.append(status.replacingOccurrences(of: "…", with: "")) }
        let body: String?
        if let snippet, !snippet.isEmpty { body = snippet } else if status != nil { body = nil } else { body = detailText(session, detail: detail) }
        parts.append(body.map { "\(ownerName): \($0)" } ?? ownerName)
        if detail.contains(.tokens), let tokens = compactTokens(session.tokens) { parts.append("\(tokens) tokens") }
        if detail.contains(.cost), let cost = cost(session.cost) { parts.append(cost) }
        if detail.contains(.time), !time.isEmpty { parts.append(time) }
        if session.unread { parts.append("Unread") }
        if session.pinned { parts.append("Pinned") } else if session.projectPinned { parts.append("Pinned in project") }   // [project-pins]
        if session.archived { parts.append("Archived") }
        if showPR, let pr = session.pullRequest { parts.append("Pull request: " + pr.summary) }
        if showPR, let verdict = PRVerdict.of(session.pullRequest) { parts.append(verdict.spoken) }   // [pr-verdict]
        if muted { parts.append("Muted") }              // UX study #248: the bot is muted on this iPhone
        if let colorName, !colorName.isEmpty { parts.append("Color: \(colorName)") }
        if busy { parts.append("Deleting") }
        return parts.joined(separator: ". ")
    }
}
