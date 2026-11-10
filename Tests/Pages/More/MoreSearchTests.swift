// 3x-morepages §18 (U17): More search's ranking, grouping and what it never offers.
import Testing
@testable import HermesHQNative

struct MoreSearchTests {
    typealias Item = MoreSearch.Item
    static let pages = [Item(id: "tab-bots", title: "Bots"), Item(id: "tab-sessions", title: "Sessions"), Item(id: "tab-jobs", title: "Jobs"),
                        Item(id: "settings", title: "Settings"), Item(id: "files", title: "Files"), Item(id: "review", title: "Review"),
                        Item(id: "command-center", title: "Status & Maintenance"), Item(id: "usage", title: "Usage"),
                        Item(id: "webhooks", title: "Webhooks"),
                        Item(id: "import-sessions", title: "Import Sessions"), Item(id: "star-map", title: "Star Map")]
    static let bots = [Item(id: "default", title: "Hermes", detail: "Bot"), Item(id: "research", title: "Research", detail: "Bot", keywords: ["research", "reads papers"]),
                       Item(id: "web", title: "Webster", detail: "Bot")]
    static let sessions = (1...9).map { Item(id: "s\($0)", title: "Web scrape \($0)", detail: "Research") }

    func find(_ query: String, pages: [Item] = pages, actions: [Item] = MoreSearch.actions(.init(kanban: true, commandCenter: true, version: "v0.9.1+abc")),
              all: Bool = false) -> [MoreSearch.Group] {
        MoreSearch.results(query: query, pages: pages, bots: Self.bots, sessions: Self.sessions, settings: SettingsSearch.index(),
                           actions: actions, allSessions: all)
    }

    /// Audit 863 (08d-4): More search reads each page's own words (MorePages.pages), not only its shorter list.
    @MainActor @Test func aPagesOwnWordsFindIt() {
        let pages = [("messaging", "Messaging"), ("star-map", "Star Map"), ("spawn-tree", "Spawn Tree"),
                     ("command-center", "Status & Maintenance")].map { Item(id: $0.0, title: $0.1, keywords: MorePages.keywords(for: $0.0)) }
        func goTo(_ query: String) -> String? { find(query, pages: pages).first { $0.kind == .goTo }?.rows.first?.id }
        #expect(goTo("telegram") == "messaging")
        #expect(goTo("memory") == "star-map")
        #expect(goTo("subagents") == "spawn-tree")
        #expect(goTo("doctor") == "command-center")
        #expect(goTo("logs") == "command-center")
    }

    @Test func anEmptyQueryFindsNothing() {
        #expect(find("").isEmpty)
        #expect(find("   ").isEmpty)
        #expect(MoreSearch.first(find("")) == nil)
    }

    @Test func groupsComeInTheSpecsOrder() {
        let groups = find("web")
        #expect(groups.map(\.kind) == [.goTo, .bots, .sessions, .settings])   // "Web Tools Open Private Addresses" (stress test #105)
        #expect(groups[0].rows.first?.title == "Webhooks")
        #expect(groups[1].rows.map(\.title) == ["Webster"])
        #expect(MoreSearch.first(groups)?.item.id == "webhooks")
        #expect(MoreSearch.Kind.allCases.map(\.title) == ["Go To", "Bots", "Sessions", "Settings", "Actions"])
    }

    @Test func sessionsStopAtSixAndOfferTheRest() {
        let group = find("web").first { $0.kind == .sessions }
        #expect(group?.rows.count == 6)
        #expect(group?.total == 9)
        #expect(group?.showAll == "Show All 9")
        let all = find("web", all: true).first { $0.kind == .sessions }
        #expect(all?.rows.count == 9)
        #expect(all?.showAll == nil)
        #expect(find("web").first { $0.kind == .goTo }?.showAll == nil)
    }

    @Test func theWebsKeywordsFindPages() {
        #expect(find("git").first?.rows.map(\.id) == ["review"])
        #expect(find("codex").first?.rows.map(\.id) == ["import-sessions"])
        #expect(find("triggers").first?.rows.map(\.id) == ["webhooks"])
        // [status-page] Usage is its own page; Status & Maintenance is still found by its old name and its second part.
        #expect(find("usage").first { $0.kind == .goTo }?.rows.map(\.id) == ["usage"])
        #expect(find("tokens").first { $0.kind == .goTo }?.rows.map(\.id) == ["usage"])
        #expect(find("command center").first { $0.kind == .goTo }?.rows.map(\.id) == ["command-center"])
        #expect(find("maintenance").first { $0.kind == .goTo }?.rows.map(\.id) == ["command-center"])
        #expect(find("status").first { $0.kind == .goTo }?.rows.map(\.id) == ["command-center"])
        #expect(find("folder").first?.rows.map(\.id) == ["files"])
    }

    @Test func aHiddenPageIsNeverOffered() {
        let shown = Self.pages.filter { $0.id != "webhooks" && $0.id != "review" }
        #expect(find("webhooks", pages: shown).allSatisfy { $0.kind != .goTo })
        #expect(find("git", pages: shown).allSatisfy { $0.kind != .goTo })
        #expect(find("hooks", pages: shown).allSatisfy { group in !group.rows.contains { $0.id == "webhooks" } })
    }

    @Test func ranking() {
        #expect(MoreSearch.score("se", title: "Sessions") == 0)
        #expect(MoreSearch.score("se", title: "Import Sessions") == 1)
        #expect(MoreSearch.score("ss", title: "Sessions") == 2)
        #expect(MoreSearch.score("git", title: "Review", keywords: ["git"]) == 3)
        #expect(MoreSearch.score("xyz", title: "Review", keywords: ["git"]) == nil)
        #expect(MoreSearch.score("IMPORT ses", title: "Import Sessions") == 0)
        #expect(MoreSearch.score("ses imp", title: "Import Sessions") == 1)
        #expect(MoreSearch.score("café", title: "Cafe Notes") == 0)          // diacritics and case
        #expect(MoreSearch.score("import zzz", title: "Import Sessions") == nil)   // every word must match
        // prefix before word-prefix before substring before keyword
        let items = [Item(id: "k", title: "Review", keywords: ["sessions"]), Item(id: "sub", title: "Obsessions"),
                     Item(id: "word", title: "Import Sessions"), Item(id: "pre", title: "Sessions")]
        #expect(MoreSearch.rank(items, query: "sessions").map(\.id) == ["pre", "word", "sub", "k"])
        // one score keeps the given order; a repeated id shows once
        let same = [Item(id: "a", title: "Star Map"), Item(id: "b", title: "Start"), Item(id: "a", title: "Star Map")]
        #expect(MoreSearch.rank(same, query: "sta").map(\.id) == ["a", "b"])
    }

    @Test func settingsAreFoundAndSayWhereTheyLive() {
        let group = find("about").first { $0.kind == .settings }
        #expect(group != nil)
        #expect(group?.rows.allSatisfy { $0.detail.hasPrefix("Settings") } == true)
        #expect((group?.rows.count ?? 0) <= MoreSearch.limit)
    }

    @Test func actionsShowOnlyWhereTheyWork() {
        let full = MoreSearch.actions(.init(kanban: true, commandCenter: true, version: "v0.9.1+abc"))
        #expect(full.map(\.id) == ["new-chat", "new-bot", "new-task", "restart-gateway", "update-hermes", "perf-logs"])
        #expect(full.first { $0.id == "update-hermes" }?.detail == "Hermes 0.9.1")
        #expect(full.first { $0.id == "update-hermes" }?.title == "Update Hermes")
        #expect(MoreSearch.actions(.init(kanban: false, commandCenter: false)).map(\.id) == ["new-chat", "new-bot", "perf-logs"])
        #expect(MoreSearch.actions(.init(writable: false, kanban: true, commandCenter: true)).map(\.id) == ["perf-logs"])
        #expect(MoreSearch.actions(.init(commandCenter: true, version: nil)).first { $0.id == "update-hermes" }?.detail == "")
        #expect(MoreSearch.actions(.init(commandCenter: true, version: " ")).first { $0.id == "update-hermes" }?.detail == "")
        let rest = find("rest").first { $0.kind == .actions }
        #expect(rest?.rows.first?.id == "restart-gateway")
        for item in full { #expect(!item.title.contains("Dispatch")) }
    }

    @Test func versionsReadShort() {
        #expect(MoreSearch.shortVersion("v1.2.3") == "1.2.3")
        #expect(MoreSearch.shortVersion(" 1.2.3-rc1 ") == "1.2.3")
        #expect(MoreSearch.shortVersion("V2.0+build") == "2.0")
        #expect(MoreSearch.shortVersion("") == "")
    }

    @Test func aLargeRosterStaysBounded() {
        let many = (0..<5000).map { Item(id: "s\($0)", title: "Session \($0)") }
        let groups = MoreSearch.results(query: "session 4", pages: [], bots: [], sessions: many, settings: [], actions: [])
        #expect(groups.first?.rows.count == 6)
        #expect((groups.first?.total ?? 0) > 6)
    }
}
