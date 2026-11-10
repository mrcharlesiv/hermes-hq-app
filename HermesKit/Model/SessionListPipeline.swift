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
// its chats alone, newest first, in one run.
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
    /// Group By Bot's headers: each bot's display name by profile (missing: the profile).
    var botNames: [String: String] = [:]
    /// [sessions-fresh] The header's New or Working chip (in memory, as the bot chip).
    var statusChip: SessionStatusChip? = nil
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

    /// [sessions-fresh] A chat a status chip lists. Never an archived one.
    static func matches(_ chip: SessionStatusChip, _ session: SessionSummary, keep: Set<String> = []) -> Bool {
        switch chip {
        case .new: isNew(session, keep: keep)
        case .working: !session.archived && (session.isRunning || session.status == .working)
        }
    }

    /// [sessions-fresh] The chips' counts under the bot chip (the Filter menu's filters do not narrow them).
    static func chipCounts(_ input: SessionListInput) -> [SessionStatusChip: Int] {
        var counts: [SessionStatusChip: Int] = [:]
        for session in input.live where input.botFilter == nil || session.profile == input.botFilter {
            for chip in SessionStatusChip.allCases where matches(chip, session) { counts[chip, default: 0] += 1 }
        }
        return counts
    }

    static func groups(_ input: SessionListInput) -> [SessionGroup] {
        let input = withArchivedOutside(input)
        var out = folded(listed(input), input)
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
        let needsProject = !picked.isEmpty || isFresh(prefs) || (prefs.groupBy == .project && !isFlat(prefs))
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
            if countsWhole, !session.pinned, prefs.statusFilter.isEmpty || prefs.statusFilter.contains(session.status),
               wholeSeen.insert(key(session)).inserted {
                let found = SessionProjects.key(cwd: session.cwd, profile: session.profile, projectsByProfile: input.projectsByProfile)
                if picked.isEmpty || picked.contains(found) { wholeByProject[found, default: 0] += 1 }
            }
            if let bot = input.botFilter, session.profile != bot { continue }
            if !prefs.statusFilter.isEmpty, !prefs.statusFilter.contains(session.status) { continue }
            let id = key(session)
            if needsProject {
                let found = SessionProjects.key(cwd: session.cwd, profile: session.profile, projectsByProfile: input.projectsByProfile)
                if !picked.isEmpty, !picked.contains(found) { continue }
                projectOf[id] = found
            }
            guard seen.insert(id).inserted else { continue }
            rows.append(session)
        }
        if let chip = input.statusChip {
            // [sessions-fresh] A status chip: its chats alone, newest first, in one run (Pinned's too).
            let run = sort(rows.filter { matches(chip, $0, keep: input.keepNew) }, by: .updated)
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
        let fresh = lifts ? sort(rows.filter { isNew($0, keep: input.keepNew) }, by: .updated) : []
        let lifted = Set(fresh.map(key))
        let pinned = ranked(sorted.filter { $0.pinned && !lifted.contains(key($0)) })
        // A project keeps its new chats to count them (`folded` leaves them out of its rows).
        let keepsNew = prefs.groupBy == .project
        let rest = sorted.filter { !$0.pinned && (keepsNew || !lifted.contains(key($0))) }
        var out = fresh.isEmpty ? [] : [SessionGroup(id: newId, title: newTitle, sessions: fresh)]
        if !pinned.isEmpty { out.append(SessionGroup(id: "pinned", title: "Pinned", sessions: pinned)) }
        guard !rest.isEmpty else { return out + folders }
        if isFlat(prefs) { return out + [SessionGroup(id: flatId, title: "", sessions: rest)] + folders }

        /// One group per project, by its newest chat (Home last), then the user's order, favorites first.
        func projectGroups(_ rows: [SessionSummary]) -> [SessionGroup] {
            let labels = Dictionary(input.projects.map { ($0.key, $0.label) }, uniquingKeysWith: { first, _ in first })
            var groups = bucketed(rows) { session in
                let key = project(session)
                return (projectPrefix + key, labels[key] ?? SessionProjects.homeLabel)
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
            // [sessions-fresh] The projects (Home's chats are Recent's alone), their newest few under "Projects" until
            // See All; then every chat newest first.
            var projects = projectGroups(rest).filter { $0.id != projectPrefix + SessionProjects.homeKey }
            if !projects.isEmpty {
                // A filter narrowing the list shows every project it finds; See All (and Show Less) only while there are
                // projects to hide.
                // Every favorite shows (they come first), at least `freshProjectRows` (owner: three favorites, two shown).
                let shown = max(freshProjectRows, projects.filter(\.favorite).count)
                let narrowed = !prefs.statusFilter.isEmpty || !picked.isEmpty
                if !narrowed && projects.count > shown { projects[0].projectsTotal = projects.count }
                projects[0].projectsAll = narrowed || input.expandedGroups.contains(projectsId) || projects.count <= shown
                if !projects[0].projectsAll { projects = Array(projects.prefix(shown)) }
            }
            out += projects
            // Show › Project Chats in Recent off: a project's chats stay on its card (See All finds a project past
            // the first few), and Recent keeps Home's.
            let recent = prefs.projectChatsInRecent ? rest : rest.filter { project($0) == SessionProjects.homeKey }
            if !recent.isEmpty {
                out.append(SessionGroup(id: recentId, title: recentTitle, sessions: ranked(sort(recent, by: prefs.sortBy))))
            }
        case .status:
            let working = ranked(rest.filter { $0.status == .working || $0.status == .needsInput })
            let done = ranked(rest.filter { $0.status != .working && $0.status != .needsInput })
            if !working.isEmpty { out.append(SessionGroup(id: "status-working", title: "Working", sessions: working)) }
            if !done.isEmpty { out.append(SessionGroup(id: "status-done", title: "Done", sessions: done)) }
        case .project:
            out += projectGroups(rest)
        case .bot:
            // [manual-order] One group per bot, the bot with the newest chat first, then the user's order.
            var groups = bucketed(rest) { session in
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

    /// A titled group can fold to its header; a project draws its newest `projectFirstRows` until opened. `total` is
    /// every chat the group holds, `more` the ones past the drawn ones. A status or project filter narrowing the list
    /// shows every match (a closed group would hide what the filter was set to find); the platform folders keep their
    /// own rule.
    static func folded(_ groups: [SessionGroup], _ input: SessionListInput) -> [SessionGroup] {
        let filtered = !input.prefs.statusFilter.isEmpty || !input.prefs.projectFilter.intersection(input.projects.map(\.key)).isEmpty
        return groups.map { group in
            guard group.source == nil, !group.title.isEmpty else { return group }
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
            // Recent's Pinned never closes: it draws its newest few until See All.
            let freshPinned = isFresh(input.prefs) && group.id == "pinned"
            let closed = isProject(group.id) ? !input.openGroups.contains(group.id) : !freshPinned && input.collapsedGroups.contains(group.id)
            let first = group.id == newId ? newFirstRows : freshPinned ? freshPinnedRows : projectFirstRows
            if folds(group), closed {
                group.collapsed = true
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
    static func folds(_ group: SessionGroup) -> Bool {
        guard group.source == nil, !group.title.isEmpty, group.id != otherAppsId else { return false }
        return group.id == newId || group.id == "pinned" || group.id.hasPrefix("status-") || group.id.hasPrefix(projectPrefix)
            || group.id.hasPrefix(botPrefix)
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
        if detail.contains(.preview), titled, let preview = session.preview?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preview.isEmpty { return preview }
        return session.metadata.isEmpty ? nil : session.metadata
    }

    /// One VoiceOver stop, the web's order: title · status · "<Owner>: <detail>" · figures and time · Unread · Pinned
    /// · Color · Deleting. The figures are read out ("1.2k tokens", "$0.34").
    static func accessibilityLabel(title: String, session: SessionSummary, ownerName: String, detail: Set<SessionRowDetail>,
                                   time: String, snippet: String? = nil, colorName: String? = nil, busy: Bool = false,
                                   muted: Bool = false) -> String {
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
        if session.pinned { parts.append("Pinned") }
        if session.archived { parts.append("Archived") }
        if muted { parts.append("Muted") }              // UX study #248: the bot is muted on this iPhone
        if let colorName, !colorName.isEmpty { parts.append("Color: \(colorName)") }
        if busy { parts.append("Deleting") }
        return parts.joined(separator: ". ")
    }
}
