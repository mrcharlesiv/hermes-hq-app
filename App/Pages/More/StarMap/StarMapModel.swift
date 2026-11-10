// More › Star Map (docs/spec/3x-morepages.md §17): what the page holds. The graph is read and decoded off the main
// thread; the filtered sections and the Map's layout are computed off it too, once per graph and filter.

import SwiftUI
import UIKit

@MainActor @Observable
final class StarMapModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    enum Mode: String, CaseIterable, Identifiable {
        case map, list
        var id: String { rawValue }
        var title: String { self == .map ? "Map" : "List" }
    }

    /// What is on show: the filter's sections, the Map's layout and the subtitle, made together off the main thread.
    nonisolated struct Shown: Sendable, Equatable {
        var sections: [StarMapSection] = []
        var memory: [StarMapMemoryCard] = []
        var layout = StarMapLayout()
        var subtitle = ""
        var skills = 0
        /// Bumped for every new graph or filter: the Map frames the new layout once.
        var generation = 0

        @concurrent
        static func make(_ graph: StarMapGraph, filter: StarMapFilter, generation: Int) async -> Shown {
            let sections = StarMapRules.sections(graph.nodes, filter: filter)
            let stars = StarMapRules.stars(graph.nodes, filter: filter)
            let kept = Set(stars.map(\.id))
            let layout = StarMapLayout(nodes: stars, edges: graph.edges.filter { kept.contains($0.source) && kept.contains($0.target) },
                                       colors: StarMapLayout.colors(for: graph.nodes.map(\.category)))
            return Shown(sections: sections, memory: filter == .all ? graph.memory : [], layout: layout,
                         subtitle: StarMapRules.subtitle(sections), skills: sections.reduce(0) { $0 + $1.nodes.count },
                         generation: generation)
        }
    }

    static let modeKey = "pages.more.starmap.view"

    let context: MorePages.Context
    private(set) var phase: Phase = .loading
    private(set) var graph: StarMapGraph?
    private(set) var shown = Shown()
    private(set) var nodes: [String: StarMapNode] = [:]
    var selected: StarMapNode?
    var profile: String { didSet { if profile != oldValue { profileChanged() } } }
    var filter: StarMapFilter = .all { didSet { if filter != oldValue { PagesHaptics.selection(); refilter() } } }   // a pick
    /// Audit 863 (08d-6): a Refresh (or pull) failed with a map on show: said over it, as Usage and Logs do.
    private(set) var refreshFailed = false
    var mode: Mode { didSet { if mode != oldValue { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) } } }

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var shownTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var firstRead = true

    init(context: MorePages.Context) {
        self.context = context
        profile = MoreBotChoice.read("star-map", context: context)
        // The List is the VoiceOver path (§17): with VoiceOver on the page opens there, without forgetting the choice.
        let saved = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:)) ?? .map
        mode = HQAccessibility.voiceOver ? .list : saved
    }

    var bots: [Bot] { context.botChoices }
    var showsBotPicker: Bool { context.bots.count > 1 }
    /// [mac-audit] Owner 2026-11-02 (#21): this Hermes has no Star Map. On the Mac the page then shows the state alone,
    /// without the Bot picker over it.
    var isUnavailable: Bool { if case .failed(let reason) = phase { return reason == MoreWire.olderHermes } else { return false } }
    var isEmpty: Bool { graph?.isEmpty ?? false }
    /// The graph has stars, but none passes the filter.
    var filterMiss: Bool { filter != .all && graph?.isEmpty == false && shown.layout.stars.isEmpty }

    func start() {
        if graph == nil, loadTask == nil { load() }
    }

    func retry() {
        phase = graph == nil ? .loading : phase
        load()
    }

    /// Reads the graph again. With a graph on show a failure keeps it (offline: the page keeps its data).
    func load() {
        loadTask?.cancel()
        let client = context.client, profile = profile
        let first = firstRead
        firstRead = false
        if graph == nil { phase = .loading }
        loadTask = Task { [weak self] in
            let started = CACurrentMediaTime()
            do {
                let graph = try await StarMapAPI.graph(client, profile: profile)
                guard let self, !Task.isCancelled, self.profile == profile else { return }
                if first { MorePages.noteRead("star-map", error: nil) }
                AppLog.note("starmap", "graph: \(graph.nodes.count) nodes, \(graph.edges.count) edges, \(graph.memory.count) cards in \(Int((CACurrentMediaTime() - started) * 1000)) ms")
                self.take(graph)
            } catch {
                guard let self, !Task.isCancelled, self.profile == profile else { return }
                // A 404 for a named bot is that bot's scope, not a gateway without the route: only the default bot's
                // answer says whether the row belongs in More.
                let named = !MoreWire.profileQuery(profile).isEmpty
                let missing = first && !named ? MorePages.noteRead("star-map", error: error) : false
                AppLog.note("starmap", "graph failed: \(PageStates.scrubbed(PagesREST.reason(error)))")
                self.loadTask = nil
                guard self.graph == nil else { self.refreshFailed = true; return }
                self.phase = .failed(missing ? MoreWire.olderHermes : PagesREST.reason(error))
            }
        }
    }

    /// Pull to refresh on the List: returns when the read has ended.
    func refresh() async {
        load()
        await loadTask?.value
    }

    private func take(_ graph: StarMapGraph) {
        self.graph = graph
        refreshFailed = false
        nodes = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        loadTask = nil
        refilter(thenLoaded: true)
    }

    private func refilter(thenLoaded: Bool = false) {
        guard let graph else { return }
        shownTask?.cancel()
        generation += 1
        let filter = filter, generation = generation
        shownTask = Task { [weak self] in
            let shown = await Shown.make(graph, filter: filter, generation: generation)
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.shown = shown
            if thenLoaded { self.phase = .loaded }
        }
    }

    private func profileChanged() {
        MoreBotChoice.save(profile, page: "star-map", context: context)
        PagesHaptics.selection()
        selected = nil
        refreshFailed = false
        graph = nil
        nodes = [:]
        shown = Shown()
        phase = .loading
        load()
    }

    func open(star id: String) {
        guard let node = nodes[id] else { return }
        PagesHaptics.selection()
        selected = node
    }
}
