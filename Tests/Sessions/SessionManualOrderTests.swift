import Foundation
import Testing
@testable import HermesHQNative

/// [manual-order] Sort By Manual, Group By Bot, and the projects' and bots' hand-picked order with favorites first
/// (tester and the owner, Nous Discord 2026-10-29).
@Suite struct SessionManualOrderTests {
    private static let now = Date(timeIntervalSince1970: 1_791_590_400)
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private static let projects: [String: [SessionProject]] = [
        "default": [SessionProject(id: "p1", label: "Site", root: "/home/hermes/site", paths: ["/home/hermes/site"]),
                    SessionProject(id: "p2", label: "Reading", root: "/home/hermes/reading", paths: ["/home/hermes/reading"])],
    ]

    private static func chat(_ id: String, profile: String = "default", ago: Double = 60, pinned: Bool = false,
                             cwd: String? = nil) -> SessionSummary {
        var s = SessionSummary(id: id, profile: profile, title: id, preview: "words", lastActive: now.addingTimeInterval(-ago),
                               source: "desktop", unread: false, isRunning: false)
        s.pinned = pinned; s.cwd = cwd
        return s
    }

    private static func key(_ id: String, _ profile: String = "default") -> String { profile + "\u{1F}" + id }

    private static func run(_ live: [SessionSummary], _ edit: (inout SessionListInput) -> Void = { _ in }) -> [SessionGroup] {
        var input = SessionListInput(live: live, now: now, calendar: calendar)
        edit(&input)
        return SessionListPipeline.groups(input)
    }

    // MARK: The order helper

    @Test func unknownIdsFoldInByPosition() {
        // Saved: b, c. "a" is newer than the first known one (stays on top); "d" is older (sinks below them).
        let out = SessionManualOrder.ordered(["a", "c", "b", "d"], id: { $0 }, by: ["b", "c", "gone"])
        #expect(out == ["a", "b", "c", "d"])
        #expect(SessionManualOrder.ordered(["x", "y"], id: { $0 }, by: []) == ["x", "y"])
        #expect(SessionManualOrder.ordered(["x", "y"], id: { $0 }, by: ["gone"]) == ["x", "y"])
        #expect(SessionManualOrder.ordered(["x", "y", "x"], id: { $0 }, by: ["y", "x", "y"]) == ["y", "x"])   // duplicates once
    }

    @Test func aMovedRunKeepsTheOtherIdsInPlace() {
        // The saved order holds another group's ids too; the run takes the place its first id held.
        #expect(SessionManualOrder.merged(["o1", "a", "o2", "b", "c"], with: ["c", "a", "b"]) == ["o1", "c", "a", "b", "o2"])
        #expect(SessionManualOrder.merged([], with: ["b", "a"]) == ["b", "a"])
        #expect(SessionManualOrder.merged(["o1"], with: ["new", "x"]) == ["new", "x", "o1"])
        #expect(SessionManualOrder.moved(["a", "b", "c"], from: 0, to: 2) == ["b", "c", "a"])
        #expect(SessionManualOrder.moved(["a", "b", "c"], from: 2, to: 0) == ["c", "a", "b"])
        #expect(SessionManualOrder.moved(["a", "b"], from: 5, to: 0) == ["a", "b"])
    }

    // MARK: Sort By Manual

    @Test func manualKeepsTheDraggedOrderInRecent() {
        let rows = [Self.chat("new", ago: 60), Self.chat("mid", ago: 600), Self.chat("old", ago: 6_000),
                    Self.chat("lastMonth", ago: 86_400 * 40)]
        let order = [Self.key("old"), Self.key("new"), Self.key("lastMonth"), Self.key("mid")]
        let updated = Self.run(rows) { $0.chatOrder = order }
        #expect(updated.flatMap(\.sessions).map(\.id) == ["new", "mid", "old", "lastMonth"])        // Updated ignores it
        let manual = Self.run(rows) { $0.prefs.sortBy = .manual; $0.chatOrder = order }
        // [sessions-fresh] One Recent run (no date headers now), in the dragged order.
        #expect(manual.map(\.id) == [SessionListPipeline.recentId])
        #expect(manual.first?.sessions.map(\.id) == ["old", "new", "lastMonth", "mid"])
        var prefs = SessionsViewPrefs()
        prefs.sortBy = .manual
        #expect(!SessionListPipeline.isFlat(prefs))                              // Manual has headers
    }

    @Test func manualOrdersPinnedAndANewChatStaysOnTop() {
        let rows = [Self.chat("p1", pinned: true), Self.chat("p2", ago: 90, pinned: true), Self.chat("fresh", ago: 5),
                    Self.chat("a", ago: 100), Self.chat("b", ago: 200)]
        let groups = Self.run(rows) {
            $0.prefs.sortBy = .manual
            $0.chatOrder = [Self.key("p2"), Self.key("p1"), Self.key("b"), Self.key("a")]
        }
        #expect(groups.first?.id == "pinned" && groups.first?.sessions.map(\.id) == ["p2", "p1"])
        #expect(groups[1].sessions.map(\.id) == ["fresh", "b", "a"])            // started since the drag: on top
    }

    // MARK: Group By Bot

    @Test func groupByBotHasAGroupPerBotNewestFirstThenTheUsersOrder() {
        let rows = [Self.chat("h1", ago: 300), Self.chat("r1", profile: "research", ago: 30), Self.chat("h2", ago: 10),
                    Self.chat("c1", profile: "coder", ago: 900)]
        let names = ["default": "Hermes", "research": "Research", "coder": "Coder"]
        var groups = Self.run(rows) { $0.prefs.groupBy = .bot; $0.botNames = names }
        #expect(groups.map(\.title) == ["Hermes", "Research", "Coder"])
        #expect(groups.map(\.id) == ["bot-default", "bot-research", "bot-coder"])
        #expect(groups[0].sessions.map(\.id) == ["h2", "h1"])
        #expect(groups.allSatisfy(SessionListPipeline.folds))
        groups = Self.run(rows) { $0.prefs.groupBy = .bot; $0.botNames = names; $0.botOrder = ["coder", "default"] }
        #expect(groups.map(\.title) == ["Coder", "Hermes", "Research"])          // research, unknown and older, sinks
        #expect(SessionListPipeline.botProfile("bot-coder") == "coder" && SessionListPipeline.botProfile("project-x") == nil)
    }

    @Test func groupByBotIsOfferedWithASecondBot() {
        var state = SessionFilterState()
        state.botCount = 1
        #expect(!SessionFilterWords.groupOptions(state).contains(.bot))
        state.botCount = 2
        #expect(SessionFilterWords.groupOptions(state) == [.date, .bot, .status])
        #expect(SessionFilterWords.name(.bot) == "Bot" && SessionFilterWords.name(.manual) == "Manual")
        #expect(SessionFilterWords.sortOptions(state).last == .manual)
        #expect(SessionFilterWords.reorderTitle(state) == nil)
        state.prefs.groupBy = .bot
        #expect(SessionFilterWords.reorderTitle(state) == "Reorder Bots…")
        state.prefs.sortBy = .tokens
        #expect(SessionFilterWords.reorderTitle(state) == nil)                   // one run, no groups to put in order
    }

    // MARK: Projects' order and favorites

    private static var projectRows: [SessionSummary] {
        [Self.chat("home", ago: 5), Self.chat("site", ago: 100, cwd: "/home/hermes/site"),
         Self.chat("reading", ago: 50, cwd: "/home/hermes/reading")]
    }

    private static func projectGroups(_ edit: (inout SessionListInput) -> Void = { _ in }) -> [SessionGroup] {
        run(projectRows) { input in
            input.prefs.groupBy = .project
            input.projectsByProfile = projects
            input.projects = SessionProjects.menuEntries(projects, order: ["default"])
            edit(&input)
        }
    }

    @Test func projectsFollowTheUsersOrderAndHomeCanGoFirst() {
        #expect(Self.projectGroups().map(\.title) == ["Reading", "Site", "Home"])
        let groups = Self.projectGroups { $0.projectOrder = [SessionProjects.homeKey, "/home/hermes/site", "/home/hermes/reading"] }
        #expect(groups.map(\.title) == ["Home", "Site", "Reading"])
        #expect(groups.allSatisfy { !$0.favorite })
    }

    @Test func favoriteProjectsStayOnTopAndShowTheirStar() {
        let groups = Self.projectGroups { $0.favoriteProjects = ["/home/hermes/site"] }
        #expect(groups.map(\.title) == ["Site", "Reading", "Home"])
        #expect(groups.map(\.favorite) == [true, false, false])
        // Two favorites keep the user's order among themselves, above the rest.
        let both = Self.projectGroups {
            $0.favoriteProjects = ["/home/hermes/site", SessionProjects.homeKey]
            $0.projectOrder = [SessionProjects.homeKey, "/home/hermes/reading", "/home/hermes/site"]
        }
        #expect(both.map(\.title) == ["Home", "Site", "Reading"])
    }

    @Test func reorderIsOfferedUnderGroupByProject() {
        var state = SessionFilterState()
        state.projects = [SessionProjectEntry(key: "p", label: "P"), SessionProjectEntry(key: SessionProjects.homeKey, label: "Home")]
        state.prefs.groupBy = .project
        #expect(SessionFilterWords.reorderTitle(state) == "Reorder Projects…")
        let group = SessionFilterMenuModel.nodes(state).flatMap(\.children).first { $0.id == "sessions.filter.group" }
        let reorder = group?.children.last?.children.first
        #expect(reorder?.title == "Reorder Projects…" && reorder?.kind == .action(.reorderGroups))
        var applied = state
        #expect(!SessionFilterApply.apply(.reorderGroups, to: &applied, homeBot: "default"))
        #expect(applied == state)
    }

    // MARK: Kept on the device

    @Test func ordersAndFavoritesSurviveAnOlderOrNewerFile() throws {
        var state = SessionsDeviceState()
        state.chatOrder = ["a", "b"]; state.projectOrder = ["home"]; state.botGroupOrder = ["coder"]; state.favoriteProjects = ["/x"]
        state.view.sortBy = .manual; state.view.groupBy = .bot
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(SessionsDeviceState.self, from: data)
        #expect(back == state)
        // A file from before these fields reads as no order.
        let old = try JSONDecoder().decode(SessionsDeviceState.self, from: Data(#"{"collapsedGroups":{}}"#.utf8))
        #expect(old.chatOrder.isEmpty && old.projectOrder.isEmpty && old.favoriteProjects.isEmpty)
    }
}
