// [sessions-m9] What the Sessions Filter & Sort menu, its button and the strip under the chips say
// (docs/spec/3x-sessions.md §3.2, §3.4, §5, §6; the web's `S/ui-lists/filter-menu.ts`, `filter-token.ts`,
// `filter-strip.tsx`). Pure: the menu is a tree of plain nodes the view controller turns into a `UIMenu`, so every
// word here is unit-tested without UIKit.

import Foundation

// MARK: - Projects (§3.4)

/// A project the list can be narrowed to or grouped by. Under All two bots can each have a project on one folder: the
/// key is the folder, so they are one entry.
nonisolated struct SessionProjectEntry: Hashable, Sendable, Identifiable {
    var key: String
    var label: String
    var id: String { key }
}

nonisolated enum SessionProjects {
    /// The key and name of "no project" (the web's `isNoProject` bucket, `B/ui-lists-gates.ts:110-113`).
    static let homeKey = "home"
    static let homeLabel = "Home"

    /// A project's key: its folder without a trailing slash (never expanded: the folder is the gateway computer's).
    static func key(_ project: SessionProject, profile: String) -> String {
        var root = project.root.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        return root.isEmpty ? "id:\(profile)/\(project.id)" : root
    }

    /// Every bot's projects as one list: one entry per key, named by the first bot in `order` that has it, sorted by
    /// name (case-insensitive, numbers in order). Without Home.
    static func entries(_ projectsByProfile: [String: [SessionProject]], order: [String]) -> [SessionProjectEntry] {
        var seen = Set<String>()
        var out: [SessionProjectEntry] = []
        let profiles = order.filter { projectsByProfile[$0] != nil } + projectsByProfile.keys.filter { !order.contains($0) }.sorted()
        for profile in profiles {
            for project in projectsByProfile[profile] ?? [] {
                let key = key(project, profile: profile)
                guard seen.insert(key).inserted else { continue }
                out.append(SessionProjectEntry(key: key, label: project.label))
            }
        }
        return out.sorted { a, b in
            let order = a.label.compare(b.label, options: [.caseInsensitive, .numeric])
            return order == .orderedSame ? a.key < b.key : order == .orderedAscending
        }
    }

    /// What Filter › Project lists: the projects with Home last, and nothing at all unless there is more than one
    /// entry counting Home (`projects.length > 1`).
    static func menuEntries(_ projectsByProfile: [String: [SessionProject]], order: [String]) -> [SessionProjectEntry] {
        let entries = entries(projectsByProfile, order: order)
        return entries.isEmpty ? [] : entries + [SessionProjectEntry(key: homeKey, label: homeLabel)]
    }

    /// The key of the project that holds a chat's folder (the longest folder match); Home when none does.
    static func key(cwd: String?, profile: String, projectsByProfile: [String: [SessionProject]]) -> String {
        guard let projects = projectsByProfile[profile], !projects.isEmpty,
              let id = SessionProject.owner(of: cwd, in: projects), let project = projects.first(where: { $0.id == id }) else { return homeKey }
        return key(project, profile: profile)
    }
}

// MARK: - State and words

/// Everything the menu, the button and the strip read.
nonisolated struct SessionFilterState: Hashable, Sendable {
    var prefs = SessionsViewPrefs()
    /// Show › Background Runs (not a filter: it is not counted, does not fill the button, Clear Filters leaves it).
    var showBackgroundRuns = false
    /// Show › Outside Chats (not a filter either). Show › Archived is `prefs.showArchived`: it adds rows too, so it is
    /// not a filter either.
    var showOutsideChats = false
    /// The chip's bot (never stored).
    var botFilter: String? = nil
    /// Filter › Project's list (Home last); empty when the gateway has no projects.
    var projects: [SessionProjectEntry] = []
    var botCount = 1
    /// Some listed chat reports spend ("a cost sort would rank a list of zeroes").
    var anySpend = false
    /// Either unread source holds a Sessions chat.
    var hasUnread = false
}

nonisolated enum SessionFilterWords {
    static func name(_ sort: SessionSortBy) -> String {
        switch sort {
        case .updated: "Updated"
        case .created: "Created"
        case .status: "Status"
        case .tokens: "Tokens"
        case .cost: "Cost"
        case .manual: "Manual"
        }
    }

    static func name(_ group: SessionGroupBy) -> String {
        switch group {
        case .date: "Recent"          // [sessions-fresh] Pinned, Projects, then Recent: no date headers now
        case .project: "Project"
        case .bot: "Bot"
        case .status: "Status"
        }
    }

    static func name(_ detail: SessionRowDetail) -> String {
        switch detail {
        case .time: "Time"
        case .preview: "Preview"
        case .tokens: "Tokens"
        case .cost: "Cost"
        }
    }

    static func name(_ status: SessionStatus) -> String {
        switch status {
        case .needsInput: "Needs Input"
        case .working: "Working"
        case .unread: "Unread"
        case .draft: "Draft"
        case .idle: "Idle"
        }
    }

    /// C-07 (`filter-token.ts:15-17`): a project the list does not have narrows nothing, so it is not counted.
    static func effectiveProjects(_ state: SessionFilterState) -> Set<String> {
        state.prefs.projectFilter.intersection(state.projects.map(\.key))
    }

    static func filterCount(_ state: SessionFilterState) -> Int {
        state.prefs.statusFilter.count + effectiveProjects(state).count
    }

    /// A chip is a filter for the end row, the deeper read and the empty state; not for the button or the strip.
    static func filtersActive(_ state: SessionFilterState) -> Bool { filterCount(state) > 0 || state.botFilter != nil }

    /// The button's accessible name (`filter-button.tsx:13-33`).
    static func buttonLabel(_ state: SessionFilterState) -> String {
        let count = filterCount(state)
        return count == 0 ? "Filter and Sort" : "Filter and Sort, \(count) \(count == 1 ? "filter" : "filters") on"
    }

    /// The button's value (`filterToken`): the names when there are at most two, else "N Filters".
    static func token(_ state: SessionFilterState) -> String? {
        let count = filterCount(state)
        guard count > 0 else { return nil }
        let picked = effectiveProjects(state)
        let names = SessionStatus.allCases.filter(state.prefs.statusFilter.contains).map(name)
            + state.projects.filter { picked.contains($0.key) }.map(\.label)
        return names.count == count && count <= 2 ? names.joined(separator: " · ") : "\(count) \(count == 1 ? "Filter" : "Filters")"
    }

    /// The strip (`filterStripText`): status names in menu order, then "Project" / "N Projects"; one or two joined
    /// " · ", else "N Filters" (projects count once). Never the chip's bot, nor Show's choices.
    static func stripText(_ state: SessionFilterState) -> String? {
        let projects = effectiveProjects(state).count
        let names = SessionStatus.allCases.filter(state.prefs.statusFilter.contains).map(name)
            + (projects == 0 ? [] : [projects == 1 ? "Project" : "\(projects) Projects"])
        guard !names.isEmpty else { return nil }
        return names.count <= 2 ? names.joined(separator: " · ") : "\(names.count) Filters"
    }

    /// "Any" (or `none`), one or two names joined ", ", else "N Selected" (`picked`, `filter-menu.ts:41-44`).
    static func picked(_ names: [String], none: String = "Any") -> String {
        names.isEmpty ? none : names.count > 2 ? "\(names.count) Selected" : names.joined(separator: ", ")
    }

    static func detailSubtitle(_ state: SessionFilterState) -> String {
        picked(detailOptions(state).filter(state.prefs.shownDetail.contains).map(name), none: "None")
    }

    static func statusSubtitle(_ state: SessionFilterState) -> String {
        picked(SessionStatus.allCases.filter(state.prefs.statusFilter.contains).map(name))
    }

    /// nil when there are no projects to list (the submenu then holds only New Project…).
    static func projectSubtitle(_ state: SessionFilterState) -> String? {
        guard !state.projects.isEmpty else { return nil }
        return picked(state.projects.filter { state.prefs.projectFilter.contains($0.key) }.map(\.label))
    }

    /// Show's checks that are on, in the menu's order: one by its row's own title ("Outside Chats"), two or three by
    /// their first words ("Outside, Background, Archived", which the menu wraps onto more lines rather than cut),
    /// "Chats" with none. [tester batch 3, 2026-10-25] With all three on it read "Runs, Archived": Outside Chats was
    /// never named.
    static func showSubtitle(_ state: SessionFilterState) -> String {
        let on = [state.showOutsideChats ? "Outside Chats" : nil, state.showBackgroundRuns ? "Background Runs" : nil,
                  state.prefs.showArchived ? "Archived" : nil].compactMap { $0 }
        guard on.count > 1 else { return on.first ?? "Chats" }
        return on.map { $0.components(separatedBy: " ")[0] }.joined(separator: ", ")
    }

    /// "None" while the list is one run without headers (Sort By Tokens or Cost), else the choice (C-10).
    static func groupSubtitle(_ state: SessionFilterState) -> String {
        SessionListPipeline.isFlat(state.prefs) ? "None" : name(state.prefs.groupBy)
    }

    /// Cost is offered only once some chat reports spend, or while it is the choice.
    static func sortOptions(_ state: SessionFilterState) -> [SessionSortBy] {
        SessionSortBy.allCases.filter { $0 != .cost || state.anySpend || state.prefs.sortBy == .cost }
    }

    /// Project is offered only when the gateway has projects, Bot only with a second bot; either while it is the choice.
    static func groupOptions(_ state: SessionFilterState) -> [SessionGroupBy] {
        SessionGroupBy.allCases.filter { option in
            switch option {
            case .project: !state.projects.isEmpty || state.prefs.groupBy == .project
            case .bot: state.botCount > 1 || state.prefs.groupBy == .bot
            default: true
            }
        }
    }

    /// [manual-order] Group By's last row: "Reorder Projects…" / "Reorder Bots…" while those groups are drawn.
    static func reorderTitle(_ state: SessionFilterState) -> String? {
        guard !SessionListPipeline.isFlat(state.prefs) else { return nil }
        switch state.prefs.groupBy {
        case .project: return state.projects.isEmpty ? nil : "Reorder Projects…"
        case .bot: return state.botCount > 1 ? "Reorder Bots…" : nil
        default: return nil
        }
    }

    static func detailOptions(_ state: SessionFilterState) -> [SessionRowDetail] {
        SessionRowDetail.allCases.filter { $0 != .cost || state.anySpend || state.prefs.rowDetail.contains(.cost) }
    }
}

// MARK: - The menu (§5)

nonisolated enum SessionFilterAction: Hashable, Sendable {
    case sort(SessionSortBy)
    case group(SessionGroupBy)
    case detail(SessionRowDetail)
    case status(SessionStatus)
    case project(String)
    case newProject
    /// [manual-order] Group By › Reorder Projects… / Reorder Bots… (opens the reorder page).
    case reorderGroups
    case allBots
    case runs
    case outside
    case archived
    /// [sessions-fresh] Show › Bot Faces.
    case botFaces
    /// Show › Project Chats in Recent.
    case projectChatsInRecent
    case clear
    case readAll
}

/// One row of the menu: an action, a submenu, or an inline group.
nonisolated struct SessionFilterNode: Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case action(SessionFilterAction)
        /// `single`: one choice, checked (Sort By, Group By).
        case submenu(single: Bool)
        case inline
    }
    /// The accessibility identifier, and the menu's identity while it is open.
    var id: String
    var title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var checked = false
    var disabled = false
    var keepsOpen = false
    var kind: Kind
    var children: [SessionFilterNode] = []
}

nonisolated enum SessionFilterMenuModel {
    /// Which row ends the menu. It is chosen when the menu opens and is not swapped while it stays open; its disabled
    /// state follows the toggles (`liveRows`, `filter-menu.ts:53-63`).
    nonisolated enum End: Hashable, Sendable { case clear, readAll }

    static func end(_ state: SessionFilterState) -> End { SessionFilterWords.filtersActive(state) ? .clear : .readAll }

    static func nodes(_ state: SessionFilterState, end: End? = nil) -> [SessionFilterNode] {
        typealias W = SessionFilterWords
        let prefs = state.prefs
        func check(_ id: String, _ title: String, _ on: Bool, _ action: SessionFilterAction, symbol: String? = nil) -> SessionFilterNode {
            SessionFilterNode(id: id, title: title, symbol: symbol, checked: on, keepsOpen: true, kind: .action(action))
        }
        let sort = SessionFilterNode(
            id: "sessions.filter.sort", title: "Sort By", subtitle: W.name(prefs.sortBy), symbol: "arrow.up.arrow.down",
            kind: .submenu(single: true),
            children: W.sortOptions(state).map {
                SessionFilterNode(id: "sessions.filter.sort.\($0.rawValue)", title: W.name($0), checked: $0 == prefs.sortBy, kind: .action(.sort($0)))
            })
        var groupRows = W.groupOptions(state).map {
            // Parked while the list is flat: a pick would move the check and change nothing.
            SessionFilterNode(id: "sessions.filter.group.\($0.rawValue)", title: W.name($0), checked: $0 == prefs.groupBy,
                              disabled: SessionListPipeline.isFlat(prefs), kind: .action(.group($0)))
        }
        if let reorder = W.reorderTitle(state) {
            groupRows.append(SessionFilterNode(id: "sessions.filter.group.reorder-section", title: "", kind: .inline, children: [
                SessionFilterNode(id: "sessions.filter.group.reorder", title: reorder, symbol: "line.3.horizontal",
                                  kind: .action(.reorderGroups)),
            ]))
        }
        let group = SessionFilterNode(
            id: "sessions.filter.group", title: "Group By", subtitle: W.groupSubtitle(state), symbol: "rectangle.grid.1x2",
            kind: .submenu(single: true), children: groupRows)
        func detailId(_ detail: SessionRowDetail) -> String { detail == .time ? "time" : detail.rawValue }
        let detail = SessionFilterNode(
            id: "sessions.filter.detail", title: "Row Detail", subtitle: W.detailSubtitle(state), symbol: "text.alignleft",
            kind: .submenu(single: false),
            children: W.detailOptions(state).map {
                check("sessions.filter.detail.\(detailId($0))", W.name($0), prefs.shownDetail.contains($0), .detail($0))
            })
        let status = SessionFilterNode(
            id: "sessions.filter.status", title: "Status", subtitle: W.statusSubtitle(state), symbol: "circle.dashed",
            kind: .submenu(single: false),
            children: SessionStatus.allCases.map {
                check("sessions.filter.status.\($0.rawValue)", W.name($0), prefs.statusFilter.contains($0), .status($0))
            })
        let newProject = SessionFilterNode(id: "sessions.filter.project.new", title: "New Project…", symbol: "folder.badge.plus",
                                           kind: .action(.newProject))
        var projectRows = state.projects.enumerated().map { index, entry in
            check("sessions.filter.project.\(index)", entry.label, prefs.projectFilter.contains(entry.key), .project(entry.key))
        }
        if projectRows.isEmpty {
            projectRows = [newProject]
        } else {
            projectRows.append(SessionFilterNode(id: "sessions.filter.project.create", title: "", kind: .inline, children: [newProject]))
        }
        let project = SessionFilterNode(id: "sessions.filter.project", title: "Project", subtitle: W.projectSubtitle(state), symbol: "folder",
                                        kind: .submenu(single: false), children: projectRows)
        var filter = [status, project]
        if state.botCount > 1 {
            filter.append(check("sessions.filter.allbots", "All Bots", state.botFilter == nil, .allBots, symbol: "person.2"))
        }
        // [sessions-fresh] Bot Faces and Project Chats in Recent only under Group By Recent: the other groupings keep
        // their full rows and have no Recent.
        let faces = SessionListPipeline.isFresh(prefs)
            ? [check("sessions.filter.faces", "Bot Faces", prefs.botFaces, .botFaces, symbol: "face.smiling"),
               check("sessions.filter.projectchats", "Project Chats in Recent", prefs.projectChatsInRecent, .projectChatsInRecent,
                     symbol: "folder")] : []
        filter.append(SessionFilterNode(
            id: "sessions.filter.show", title: "Show", subtitle: W.showSubtitle(state), symbol: "eye", kind: .submenu(single: false),
            children: faces + [check("sessions.filter.outside", "Outside Chats", state.showOutsideChats, .outside,
                                     symbol: "bubble.left.and.bubble.right"),
                               check("sessions.filter.runs", "Background Runs", state.showBackgroundRuns, .runs, symbol: "gearshape.2"),
                               check("sessions.filter.archived", "Archived", prefs.showArchived, .archived, symbol: "archivebox")]))
        let active = W.filtersActive(state)
        let last: SessionFilterNode
        switch end ?? self.end(state) {
        case .clear:
            last = SessionFilterNode(id: "sessions.filter.clear", title: "Clear Filters", symbol: "xmark.circle", disabled: !active,
                                     kind: .action(.clear))
        case .readAll:
            last = SessionFilterNode(id: "sessions.filter.readall", title: "Mark All as Read", symbol: "envelope.open",
                                     disabled: active || !state.hasUnread, kind: .action(.readAll))
        }
        return [
            SessionFilterNode(id: "sessions.filter.view", title: "", kind: .inline, children: [sort, group, detail]),
            SessionFilterNode(id: "sessions.filter.filters", title: "Filter", kind: .inline, children: filter),
            SessionFilterNode(id: "sessions.filter.end", title: "", kind: .inline, children: [last]),
        ]
    }
}

// MARK: - Applying a pick (§5.5, §5.6)

nonisolated enum SessionFilterApply {
    /// What a toggle or pick does to the choices. `homeBot`: the chip All Bots ✓ picks when it is turned off.
    /// Returns false for the rows that do something else (New Project…, Mark All as Read).
    @discardableResult
    static func apply(_ action: SessionFilterAction, to state: inout SessionFilterState, homeBot: String) -> Bool {
        switch action {
        case .sort(let value): state.prefs.sortBy = value
        case .group(let value): state.prefs.groupBy = value
        case .detail(.preview) where SessionListPipeline.isFresh(state.prefs): state.prefs.recentPreview.toggle()
        case .detail(let value): state.prefs.rowDetail.formSymmetricDifference([value])
        case .status(let value): state.prefs.statusFilter.formSymmetricDifference([value])
        case .project(let key): state.prefs.projectFilter.formSymmetricDifference([key])
        case .allBots: state.botFilter = state.botFilter == nil ? homeBot : nil
        case .runs: state.showBackgroundRuns.toggle()
        case .outside: state.showOutsideChats.toggle()
        case .archived: state.prefs.showArchived.toggle()
        case .botFaces: state.prefs.botFaces.toggle()
        case .projectChatsInRecent: state.prefs.projectChatsInRecent.toggle()
        case .clear: clear(&state)
        case .newProject, .readAll, .reorderGroups: return false
        }
        return true
    }

    /// Clear Filters (`filter-apply.ts:22-29`): status, project and the chip's bot go off; Sort By, Group By,
    /// Row Detail and Show's choices (Bot Faces, Project Chats in Recent, Outside Chats, Background Runs, Archived) stay.
    static func clear(_ state: inout SessionFilterState) {
        clearStrip(&state)
        state.botFilter = nil
    }

    /// The strip's tap (`filter-strip.tsx:28-33`): status and project; the chip's bot stays.
    static func clearStrip(_ state: inout SessionFilterState) {
        state.prefs.statusFilter = []
        state.prefs.projectFilter = []
    }
}
