// Mac polish audit (6–7 Nov 2026), batch 2: keyboard, menu bar, pop-ups and Open Quickly. The pure rules behind its
// fixes: Escape's ladder (#7, #13), the ⌘1…⌘9 numbers (#18) and the ☰ Commands pop-up's search order (#23).
import Testing
@testable import HermesHQNative

struct MacPolish2EscapeTests {
    typealias State = EscapeAction.State

    /// #13: the open model panel closes before the reply behind it is stopped; a sheet or an alert over it comes first.
    @Test func theModelPanelClosesBeforeTheReplyStops() {
        #expect(EscapeAction.decide(State(modelPanel: true)) == .closeModelPanel)
        #expect(EscapeAction.decide(State(running: true, modelPanel: true)) == .closeModelPanel)
        #expect(EscapeAction.decide(State(running: true, fieldFocused: true, modelPanel: true)) == .closeModelPanel)
        #expect(EscapeAction.decide(State(presented: true, running: true, modelPanel: true)) == .dismissPresented)
        #expect(EscapeAction.decide(State(alert: true, presented: true, modelPanel: true)) == .system)
    }

    /// #7: a question card that takes Escape skips; an approval card still takes nothing; neither stops the turn.
    @Test func aQuestionCardSkipsAndNeverStopsTheTurn() {
        #expect(EscapeAction.decide(State(question: true, running: true, questionSkips: true)) == .skipQuestion)
        #expect(EscapeAction.decide(State(question: true, running: true, fieldFocused: true)) == .nothing)
        #expect(EscapeAction.decide(State(find: true, question: true, questionSkips: true)) == .closeFind)
        #expect(EscapeAction.decide(State(presented: true, question: true, questionSkips: true)) == .dismissPresented)
        // No question waiting: the flag alone skips nothing.
        #expect(EscapeAction.decide(State(running: true, questionSkips: true)) == .stop)
    }
}

struct MacPolish2TabShortcutTests {
    /// The Mac's places: Bots, Sessions, Jobs, Artifacts, nine Tools (any tags but More's), then More.
    let places = [HQTab.bots, .sessions, .jobs, .workspace].map(\.rawValue) + Array(100..<109) + [HQTab.more.rawValue]

    /// #18: on the Mac More takes no number, so ⌘9 picks the last Tool (with more than nine places), never More.
    @Test func moreTakesNoNumberOnTheMac() {
        let more = places.count - 1
        #expect(TabShortcut.place(forShortcut: 0, keys: 9, tags: places, numbersMore: false) == 0)
        #expect(TabShortcut.place(forShortcut: 7, keys: 9, tags: places, numbersMore: false) == 7)
        #expect(TabShortcut.place(forShortcut: 8, keys: 9, tags: places, numbersMore: false) == more - 1)
        for key in 0..<9 { #expect(TabShortcut.place(forShortcut: key, keys: 9, tags: places, numbersMore: false) != more) }
        // Five places and More: ⌘6 is More's number no longer, and nothing else has it.
        let few = Array(places.prefix(5)) + [HQTab.more.rawValue]
        #expect(TabShortcut.place(forShortcut: 4, keys: 9, tags: few, numbersMore: false) == 4)
        #expect(TabShortcut.place(forShortcut: 5, keys: 9, tags: few, numbersMore: false) == nil)
    }

    /// The iPhone and iPad keep their numbers: five keys, More among them.
    @Test func theIPadNumbersEveryTab() {
        let tabs = HQTab.allCases.map(\.rawValue)
        for key in 0..<5 { #expect(TabShortcut.place(forShortcut: key, keys: 5, tags: tabs, numbersMore: true) == key) }
        #expect(TabShortcut.place(forShortcut: 5, keys: 5, tags: tabs, numbersMore: true) == nil)
    }
}

struct MacPolish2CommandsSearchTests {
    typealias Row = SlashCatalog.Row
    typealias Section = SlashCatalog.Section
    let sections = [
        Section(title: "Session", rows: [Row(command: "/new", description: "Start a new chat", skill: false),
                                         Row(command: "/retry", description: "Ask again", skill: false),
                                         Row(command: "/stop", description: "Stop the reply", skill: false)]),
        Section(title: "Info", rows: [Row(command: "/status", description: "Show the session's status", skill: false),
                                      Row(command: "/cost", description: "Show what the chat cost", skill: false)]),
    ]

    func order(_ query: String, favorites: [String] = []) -> [String] {
        SlashCatalog.ranked(SlashCatalog.filter(sections, query: query), query: query, favorites: favorites).flatMap(\.rows).map(\.command)
    }

    /// #23: "st" marks /stop (a name that starts with it), not /new (found by "Start" in its description).
    @Test func namesThatStartWithTheTypingLead() {
        #expect(order("st") == ["/stop", "/new", "/status", "/cost"])
        #expect(order("/st") == ["/stop", "/new", "/status", "/cost"])
        // A name holding it comes before a description holding it.
        #expect(order("try").first == "/retry")
    }

    /// Starred commands lead among the names that start with the typing, in starred order.
    @Test func starredFirst() {
        #expect(order("st", favorites: ["/status"]) == ["/status", "/cost", "/stop", "/new"])
        #expect(order("st", favorites: ["/stop", "/status"]).first == "/stop")
    }

    /// Nothing typed: the list as it was.
    @Test func noQueryKeepsTheOrder() {
        #expect(SlashCatalog.ranked(sections, query: "  ") == sections)
    }
}
