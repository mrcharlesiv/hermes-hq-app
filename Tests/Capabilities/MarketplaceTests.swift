// [marketplace] The Hermes Marketplace: its skills read from the page's own data (and the published skills.json), the
// SKILL.md address, the website's Install in Hermes links, the Featured rotation and Spotlight, and the plugin list's
// `featured` / `readmeUrl`, and the chips, counts and orders the site uses (2026-11-08).

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct MarketplaceTests {
    private let stocks = #"{"name":"stocks","description":"Stock quotes, history, search, compare, crypto via Yahoo.","author":"Mibay (Mibayy), Hermes Agent","category":"finance","categoryLabel":"Finance","tags":["Stocks","Finance"],"source":"optional","slug":"hermes-optional/finance/stocks","installIdentifier":"official/finance/stocks"}"#
    private let notes = #"{"name":"apple-notes","description":"Manage Apple Notes via memo CLI: create, search, edit.","author":"Hermes Agent","category":"apple","categoryLabel":"Apple","tags":[],"source":"built-in","slug":"hermes-agent/apple/apple-notes","installIdentifier":"NousResearch/hermes-agent/skills/apple/apple-notes"}"#

    /// The page streams its data as escaped string chunks; one object may be split across two of them.
    private func page(_ objects: [String]) -> String {
        let joined = "[" + objects.joined(separator: ",") + "]"
        let half = joined.index(joined.startIndex, offsetBy: joined.count / 2)
        func chunk(_ text: Substring) -> String {
            let escaped = String(data: try! JSONEncoder().encode(String(text)), encoding: .utf8)!
            return "<script>self.__next_f.push([1,\(escaped)])</script>"
        }
        return "<html><body>" + chunk(joined[..<half]) + chunk(joined[half...]) + "</body></html>"
    }

    @Test func readsSkillsFromThePage() {
        let list = MarketSkill.parsePage(page([stocks, notes, stocks]))
        #expect(list.map(\.name) == ["stocks", "apple-notes"])
        let first = list[0]
        #expect(first.categoryLabel == "Finance")
        #expect(first.isOfficial)
        #expect(!first.isBuiltIn)
        #expect(first.sourceWord == "Nous")
        #expect(first.installCommand == "hermes skills install official/finance/stocks")
        #expect(first.pageURL?.absoluteString == "https://hermes-agent.nousresearch.com/marketplace/skills/hermes-optional/finance/stocks")
        #expect(list[1].isBuiltIn)
        #expect(list[1].sourceWord == "Built into Hermes")
    }

    @Test func pageWithoutSkillsReadsEmpty() {
        #expect(MarketSkill.parsePage("<html>nothing</html>").isEmpty)
        #expect(MarketSkill.parseObjects(#"{"name":"x","installIdentifier":""}"#).isEmpty)
    }

    @Test func fullListKeepsTheMarketplaceSources() throws {
        let other = #"{"name":"lobster","description":"","source":"clawhub","identifier":"clawhub/lobster"}"#
        let nameless = #"{"description":"no name","source":"optional","installIdentifier":"official/x/y"}"#
        let data = Data("[\(stocks),\(notes),\(other),\(nameless),\(stocks)]".utf8)
        #expect(try MarketSkill.decodeFull(data).map(\.name) == ["stocks", "apple-notes"])
    }

    @Test func skillFileAddresses() {
        let list = MarketSkill.parseObjects(stocks + notes)
        #expect(list[0].skillFileURL?.absoluteString
                == "https://raw.githubusercontent.com/NousResearch/hermes-agent/HEAD/optional-skills/finance/stocks/SKILL.md")
        #expect(list[1].skillFileURL?.absoluteString
                == "https://raw.githubusercontent.com/NousResearch/hermes-agent/HEAD/skills/apple/apple-notes/SKILL.md")
        #expect(MarketplaceLinks.outside("lonely").skillFileURL == nil)
    }

    @Test func skillBodyDropsFrontMatter() {
        #expect(SkillCatalogEntryModel.body(of: "---\nname: x\ntags: [a]\n---\n\n# Stocks\nUse it.") == "# Stocks\nUse it.")
        #expect(SkillCatalogEntryModel.body(of: "# Plain") == "# Plain")
    }

    @Test @MainActor func installLinks() throws {
        func target(_ text: String) -> MarketplaceLinks.Target? {
            MarketplaceLinks.target(DeepLink.parse(URL(string: text)!, scheme: "hermes"))
        }
        #expect(target("hermes://plugin/install?catalog=blender") == .plugin("blender"))
        #expect(target("hermes://plugin/install?catalog=blender&repo=https://github.com/evil/x") == .plugin("blender"))
        #expect(target("hermes://plugin/install?repo=https://github.com/evil/x") == nil)
        #expect(target("hermes://skill/install?identifier=official/finance/stocks") == .skill("official/finance/stocks"))
        #expect(target("hermes://skill/remove?identifier=official/finance/stocks") == nil)
        #expect(target("hermes://chat/install?catalog=x") == nil)
        let outside = MarketplaceLinks.outside("clawhub/lobster")
        #expect(outside.name == "lobster")
        #expect(outside.source == "clawhub")
        #expect(!outside.isOfficial)
    }

    // MARK: Plugins

    private func plugins() throws -> [PluginCatalogEntry] {
        func row(_ name: String, tier: String, maker: String, stars: Int, featured: Int? = nil, image: Bool = false) -> String {
            #"{"name":"\#(name)","description":"d","repo":"https://github.com/\#(maker)/\#(name)","sha":"1111111111111111111111111111111111111111","tier":"\#(tier)","category":"tools","maintainer":"\#(maker)","stars":\#(stars)"#
                + (featured.map { #","featured":\#($0)"# } ?? "")
                + (image ? #","image":"https://example.com/\#(name).png""# : "")
                + #","readmeUrl":"https://raw.githubusercontent.com/\#(maker)/\#(name)/HEAD/README.md"}"#
        }
        let json = "[" + [
            row("c", tier: "official", maker: "NousResearch", stars: 5, featured: 3),
            row("a", tier: "official", maker: "NousResearch", stars: 9, featured: 1),
            row("b", tier: "official", maker: "NousResearch", stars: 1, featured: 2),
            row("big", tier: "official", maker: "NousResearch", stars: 900, image: true),
            row("x1", tier: "community", maker: "maker1", stars: 3),
            row("x2", tier: "community", maker: "maker1", stars: 30),
            row("x3", tier: "community", maker: "maker1", stars: 10),
            row("y1", tier: "community", maker: "maker2", stars: 999),
        ].joined(separator: ",") + "]"
        return try PluginCatalogEntry.decode(Data(json.utf8))
    }

    @Test func readsFeaturedAndReadme() throws {
        let list = try plugins()
        #expect(list.first { $0.name == "a" }?.featured == 1)
        #expect(list.first { $0.name == "big" }?.featured == nil)
        #expect(list.first { $0.name == "a" }?.readmeURL?.absoluteString == "https://raw.githubusercontent.com/NousResearch/a/HEAD/README.md")
        #expect(list.first { $0.name == "a" }?.installCommand == "hermes plugins install a")
    }

    @Test @MainActor func featuredRotatesWeekly() throws {
        let list = try plugins()
        let week: TimeInterval = 7 * 24 * 60 * 60
        #expect(MarketplaceFeatured.picks(list, now: Date(timeIntervalSince1970: 0)).map(\.name) == ["a", "b", "c"])
        #expect(MarketplaceFeatured.picks(list, now: Date(timeIntervalSince1970: week * 1.5)).map(\.name) == ["b", "c", "a"])
        // No curated picks: the official one with a picture and the most stars.
        let plain = list.filter { $0.featured == nil }
        #expect(MarketplaceFeatured.picks(plain).map(\.name) == ["big"])
    }

    @Test @MainActor func spotlightIsTheBusiestCommunityMaker() throws {
        let spot = try #require(MarketplaceFeatured.spotlight(try plugins()))
        #expect(spot.maker == "maker1")
        #expect(spot.picks.map(\.name) == ["x2", "x3", "x1"])
    }
    // MARK: Chips and orders (the site, 2026-11-08)

    private func mixed() throws -> (plugins: [PluginCatalogEntry], skills: [MarketSkill]) {
        func row(_ name: String, tier: String, category: String, stars: Int?, added: String) -> String {
            #"{"name":"\#(name)","description":"d","repo":"https://github.com/m/\#(name)","sha":"1111111111111111111111111111111111111111","tier":"\#(tier)","category":"\#(category)","maintainer":"m","addedAt":"\#(added)""#
                + (stars.map { #","stars":\#($0)"# } ?? "") + "}"
        }
        let json = "[" + [
            row("memo", tier: "official", category: "memory", stars: 50, added: "2026-10-01T00:00:00Z"),
            row("tool-b", tier: "verified", category: "tools", stars: 10, added: "2026-11-01T00:00:00Z"),
            row("tool-a", tier: "community", category: "tools", stars: 10, added: "2026-09-01T00:00:00Z"),
            row("pane", tier: "community", category: "desktop", stars: 99, added: "2026-08-01T00:00:00Z"),
        ].joined(separator: ",") + "]"
        let plugins = try PluginCatalogEntry.decode(Data(json.utf8))
        func skill(_ name: String, source: String, category: String, tags: [String]) -> MarketSkill {
            MarketSkill(name: name, description: "d", author: "a", category: category, categoryLabel: category.capitalized, tags: tags,
                        source: source, slug: name, installIdentifier: "x/" + name)
        }
        let skills = [
            skill("zeta", source: "optional", category: "security", tags: ["Security", "Passwords"]),
            skill("alpha", source: "NVIDIA", category: "mlops", tags: ["GPU", "Security"]),
            skill("beta", source: "built-in", category: "security", tags: ["Security"]),
        ]
        return (plugins, skills)
    }

    @Test @MainActor func opensOnPluginsAndShelvesAreAlls() {
        let state = MarketplaceState()
        #expect(state.kind == .plugins)
        #expect(!state.browsing)
        state.choose(.all)
        #expect(state.browsing)
        state.sort = .name
        #expect(!state.browsing)
    }

    @Test @MainActor func chipsWidenInARowAndNarrowAcrossRows() throws {
        let (plugins, skills) = try mixed()
        let state = MarketplaceState(kind: .plugins)
        let items = state.scoped(plugins: plugins, skills: skills)
        #expect(items.count == 4)
        state.toggle(category: "tools")
        state.toggle(category: "memory")
        #expect(Set(state.filter(items).map(\.key)) == ["memo", "tool-a", "tool-b"])
        state.toggle(.community)
        #expect(state.filter(items).map(\.key) == ["tool-a"])
        // A row counts with its own chips set aside: the tier counts see both categories, every tier.
        let tiers = Dictionary(uniqueKeysWithValues: state.tierRows(items).map { ($0.tier, $0.count) })
        #expect(tiers == [.official: 1, .verified: 1, .community: 1])
        // Categories count under the Community chip, and a chosen one stays even at nothing.
        let categories = Dictionary(uniqueKeysWithValues: state.categoryRows(items).map { ($0.key, $0.count) })
        #expect(categories == ["tools": 1, "desktop": 1, "memory": 0])
        #expect(MarketplaceTier.verified.title == "Certified")
    }

    @Test @MainActor func skillsHaveTagsAndNoTierRow() throws {
        let (plugins, skills) = try mixed()
        let state = MarketplaceState(kind: .all)
        state.toggle(.official)
        state.choose(.skills)
        #expect(state.tiers.isEmpty)
        let items = state.scoped(plugins: plugins, skills: skills)
        #expect(items.count == 3 && items.allSatisfy(\.isSkill))
        #expect(state.tierRows(items).isEmpty)
        #expect(state.tagRows(items).map(\.tag) == ["Security", "GPU", "Passwords"])
        state.toggle(tag: "GPU")
        state.toggle(tag: "Passwords")
        #expect(Set(state.filter(items).map(\.key)) == ["alpha", "zeta"])
        // A source names skills, so under All it leaves the plugins out.
        let all = MarketplaceState(kind: .all)
        all.source = "NVIDIA"
        #expect(all.scoped(plugins: plugins, skills: skills).map(\.key) == ["alpha"])
    }

    @Test @MainActor func ordersBreakTiesByName() throws {
        let (plugins, skills) = try mixed()
        let items = MarketplaceState(kind: .all).scoped(plugins: plugins, skills: skills)
        #expect(MarketplaceState.sorted(items, by: .stars).map(\.key) == ["pane", "memo", "tool-a", "tool-b", "alpha", "beta", "zeta"])
        #expect(MarketplaceState.sorted(items, by: .newest).map(\.key) == ["tool-b", "memo", "tool-a", "pane", "alpha", "beta", "zeta"])
        #expect(MarketplaceState.sorted(items, by: .name).map(\.key).prefix(3) == ["alpha", "beta", "memo"])
    }

    @Test @MainActor func searchKeepsTheChosenOrderButAnExactNameLeads() throws {
        let (plugins, skills) = try mixed()
        let state = MarketplaceState(kind: .plugins, query: "tool")
        #expect(state.ordered(state.filter(state.scoped(plugins: plugins, skills: skills))).map(\.key) == ["tool-a", "tool-b"])
        state.query = "tool-b"
        #expect(state.ordered(state.filter(state.scoped(plugins: plugins, skills: skills))).map(\.key).first == "tool-b")
    }

    @Test @MainActor func qualityOfLifeTakesDesktopAndTools() throws {
        let (plugins, _) = try mixed()
        #expect(MarketplaceFeatured.qualityOfLife(plugins).map(\.name) == ["pane", "tool-b", "tool-a"])
    }
}

private extension MarketplaceItem {
    /// The catalog name (not the shown title), for the expectations above.
    var key: String {
        switch self {
        case .plugin(let entry): entry.name
        case .skill(let entry): entry.name
        }
    }
}

// [connect-find] Owner 2026-11-11: Connectors is one of the Marketplace's kinds, and Composio's row says a key is all
// it takes.
@MainActor struct ConnectFindTests {
    @Test func connectorsIsAKindOfItsOwn() {
        #expect(MarketplaceKind.allCases.map(\.title) == ["All", "Plugins", "Skills", "Connectors"])
        #expect(MarketplaceKind.shown.contains(.connectors) == !DeviceWord.isMac)
    }

    @Test func composioRowNamesTheKey() {
        #expect(ComposioSection.title(keySaved: false) == "Use Your Composio API Key")
        #expect(ComposioSection.detail(keySaved: false, searching: false) == "Gmail, Slack and hundreds more")
        #expect(ComposioSection.title(keySaved: true) == "Your Composio Apps")
        #expect(ComposioSection.detail(keySaved: false, searching: true).hasPrefix("Not here?"))
        #expect(ConnectAppsSetupView.blurb.hasPrefix("All it takes is your Composio API key."))
    }

    @Test func appsHeaderCounts() {
        #expect(MarketplaceConnectors.appsHeader(1) == "1 App from Hermes")
        #expect(MarketplaceConnectors.appsHeader(64) == "64 Apps from Hermes")
    }
}
