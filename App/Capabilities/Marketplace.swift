// [marketplace] The Hermes Marketplace in the app, laid out as Nous's (hermes-agent.nousresearch.com/marketplace,
// 2026-11-04): Featured, All / Plugins / Skills, Official · Verified · Community, the kinds, Sort by Stars, Newest,
// Updated or Name, one search over skills, plugins and authors, then the shelves: Quality of Life, a maintainer's
// Spotlight, Talk to Hermes Anywhere (Messaging), Connectors and Make Your Own. Plugins come from plugins.json
// (`PluginCatalogStore`), skills from the Marketplace page (`SkillCatalogStore`). Everything installs for the bot in
// "Install To", through the same calls as Find Plugins and the Skills Hub.
// Owner 2026-11-04: "make sure that we have it inside of our app the exact way that it needs to be for the best user
// experience and based on how news research has it built".

import SwiftUI
import UIKit

enum MarketplaceKind: String, CaseIterable, Identifiable {
    case all, plugins, skills
    /// [connect-find] Owner 2026-11-11 ("the ability to add connectors and stuff from the marketplace should be easier
    /// to find"): the apps a bot can be connected to, beside Plugins and Skills, not a row under the last shelf.
    case connectors
    var id: String { rawValue }
    var title: String { switch self { case .all: "All"; case .plugins: "Plugins"; case .skills: "Skills"; case .connectors: "Connectors" } }

    /// The kinds the switch offers. The Mac's store front keeps its three (Connectors is one of its sidebar's Tools).
    @MainActor static var shown: [MarketplaceKind] { DeviceWord.isMac ? [.all, .plugins, .skills] : allCases }
}

enum MarketplaceSort: String, CaseIterable, Identifiable {
    case stars, newest, updated, name
    var id: String { rawValue }
    var title: String { switch self { case .stars: "Stars"; case .newest: "Newest"; case .updated: "Updated"; case .name: "Name" } }
}

/// The trust filter: official is Nous (and Hermes' own skills), verified a partner Nous certified (the site's word
/// since 2026-11), community the rest.
enum MarketplaceTier: String, CaseIterable, Identifiable {
    case official, verified, community
    var id: String { rawValue }
    var title: String { self == .verified ? "Certified" : rawValue.capitalized }
}

/// A chip row's group, for counting it with its own choices set aside (as the site's facet counts are).
enum MarketplaceFacet { case tier, category, tag }

/// One card in a result list: a plugin or a skill.
enum MarketplaceItem: Identifiable, Hashable {
    case plugin(PluginCatalogEntry)
    case skill(MarketSkill)

    var id: String {
        switch self {
        case .plugin(let entry): "plugin:" + entry.name
        case .skill(let entry): "skill:" + entry.installIdentifier
        }
    }

    var tier: MarketplaceTier {
        switch self {
        case .plugin(let entry): entry.isOfficial ? .official : entry.isVerified ? .verified : .community
        case .skill(let entry): entry.isOfficial ? .official : .community
        }
    }

    var name: String {
        switch self {
        case .plugin(let entry): entry.title
        case .skill(let entry): entry.name
        }
    }

    /// A plugin kind (`PluginCatalogCategory` raw value) or a skill category key.
    var category: String {
        switch self {
        case .plugin(let entry): entry.category.rawValue
        case .skill(let entry): entry.category
        }
    }

    /// Skills' tags; plugins carry none in the Marketplace (as on the site).
    var tags: [String] {
        if case .skill(let entry) = self { return entry.tags }
        return []
    }

    var isSkill: Bool { if case .skill = self { return true }; return false }

    var stars: Int? { if case .plugin(let entry) = self { return entry.stars }; return nil }
    var addedAt: Date? { if case .plugin(let entry) = self { return entry.addedAt }; return nil }
    var updatedAt: Date? { if case .plugin(let entry) = self { return entry.updatedAt ?? entry.addedAt }; return nil }

    func score(_ query: String) -> Int {
        switch self {
        case .plugin(let entry): entry.score(query)
        case .skill(let entry): entry.score(query)
        }
    }
}

@MainActor @Observable final class MarketplaceState {
    var kind: MarketplaceKind
    var query: String
    /// The chips, as the site's: several in one row widen the list (any of them), rows narrow it (all of them).
    var tiers: Set<MarketplaceTier>
    /// Plugin kinds (`PluginCatalogCategory` raw values) on Plugins, skill category keys on Skills.
    var categories: Set<String>
    /// Skills only: the tag chips.
    var tags: Set<String> = []
    /// Skills only: one source ("NVIDIA"), nil for all.
    var source: String?
    var sort: MarketplaceSort = .stars
    var limit = MarketplaceState.page
    /// [mac-tools] The page's search field shows these words (a See All that searches, on the Mac's grid).
    @ObservationIgnored var typeQuery: ((String) -> Void)?
    /// Under All, a search's Plugins and Skills sections each show more on their own.
    var groupLimits: [MarketplaceKind: Int] = [:]

    static let page = 24
    /// A section of a mixed search starts shorter, as on the site.
    static let groupPage = 16
    /// Tag chips on Skills: the commonest few, plus any chosen (the search covers the rest).
    static let tagChips = 8

    /// [marketplace] The site opens on Plugins (since 2026-11); the shelves are All's.
    init(kind: MarketplaceKind = .plugins, query: String = "", tier: MarketplaceTier? = nil, category: String? = nil) {
        self.kind = kind
        self.query = query
        self.tiers = tier.map { [$0] } ?? []
        self.categories = category.map { [$0] } ?? []
    }

    var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The home's shelves show only with nothing chosen, as the website's.
    var browsing: Bool { kind == .all && trimmed.isEmpty && !filtered && sort == .stars }
    var filtered: Bool { !tiers.isEmpty || !categories.isEmpty || !tags.isEmpty || source != nil }

    func clear() {
        tiers = []; categories = []; tags = []; source = nil; resetPaging()
    }

    func resetPaging() {
        limit = Self.page
        groupLimits = [:]
    }

    func groupLimit(_ kind: MarketplaceKind) -> Int { groupLimits[kind] ?? Self.groupPage }

    /// Another kind: its own categories, sources and tags start over; Skills have no tier row.
    func choose(_ kind: MarketplaceKind) {
        self.kind = kind
        categories = []; source = nil; tags = []
        if kind == .skills { tiers = [] }
        resetPaging()
    }

    func toggle(_ tier: MarketplaceTier) { tiers.formSymmetricDifference([tier]); resetPaging() }
    func toggle(category: String) { categories.formSymmetricDifference([category]); resetPaging() }
    func toggle(tag: String) { tags.formSymmetricDifference([tag]); resetPaging() }

    // MARK: Lists

    /// What the kind and source allow, before the chips and the search.
    func scoped(plugins: [PluginCatalogEntry], skills: [MarketSkill]) -> [MarketplaceItem] {
        var items: [MarketplaceItem] = []
        // A source names skills, so it leaves plugins out (the site's rule; its menu is only on Skills).
        if kind != .skills, source == nil { items += plugins.map(MarketplaceItem.plugin) }
        if kind != .plugins {
            items += skills.filter { source == nil || $0.source == source }.map(MarketplaceItem.skill)
        }
        return items
    }

    /// The items every chip row and the search let through; `except` sets one row's own choices aside, for its counts.
    func filter(_ items: [MarketplaceItem], except: MarketplaceFacet? = nil) -> [MarketplaceItem] {
        let query = trimmed
        return items.filter { item in
            (except == .tier || tiers.isEmpty || tiers.contains(item.tier))
                && (except == .category || categories.isEmpty || categories.contains(item.category))
                && (except == .tag || tags.isEmpty || item.tags.contains { tags.contains($0) })
                && (query.isEmpty || item.score(query) > 0)
        }
    }

    /// The results in the chosen order, a search's too, as on the site ("memory" leads with mem0's 68k stars, not a
    /// 50-star plugin with Memory in its name); only a plugin or skill named exactly what was typed goes first.
    func ordered(_ items: [MarketplaceItem]) -> [MarketplaceItem] {
        let sorted = Self.sorted(items, by: sort)
        let query = trimmed.lowercased()
        guard !query.isEmpty else { return sorted }
        func exact(_ item: MarketplaceItem) -> Bool {
            switch item {
            case .plugin(let entry): entry.name.lowercased() == query || entry.title.lowercased() == query
            case .skill(let entry): entry.name.lowercased() == query
            }
        }
        return sorted.filter(exact) + sorted.filter { !exact($0) }
    }

    /// The site's orders: most stars, newest or latest update first, else A to Z; ties (and skills, which have no
    /// stars or dates) go A to Z.
    static func sorted(_ items: [MarketplaceItem], by sort: MarketplaceSort) -> [MarketplaceItem] {
        func byName(_ a: MarketplaceItem, _ b: MarketplaceItem) -> Bool {
            a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        switch sort {
        case .name:
            return items.sorted(by: byName)
        case .stars:
            return items.sorted { a, b in (a.stars ?? -1) != (b.stars ?? -1) ? (a.stars ?? -1) > (b.stars ?? -1) : byName(a, b) }
        case .newest, .updated:
            func date(_ item: MarketplaceItem) -> Date { (sort == .newest ? item.addedAt : item.updatedAt) ?? .distantPast }
            return items.sorted { a, b in date(a) != date(b) ? date(a) > date(b) : byName(a, b) }
        }
    }

    // MARK: Chips

    /// Official · Certified · Community with their counts; none on Skills unless one is still chosen.
    func tierRows(_ items: [MarketplaceItem]) -> [(tier: MarketplaceTier, count: Int)] {
        guard kind != .skills || !tiers.isEmpty else { return [] }
        let counts = Dictionary(grouping: filter(items, except: .tier), by: \.tier).mapValues(\.count)
        return MarketplaceTier.allCases.compactMap { tier in
            let count = counts[tier] ?? 0
            return count > 0 || tiers.contains(tier) ? (tier, count) : nil
        }
    }

    /// The categories with their counts, A to Z with "Other" last; none under All unless one is still chosen.
    func categoryRows(_ items: [MarketplaceItem]) -> [(key: String, title: String, count: Int)] {
        guard kind != .all || !categories.isEmpty else { return [] }
        var labels: [String: String] = [:]
        var counts: [String: Int] = [:]
        for item in filter(items, except: .category) {
            switch item {
            case .plugin(let entry): labels[item.category] = entry.category.title
            case .skill(let entry): labels[item.category] = entry.categoryLabel
            }
            counts[item.category, default: 0] += 1
        }
        for key in categories where labels[key] == nil {
            labels[key] = PluginCatalogCategory(rawValue: key)?.title ?? key.capitalized
        }
        return labels.keys.sorted { a, b in
            a == "other" ? false : b == "other" ? true : (labels[a] ?? a).localizedCaseInsensitiveCompare(labels[b] ?? b) == .orderedAscending
        }.map { ($0, labels[$0] ?? $0, counts[$0] ?? 0) }
    }

    /// Skills' commonest tags, most used first, plus any chosen.
    func tagRows(_ items: [MarketplaceItem]) -> [(tag: String, count: Int)] {
        guard kind == .skills || !tags.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for item in filter(items, except: .tag) {
            for tag in Set(item.tags) { counts[tag, default: 0] += 1 }
        }
        let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let shown = Set(ranked.prefix(Self.tagChips).map(\.key)).union(tags)
        return ranked.filter { shown.contains($0.key) }.map { ($0.key, $0.value) }
            + tags.filter { counts[$0] == nil }.sorted().map { ($0, 0) }
    }
}

// MARK: - The page

final class MarketplaceController: SearchPageHost<HQScaledRoot<MarketplaceView>>, UISearchResultsUpdating {
    private let state: MarketplaceState
    private let router: SettingsRouter
    #if DEBUG
    private let debugModel: CapabilitiesModel
    #endif

    /// [marketplace-row] More › Integrations › Marketplace (and its tab, and the Mac sidebar's Tools): the page on its
    /// own, for the bot Install To starts on (Hermes').
    static func page(services: any AppServices) -> MarketplaceController {
        let model = CapabilitiesModel(services: services, profile: nil, tab: .plugins)
        // [mac-tools] The Mac's store front opens on Discover (the featured pick and the shelves); Plugins is one click down its side.
        return MarketplaceController(model: model, router: SettingsRouter(services: services, navigation: nil), kind: DeviceWord.isMac ? .all : .plugins)
    }

    init(model: CapabilitiesModel, router: SettingsRouter, kind: MarketplaceKind = .plugins, query: String = "",
         tier: MarketplaceTier? = nil, category: String? = nil) {
        let state = MarketplaceState(kind: kind, query: query, tier: tier, category: category)
        self.state = state
        self.router = router
        #if DEBUG
        debugModel = model
        #endif
        super.init(rootView: HQScaledRoot(MarketplaceView(model: model, state: state, router: router)))
        title = "Marketplace"
        navigationItem.largeTitleDisplayMode = .never
        let search = UISearchController(searchResultsController: nil)
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        // [mac] Mac polish #102: words that fit the bar's field ("Search skills, plugins an…" was cut off).
        search.searchBar.placeholder = DeviceWord.isMac ? "Search Marketplace" : "Search skills, plugins and authors"
        search.searchBar.text = query
        state.typeQuery = { [weak search] words in search?.searchBar.text = words }
        search.searchBar.searchTextField.accessibilityIdentifier = "marketplace.search"
        navigationItem.searchController = search
        PageSearchField.shownUntilIn(navigationItem)
        model.presenter = model.presenter ?? self
        // [mac-tools] The Mac's store front has Sort By at the top of each section, and its search in the bar's own row.
        if DeviceWord.isMac {
            navigationItem.preferredSearchBarPlacement = .integrated
        } else {
            installSortMenu()
        }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Sort By as a UIKit bar item, so Desktop Look draws it flat like every other bar button.
    private func installSortMenu() {
        let state = self.state
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { done in
            MainActor.assumeIsolated {
                done([UIMenu(title: "Sort By", options: .displayInline, children: MarketplaceSort.allCases.map { sort in
                    UIAction(title: sort.title, state: state.sort == sort ? .on : .off) { _ in state.sort = sort }
                })])
            }
        }])
        let item = UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"), menu: menu)
        item.accessibilityLabel = "Sort By"
        item.accessibilityIdentifier = "marketplace.sort"
        navigationItem.rightBarButtonItem = item
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if router.navigation == nil { router.navigation = navigationController }   // [marketplace-row] its own page
        // [mac] Its search field ended 8 pt from the column's edge, the cards under it 20 pt in: the bar takes the cards'
        // margins on the Mac, so the field stops where they do (its own stack in the sidebar; the Sort button stays put).
        if DeviceWord.isMac, let bar = navigationController?.navigationBar {
            bar.insetsLayoutMarginsFromSafeArea = false
            bar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != state.query else { return }
        state.query = text
        state.resetPaging()
    }

    #if DEBUG
    /// `-HQDebugMacShotsGrids` (MacShots): the segment picked, and the first plugin opened as a click on its card.
    func debugKind(_ kind: MarketplaceKind) { state.choose(kind) }
    func debugOpenFirst() {
        guard let entry = PluginCatalogStore.shared.entries?.first else { return }
        let page = PluginCatalogEntryController(model: debugModel, entry: entry, router: router)
        let close = UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { _ in
            MainTabController.current?.split?.closeDetail(animated: true)
        })
        page.navigationItem.leftBarButtonItem = close
        router.push(page)
    }
    #endif
}

struct MarketplaceView: View {
    @Bindable var model: CapabilitiesModel
    @Bindable var state: MarketplaceState
    let router: SettingsRouter
    @Environment(\.dynamicTypeSize) private var typeSize
    /// [mac-tools] The Mac page's width: the side list shows from `sideAt`.
    @State private var pageWidth: CGFloat = 0
    private var plugins: PluginCatalogStore { .shared }
    private var skills: SkillCatalogStore { .shared }

    var body: some View {
        page
        .refreshable {
            async let p: Void = plugins.load(force: true)
            async let s: Void = skills.load(force: true)
            _ = await (p, s)
        }
        .task {
            async let p: Void = plugins.load()
            async let s: Void = skills.load()
            if model.plugins == nil { Task { await model.reloadPlugins() } }
            if model.skills == nil { Task { await model.reloadSkills() } }
            _ = await (p, s)
        }
        .accessibilityIdentifier("marketplace.page")
    }

    @ViewBuilder private var page: some View {
        if DeviceWord.isMac {
            gridPage
        } else {
            List {
                if state.kind == .connectors {
                    controls
                    MarketplaceConnectors(model: model, router: router, query: state.trimmed)   // [connect-find]
                } else {
                    if state.trimmed.isEmpty, !state.filtered {
                        featured
                    }
                    controls
                    if state.browsing {
                        shelves
                    } else {
                        results
                    }
                }
            }
            .hqGroupedPage()
            .listStyle(.insetGrouped)
        }
    }

    // MARK: The Mac's grid

    /// [mac-tools] Owner 2026-11-09 (the Tools sketch): on the Mac the Marketplace is a store front over the whole
    /// window, not a list in a column beside an empty pane: the featured picks side by side, and every shelf and
    /// result a grid of cards, as many across as fit. A listing opens beside it (the grid narrows to one column of
    /// cards) and closes with its ✕.
    private var gridPage: some View {
        let wide = pageWidth >= Self.sideAt
        return HStack(spacing: 0) {
            if wide {
                storeSide
                Rectangle().fill(Color(uiColor: HQPalette.separator)).frame(width: 1).ignoresSafeArea(edges: .bottom)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if !wide {
                        VStack(alignment: .leading, spacing: 10) {
                            kindPicker
                            if model.bots.count > 1 { gridInstallTo }
                        }
                    }
                    if state.browsing {
                        let picks = MarketplaceFeatured.picks(pluginEntries)
                        if !picks.isEmpty {
                            if wide { storeHero(picks) } else {
                                gridSection("Featured Plugins") {
                                    MarketplaceCarousel(entries: picks, installed: { model.installedPlugin(for: $0) != nil }, open: { entry, install in
                                        openPlugin(entry, install: install)
                                    }, row: true)
                                }
                            }
                        }
                        gridShelves
                    } else {
                        resultsHead(wide: wide)
                        gridResults
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, wide ? 20 : 10)
                .padding(.bottom, 32)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { pageWidth = $0 })
        .background(Color(uiColor: HQPalette.groupedPage))
    }

    /// The page is drawn at 77 % on the Mac: this is about 800 pt of window. Narrower (a listing open beside it), the
    /// side list folds into the segments and chips.
    private static let sideAt: CGFloat = 1040

    // MARK: The side list

    /// Discover, then every plugin kind and skill category with its count: the store's sections down the side, as a
    /// Mac store's, where the chips ran off the window's edge.
    private var storeSide: some View {
        let pluginCounts = Dictionary(grouping: pluginEntries, by: \.category).mapValues(\.count)
        let skillRows = skillCategories
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sideRow("Discover", symbol: "star", count: nil, on: state.kind == .all && state.categories.isEmpty, id: "discover") {
                        state.choose(.all); state.clear(); state.sort = .stars
                    }
                    sideHead("Plugins")
                    sideRow("All Plugins", symbol: "puzzlepiece.extension", count: plugins.entries?.count,
                            on: state.kind == .plugins && state.categories.isEmpty, id: "plugins") { state.choose(.plugins) }
                    ForEach(PluginCatalogCategory.allCases.filter { pluginCounts[$0] != nil }.sorted { $0.title < $1.title }) { category in
                        sideRow(category.title, symbol: category.symbol, count: pluginCounts[category],
                                on: state.kind == .plugins && state.categories == [category.rawValue], id: "plugins.\(category.rawValue)") {
                            state.choose(.plugins); state.categories = [category.rawValue]
                        }
                    }
                    sideHead("Skills")
                    sideRow("All Skills", symbol: "sparkles", count: skills.entries?.count,
                            on: state.kind == .skills && state.categories.isEmpty, id: "skills") { state.choose(.skills) }
                    ForEach(skillRows, id: \.key) { row in
                        sideRow(row.title, symbol: SkillCatalogRow.symbol(category: row.key), count: row.count,
                                on: state.kind == .skills && state.categories == [row.key], id: "skills.\(row.key)") {
                            state.choose(.skills); state.categories = [row.key]
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 16)
            }
            if model.bots.count > 1 {
                Rectangle().fill(Color(uiColor: HQPalette.separator)).frame(height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Install To").font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2)
                    installToMenu { popFace(nil, model.botName).frame(maxWidth: .infinity) }
                }
                .padding(14)
            }
        }
        .frame(width: 264)
    }

    /// Skills' categories with their counts, A to Z with "Other" last.
    private var skillCategories: [(key: String, title: String, count: Int)] {
        var labels: [String: String] = [:], counts: [String: Int] = [:]
        for entry in skillEntries {
            let key = MarketplaceItem.skill(entry).category
            labels[key] = entry.categoryLabel
            counts[key, default: 0] += 1
        }
        return labels.keys.sorted { a, b in
            a == "other" ? false : b == "other" ? true : (labels[a] ?? a).localizedCaseInsensitiveCompare(labels[b] ?? b) == .orderedAscending
        }.map { ($0, labels[$0] ?? $0, counts[$0] ?? 0) }
    }

    private func sideHead(_ title: String) -> some View {
        Text(title.uppercased()).font(Font.hq(.caption).weight(.semibold)).foregroundStyle(Color.hqLabel2)
            .padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func sideRow(_ title: String, symbol: String, count: Int?, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button { HQMotion.withAnimation(.snappy) { action(); state.resetPaging() } } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(Font.hq(.subheadline)).foregroundStyle(on ? Color.hqTint : Color.hqLabel2).frame(width: 24)
                Text(title).font(Font.hq(.subheadline).weight(on ? .semibold : .regular)).foregroundStyle(Color.hqLabel).lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text(count.formatted()).font(Font.hq(.caption)).monospacedDigit().foregroundStyle(on ? Color.hqTint : Color.hqLabel2)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(on ? Color.hqTint.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("marketplace.side.\(id)")
    }

    // MARK: The top of a section

    /// "Memory" · what it is · how many, with Sort By at its right and the Official / Certified / Community chips under.
    private func resultsHead(wide: Bool) -> some View {
        let category = state.categories.count == 1 ? state.categories.first : nil
        let plugin = state.kind == .plugins ? category.flatMap(PluginCatalogCategory.init(rawValue:)) : nil
        let title = !state.trimmed.isEmpty ? "Results for “\(state.trimmed)”"
            : plugin?.title ?? category.flatMap { key in skillCategories.first { $0.key == key }?.title }
            ?? (state.kind == .plugins ? "All Plugins" : state.kind == .skills ? "All Skills" : "Plugins and Skills")
        let blurb = state.trimmed.isEmpty ? (plugin?.blurb ?? (category == nil && state.kind == .skills ? "Ready-made know-how your bots load when a task needs it." : nil)) : nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Font.hq(.title).weight(.bold)).foregroundStyle(Color.hqLabel).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    if let blurb { Text(blurb).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2) }
                }
                Spacer(minLength: 12)
                Menu {
                    Picker("Sort By", selection: $state.sort) {
                        ForEach(MarketplaceSort.allCases) { Text($0.title).tag($0) }
                    }
                } label: { popFace("Sort", state.sort.title) }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityIdentifier("marketplace.sort")
            }
            chips(categories: !wide)
        }
    }

    /// A pop-up button's face: "Sort  Most Stars ⌃".
    private func popFace(_ lead: String?, _ value: String) -> some View {
        HStack(spacing: 6) {
            if let lead { Text(lead).foregroundStyle(Color.hqLabel2) }
            Text(value).foregroundStyle(Color.hqLabel).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down").font(Font.hq(.caption2).weight(.semibold)).foregroundStyle(Color.hqLabel2)
        }
        .font(Font.hq(.subheadline))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(uiColor: MacPush.fill), in: RoundedRectangle(cornerRadius: MacField.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MacField.radius, style: .continuous).strokeBorder(Color(uiColor: MacPush.stroke)))
        .contentShape(Rectangle())
    }

    // MARK: The featured picks

    /// This week's pick large, with its picture whole, and the other picks down its right side.
    private func storeHero(_ picks: [PluginCatalogEntry]) -> some View {
        HStack(alignment: .top, spacing: 14) {
            MarketplaceHero(entry: picks[0], installed: model.installedPlugin(for: picks[0]) != nil) { install in
                openPlugin(picks[0], install: install)
            }
            if picks.count > 1 {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(picks.dropFirst()) { entry in
                            Button { openPlugin(entry) } label: {
                                HStack(spacing: 12) {
                                    MarketplaceBanner(url: entry.image, name: entry.title, symbol: entry.category.symbol)
                                        .frame(width: 150, height: 84)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.title).font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel).lineLimit(1)
                                        Text(PluginCatalogEntry.styled(entry.summary)).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                                            .lineLimit(2)
                                        Text("by \(entry.maintainer)").font(Font.hq(.caption)).foregroundStyle(Color(uiColor: HQPalette.cardNote)).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(10)
                                .background(Color(uiColor: HQPalette.card), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay { cardEdge(12) }
                                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                            .accessibilityIdentifier("marketplace.featured.pick-\(entry.name)")
                        }
                    }
                }
                .frame(width: 400)
            }
        }
        .frame(height: 344)
        .accessibilityIdentifier("marketplace.featured")
    }

    /// Where the card is the page's colour (the Desktop Look, the light iOS look) an outline is its edge.
    @ViewBuilder private func cardEdge(_ radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color(uiColor: MarketplaceHero.edge))
    }

    private var kindPicker: some View {
        HQSegmentedPicker("Show", options: MarketplaceKind.shown.map { ($0.title, $0) }, selection: Binding(get: { state.kind }, set: { kind in
            state.choose(kind)
        }))
        .accessibilityIdentifier("marketplace.kind")
    }

    /// "Install To  Hermes ⌃": the bot new plugins and skills go to, as a pop-up.
    private var gridInstallTo: some View {
        installToMenu { popFace("Install To", model.botName) }.fixedSize()
    }

    private func installToMenu<Face: View>(@ViewBuilder face: () -> Face) -> some View {
        Menu {
            Picker("Install To", selection: Binding(get: { model.profile }, set: { bot in
                guard bot != model.profile else { return }
                model.profile = bot
                Task { if model.tab != .skills { await model.reloadSkills() }; if model.tab != .plugins { await model.reloadPlugins() } }
            })) {
                ForEach(model.bots) { bot in Text(bot.name).tag(bot.id) }
            }
        } label: { face() }
        .buttonStyle(.plain)
        .accessibilityIdentifier("marketplace.install-to")
    }

    /// A shelf's picks in whole rows: four picks in three columns show three, not a fourth alone on its own row.
    private func wholeRows<T>(_ items: [T]) -> [T] {
        guard pageWidth >= Self.sideAt else { return items }
        let columns = max(1, Int((pageWidth - 265 - 48 + 12) / (350 + 12)))
        return items.count > columns ? Array(items.prefix(items.count - items.count % columns)) : items
    }

    private static let gridColumns = [GridItem(.adaptive(minimum: 350), spacing: 12, alignment: .top)]

    /// A titled part of the grid page: its name (and See All), what it holds, a line under it.
    private func gridSection<Content: View>(_ title: String, note: String? = nil, seeAll: (title: String, id: String, action: () -> Void)? = nil,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if !title.isEmpty {
                    Text(title).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel).accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 0)
                if let seeAll {
                    Button(action: seeAll.action) { Text(seeAll.title).font(Font.hq(.subheadline)).foregroundStyle(Color.hqTint) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(seeAll.id)
                }
            }
            content()
            if let note { Text(note).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2) }
        }
    }

    private func cards<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: 12) { content() }
    }

    /// A card of the grid: what it holds on the card's colour, lit under the pointer.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)   // the Mac draws the page at 77 %
            .background(Color(uiColor: HQPalette.card), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { cardEdge(12) }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .hoverEffect(.highlight)
    }

    @ViewBuilder private func itemCard(_ item: MarketplaceItem) -> some View {
        switch item {
        case .plugin(let entry): pluginCard(entry)
        case .skill(let entry): skillCard(entry)
        }
    }

    private func pluginCard(_ entry: PluginCatalogEntry) -> some View {
        let maker = entry.maintainer.isEmpty ? nil : Text(entry.maintainer)
        let stars = entry.stars.map { Text("\(Image(systemName: "star.fill")) \($0.starWords)") }
        let line: Text? = maker.map { m in stars.map { Text("\(m)  ·  \($0)") } ?? m } ?? stars
        return storeCard(id: "plugin-catalog-row-\(entry.name)", symbol: entry.category.symbol, color: entry.category.storeColor,
                         title: entry.title, badge: entry.tierWord, summary: Text(PluginCatalogEntry.styled(entry.summary)), line: line,
                         installed: model.installedPlugin(for: entry) != nil, open: { openPlugin(entry) },
                         install: {
            // One small button a card: it asks first (a skill's Install does too), then installs on the plugin's page.
            let from = entry.isOfficial ? "It comes from Nous. " : "It comes from \(entry.maintainer), listed in the Hermes Marketplace. "
            TextPrompt.confirmPlain(title: "Install \(entry.title) for \(model.botName)?",
                                    message: from + "Hermes installs the exact version Nous checked.",
                                    action: "Install", from: model.presenter) { openPlugin(entry, install: true) }
        })
    }

    private func skillCard(_ entry: MarketSkill) -> some View {
        let words = [entry.author, entry.categoryLabel].filter { !$0.isEmpty }.joined(separator: "  ·  ")
        return storeCard(id: "skill-catalog-row-\(entry.name)", symbol: SkillCatalogRow.symbol(entry), color: MarketplaceTile.color(for: entry.category),
                         title: entry.name, badge: entry.badge, summary: Text(entry.description), line: words.isEmpty ? nil : Text(words),
                         installed: model.skillInstalled(entry), open: { openSkill(entry) }, install: { model.install(entry) })
    }

    /// A plugin or skill as a store's card: its tile, name and badge, two lines of what it does, who made it, and
    /// Install (or Installed) at the bottom right. The card opens its listing; Install starts the install.
    private func storeCard(id: String, symbol: String, color: Color, title: String, badge: String?, summary: Text, line: Text?,
                           installed: Bool, open: @escaping () -> Void, install: @escaping () -> Void) -> some View {
        card {
            Button(action: open) {
                HStack(alignment: .top, spacing: 12) {
                    MarketplaceTile(symbol: symbol, color: color, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(title).font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel).lineLimit(1)
                            if let badge { PluginTierBadge(words: badge) }
                        }
                        summary.font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(2, reservesSpace: true)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 6)
                        (line ?? Text(" ")).font(Font.hq(.caption)).foregroundStyle(Color(uiColor: HQPalette.cardNote)).lineLimit(1)
                            .padding(.trailing, 92)   // Install's room
                            .frame(minHeight: 26)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
            .overlay(alignment: .bottomTrailing) {
                if installed {
                    Label("Installed", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                        .font(Font.hq(.caption).weight(.semibold)).foregroundStyle(.green)
                        .frame(minHeight: 26)
                } else {
                    Button(action: install) {
                        Text("Install").font(Font.hq(.caption).weight(.bold)).foregroundStyle(Color.hqTint)
                            .padding(.horizontal, 14).frame(minHeight: 26)
                            .background(Color.hqTint.opacity(0.14), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Install \(title)")
                    .accessibilityIdentifier("\(id).install")
                }
            }
        }
    }

    private func gridNote(_ words: String, retry: (id: String, action: () async -> Void)? = nil) -> some View {
        HStack(spacing: 12) {
            Text(words).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button("Try Again") { Task { await retry.action() } }.accessibilityIdentifier(retry.id)
            }
        }
        .font(Font.hq(.subheadline))
    }

    private var gridLoading: some View {
        cards { ForEach(0..<8, id: \.self) { _ in card { SkeletonLine() } } }
    }

    @ViewBuilder private var gridShelves: some View {
        if plugins.entries == nil, let error = plugins.error {
            gridNote(error, retry: ("marketplace.retry", { await plugins.load(force: true) }))
        } else if plugins.entries == nil {
            gridLoading
        } else {
            let quality = MarketplaceFeatured.qualityOfLife(pluginEntries)
            if !quality.isEmpty {
                gridSection("Quality of Life Improvements", note: "The most-starred desktop and tool plugins in the catalog.",
                            seeAll: ("See All", "marketplace.shelf.quality.all", {
                    narrow(to: .plugins, category: PluginCatalogCategory.tools.rawValue)
                })) { cards { ForEach(wholeRows(quality)) { pluginCard($0) } } }
            }
            if let spotlight = MarketplaceFeatured.spotlight(pluginEntries) {
                gridSection("Spotlight: \(spotlight.maker)",
                            note: "\(spotlight.picks.count) picks from the community maintainer with the most plugins in the catalog.",
                            seeAll: ("See All", "marketplace.shelf.spotlight.all", {
                    narrow(to: .plugins, query: spotlight.maker)
                })) { cards { ForEach(wholeRows(spotlight.picks)) { pluginCard($0) } } }
            }
            if skills.entries == nil || !skillEntries.isEmpty {
                let official = skillEntries.filter { $0.source == "optional" }
                gridSection("Skills from Nous", note: "Ready-made know-how your bots load when a task needs it.",
                            seeAll: skills.entries == nil ? nil : ("See All \(skillEntries.count.formatted()) Skills", "marketplace.shelf.skills.all", {
                    narrow(to: .skills)
                })) {
                    if skills.entries == nil {
                        if let error = skills.error {
                            gridNote(error, retry: ("marketplace.retry.skills", { await skills.load(force: true) }))
                        } else {
                            gridLoading
                        }
                    } else {
                        cards { ForEach(wholeRows(Array(official.prefix(8)))) { skillCard($0) } }
                    }
                }
            }
            if let context = MarketplaceAnywhere.context(model.services), MorePages.factories["messaging"] != nil {
                let more = pluginEntries.filter { $0.category == .platform }.count
                gridSection("Talk to Hermes Anywhere",
                            note: "Chat where you already are. Set each one up in Messaging, or add more chat apps with a plugin.",
                            seeAll: more == 0 ? nil : ("\(more.formatted()) Messaging Plugins", "marketplace.shelf.anywhere.all", {
                    narrow(to: .plugins, category: PluginCatalogCategory.platform.rawValue)
                })) {
                    cards {
                        ForEach(MarketplaceAnywhere.platforms, id: \.name) { platform in
                            card {
                                Button {
                                    if let page = MorePages.factories["messaging"]?(context) { beside(page); router.push(page) }
                                } label: {
                                    wordsCard(platform.name, platform.blurb, symbol: platform.symbol)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("marketplace.anywhere.\(platform.name.lowercased())")
                            }
                        }
                    }
                }
            }
            gridSection("More") {
                cards {
                    card {
                        Button {
                            let page = CapabilitiesViewController(services: model.services, profile: model.profile, tab: .connectors)
                            beside(page)
                            router.push(page)
                        } label: {
                            wordsCard("Connectors", "Connect Hermes to the apps you already use, with one sign-in each.",
                                      symbol: CapabilitiesTab.connectors.symbol)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("marketplace.connectors")
                    }
                    linkCard("Make a Hermes Plugin", "Build a plugin or a skill for Hermes and send it to Nous to be listed.",
                             MarketplaceMore.developerURL, id: "marketplace.developer")
                    linkCard("Open the Marketplace Website", "Everything in the Marketplace, in your browser.",
                             MarketplaceMore.websiteURL, id: "marketplace.website")
                }
            }
        }
    }

    private func wordsCard(_ title: String, _ blurb: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            MarketplaceTile(symbol: symbol, color: MarketplaceTile.color(for: title), size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel)
                Text(blurb).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(3).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private func linkCard(_ title: String, _ blurb: String, _ url: URL, id: String) -> some View {
        card {
            Button {
                if let host = router.presenter { LinkOpener.open(url, from: host) }
            } label: {
                wordsCard(title, blurb, symbol: "arrow.up.right")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
        }
    }

    @ViewBuilder private var gridResults: some View {
        let plugsMissing = state.kind != .skills && plugins.entries == nil
        let skillsMissing = state.kind != .plugins && skills.entries == nil
        let plugsShown = state.kind != .skills && !plugsMissing
        let skillsShown = state.kind != .plugins && !skillsMissing
        if !plugsShown && !skillsShown {
            if let error = (plugsMissing ? plugins.error : nil) ?? (skillsMissing ? skills.error : nil) {
                gridNote(error, retry: ("marketplace.retry", { await plugins.load(force: true); await skills.load(force: true) }))
            } else {
                gridLoading
            }
        } else {
            let found = matching()
            if plugsMissing { gridMissing(plugins.error, what: "plugins") { await plugins.load(force: true) } }
            if skillsMissing { gridMissing(skills.error, what: "skills") { await skills.load(force: true) } }
            let foundPlugins = found.filter { !$0.isSkill }, foundSkills = found.filter(\.isSkill)
            if state.kind == .all, !foundPlugins.isEmpty, !foundSkills.isEmpty {
                gridGroup(foundPlugins, kind: .plugins)
                gridGroup(foundSkills, kind: .skills)
            } else if found.isEmpty {
                Text(state.trimmed.isEmpty ? "Nothing here matches these filters." : "Nothing in the Marketplace matches “\(state.trimmed)”.")
                    .font(Font.hq(.body)).foregroundStyle(Color.hqLabel2)
                    .accessibilityIdentifier("marketplace.none")
            } else {
                let note: String? = state.kind == .skills || state.source != nil ? Self.skillsFooter : (state.kind == .plugins ? Self.pluginsFooter : nil)
                gridSection("\(min(state.limit, found.count)) of \(found.count.formatted()) \(resultWord(found.count, kind: state.kind))", note: note) {
                    cards { ForEach(found.prefix(state.limit)) { itemCard($0) } }
                    if found.count > state.limit {
                        gridMore(left: found.count - state.limit, id: "marketplace.more") { state.limit += MarketplaceState.page }
                    }
                }
            }
        }
    }

    private func gridGroup(_ items: [MarketplaceItem], kind: MarketplaceKind) -> some View {
        let limit = state.groupLimit(kind)
        let title = items.count > limit ? "\(limit) of \(items.count.formatted()) \(resultWord(items.count, kind: kind))"
                                        : "\(items.count.formatted()) \(resultWord(items.count, kind: kind))"
        return gridSection(title, note: kind == .skills ? Self.skillsFooter : Self.pluginsFooter) {
            cards { ForEach(items.prefix(limit)) { itemCard($0) } }
            if items.count > limit {
                gridMore(left: items.count - limit, id: "marketplace.more.\(kind.rawValue)") {
                    state.groupLimits[kind] = limit + MarketplaceState.page
                }
            }
        }
    }

    private func gridMore(left: Int, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Show More (\(left.formatted()) left)").font(Font.hq(.subheadline)).foregroundStyle(Color.hqTint)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Color(uiColor: HQPalette.card), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Show more, \(left) left")
        .accessibilityIdentifier(id)
    }

    @ViewBuilder private func gridMissing(_ error: String?, what: String, retry: @escaping () async -> Void) -> some View {
        if let error {
            gridNote("The Marketplace’s \(what) didn’t load. \(error)", retry: ("marketplace.retry.\(what)", retry))
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading \(what)…").foregroundStyle(Color.hqLabel2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("marketplace.loading.\(what)")
        }
    }

    /// A shelf's See All on the grid: the store front itself narrows to it (its segment, chip or search say so, and
    /// undo it), where the list pushes a second Marketplace page.
    private func narrow(to kind: MarketplaceKind, category: String? = nil, query: String? = nil) {
        HQMotion.withAnimation(.snappy) {
            state.choose(kind)
            if let category { state.categories = [category] }
            if let query { state.query = query; state.typeQuery?(query) }
            state.resetPaging()
        }
    }

    /// `page` is about to show beside the grid: it gets a ✕ that closes it (the grid takes the window back).
    private func beside(_ page: UIViewController) {
        #if targetEnvironment(macCatalyst)
        guard let split = MainTabController.current?.split, split.isDouble else { return }
        let close = UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { _ in
            MainTabController.current?.split?.closeDetail(animated: true)
        })
        close.accessibilityLabel = "Close"
        close.accessibilityIdentifier = "marketplace.detail.close"
        page.navigationItem.leftBarButtonItem = close
        #endif
    }

    // MARK: Lists

    private var pluginEntries: [PluginCatalogEntry] { plugins.entries ?? [] }
    private var skillEntries: [MarketSkill] { skills.entries ?? [] }

    /// What the kind and source allow, before the chips and the search.
    private func scoped() -> [MarketplaceItem] { state.scoped(plugins: pluginEntries, skills: skillEntries) }

    private func matching() -> [MarketplaceItem] { state.ordered(state.filter(scoped())) }

    // MARK: Featured

    @ViewBuilder private var featured: some View {
        let picks = MarketplaceFeatured.picks(pluginEntries)
        if !picks.isEmpty, state.kind != .skills {
            Section {
                MarketplaceCarousel(entries: picks, installed: { model.installedPlugin(for: $0) != nil }) { entry, install in
                    openPlugin(entry, install: install)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: { HQSectionLabel { Text("Featured Plugins") } }
        }
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        Section {
            // [desktop-segments] Owner 2026-11-05: the raw segmented Picker drew iOS 26's glass pill over the Desktop
            // Look's outlined strip images (a warped band); HQSegmentedPicker shows the look's own strip there.
            HQSegmentedPicker("Show", options: MarketplaceKind.shown.map { ($0.title, $0) }, selection: Binding(get: { state.kind }, set: { kind in
                state.choose(kind)
            }))
            .accessibilityIdentifier("marketplace.kind")
            .hqDesktopBareRow()
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0))
            if state.kind != .connectors {   // [connect-find] no Official / Certified / Community for apps
                chips
                    .hqDesktopBareRow()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
            }
        }
        if model.bots.count > 1 {
            if DeviceWord.isMac || typeSize.isAccessibilitySize {
                Section { MarketplaceInstallTo(model: model) }
            } else {
                // [market-slim] One quiet line at the trailing edge above the list, not a full-width box of its own.
                Section {
                    MarketplaceInstallTo(model: model, compact: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .hqDesktopBareRow()
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }
                .listSectionSpacing(.compact)
            }
        }
    }

    /// A Sources menu on Skills, Official 21 · Certified 11 · Community 1,171, the categories, then Skills' tags, each
    /// row counted with its own choices set aside (the site's counts). Several chips in a row can be on at once.
    private var chips: some View { chips(categories: true) }

    /// `categories` false: the Mac's side list holds them.
    private func chips(categories withCategories: Bool) -> some View {
        let base = scoped()
        let tiers = state.tierRows(base)
        let categories = withCategories ? state.categoryRows(base) : []
        let tags = state.tagRows(base)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if state.kind == .skills { sourceMenu }
                ForEach(tiers, id: \.tier) { row in
                    MarketplaceChip(title: row.tier.title, count: row.count, on: state.tiers.contains(row.tier)) {
                        state.toggle(row.tier)
                    }
                    .accessibilityIdentifier("marketplace.tier.\(row.tier.rawValue)")
                }
                if !tiers.isEmpty, !categories.isEmpty { Divider().frame(height: 18) }
                ForEach(categories, id: \.key) { row in
                    MarketplaceChip(title: row.title, count: row.count, on: state.categories.contains(row.key)) {
                        state.toggle(category: row.key)
                    }
                    .accessibilityIdentifier("marketplace.category.\(row.key)")
                }
                if !tags.isEmpty, !(tiers.isEmpty && categories.isEmpty) { Divider().frame(height: 18) }
                ForEach(tags, id: \.tag) { row in
                    MarketplaceChip(title: row.tag, count: row.count, on: state.tags.contains(row.tag)) {
                        state.toggle(tag: row.tag)
                    }
                    .accessibilityIdentifier("marketplace.tag.\(row.tag)")
                }
                // The Mac's side list holds the category: Clear there undoes only the chips.
                if withCategories ? state.filtered : !(state.tiers.isEmpty && state.tags.isEmpty && state.source == nil) {
                    Button("Clear") {
                        HQMotion.withAnimation(.snappy) {
                            if withCategories { state.clear() } else { state.tiers = []; state.tags = []; state.source = nil; state.resetPaging() }
                        }
                    }
                        .font(Font.hq(.subheadline)).foregroundStyle(Color.hqTint).buttonStyle(.plain)
                        .accessibilityIdentifier("marketplace.clear")
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private var sourceMenu: some View {
        let counts = Dictionary(grouping: skillEntries, by: \.source).mapValues(\.count)
        return Menu {
            Picker("Source", selection: Binding(get: { state.source }, set: { state.source = $0; state.categories = []; state.resetPaging() })) {
                Text("All Sources (\(skillEntries.count))").tag(String?.none)
                ForEach(MarketSkill.sources.filter { counts[$0] != nil }, id: \.self) { source in
                    Text("\(MarketSkill.sourceWord(source)) (\(counts[source] ?? 0))").tag(Optional(source))
                }
            }
        } label: {
            MarketplaceChipFace(title: state.source.map(MarketSkill.sourceWord) ?? "All Sources", count: nil, on: state.source != nil,
                                menu: true)
        }
        .accessibilityIdentifier("marketplace.source")
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        // A list this view needs that hasn't read (failed, or still on its way): never "nothing matches" for it.
        let plugsMissing = state.kind != .skills && plugins.entries == nil
        let skillsMissing = state.kind != .plugins && skills.entries == nil
        let plugsShown = state.kind != .skills && !plugsMissing
        let skillsShown = state.kind != .plugins && !skillsMissing
        if !plugsShown && !skillsShown {
            if let error = (plugsMissing ? plugins.error : nil) ?? (skillsMissing ? skills.error : nil) {
                Section {
                    Text(error).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true).padding(.vertical, 2)
                    Button("Try Again") { Task { await plugins.load(force: true); await skills.load(force: true) } }
                        .accessibilityIdentifier("marketplace.retry")
                }
            } else {
                Section { ForEach(0..<6, id: \.self) { _ in SkeletonLine() } }
            }
        } else {
            let found = matching()
            if plugsMissing { missing(plugins.error, what: "plugins") { await plugins.load(force: true) } }
            if skillsMissing { missing(skills.error, what: "skills") { await skills.load(force: true) } }
            let foundPlugins = found.filter { !$0.isSkill }, foundSkills = found.filter(\.isSkill)
            if state.kind == .all, !foundPlugins.isEmpty, !foundSkills.isEmpty {
                // [marketplace] A search over both kinds reads as two sections, Plugins then Skills, as on the site.
                group(foundPlugins, kind: .plugins)
                group(foundSkills, kind: .skills)
            } else {
                Section {
                    if found.isEmpty {
                        Text(state.trimmed.isEmpty ? "Nothing here matches these filters." : "Nothing in the Marketplace matches “\(state.trimmed)”.")
                            .foregroundStyle(Color.hqLabel2).padding(.vertical, 4)
                            .accessibilityIdentifier("marketplace.none")
                    }
                    ForEach(found.prefix(state.limit)) { row($0) }
                    if found.count > state.limit {
                        moreButton(left: found.count - state.limit, id: "marketplace.more") { state.limit += MarketplaceState.page }
                    }
                } header: { HQSectionLabel {
                    if !found.isEmpty { Text("\(min(state.limit, found.count)) of \(found.count.formatted()) \(resultWord(found.count, kind: state.kind))") }
                } } footer: { HQSectionFooter {
                    if state.kind == .skills || state.source != nil {
                        Text(Self.skillsFooter)
                    } else if state.kind == .plugins {
                        Text(Self.pluginsFooter)
                    }
                } }
            }
        }
    }

    private static let skillsFooter = "Skills from Hermes, Nous, NVIDIA, OpenAI, Hugging Face and Anthropic. Search the Skills Hub on the Skills page for community skills."
    private static let pluginsFooter = "Nous reviews every plugin before it is listed, and Hermes installs the exact version it checked."

    /// One kind's section of a mixed search, shorter at first, with its own Show More.
    private func group(_ items: [MarketplaceItem], kind: MarketplaceKind) -> some View {
        let limit = state.groupLimit(kind)
        return Section {
            ForEach(items.prefix(limit)) { row($0) }
            if items.count > limit {
                moreButton(left: items.count - limit, id: "marketplace.more.\(kind.rawValue)") {
                    state.groupLimits[kind] = limit + MarketplaceState.page
                }
            }
        } header: { HQSectionLabel {
            Text(items.count > limit ? "\(limit) of \(items.count.formatted()) \(resultWord(items.count, kind: kind))"
                                      : "\(items.count.formatted()) \(resultWord(items.count, kind: kind))")
        } } footer: { HQSectionFooter { Text(kind == .skills ? Self.skillsFooter : Self.pluginsFooter) } }
    }

    private func moreButton(left: Int, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { BrowseRowLabel(title: "Show More", count: left) }
            .buttonStyle(.plain)
            .accessibilityLabel("Show more, \(left) left")
            .accessibilityIdentifier(id)
    }

    /// One of the two lists, not read yet under the other's results: why, with Try Again, or that it is on its way.
    private func missing(_ error: String?, what: String, retry: @escaping () async -> Void) -> some View {
        Section {
            if let error {
                Text("The Marketplace’s \(what) didn’t load. \(error)")
                    .foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true).padding(.vertical, 2)
                Button("Try Again") { Task { await retry() } }
                    .accessibilityIdentifier("marketplace.retry.\(what)")
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading \(what)…").foregroundStyle(Color.hqLabel2)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("marketplace.loading.\(what)")
            }
        }
    }

    private func resultWord(_ count: Int, kind: MarketplaceKind) -> String {
        switch kind {
        case .plugins: count == 1 ? "Plugin" : "Plugins"
        case .skills: count == 1 ? "Skill" : "Skills"
        case .all, .connectors: count == 1 ? "Result" : "Results"
        }
    }

    @ViewBuilder private func row(_ item: MarketplaceItem) -> some View {
        switch item {
        case .plugin(let entry):
            PluginCatalogRow(entry: entry, installed: model.installedPlugin(for: entry) != nil) { openPlugin(entry) }
        case .skill(let entry):
            SkillCatalogRow(entry: entry, installed: model.skillInstalled(entry)) { openSkill(entry) }
        }
    }

    // MARK: Shelves

    @ViewBuilder private var shelves: some View {
        if plugins.entries == nil, let error = plugins.error {
            Section {
                Text(error).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true).padding(.vertical, 2)
                Button("Try Again") { Task { await plugins.load(force: true) } }
                    .accessibilityIdentifier("marketplace.retry")
            }
        } else if plugins.entries == nil {
            Section { ForEach(0..<4, id: \.self) { _ in SkeletonLine() } }
        } else {
            shelf(title: "Quality of Life Improvements", blurb: "The most-starred desktop and tool plugins in the catalog.", id: "quality",
                  items: MarketplaceFeatured.qualityOfLife(pluginEntries)) {
                router.push(MarketplaceController(model: model, router: router, kind: .plugins, category: PluginCatalogCategory.tools.rawValue))
            }
            if let spotlight = MarketplaceFeatured.spotlight(pluginEntries) {
                shelf(title: "Spotlight: \(spotlight.maker)",
                      blurb: "\(spotlight.picks.count) picks from the community maintainer with the most plugins in the catalog.", id: "spotlight",
                      items: spotlight.picks) {
                    router.push(MarketplaceController(model: model, router: router, kind: .plugins, query: spotlight.maker))
                }
            }
            if skills.entries == nil || !skillEntries.isEmpty {
                let official = skillEntries.filter { $0.source == "optional" }
                Section {
                    if skills.entries == nil {
                        // Failed or still reading: the shelf stays, saying so (it had vanished).
                        if let error = skills.error {
                            Text(error).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true).padding(.vertical, 2)
                            Button("Try Again") { Task { await skills.load(force: true) } }
                                .accessibilityIdentifier("marketplace.retry.skills")
                        } else {
                            ForEach(0..<2, id: \.self) { _ in SkeletonLine() }
                        }
                    } else {
                        ForEach(official.prefix(4)) { entry in
                            SkillCatalogRow(entry: entry, installed: model.skillInstalled(entry)) { openSkill(entry) }
                        }
                        Button { router.push(MarketplaceController(model: model, router: router, kind: .skills)) } label: {
                            BrowseRowLabel(title: "See All Skills", count: skillEntries.count)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("marketplace.shelf.skills.all")
                    }
                } header: { HQSectionLabel { Text("Skills from Nous") } } footer: { HQSectionFooter {
                    Text("Ready-made know-how your bots load when a task needs it.")
                } }
            }
            MarketplaceAnywhere(model: model, router: router)
            MarketplaceMore(model: model, router: router)
        }
    }

    private func shelf(title: String, blurb: String, id: String, items: [PluginCatalogEntry], seeAll: @escaping () -> Void) -> some View {
        Section {
            ForEach(items) { entry in
                PluginCatalogRow(entry: entry, installed: model.installedPlugin(for: entry) != nil) { openPlugin(entry) }
            }
            Button(action: seeAll) {
                HStack {
                    Text("See All").foregroundStyle(Color.hqTint)
                    Spacer()
                    SettingsChevron().accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("marketplace.shelf.\(id).all")
        } header: { HQSectionLabel { Text(title) } } footer: { HQSectionFooter { Text(blurb) } }
    }

    // MARK: Opening

    private func openPlugin(_ entry: PluginCatalogEntry, install: Bool = false) {
        let page = PluginCatalogEntryController(model: model, entry: entry, router: router)
        beside(page)
        // Before the push: beside the Mac's store front the page is shown at once, and would have appeared already.
        if install { page.installWhenShown(router: router) }
        router.push(page)
    }

    private func openSkill(_ entry: MarketSkill) {
        let page = SkillCatalogEntryController(model: model, entry: entry, router: router)
        beside(page)
        router.push(page)
    }
}

// MARK: - On the Skills page

/// Under the Skills list: Marketplace skills that match the search (or a way into the Marketplace), as Find Plugins
/// sits under Plugins.
struct SkillsMarketplaceSection: View {
    @Bindable var model: CapabilitiesModel
    let router: SettingsRouter
    private var catalog: SkillCatalogStore { .shared }

    var body: some View {
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = catalog.entries ?? []
        let matches = query.isEmpty ? [] : MarketSkill.search(entries, query).filter { !model.skillInstalled($0) }
        Section {
            ForEach(matches.prefix(5)) { entry in
                SkillCatalogRow(entry: entry, installed: false) {
                    router.push(SkillCatalogEntryController(model: model, entry: entry, router: router))
                }
            }
            Button {
                router.push(MarketplaceController(model: model, router: router, kind: .skills, query: matches.count > 5 ? query : ""))
            } label: {
                BrowseRowLabel(title: matches.count > 5 ? "See All Results" : "Open the Marketplace", count: matches.count > 5 ? matches.count : entries.count)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("skills.marketplace.open")
        } header: { HQSectionLabel { Text("Hermes Marketplace") } } footer: { HQSectionFooter {
            Text("Skills from Hermes, Nous, NVIDIA, OpenAI, Hugging Face and Anthropic, ready to install.")
        } }
        .task { await catalog.load() }
    }
}

// MARK: - Picks

@MainActor enum MarketplaceFeatured {
    private static let week: TimeInterval = 7 * 24 * 60 * 60

    /// The website's hero picks (apps/shared catalog-featured.ts): the curated ranks, starting at this week's; with none,
    /// the newest pictured official plugin of the last 30 days, else the official one with a picture and the most stars.
    static func picks(_ entries: [PluginCatalogEntry], now: Date = Date()) -> [PluginCatalogEntry] {
        let curated = entries.filter { $0.featured != nil }.sorted { ($0.featured ?? 0) < ($1.featured ?? 0) }
        if !curated.isEmpty {
            let start = Int(now.timeIntervalSince1970 / week) % curated.count
            return Array(curated[start...] + curated[..<start])
        }
        let official = entries.filter(\.isOfficial)
        let fresh = official.filter { $0.image != nil && ($0.addedAt ?? .distantPast) > now.addingTimeInterval(-30 * 24 * 60 * 60) }
            .sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
        let pick = fresh.first ?? official.sorted { a, b in
            (a.image != nil) != (b.image != nil) ? a.image != nil : (a.stars ?? 0) > (b.stars ?? 0)
        }.first
        return pick.map { [$0] } ?? []
    }

    static func isPick(_ entry: PluginCatalogEntry) -> Bool { entry.featured != nil }

    /// The site's Quality of Life shelf: the four most-starred desktop and tool plugins that aren't featured.
    static func qualityOfLife(_ entries: [PluginCatalogEntry]) -> [PluginCatalogEntry] {
        Array(entries.filter { ($0.category == .tools || $0.category == .desktop) && !isPick($0) }
            .enumerated().sorted { ($0.element.stars ?? -1) != ($1.element.stars ?? -1) ? ($0.element.stars ?? -1) > ($1.element.stars ?? -1) : $0.offset < $1.offset }
            .map(\.element).prefix(4))
    }

    /// The community maintainer with the most plugins, and their four most-starred (the website's Spotlight).
    static func spotlight(_ entries: [PluginCatalogEntry]) -> (maker: String, picks: [PluginCatalogEntry])? {
        let community = entries.filter { !$0.isOfficial && !$0.isVerified && !$0.maintainer.isEmpty }
        let counts = Dictionary(grouping: community, by: \.maintainer).mapValues(\.count)
        guard let maker = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key,
              (counts[maker] ?? 0) >= 2 else { return nil }
        let picks = community.filter { $0.maintainer == maker }.sorted { ($0.stars ?? 0) > ($1.stars ?? 0) }
        return (maker, Array(picks.prefix(4)))
    }
}

extension CapabilitiesModel {
    /// A Marketplace skill this bot already has (by name: Hermes lists skills by name, not by where they came from).
    func skillInstalled(_ entry: MarketSkill) -> Bool {
        hubInstalled.contains(entry.installIdentifier) || (skills ?? []).contains { $0.name == entry.name }
    }

    /// "Install" on a Marketplace skill: asks first, saying where it comes from, then installs as a hub skill does.
    func install(_ entry: MarketSkill, done: (() -> Void)? = nil) {
        guard !running.contains(entry.installIdentifier) else { return }
        let bot = botName
        let from = entry.isOfficial ? "It comes from Nous. " : "It comes from \(entry.sourceWord), listed in the Hermes Marketplace. "
        TextPrompt.confirmPlain(title: "Install \(entry.name) for \(bot)?",
                                message: from + "The gateway downloads it and checks it before it is installed. \(bot) can use it in new chats.",
                                action: "Install", from: presenter) { [weak self] in
            self?.runInstall(OfficialSkill(name: entry.name, description: entry.description, identifier: entry.installIdentifier,
                                           category: nil, installed: false)) { [weak self] in
                self?.hubInstalled.insert(entry.installIdentifier)
                done?()
            }
        }
    }
}

// MARK: - Pieces

/// The bot an install goes to, as Hermes Desktop's "Install to".
struct MarketplaceInstallTo: View {
    @Bindable var model: CapabilitiesModel
    /// [market-slim] "Install to Hermes ⌃" as one line of small words (the iPhone's Marketplace).
    var compact = false

    var body: some View {
        Menu {
            Picker("Install To", selection: Binding(get: { model.profile }, set: { bot in
                guard bot != model.profile else { return }
                model.profile = bot
                // The page's own tab reloads with the bot; the Marketplace shows both kinds' Installed marks.
                Task { if model.tab != .skills { await model.reloadSkills() }; if model.tab != .plugins { await model.reloadPlugins() } }
            })) {
                ForEach(model.bots) { bot in Text(bot.name).tag(bot.id) }
            }
        } label: {
            if compact {
                HStack(spacing: 4) {
                    Text("\(Text("Install to ").foregroundStyle(Color.hqLabel2))\(Text(model.botName).fontWeight(.semibold).foregroundStyle(Color.hqLabel))")
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small).foregroundStyle(Color.hqLabel2)
                }
                .font(Font.hq(.footnote))
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            } else {
                SettingsMenuRowFace(label: Text("Install To").foregroundStyle(Color.hqLabel), value: model.botName)
            }
        }
        .accessibilityIdentifier("marketplace.install-to")
    }
}

struct MarketplaceChip: View {
    var title: String
    var count: Int?
    var on: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.play(.selection)   // a filter chip, as Sessions' bot chips
            action()
        } label: { MarketplaceChipFace(title: title, count: count, on: on) }
            .buttonStyle(.plain)
            .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

struct MarketplaceChipFace: View {
    var title: String
    var count: Int?
    var on: Bool
    var menu = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(Font.hq(.subheadline).weight(on ? .semibold : .regular))
            if let count { Text(count.formatted()).font(Font.hq(.footnote)).foregroundStyle(on ? Color.hqTint : Color.hqLabel2) }
            if menu { Image(systemName: "chevron.down").font(Font.hq(.caption2).weight(.semibold)) }
        }
        .foregroundStyle(on ? Color.hqTint : Color.hqLabel)
        // [ui-sizing 2026-11-09] 12 / 8 as the Kanban and Sessions chips (11 / 6, about 30 pt), with a 44 pt touch.
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(on ? Color.hqTint.opacity(0.14) : Color.hqFill3, in: Capsule())
        .fixedSize()
        .contentShape(Capsule().inset(by: -5))
    }
}

struct SkillCatalogRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let entry: MarketSkill
    var installed: Bool
    /// [mac-tools] No chevron on a card of the Mac's Marketplace grid.
    var chevron = true
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                ConnectorSymbolTile(name: entry.name, symbol: SkillCatalogRow.symbol(entry), size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.name).font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel).lineLimit(1)
                        PluginTierBadge(words: entry.badge)
                    }
                    if !entry.description.isEmpty {
                        Text(entry.description).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : Density.compact ? 1 : 2)   // [ui-sizing] Compact: one line
                    }
                    if installed {
                        Label("Installed", systemImage: "checkmark.circle.fill").font(Font.hq(.caption)).foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Text([entry.author, entry.categoryLabel].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                            .font(Font.hq(.caption)).foregroundStyle(Color.hqLabel3).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if chevron { SettingsChevron() }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("skill-catalog-row-\(entry.name)")
    }

    static func symbol(_ entry: MarketSkill) -> String { symbol(category: entry.category) }

    static func symbol(category: String) -> String {
        let key = category.lowercased()
        let table: [(String, String)] = [
            ("security", "lock.shield"), ("apple", "apple.logo"), ("finance", "chart.line.uptrend.xyaxis"), ("research", "magnifyingglass"),
            ("creative", "paintpalette"), ("media", "film"), ("productivity", "checklist"), ("software", "chevron.left.forwardslash.chevron.right"),
            ("devops", "server.rack"), ("data", "tablecells"), ("mlops", "cpu"), ("training", "cpu"), ("inference", "cpu"), ("gpu", "cpu"),
            ("vision", "eye"), ("robot", "gearshape.2"), ("physical", "gearshape.2"), ("network", "network"), ("agent", "person.2.wave.2"),
            ("blockchain", "bitcoinsign.circle"), ("health", "heart"), ("gaming", "gamecontroller"), ("communication", "bubble.left"),
            ("social", "person.3"), ("home", "house"), ("web", "globe"), ("mcp", "point.3.connected.trianglepath.dotted"),
        ]
        return table.first { key.contains($0.0) }?.1 ?? "sparkles"
    }
}

/// [mac-tools] A listing's tile on the Mac's store front: its kind's symbol in white on the kind's colour.
struct MarketplaceTile: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 46

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .medium))   // a11y-font-ok: a glyph sized to its tile
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [color.opacity(0.92), color.opacity(0.68)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }

    private static let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .green, .indigo, .cyan, .red, .brown]

    /// One colour per word (a skill's category, a card's name), the same every launch.
    static func color(for word: String) -> Color {
        palette[word.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 } % palette.count]
    }
}

extension PluginCatalogCategory {
    var storeColor: Color {
        switch self {
        case .memory: .purple
        case .tools: .orange
        case .models: .blue
        case .web: .teal
        case .voice: .pink
        case .platform: .green
        case .automation: .indigo
        case .general: .gray
        case .desktop: .cyan
        }
    }
}

/// [mac-tools] The Mac store front's lead card: the week's pick with its words at the left and its picture whole at the
/// right, over a soft blurred copy of the picture.
struct MarketplaceHero: View {
    let entry: PluginCatalogEntry
    var installed: Bool
    let open: (_ install: Bool) -> Void
    @State private var image: UIImage?

    /// A card's outline where the card is the page's colour (the Desktop Look, the light iOS look).
    static let edge = UIColor { traits in
        Theme.isDesktop || traits.userInterfaceStyle != .dark ? HQPalette.separator.resolvedColor(with: traits) : .clear
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("FEATURED THIS WEEK").font(Font.hq(.caption).weight(.bold)).foregroundStyle(Color.hqTint)
                Text(entry.title).font(Font.hq(.largeTitle).weight(.bold)).foregroundStyle(Color.hqLabel)
                    .lineLimit(2).minimumScaleFactor(0.7)
                HStack(spacing: 6) {
                    if let tier = entry.tierWord { PluginTierBadge(words: tier) }
                    Text("by \(entry.maintainer)").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                }
                Text(PluginCatalogEntry.styled(entry.summary)).font(Font.hq(.body)).foregroundStyle(Color.hqLabel2)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if installed {
                        Label("Installed", systemImage: "checkmark.circle.fill").font(Font.hq(.subheadline).weight(.semibold))
                            .foregroundStyle(.green)
                    } else {
                        Button { open(true) } label: {
                            Text("Install").font(Font.hq(.subheadline).weight(.semibold)).frame(minWidth: 84, minHeight: 30)
                        }
                        .hqGlassProminentButtonStyle()
                        .accessibilityIdentifier("marketplace.featured.install-\(entry.name)")
                    }
                    Button { open(false) } label: {
                        Text("Details").font(Font.hq(.subheadline).weight(.semibold)).frame(minWidth: 84, minHeight: 30)
                    }
                    .hqBorderedButtonStyle()
                    .accessibilityIdentifier("marketplace.featured.details-\(entry.name)")
                }
            }
            .padding(26)
            .frame(width: 400, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                        .transition(.opacity)
                } else {
                    MarketplaceTile(symbol: entry.category.symbol, color: entry.category.storeColor, size: 120)
                }
            }
            .padding(.vertical, 26).padding(.trailing, 26)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            ZStack {
                Color(uiColor: HQPalette.card)
                if let image { Image(uiImage: image).resizable().scaledToFill().blur(radius: 40).opacity(0.38) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(uiColor: Self.edge)) }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { open(false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Featured: \(entry.title), by \(entry.maintainer)")
        .task(id: entry.image) {
            guard let url = entry.image else { return }
            if let kept = MarketplaceImages.kept(url) { image = kept; return }
            if let loaded = await MarketplaceImages.load(url) { HQMotion.withAnimation(.easeOut(duration: 0.2)) { image = loaded } }
        }
    }
}

/// The hero: one card per pick, swiped sideways, with its picture, who made it, and Install / Details.
struct MarketplaceCarousel: View {
    let entries: [PluginCatalogEntry]
    let installed: (PluginCatalogEntry) -> Bool
    let open: (PluginCatalogEntry, Bool) -> Void
    /// [mac-tools] The Mac's grid: the picks side by side in a row that scrolls, not one card a page.
    var row = false
    @State private var page = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if row {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(entries) { entry in card(entry).frame(width: 340, height: 318) }
                }
            }
            .scrollClipDisabled()
            .accessibilityIdentifier("marketplace.featured")
        } else {
            pages
        }
    }

    private var pages: some View {
        VStack(spacing: 8) {
            TabView(selection: $page) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    card(entry).tag(index).padding(.horizontal, 2)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: typeSize.isAccessibilitySize ? 470 : slim ? 136 : 330)
            if entries.count > 1 {
                HStack(spacing: 6) {
                    ForEach(entries.indices, id: \.self) { index in
                        Capsule().fill(index == page ? Color.hqTint : Color.hqLabel3.opacity(0.5))
                            .frame(width: index == page ? 16 : 6, height: 6)
                    }
                }
                .animation(HQMotion.swiftUI(.snappy), value: page)
                .accessibilityElement()
                .accessibilityLabel("Featured plugin \(page + 1) of \(entries.count)")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: page = min(page + 1, entries.count - 1)
                    case .decrement: page = max(page - 1, 0)
                    @unknown default: break
                    }
                }
            }
        }
        .padding(.bottom, 4)
        .accessibilityIdentifier("marketplace.featured")
    }

    /// [market-slim] Owner 2026-11-10 (design pick 17): on the iPhone and iPad the featured plugin is a slim card, its
    /// picture a square on the left, so the list under the filters starts on the first screen (the banner card and
    /// its buttons took half of it). The Mac's row of cards and the accessibility text sizes keep the banner card.
    private var slim: Bool { !row && !DeviceWord.isMac && !typeSize.isAccessibilitySize }

    @ViewBuilder private func card(_ entry: PluginCatalogEntry) -> some View {
        if slim { slimCard(entry) } else { bannerCard(entry) }
    }

    private func slimCard(_ entry: PluginCatalogEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            MarketplaceBanner(url: entry.image, name: entry.title, symbol: entry.category.symbol)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: HQShape.radius(12, .card), style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let tier = entry.tierWord { PluginTierBadge(words: tier) }
                    Text(entry.maintainer).font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                }
                Text(entry.title).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel).lineLimit(1)
                Text(PluginCatalogEntry.styled(entry.summary)).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                HStack(spacing: 8) {
                    if installed(entry) {
                        Label("Installed", systemImage: "checkmark.circle.fill").font(Font.hq(.footnote).weight(.semibold))
                            .foregroundStyle(.green)
                    } else {
                        Button { open(entry, true) } label: {
                            Text("Install").font(Font.hq(.footnote).weight(.semibold)).frame(minWidth: 56, minHeight: 22)
                        }
                        .hqGlassProminentButtonStyle()
                        .accessibilityIdentifier("marketplace.featured.install-\(entry.name)")
                    }
                    Button { open(entry, false) } label: {
                        Text("Details").font(Font.hq(.footnote).weight(.semibold)).frame(minWidth: 56, minHeight: 22)
                    }
                    .hqBorderedButtonStyle()
                    .accessibilityIdentifier("marketplace.featured.details-\(entry.name)")
                }
                .padding(.top, 3)
            }
        }
        .padding(10)
        .background(Color(uiColor: HQPalette.card), in: RoundedRectangle(cornerRadius: HQShape.radius(14, .card), style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: HQShape.radius(14, .card), style: .continuous))
        .onTapGesture { open(entry, false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.title), \(entry.tierWord ?? "Community") plugin by \(entry.maintainer)")
    }

    private func bannerCard(_ entry: PluginCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MarketplaceBanner(url: entry.image, name: entry.title, symbol: entry.category.symbol, wholeUpTo: DeviceWord.isMac ? 150 : nil)
                .frame(height: DeviceWord.isMac ? nil : 150)
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let tier = entry.tierWord { PluginTierBadge(words: tier) }
                    Text("by \(entry.maintainer)").font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                }
                Text(entry.title).font(Font.hq(.title3).weight(.bold)).foregroundStyle(Color.hqLabel).lineLimit(1)
                Text(PluginCatalogEntry.styled(entry.summary)).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    if installed(entry) {
                        Label("Installed", systemImage: "checkmark.circle.fill").font(Font.hq(.subheadline).weight(.semibold))
                            .foregroundStyle(.green)
                    } else {
                        Button { open(entry, true) } label: {
                            Text("Install").font(Font.hq(.subheadline).weight(.semibold)).frame(minWidth: 70, minHeight: 28)
                        }
                        .hqGlassProminentButtonStyle()
                        .accessibilityIdentifier("marketplace.featured.install-\(entry.name)")
                    }
                    Button { open(entry, false) } label: {
                        Text("Details").font(Font.hq(.subheadline).weight(.semibold)).frame(minWidth: 70, minHeight: 28)
                    }
                    .hqBorderedButtonStyle()
                    .accessibilityIdentifier("marketplace.featured.details-\(entry.name)")
                }
            }
            .padding(14)
        }
        .background(Color(uiColor: HQPalette.card), in: RoundedRectangle(cornerRadius: HQShape.radius(14, .card), style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: HQShape.radius(14, .card), style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: HQShape.radius(14, .card), style: .continuous))
        .onTapGesture { open(entry, false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.title), \(entry.tierWord ?? "Community") plugin by \(entry.maintainer)")
    }
}

/// A listing's picture (GitHub-hosted), drawn to fill; the kind's symbol on a tint until it arrives, or when it has none.
struct MarketplaceBanner: View {
    let url: URL?
    let name: String
    let symbol: String
    /// [mac] Owner 2026-11-07 (yes to the polish pass's call): a featured card's picture shows whole instead of losing
    /// its lettering to the crop ("MEMORY WIKI" cut at the bottom in the sidebar's column). A wide picture takes its own
    /// height, up to this many points; a taller one fits inside them over a soft blurred copy of itself, so the cards
    /// keep one height. nil: the caller's frame crops it (the iPhone, the lists).
    var wholeUpTo: CGFloat? = nil
    @State private var image: UIImage?
    @State private var width: CGFloat = 0

    /// The picture's own height at the banner's width, up to `wholeUpTo`.
    private var height: CGFloat? {
        guard let cap = wholeUpTo else { return nil }
        guard let image, width > 0, image.size.width > 0 else { return cap }
        return min(cap, (width * image.size.height / image.size.width).rounded())
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.hqTint.opacity(0.85), Color.hqTint.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: symbol).font(.system(size: 44, weight: .light)).foregroundStyle(.white.opacity(0.85))   // a11y-font-ok: a placeholder glyph sized to its picture tile
            if let image, wholeUpTo != nil {
                ZStack {
                    Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill().blur(radius: 20).opacity(0.55) }.clipped()
                    Image(uiImage: image).resizable().scaledToFit()
                }
                .transition(.opacity)
            } else if let image {
                Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }.clipped().transition(.opacity)
            }
        }
        .frame(height: height)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { return }
            if let kept = MarketplaceImages.kept(url) { image = kept; return }
            if let loaded = await MarketplaceImages.load(url) { HQMotion.withAnimation(.easeOut(duration: 0.2)) { image = loaded } }
        }
    }
}

@MainActor enum MarketplaceImages {
    private static let cache = NSCache<NSURL, UIImage>()

    static func kept(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    static func load(_ url: URL) async -> UIImage? {
        if let kept = kept(url) { return kept }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 8 * 1024 * 1024 else { return nil }
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let full = UIImage(data: data) else { return nil }
            let width: CGFloat = 900
            guard full.size.width > width else { return full.preparingForDisplay() }
            let size = CGSize(width: width, height: full.size.height * width / full.size.width)
            return full.preparingThumbnail(of: size)
        }.value
        if let image, image.size.width >= 64 { cache.setObject(image, forKey: url as NSURL); return image }
        return nil
    }
}

/// "Talk to Hermes Anywhere": the chat apps a bot can answer in, each opening Messaging.
struct MarketplaceAnywhere: View {
    let model: CapabilitiesModel
    let router: SettingsRouter

    static let platforms: [(name: String, blurb: String, symbol: String)] = [
        ("Telegram", "Chat with Hermes through a Telegram bot.", "paperplane.fill"),
        ("Discord", "Bring Hermes into servers and direct messages.", "gamecontroller.fill"),
        ("Slack", "Connect Hermes to your Slack workspace.", "number"),
        ("WhatsApp", "Message your bot through WhatsApp.", "phone.bubble.fill"),
        ("Signal", "Reach Hermes through private Signal chats.", "lock.circle.fill"),
        ("Matrix", "Connect rooms and direct messages to Hermes.", "square.grid.3x3.fill"),
    ]

    var body: some View {
        if let context = Self.context(model.services), MorePages.factories["messaging"] != nil {
            Section {
                ForEach(Self.platforms, id: \.name) { platform in
                    Button { open(context) } label: {
                        HStack(spacing: 12) {
                            ConnectorSymbolTile(name: platform.name, symbol: platform.symbol, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(platform.name).font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel)
                                Text(platform.blurb).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            SettingsChevron()
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("marketplace.anywhere.\(platform.name.lowercased())")
                }
                // [marketplace] The site's See All here: the Marketplace's messaging plugins (more chat apps).
                let more = (PluginCatalogStore.shared.entries ?? []).filter { $0.category == .platform }.count
                if more > 0 {
                    Button {
                        router.push(MarketplaceController(model: model, router: router, kind: .plugins, category: PluginCatalogCategory.platform.rawValue))
                    } label: {
                        BrowseRowLabel(title: "Messaging Plugins", count: more)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("marketplace.shelf.anywhere.all")
                }
            } header: { HQSectionLabel { Text("Talk to Hermes Anywhere") } } footer: { HQSectionFooter {
                Text("Chat where you already are. Set each one up in Messaging, or add more chat apps with a plugin.")
            } }
        }
    }

    private func open(_ context: MorePages.Context) {
        guard let page = MorePages.factories["messaging"]?(context) else { return }
        router.push(page)
    }

    static func context(_ services: any AppServices) -> MorePages.Context? {
        guard let pages = services as? PagesServices, let account = pages.account, let client = pages.gateway else { return nil }
        let makeChat: (any ChatSessionModel) -> UIViewController = (services as? AppModel)?.makeChatScreen ?? { ChatViewController(session: $0) }
        return MorePages.Context(services: services, pages: pages, client: client, account: account, makeChat: makeChat)
    }
}

/// The developer's way in, under the shelves.
struct MarketplaceMore: View {
    let model: CapabilitiesModel
    let router: SettingsRouter

    static let developerURL = URL(string: "https://hermes-agent.nousresearch.com/docs/developer-guide/plugins")!
    static let websiteURL = URL(string: "https://hermes-agent.nousresearch.com/marketplace")!

    var body: some View {
        // [connect-find] Connectors is one of the page's kinds now (All · Plugins · Skills · Connectors): its row under
        // the last shelf here was a second way in on the same page, and the one nobody reached.
        Section {
            link("Make a Hermes Plugin", Self.developerURL, id: "marketplace.developer")
            link("Open the Marketplace Website", Self.websiteURL, id: "marketplace.website")
        } header: { HQSectionLabel { Text("Developer?") } } footer: { HQSectionFooter {
            Text("Build a plugin or a skill for Hermes and send it to Nous to be listed.")
        } }
    }

    private func link(_ title: String, _ url: URL, id: String) -> some View {
        Button {
            if let host = router.presenter { LinkOpener.open(url, from: host) }
        } label: {
            HStack {
                Text(title).foregroundStyle(Color.hqTint)
                Spacer()
                Image(systemName: "arrow.up.right").font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqLabel3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

// MARK: - Connectors

/// [connect-find] Marketplace › Connectors: every app in Hermes' own catalog the bot
/// in Install To doesn't have yet, each opening the page that installs it, and a way to what the bot has connected.
/// The page's search narrows the apps.
struct MarketplaceConnectors: View {
    @Bindable var model: CapabilitiesModel
    let router: SettingsRouter
    var query: String

    static func appsHeader(_ count: Int) -> String { count == 1 ? "1 App from Hermes" : "\(count) Apps from Hermes" }
    static let mineTitle = "Your Connectors"

    var body: some View {
        let all = model.catalogAvailable
        let shown = query.isEmpty ? all : all.filter { $0.matches(query) }
        Group {
            if model.catalog == nil, model.isConnected {
                Section { ForEach(0..<4, id: \.self) { _ in SkeletonLine() } }
            } else if !all.isEmpty {
                Section {
                    if shown.isEmpty {
                        Text("No app matches “\(query)”.").foregroundStyle(Color.hqLabel2).padding(.vertical, 4)
                    }
                    ForEach(shown) { entry in
                        CatalogRow(entry: entry) { router.push(CatalogAppController(model: model, entry: entry, router: router)) }
                    }
                } header: { HQSectionLabel { Text(Self.appsHeader(shown.count)) } }
            }
            // [composio-row] Only under a search no Hermes app answers (Composio's place is its row in More).
            if ComposioSection.cameUpShort(query: query, loaded: model.catalog != nil, matches: shown.count) {
                ComposioSection(model: model, router: router)
            }
            Section {
                NavRow(title: Self.mineTitle, systemImage: CapabilitiesTab.connectors.symbol) {
                    router.push(CapabilitiesViewController(services: model.services, profile: model.profile, tab: .connectors))
                }
                .accessibilityIdentifier("marketplace.connectors")
                // The bot in Install To decides which apps are left to add: read for it, and again when it changes.
                // (On this one row: a task on the group would run once for each section.)
                .task(id: model.profile) {
                    if !model.fresh("servers") { Task { await model.reloadServers() } }
                    if !model.fresh("catalog") { await model.reloadCatalog() }
                }
            } footer: { HQSectionFooter {
                Text("What \(model.botName) has connected, apps through a Nous account, and adding a connector by web address or command.")
            } }
        }
    }
}
