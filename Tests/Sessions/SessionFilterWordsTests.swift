import Foundation
import Testing
@testable import HermesHQNative

/// [sessions-m9] The Filter & Sort menu's words, the button and the strip (docs/spec/3x-sessions.md §5, §6).
@Suite struct SessionFilterWordsTests {
    private static let projects = [SessionProjectEntry(key: "/r", label: "Reading"), SessionProjectEntry(key: "/s", label: "Site"),
                                   SessionProjectEntry(key: "/t", label: "Trips"), SessionProjectEntry(key: "home", label: "Home")]

    private func state(_ edit: (inout SessionFilterState) -> Void = { _ in }) -> SessionFilterState {
        var s = SessionFilterState(projects: Self.projects, botCount: 3, anySpend: true, hasUnread: true)
        edit(&s)
        return s
    }

    private func node(_ id: String, in nodes: [SessionFilterNode]) -> SessionFilterNode? {
        for n in nodes {
            if n.id == id { return n }
            if let found = node(id, in: n.children) { return found }
        }
        return nil
    }

    @Test func menuShapeAndWords() throws {
        let nodes = SessionFilterMenuModel.nodes(state())
        #expect(nodes.map(\.id) == ["sessions.filter.view", "sessions.filter.filters", "sessions.filter.end"])
        #expect(nodes[1].title == "Filter" && nodes.allSatisfy { $0.kind == .inline })
        #expect(nodes[0].children.map(\.title) == ["Sort By", "Group By", "Row Detail"])
        // [sessions-fresh] was Date. Recent's rows are one line until Preview is picked there (`recentPreview`).
        #expect(nodes[0].children.map(\.subtitle) == ["Updated", "Recent", "Time"])
        #expect(nodes[0].children.map(\.symbol) == ["arrow.up.arrow.down", "rectangle.grid.1x2", "text.alignleft"])
        #expect(nodes[1].children.map(\.title) == ["Status", "Project", "All Bots", "Show"])
        #expect(nodes[1].children.map(\.subtitle) == ["Any", "Any", nil, "Chats"])
        #expect(nodes[2].children.map(\.title) == ["Mark All as Read"])
        let sort = try #require(node("sessions.filter.sort", in: nodes))
        #expect(sort.kind == .submenu(single: true))
        #expect(sort.children.map(\.title) == ["Updated", "Created", "Status", "Tokens", "Cost", "Manual"])     // [manual-order]
        #expect(sort.children.map(\.id).last == "sessions.filter.sort.manual" && sort.children.allSatisfy { !$0.keepsOpen })
        #expect(sort.children.filter(\.checked).map(\.title) == ["Updated"])
        let group = try #require(node("sessions.filter.group", in: nodes))
        #expect(group.children.map(\.title) == ["Recent", "Project", "Bot", "Status"])        // [manual-order] Bot with a second bot
        let detail = try #require(node("sessions.filter.detail", in: nodes))
        #expect(detail.children.map(\.id) == ["sessions.filter.detail.time", "sessions.filter.detail.preview",
                                              "sessions.filter.detail.tokens", "sessions.filter.detail.cost"])
        #expect(detail.children.allSatisfy(\.keepsOpen) && detail.children.filter(\.checked).map(\.title) == ["Time"])
        let status = try #require(node("sessions.filter.status", in: nodes))
        #expect(status.children.map(\.title) == ["Needs Input", "Working", "Unread", "Draft", "Idle"])
        #expect(status.children.map(\.id).first == "sessions.filter.status.needs-input")
        let project = try #require(node("sessions.filter.project", in: nodes))
        #expect(project.children.map(\.title) == ["Reading", "Site", "Trips", "Home", ""])
        #expect(project.children.last?.children.map(\.title) == ["New Project…"])
        #expect(project.children.map(\.id).prefix(2) == ["sessions.filter.project.0", "sessions.filter.project.1"])
        let show = try #require(node("sessions.filter.show", in: nodes))
        // [sessions-fresh] Bot Faces and Project Chats in Recent first, on by default, under Group By Recent alone.
        #expect(show.children.map(\.title) == ["Bot Faces", "Project Chats in Recent", "Outside Chats", "Background Runs", "Archived"])
        #expect(show.children.map(\.id) == ["sessions.filter.faces", "sessions.filter.projectchats", "sessions.filter.outside",
                                            "sessions.filter.runs", "sessions.filter.archived"])
        #expect(show.children.prefix(2).allSatisfy { $0.checked && $0.keepsOpen })
        let byProject = SessionFilterMenuModel.nodes(state { $0.prefs.groupBy = .project })
        #expect(node("sessions.filter.faces", in: byProject) == nil)
        #expect(node("sessions.filter.projectchats", in: byProject) == nil)
        var hidden = state()
        SessionFilterApply.apply(.projectChatsInRecent, to: &hidden, homeBot: "default")
        #expect(!hidden.prefs.projectChatsInRecent && SessionFilterWords.filterCount(hidden) == 0)
        #expect(node("sessions.filter.allbots", in: nodes)?.checked == true)
    }

    /// A tester, 2026-11-12: Row Detail › Preview did nothing under Group By Recent (its rows are one line). There it
    /// is its own switch (`recentPreview`, off by default); the other groupings keep `rowDetail`'s, and neither moves the other.
    @Test func previewUnderRecentIsItsOwnSwitch() throws {
        var s = state()
        #expect(!s.prefs.shownDetail.contains(.preview))
        SessionFilterApply.apply(.detail(.preview), to: &s, homeBot: "default")
        #expect(s.prefs.recentPreview && s.prefs.rowDetail == [.preview, .time] && s.prefs.shownDetail == [.preview, .time])
        let detail = try #require(node("sessions.filter.detail", in: SessionFilterMenuModel.nodes(s)))
        #expect(detail.children.filter(\.checked).map(\.title) == ["Time", "Preview"])
        #expect(SessionFilterWords.detailSubtitle(s) == "Time, Preview")
        s.prefs.groupBy = .project
        SessionFilterApply.apply(.detail(.preview), to: &s, homeBot: "default")
        #expect(s.prefs.recentPreview && s.prefs.rowDetail == [.time] && s.prefs.shownDetail == [.time])
        // Kept across a save.
        var saved = SessionsViewPrefs()
        saved.recentPreview = true
        let back = try JSONDecoder().decode(SessionsViewPrefs.self, from: JSONEncoder().encode(saved))
        #expect(back.recentPreview && back.shownDetail.contains(.preview))
        #expect(try JSONDecoder().decode(SessionsViewPrefs.self, from: Data("{}".utf8)).recentPreview == false)
    }

    @Test func optionsThatComeAndGo() {
        // One bot: no All Bots. No projects: Project holds only New Project…, no subtitle; Group By has no Project.
        let bare = SessionFilterMenuModel.nodes(SessionFilterState(botCount: 1))
        #expect(node("sessions.filter.allbots", in: bare) == nil)
        #expect(node("sessions.filter.project", in: bare)?.children.map(\.title) == ["New Project…"])
        #expect(node("sessions.filter.project", in: bare)?.subtitle == nil)
        #expect(node("sessions.filter.group", in: bare)?.children.map(\.title) == ["Recent", "Status"])
        // No spend: no Cost, unless it is already the choice.
        #expect(node("sessions.filter.sort", in: bare)?.children.map(\.title) == ["Updated", "Created", "Status", "Tokens", "Manual"])
        #expect(node("sessions.filter.detail", in: bare)?.children.map(\.title) == ["Time", "Preview", "Tokens"])
        var chosen = SessionFilterState(botCount: 1)
        chosen.prefs.sortBy = .cost
        chosen.prefs.rowDetail.insert(.cost)
        chosen.prefs.groupBy = .project
        let kept = SessionFilterMenuModel.nodes(chosen)
        #expect(node("sessions.filter.sort", in: kept)?.children.map(\.title).suffix(2) == ["Cost", "Manual"])
        #expect(node("sessions.filter.detail", in: kept)?.children.map(\.title).last == "Cost")
        #expect(node("sessions.filter.group", in: kept)?.children.map(\.title) == ["Recent", "Project", "Status"])
        #expect(node("sessions.filter.faces", in: kept) == nil)                                  // [sessions-fresh] not under a ranked sort
        #expect(node("sessions.filter.group", in: kept)?.subtitle == "None")                    // C-10
        #expect(node("sessions.filter.group", in: kept)?.children.allSatisfy(\.disabled) == true)
        #expect(node("sessions.filter.group", in: bare)?.children.contains(where: \.disabled) == false)
        // Show › Archived adds rows to the grouped list: Group By stays live.
        var archived = SessionFilterState(botCount: 1)
        archived.prefs.showArchived = true
        #expect(node("sessions.filter.group", in: SessionFilterMenuModel.nodes(archived))?.subtitle == "Recent")
        #expect(node("sessions.filter.group", in: SessionFilterMenuModel.nodes(archived))?.children.contains(where: \.disabled) == false)
    }

    @Test func subtitles() {
        #expect(SessionFilterWords.picked([]) == "Any")
        #expect(SessionFilterWords.picked(["Working", "Unread"]) == "Working, Unread")
        #expect(SessionFilterWords.picked(["a", "b", "c"]) == "3 Selected")
        #expect(SessionFilterWords.detailSubtitle(state { $0.prefs.rowDetail = [] }) == "None")
        #expect(SessionFilterWords.detailSubtitle(state { $0.prefs.groupBy = .project; $0.prefs.rowDetail = [.time, .preview, .tokens] }) == "3 Selected")
        #expect(SessionFilterWords.detailSubtitle(state { $0.prefs.groupBy = .project; $0.prefs.rowDetail = Set(SessionRowDetail.allCases) }) == "4 Selected")
        #expect(SessionFilterWords.detailSubtitle(state { $0.prefs.rowDetail = [.cost, .time] }) == "Time, Cost")     // menu order
        #expect(SessionFilterWords.statusSubtitle(state { $0.prefs.statusFilter = [.unread, .working] }) == "Working, Unread")
        #expect(SessionFilterWords.projectSubtitle(state { $0.prefs.projectFilter = ["/s"] }) == "Site")
        #expect(SessionFilterWords.groupSubtitle(state { $0.prefs.sortBy = .tokens }) == "None")
        #expect(SessionFilterWords.groupSubtitle(state { $0.prefs.showArchived = true; $0.prefs.groupBy = .status }) == "Status")
        #expect(SessionFilterWords.groupSubtitle(state { $0.prefs.groupBy = .status }) == "Status")
    }

    /// [tester batch 3] Show names every check that is on, for each of the eight ways the three can be set: one by its
    /// row's title, two or three by their first words in the menu's order (all three read "Runs, Archived" before).
    @Test(arguments: [
        (false, false, false, "Chats"),
        (true, false, false, "Outside Chats"),
        (false, true, false, "Background Runs"),
        (false, false, true, "Archived"),
        (true, true, false, "Outside, Background"),
        (true, false, true, "Outside, Archived"),
        (false, true, true, "Background, Archived"),
        (true, true, true, "Outside, Background, Archived"),
    ])
    func showSubtitle(outside: Bool, runs: Bool, archived: Bool, shown: String) throws {
        let checks = state { $0.showOutsideChats = outside; $0.showBackgroundRuns = runs; $0.prefs.showArchived = archived }
        #expect(SessionFilterWords.showSubtitle(checks) == shown)
        let show = try #require(node("sessions.filter.show", in: SessionFilterMenuModel.nodes(checks)))
        #expect(show.subtitle == shown, "the menu's row says the same")
        // [sessions-fresh] Bot Faces and Project Chats in Recent (on by default) add no rows: Show's subtitle leaves them out.
        let layout: Set<String> = ["sessions.filter.faces", "sessions.filter.projectchats"]
        #expect(show.children.filter { $0.checked && !layout.contains($0.id) }.count == [outside, runs, archived].filter { $0 }.count)
    }

    @Test func showSubtitleNamesAOneCheckAsItsRowAndFollowsEachToggle() throws {
        // One check on: the subtitle is that row's own title, whatever the menu calls it.
        let rows = try #require(node("sessions.filter.show", in: SessionFilterMenuModel.nodes(state()))).children
            .filter { $0.id != "sessions.filter.faces" && $0.id != "sessions.filter.projectchats" }
        let alone: [SessionFilterState] = [state { $0.showOutsideChats = true }, state { $0.showBackgroundRuns = true },
                                           state { $0.prefs.showArchived = true }]
        #expect(alone.map(SessionFilterWords.showSubtitle) == rows.map(\.title))
        // Each toggle through the menu's own action re-says it (the parent row's subtitle while the menu is open).
        var s = state()
        var said: [String] = []
        for action: SessionFilterAction in [.outside, .runs, .archived, .outside, .runs, .archived] {
            SessionFilterApply.apply(action, to: &s, homeBot: "default")
            said.append(try #require(node("sessions.filter.show", in: SessionFilterMenuModel.nodes(s))).subtitle ?? "")
        }
        #expect(said == ["Outside Chats", "Outside, Background", "Outside, Background, Archived",
                         "Background, Archived", "Archived", "Chats"])
        // Show's checks add rows: none of them is counted as a filter, so the button and the strip do not name them.
        let all = state { $0.showOutsideChats = true; $0.showBackgroundRuns = true; $0.prefs.showArchived = true }
        #expect(SessionFilterWords.filterCount(all) == 0 && SessionFilterWords.token(all) == nil)
    }

    @Test func buttonCountLabelAndToken() {
        #expect(SessionFilterWords.buttonLabel(state()) == "Filter and Sort")
        #expect(SessionFilterWords.token(state()) == nil)
        let one = state { $0.prefs.statusFilter = [.unread] }
        #expect(SessionFilterWords.filterCount(one) == 1)
        #expect(SessionFilterWords.buttonLabel(one) == "Filter and Sort, 1 filter on" && SessionFilterWords.token(one) == "Unread")
        let two = state { $0.prefs.statusFilter = [.unread, .working] }
        #expect(SessionFilterWords.buttonLabel(two) == "Filter and Sort, 2 filters on" && SessionFilterWords.token(two) == "Working · Unread")
        let named = state { $0.prefs.projectFilter = ["/r"]; $0.prefs.showArchived = true }
        #expect(SessionFilterWords.token(named) == "Reading")
        let three = state { $0.prefs.statusFilter = [.unread, .working]; $0.prefs.projectFilter = ["/r"]; $0.prefs.showArchived = true }
        #expect(SessionFilterWords.token(three) == "3 Filters")
        // A chip and Show's choices (Background Runs, Outside Chats, Archived: they add rows) are not counted and do
        // not fill the button.
        let chip = state { $0.botFilter = "research"; $0.showBackgroundRuns = true; $0.showOutsideChats = true; $0.prefs.showArchived = true }
        #expect(SessionFilterWords.filterCount(chip) == 0 && SessionFilterWords.token(chip) == nil)
        #expect(SessionFilterWords.filtersActive(chip))
        // C-07: a project the list no longer has is not counted.
        let gone = state { $0.prefs.projectFilter = ["/gone"] }
        #expect(SessionFilterWords.filterCount(gone) == 0 && !SessionFilterWords.filtersActive(gone))
    }

    @Test func stripText() {
        #expect(SessionFilterWords.stripText(state()) == nil)
        #expect(SessionFilterWords.stripText(state { $0.prefs.statusFilter = [.unread] }) == "Unread")
        #expect(SessionFilterWords.stripText(state { $0.prefs.statusFilter = [.unread, .working] }) == "Working · Unread")
        #expect(SessionFilterWords.stripText(state { $0.prefs.projectFilter = ["/r"] }) == "Project")
        #expect(SessionFilterWords.stripText(state { $0.prefs.projectFilter = ["/r", "/s", "/t"]; $0.prefs.showArchived = true }) == "3 Projects")
        #expect(SessionFilterWords.stripText(state { $0.prefs.statusFilter = [.working, .unread]; $0.prefs.projectFilter = ["/r"] }) == "3 Filters")
        #expect(SessionFilterWords.stripText(state { $0.prefs.showArchived = true }) == nil)      // Show's choices add rows
        #expect(SessionFilterWords.stripText(state { $0.botFilter = "research" }) == nil)        // never the chip's bot
        #expect(SessionFilterWords.stripText(state { $0.showBackgroundRuns = true }) == nil)
    }

    @Test func endRowFollowsTheTogglesWithoutSwapping() throws {
        // Opened with nothing on: Mark All as Read; a filter then disables it, but it is not swapped.
        let opened = state()
        let end = SessionFilterMenuModel.end(opened)
        #expect(end == .readAll)
        #expect(node("sessions.filter.readall", in: SessionFilterMenuModel.nodes(opened, end: end))?.disabled == false)
        let filtered = state { $0.prefs.statusFilter = [.unread] }
        let after = SessionFilterMenuModel.nodes(filtered, end: end)
        #expect(node("sessions.filter.readall", in: after)?.disabled == true && node("sessions.filter.clear", in: after) == nil)
        #expect(node("sessions.filter.readall", in: SessionFilterMenuModel.nodes(state { $0.hasUnread = false }))?.disabled == true)
        // Opened with a filter (or a chip): Clear Filters; it disables once nothing is on.
        #expect(SessionFilterMenuModel.end(filtered) == .clear && SessionFilterMenuModel.end(state { $0.botFilter = "a" }) == .clear)
        #expect(node("sessions.filter.clear", in: SessionFilterMenuModel.nodes(filtered))?.disabled == false)
        #expect(node("sessions.filter.clear", in: SessionFilterMenuModel.nodes(opened, end: .clear))?.disabled == true)
    }

    @Test func applyingPicks() {
        var s = state { $0.showBackgroundRuns = true; $0.prefs.sortBy = .tokens }
        #expect(SessionFilterApply.apply(.status(.unread), to: &s, homeBot: "default") && s.prefs.statusFilter == [.unread])
        SessionFilterApply.apply(.status(.unread), to: &s, homeBot: "default")
        #expect(s.prefs.statusFilter.isEmpty)
        SessionFilterApply.apply(.detail(.tokens), to: &s, homeBot: "default")
        #expect(s.prefs.rowDetail == [.time, .preview, .tokens])
        SessionFilterApply.apply(.group(.status), to: &s, homeBot: "default")
        SessionFilterApply.apply(.allBots, to: &s, homeBot: "default")
        #expect(s.botFilter == "default")                                              // off: the home bot's chip lights
        SessionFilterApply.apply(.allBots, to: &s, homeBot: "default")
        #expect(s.botFilter == nil)
        #expect(!SessionFilterApply.apply(.newProject, to: &s, homeBot: "default") && !SessionFilterApply.apply(.readAll, to: &s, homeBot: "default"))
        // Clear Filters: status, project and the chip; never the sort, the grouping, Row Detail or Show's choices.
        s.prefs.statusFilter = [.working]; s.prefs.projectFilter = ["/r"]; s.prefs.showArchived = true; s.botFilter = "research"
        var strip = s
        SessionFilterApply.clearStrip(&strip)
        #expect(strip.prefs.statusFilter.isEmpty && strip.prefs.projectFilter.isEmpty && strip.prefs.showArchived && strip.botFilter == "research")
        SessionFilterApply.apply(.clear, to: &s, homeBot: "default")
        #expect(!SessionFilterWords.filtersActive(s) && s.botFilter == nil)
        #expect(s.prefs.sortBy == .tokens && s.prefs.groupBy == .status && s.prefs.rowDetail.contains(.tokens) && s.showBackgroundRuns && s.prefs.showArchived)
    }

    @Test func prefsRoundTripAndReadLeniently() throws {
        var prefs = SessionsViewPrefs()
        prefs.sortBy = .cost; prefs.groupBy = .project; prefs.rowDetail = [.tokens]; prefs.statusFilter = [.needsInput, .draft]
        prefs.projectFilter = ["/r", "home"]; prefs.showArchived = true
        let data = try JSONEncoder().encode(prefs)
        #expect(try JSONDecoder().decode(SessionsViewPrefs.self, from: data) == prefs)
        #expect(String(decoding: data, as: UTF8.self).contains("\"needs-input\""))
        // A file from a newer build (unknown values, wrong types) reads as defaults, field by field; never an error.
        let odd = #"{"sortBy":"shuffle","groupBy":7,"rowDetail":["updated","sparkles"],"statusFilter":"all","projectFilter":["/r"],"showArchived":"yes","new":1}"#
        let read = try JSONDecoder().decode(SessionsViewPrefs.self, from: Data(odd.utf8))
        #expect(read.sortBy == .updated && read.groupBy == .date && read.rowDetail == [.time] && read.statusFilter.isEmpty)
        #expect(read.projectFilter == ["/r"] && !read.showArchived)
        #expect(try JSONDecoder().decode(SessionsViewPrefs.self, from: Data("[]".utf8)) == SessionsViewPrefs())
        // An older device-state file (no `view`, no `projects`) keeps what it has.
        let old = try JSONDecoder().decode(SessionsDeviceState.self, from: Data(#"{"showBackgroundRuns":true,"colors":{"x":2}}"#.utf8))
        #expect(old.showBackgroundRuns && old.colors == ["x": 2] && old.view == SessionsViewPrefs() && old.projects.isEmpty)
    }

    @Test func projectsKeysAndEntries() {
        let a = SessionProject(id: "p", label: "Site", root: " /w/site/ ", paths: [])
        #expect(SessionProjects.key(a, profile: "x") == "/w/site")
        #expect(SessionProjects.key(SessionProject(id: "p", label: "Odd", root: "", paths: []), profile: "x") == "id:x/p")
        #expect(SessionProjects.menuEntries([:], order: []).isEmpty)                               // no projects: nothing, not even Home
        let by = ["b": [SessionProject(id: "1", label: "site 10", root: "/w/10", paths: ["/w/10"])],
                  "a": [SessionProject(id: "2", label: "Site 2", root: "/w/2", paths: ["/w/2"])]]
        #expect(SessionProjects.menuEntries(by, order: ["a", "b"]).map(\.label) == ["Site 2", "site 10", "Home"])
        #expect(SessionProjects.key(cwd: "/w/2/src", profile: "a", projectsByProfile: by) == "/w/2")
        #expect(SessionProjects.key(cwd: "/w/2/src", profile: "b", projectsByProfile: by) == SessionProjects.homeKey)
        #expect(SessionProjects.key(cwd: nil, profile: "a", projectsByProfile: by) == SessionProjects.homeKey)
    }
}
