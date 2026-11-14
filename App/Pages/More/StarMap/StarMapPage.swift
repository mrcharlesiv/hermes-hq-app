// More › Insights › Star Map (docs/spec/3x-morepages.md §17, D-M14): what a bot has learned, as a map of stars and as
// a list. Read-only: no map codes, no timeline, no editing or deleting from the phone.
// Wording: `V/i18n/en.ts` starmap (subtitle, filters, "Memory", "Refresh", the empty lines).

import SwiftUI
import UIKit

extension MorePages {
    static func installStarMap() {
        factories["star-map"] = { context in
            let model = StarMapModel(context: context)
            let stage = StarMapStage()
            let page = MorePageController(title: "Star Map", identifier: "starmap.page", StarMapPage(model: model, stage: stage))
            page.retained = [model, stage]
            page.keyRefresh = { [weak model] in Task { await model?.refresh() } }   // [Mac UI check 2026-11-13] ⌘R, as a pull (the Mac has no pull)
            page.onAppear = { model.start() }
            #if DEBUG
            stage.onFramed = { [weak stage] in if let stage { StarMapProbe.startIfWanted(stage) } }
            #endif
            return page
        }
    }
}

struct StarMapPage: View {
    @Bindable var model: StarMapModel
    let stage: StarMapStage

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color.hqGroupedPage)
        .toolbar {
            // [mac] Stress test 2026-10-28 #9 (Star Map): with no graph to filter the glyph was drawn disabled, at
            // 2.7:1 against the other bar glyphs' 8.8:1, so it read as broken. On the Mac it shows only with a graph.
            if hasGraph || !DeviceWord.isMac {
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
                    // [mac] Stress test 2026-10-28 #56: in the Desktop Look the bar's items are plain glyphs; this one was
                    // the only one drawn on a filled grey circle (the bar's shared glass behind a SwiftUI item).
                    // [mac-ten] Owner 2026-11-11 ("weird UI issues"): in the iOS look too. Every other page's bar
                    // buttons are bare glyphs on the Mac (Tasks' Filter, Jobs' +, the chat's ⋯); this one alone sat on
                    // a glass circle.
                    .sharedBackgroundVisibility(DeviceWord.isMac ? .hidden : .automatic)
            }
        }
        .sheet(item: $model.selected) { node in
            StarMapNodeSheet(node: node, client: model.context.client, profile: model.profile)
        }
    }

    private var hasGraph: Bool { model.phase == .loaded && !model.isEmpty }
    /// [mac-audit] Owner 2026-11-02 (#21): no Bot picker over "Not Available on This Hermes" on the Mac.
    private var showsPicker: Bool { model.showsBotPicker && !(DeviceWord.isMac && model.isUnavailable) }

    // MARK: Header

    @ViewBuilder private var header: some View {
        if hasGraph || showsPicker {
            VStack(spacing: 8) {
                // The bot in its own grouped row at the top, as on the other per-bot More pages (UX study #49).
                if showsPicker {
                    MoreBotPicker(bots: model.bots, selection: $model.profile, card: true)
                        .padding(.bottom, 4)
                }
                if hasGraph {
                    HQSegmentedPicker("View", options: StarMapModel.Mode.allCases.map { ($0.title, $0) }, selection: $model.mode)   // [desktoplook3]
                    .accessibilityIdentifier("starmap.mode")
                    Text(model.shown.subtitle)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("starmap.subtitle")
                    if model.refreshFailed {
                        // Audit 863 (08d-6): as Usage and Recent Logs say it.
                        HStack(spacing: 12) {
                            Text("Couldn’t refresh. Showing the last map.").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Try Again") { model.retry() }.hqBorderedButtonStyle()
                        }
                        .accessibilityIdentifier("starmap.refresh-failed")
                    }
                }
            }
            // [mac] Stress test 2026-10-28 round 6: the Bot card, the View segments and the subtitle at the readable
            // width, centred, as the other per-bot pages (they ran the whole pane, about 21 to 975 pt).
            .frame(maxWidth: DeviceWord.isMac ? MacForm.readableWidth : .infinity)
            .frame(maxWidth: .infinity)
            // [mac] Stress test 2026-10-28 #53, #55: the page inset, sides and under the bar, as the other per-bot pages.
            .padding(.horizontal, DeviceWord.isMac ? MacInset.side : 16)
            .padding(.top, MacInset.top(otherwise: 8))
            .padding(.bottom, 8)
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $model.filter) {
                ForEach(StarMapFilter.allCases) { filter in Text(filter.title).tag(filter) }
            }
            Section {
                Button("Refresh", systemImage: "arrow.clockwise") { model.retry() }
            }
        } label: {
            // Plain `Image` in a SwiftUI toolbar `Menu` doesn't pick up DesktopBars' automatic bar-item retinting
            // (that hook only fires for `UIBarButtonItem.image`), so the glyph needs its own color here, matching
            // what every other page's Filter draws for its "off" state: `.label` in the iOS look, `label2` in the
            // Desktop Look (both pages #1).
            Image(systemName: model.filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(Theme.isDesktop ? Color.hqLabel2 : Color.hqLabel)
        }
        .accessibilityLabel("Filter")
        .accessibilityValue(model.filter.title)
        .accessibilityIdentifier("starmap.filter")
        .disabled(!hasGraph)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            MoreSkeleton(retry: { model.retry() })
        case .failed(let reason):
            MoreErrorState(title: "Couldn’t Load Star Map", reason: reason) { model.retry() }
        case .loaded:
            if model.isEmpty {
                MoreEmptyState(symbol: "sparkles", title: "Nothing learned yet",
                               text: "As Hermes builds skills and memories for your work, they appear here.")
            } else if model.filterMiss {
                MoreEmptyState(symbol: "line.3.horizontal.decrease", title: "No \(model.filter.title) Skills",
                               text: "Nothing here matches this filter yet.") {
                    Button("Show All") { model.filter = .all }
                        .hqEmptyActionButtonStyle()   // [mac] Stress test 2026-10-28 #55 (round 6)
                        .buttonBorderShape(.capsule)
                }
            } else if model.mode == .map {
                StarMapCanvas(stage: stage, layout: model.shown.layout, generation: model.shown.generation) { model.open(star: $0) }
            } else {
                StarMapList(model: model)
            }
        }
    }
}

// MARK: - List

struct StarMapList: View {
    let model: StarMapModel

    var body: some View {
        List { Group {
            ForEach(model.shown.sections) { section in
                Section {
                    ForEach(section.nodes) { node in
                        Button { model.open(star: node.id) } label: { StarMapRow(node: node) }
                            .accessibilityIdentifier("starmap.row.\(node.id)")
                    }
                } header: { HQSectionLabel {
                    Text(section.header).accessibilityIdentifier("starmap.section.\(section.category)")
                } }
            }
            if !model.shown.memory.isEmpty {
                Section {
                    ForEach(model.shown.memory) { card in StarMapMemoryRow(card: card) }
                } header: { HQSectionLabel {
                    Text("Memory").accessibilityIdentifier("starmap.section.memory-cards")
                } }
            }
        }.hqMacSettingsRowInsets() }
        .listStyle(.insetGrouped)
        .hqMacForm()   // [mac] Stress test 2026-10-28 #8, #53: the readable width, one inset, small switches
        .hqGroupedPage()
        .refreshable { await model.refresh() }
        .accessibilityIdentifier("starmap.list")
    }
}

private struct StarMapRow: View {
    var node: StarMapNode

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(node.label).font(Font.hq(.body)).foregroundStyle(Color.hqLabel)
                Text(StarMapRules.usedLine(node.useCount)).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if node.pinned {
                Image(systemName: "pin.fill").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).accessibilityLabel("Pinned")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A memory card: its title and its text, folded at 4 lines until Show More.
private struct StarMapMemoryRow: View {
    var card: StarMapMemoryCard
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !card.title.isEmpty {
                Text(card.title).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel).lineLimit(open ? nil : 2)
            }
            if !card.body.isEmpty, card.body != card.title {
                Text(card.body).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(open ? nil : 4)
            }
            if StarMapRules.folds(card.body) {
                Button(open ? "Show Less" : "Show More") { Haptics.play(.selection); open.toggle() }
                    .font(Font.hq(.subheadline))
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("starmap.memory.more.\(card.id)")
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Node sheet

/// What a star says: its facts from the graph, and its text from `/api/learning/node`. Read-only.
struct StarMapNodeSheet: View {
    enum Words: Equatable {
        case loading
        case text(String)
        case failed
        case missing
    }

    var node: StarMapNode
    let client: any GatewayClient
    var profile: String
    @State private var text: Words = .loading
    @State private var attempt = 0

    @Environment(\.hqGlassSheet) private var glass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(node.label)
                    .font(Font.hq(.title3).weight(.semibold))
                    .foregroundStyle(Color.hqLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("starmap.node.title")
                // [starmap-tags] Owner 2026-11-10 (design pick 21): the kind, category, state and pin are small tags
                // under the title and the use and maker one quiet line, so what the skill or memory says leads the
                // sheet (they were six rows in a box above it). At the accessibility text sizes the rows stay.
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 0) {
                        fact("Kind", StarMapRules.kindWord(node))
                        fact("Category", StarMapRules.categoryTitle(node.category))
                        if node.kind == .skill { fact("Use", StarMapRules.usedLine(node.useCount)) }
                        fact("State", StarMapRules.stateWord(node.state))
                        if let by = StarMapRules.createdByWord(node.createdBy) { fact("Created By", by) }
                        if node.pinned { fact("Pinned", "Yes") }
                    }
                    .hqGlassCard()   // [glass-audit] the facts on a solid card while the sheet sits on glass
                    if !(glass && GlassSheetKit.designed) { Divider() }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        PagesFlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                Text(tag)
                                    .font(Font.hq(.footnote).weight(.medium))
                                    .foregroundStyle(Color.hqLabel)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Capsule().fill(glass ? Color(uiColor: HQPalette.sheetCard) : Color.hqFill3))
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(tags.joined(separator: ", "))
                        .accessibilityIdentifier("starmap.node.tags")
                        if !quietLine.isEmpty {
                            Text(quietLine).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                                .accessibilityIdentifier("starmap.node.line")
                        }
                    }
                    .padding(.top, -6)
                }
                words.hqGlassCard()
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .hqGlassSheetPage()   // [glass-audit] the system's glass, designed for: cards, and opaque in the Desktop Look
        .accessibilityIdentifier("starmap.node")
        .task(id: attempt) { await read() }
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    private var tags: [String] {
        [StarMapRules.kindWord(node), StarMapRules.categoryTitle(node.category), StarMapRules.stateWord(node.state), node.pinned ? "Pinned" : ""]
            .filter { !$0.isEmpty }
    }

    /// "Used 14 times · Created by Hermes"
    private var quietLine: String {
        [node.kind == .skill ? StarMapRules.usedLine(node.useCount) : nil,
         StarMapRules.createdByWord(node.createdBy).map { "Created by \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
            Spacer(minLength: 8)
            Text(value).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel).multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var words: some View {
        switch text {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading…").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("starmap.node.loading")
        case .text(let content):
            Text(content)
                .font(Font.hq(.callout))
                .foregroundStyle(Color.hqLabel)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("starmap.node.text")
        case .failed:
            VStack(alignment: .leading, spacing: 10) {
                Text("Couldn’t load this.").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                    .accessibilityIdentifier("starmap.node.failed")
                Button("Try Again") { text = .loading; attempt += 1 }
                    .hqGlassButtonStyle()
                    .accessibilityIdentifier("starmap.node.retry")
            }
        case .missing:
            Text("This is no longer in the map.").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                .accessibilityIdentifier("starmap.node.missing")
        }
    }

    private func read() async {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "HQDebugTour") == "starnode" {
            text = .text("Builds the site with `npm run build`, checks the output folder, then uploads it with the deploy key from the vault. Learned on Oct 12 after two failed deploys: always clear the cache first, and wait for the health check to pass before telling the owner it is live.")
            return
        }
        #endif
        do {
            let detail = try await StarMapAPI.node(client, id: node.id, profile: profile)
            guard !Task.isCancelled else { return }
            text = .text(detail.content)
        } catch {
            guard !Task.isCancelled else { return }
            text = StarMapAPI.isMissing(error) ? .missing : .failed
        }
    }
}
