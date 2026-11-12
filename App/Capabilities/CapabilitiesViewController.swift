// Settings › Bots & Tools › Skills / Connectors (spec 1x-settings §9): one page "Capabilities" scoped to a bot, with a
// bot picker, a Skills | Connectors control whose segments size to their labels (`MEM/segmented-labels-whole.md`; a
// pull-down at accessibility sizes), and the lists.
// [cap-pages] Owner 2026-11-03 (one home per page; tabs only to flip between lists of one kind): no tabs. Capabilities
// is a list of four rows (`CapabilitiesHubController`), and Skills, Tools, Connectors and Plugins are each a page of
// their own: this controller, one list, titled with it, with its own search and ⋯.

import SwiftUI
import UIKit

final class CapabilitiesViewController: UIHostingController<HQScaledRoot<CapabilitiesView>>, UISearchResultsUpdating {
    let model: CapabilitiesModel
    private var searchCapsule: PageBarCapsule?

    /// `tab`: the list the page is. `botLocked`: opened from a bot’s own page (Bot Info › Skills), so the Bot row is
    /// that bot, not a picker. `settingsPage`: opened under Settings, so on the Mac its rows are Settings' rows.
    init(services: any AppServices, profile: String?, tab: CapabilitiesTab, focus: String? = nil, botLocked: Bool = false,
         settingsPage: Bool = false) {
        let model = CapabilitiesModel(services: services, profile: profile, tab: tab)
        model.focusServer = focus
        self.model = model
        let router = SettingsRouter(services: services, navigation: nil)
        super.init(rootView: HQScaledRoot(CapabilitiesView(model: model, router: router, botLocked: botLocked, settingsPage: settingsPage)))
        title = tab.title
        navigationItem.largeTitleDisplayMode = .never
        view.accessibilityIdentifier = "capabilities.\(tab.rawValue)"
        // [morepages] 3x-morepages §5: the field folds behind the bar's magnifier, as on every list page.
        let capsule = PageBarCapsule.search(on: self, page: "capabilities", placeholder: tab.prompt, updater: self)
        searchCapsule = capsule
        model.presenter = self
        model.openSearch = { [weak capsule] in capsule?.openSearch() }
        installMenu()
    }

    /// The trailing `ellipsis` menu (3x §3.2): what it holds depends on the list, read when it opens.
    private func installMenu() {
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            MainActor.assumeIsolated { done(self?.menuItems() ?? []) }
        }])
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: menu)
        item.accessibilityLabel = "More"
        item.accessibilityIdentifier = "capabilities.more"
        navigationItem.rightBarButtonItems = [item, searchCapsule?.searchItem].compactMap { $0 }   // [morepages] ⋯ at the edge, Search inside it
    }

    private func menuItems() -> [UIMenuElement] {
        let model = self.model
        var items: [UIMenuElement] = [UIAction(title: "Refresh", image: UIImage(systemName: "arrow.clockwise")) { _ in Task { await model.refresh() } }]
        switch model.tab {
        case .skills:
            items.append(UIAction(title: "Marketplace", image: UIImage(systemName: "bag")) { [weak self] _ in   // [marketplace]
                guard let self else { return }
                self.rootView.router.push(MarketplaceController(model: model, router: self.rootView.router, kind: .skills))
            })
            if model.hasUsage, !model.readOnly {
                let action = UIAction(title: "Disable Unused", image: UIImage(systemName: "moon.zzz")) { _ in model.disableUnused() }
                if model.unusedSkills.isEmpty || model.disabling != nil { action.attributes = .disabled }
                items.append(action)
            }
        case .tools:
            let usable = model.toolUsage != nil
            items.append(UIMenu(title: "Sort", image: UIImage(systemName: "arrow.up.arrow.down"), children: ToolSort.allCases.map { sort in
                let action = UIAction(title: sort.title, state: model.effectiveSort == sort ? .on : .off) { _ in model.toolSort = sort }
                if !usable, sort != .name { action.attributes = .disabled }
                return action
            }))
        case .connectors:
            if !model.readOnly {
                items.append(UIAction(title: "Add Your Own…", image: UIImage(systemName: "plus")) { [weak self] _ in self?.addConnector() })
            }
        case .plugins:   // [find-plugins]
            items.append(UIAction(title: "Marketplace", image: UIImage(systemName: "bag")) { [weak self] _ in   // [marketplace]
                guard let self else { return }
                self.rootView.router.push(MarketplaceController(model: model, router: self.rootView.router, kind: .plugins))
            })
            if !model.readOnly, !model.pluginsUnavailable {
                items.append(UIAction(title: "Install from Git…", image: UIImage(systemName: "plus")) { [weak self] _ in
                    guard let self else { return }
                    self.rootView.router.push(PluginInstallController(model: model, router: self.rootView.router))
                })
            }
        }
        return items
    }

    func addConnector() {
        AddConnectorController.present(model: model, from: self) { [weak self] name in
            guard let self, let server = self.model.servers?.first(where: { $0.name == name }) else { return }
            self.rootView.router.push(ConnectorPageController(model: self.model, server: server, router: self.rootView.router))
        }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        searchCapsule?.restoreIfTyped()   // [morepages]
        rootView.router.navigation = navigationController
        model.managed?.presenter = self   // [connectors]
        model.appear()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.disappear()
    }

    func updateSearchResults(for searchController: UISearchController) {
        searchCapsule?.updateSearchState()   // [morepages]
        model.query = searchController.searchBar.text ?? ""
    }
}

struct CapabilitiesView: View {
    @Bindable var model: CapabilitiesModel
    let router: SettingsRouter
    var botLocked = false
    /// [mac] Stress test 2026-10-28 round 9: opened from Settings (Skills, Tools, Plugins), so its rows are the
    /// Settings pages' rows (`hqMacForm(settings:)`); More's Capabilities keeps its own.
    var settingsPage = false

    var body: some View {
        ScrollViewReader { proxy in
            list
                // [capabilities] 3x §17.5 e (DECISION R3-c): opened from an issue, the failing connector is scrolled into
                // view once its list is there; the order of the list is unchanged.
                .onChange(of: model.focusTarget, initial: true) { _, target in
                    guard let target else { return }
                    model.focusServer = nil
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))   // the rows are laid out first
                        if HQMotion.reduced { proxy.scrollTo(target, anchor: .center) } else { withAnimation { proxy.scrollTo(target, anchor: .center) } }
                        model.spokenServer = target
                    }
                }
        }
    }

    private var list: some View {
        List { Group {
            // The bot in its own grouped row at the top, drawn as on the other per-bot More pages (UX study #49):
            // everything below is that bot's.
            Section {
                // From a bot's own page the card stays that bot's: it can't switch away (UX study #187), so it's a plain
                // row, not a menu with one choice.
                if botLocked {
                    LabeledContent {
                        Text(model.botName).foregroundStyle(Color.hqLabel2)
                    } label: {
                        HStack(spacing: 12) {
                            if let bot = model.pickerBots.first(where: { $0.id == model.profile }) {
                                HeadImage(raw: bot.head, profile: bot.id, size: 28)
                            }
                            Text("Bot").foregroundStyle(Color.hqLabel)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("capabilities.bot")
                } else {
                    MoreBotPicker(bots: model.pickerBots, selection: Binding(get: { model.profile }, set: { id in
                        guard id != model.profile else { return }
                        Haptics.play(.selection)
                        model.profile = id
                    }), identifier: "capabilities.bot")
                }
            }
            if let failed = model.refreshFailed, failed == model.tab {
                Section {
                    HStack(spacing: 12) {
                        Text("Couldn’t refresh. Showing the last list.").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Try Again") { Task { await model.refresh() } }.hqBorderedButtonStyle()
                    }
                    .padding(.vertical, 3)
                    .accessibilityIdentifier("capabilities.refresh-failed")
                }
            }
            switch model.tab {
            case .skills: SkillsSections(model: model, router: router)
            case .tools: ToolsetsSections(model: model, router: router)
            case .connectors: ConnectorsSections(model: model, router: router)
            case .plugins: PluginsSections(model: model, router: router)
            }
        }.hqMacSettingsRowInsets() }
        // [mac] Stress test 2026-10-28 round 8: the empty states (No Tools, No Plugins) know the list's height, so they
        // are centred in the room under the Bot row. Without it they had their 280 pt floor, too short for Plugins'
        // symbol, title, line and button: ContentUnavailableView dropped the symbol and its title stood about 80 pt
        // higher than Tools'.
        .hqMacListHeight()
        .hqMacForm(settings: settingsPage)       // [mac] Stress test 2026-10-28 #8: readable width, small switches; round 9: Settings' rows
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .contentMargins(.top, MacInset.top(otherwise: 0), for: .scrollContent)   // [mac] Stress test 2026-10-28 #53
        .accessibilityIdentifier("capabilities.list")
        .refreshable { await model.refresh() }
    }

}

/// Tabs whose labels are never cut (3x §2, DECISION 2-a): one row while every whole label fits, else rows of two acting
/// as one control; a pull-down at accessibility sizes. Bot Info's five tabs and Theme's three ([cap-pages] Capabilities'
/// four are pages of their own since 2026-11-03).
/// [page-tabs] An odd number of tabs that doesn't fit one row is the pull-down too: rows of two would leave one alone.
struct WholeLabelTabs<Tab: Hashable>: View {
    var tabs: [Tab]
    var title: (Tab) -> String
    @Binding var selection: Tab
    var identifier: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            pullDown
        } else if tabs.count.isMultiple(of: 2) {
            ViewThatFits(in: .horizontal) {
                oneRow
                VStack(spacing: 8) {
                    ForEach(Array(stride(from: 0, to: tabs.count, by: 2)), id: \.self) { start in
                        let pair = Array(tabs[start..<min(start + 2, tabs.count)])
                        WholeLabelSegments(titles: pair.map(title),
                                           selected: Binding(get: { pair.firstIndex(of: selection) ?? UISegmentedControl.noSegment },
                                                             set: { if pair.indices.contains($0) { selection = pair[$0] } }))
                            .frame(height: HQFont.scaled(32))   // [ui-sizing] × UI Scale, as its titles
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                oneRow
                pullDown
            }
        }
    }

    private var oneRow: some View {
        WholeLabelSegments(titles: tabs.map(title),
                           selected: Binding(get: { tabs.firstIndex(of: selection) ?? 0 }, set: { selection = tabs[$0] }),
                           fitsWhole: true)
            .frame(height: HQFont.scaled(32))   // [ui-sizing] × UI Scale, as its titles
            .accessibilityIdentifier(identifier)
    }

    private var pullDown: some View {
        Menu {
            ForEach(tabs, id: \.self) { tab in
                Button { selection = tab } label: {
                    if tab == selection { Label(title(tab), systemImage: "checkmark") } else { Text(title(tab)) }
                }
            }
        } label: {
            HStack {
                Text(title(selection)).font(Font.hq(.body).weight(.semibold))
                Image(systemName: "chevron.up.chevron.down").font(Font.hq(.footnote))
            }
            // [page-tabs] The whole row opens it, not only its words (a tap beside them did nothing).
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(identifier)
    }
}

/// A segmented control whose labels are never cut: equal segments while every label fits one, else each segment as
/// wide as its label (`apportionsSegmentWidthsByContent`, `MEM/segmented-labels-whole.md`).
final class WholeLabelSegmentedControl: UISegmentedControl {
    /// [page-tabs] The font the titles are drawn in: the control's own 13 pt (the chosen one semibold, the widest), which
    /// doesn't grow with the text size, unless one is set (the Mac's). Measured in Body was a guess that ran 15–40 % wide:
    /// Bot Info's five tabs, 304 pt in a 370 pt row, read as not fitting.
    var drawnFont: UIFont {
        (titleTextAttributes(for: .selected)?[.font] as? UIFont) ?? (titleTextAttributes(for: .normal)?[.font] as? UIFont)
            ?? HQFont.segmentedDefault
    }

    override func layoutSubviews() {
        let font = drawnFont
        let widest = (0..<numberOfSegments).map { (titleForSegment(at: $0) ?? "") as NSString }
            .map { $0.size(withAttributes: [.font: font]).width }.max() ?? 0
        let fits = numberOfSegments > 0 && widest + 24 <= bounds.width / CGFloat(numberOfSegments)
        if apportionsSegmentWidthsByContent == fits { apportionsSegmentWidthsByContent = !fits }
        super.layoutSubviews()
    }
}

/// iOS 26's segmented control with the Desktop Look off; the desktop's outlined strip with it on. The control draws
/// its own glass pill over any images UIKit is given, which on the look showed the chosen tab as a dark smudge (owner,
/// 2026-10-14: "it's currently black instead of, like, showing that it's selected").
struct WholeLabelSegments: View {
    var titles: [String]
    @Binding var selected: Int
    /// [capabilities] Report the width every whole label needs (for `ViewThatFits`); otherwise take what is offered.
    var fitsWhole = false
    /// A tick on a new pick (false: the caller plays its own).
    var ticks = true

    var body: some View {
        let _ = Theme.touch()         // follows a live toggle of the look
        if Theme.isDesktop {
            DesktopSegmentStrip(options: titles.enumerated().map { ($0.element, $0.offset) }, selection: $selected,
                                wholeLabels: true, ticks: ticks)
                .accessibilityElement(children: .contain)
        } else {
            WholeLabelSegmentsControl(titles: titles, selected: $selected, fitsWhole: fitsWhole, ticks: ticks)
        }
    }
}

struct WholeLabelSegmentsControl: UIViewRepresentable {
    var titles: [String]
    @Binding var selected: Int
    var fitsWhole = false
    var ticks = true

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        let font = (uiView as? WholeLabelSegmentedControl)?.drawnFont ?? HQFont.segmentedDefault
        // Each whole label and the control's own room around it (about 19 pt a segment on iOS 26; 24 kept to spare).
        let needed = titles.reduce(CGFloat(0)) { $0 + ($1 as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + 24 }
        let height = proposal.height ?? 32
        if fitsWhole, proposal.width == nil { return CGSize(width: needed, height: height) }
        return CGSize(width: proposal.width ?? needed, height: height)
    }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = WholeLabelSegmentedControl(items: titles)
        control.apportionsSegmentWidthsByContent = true
        control.addAction(UIAction { [weak control] _ in
            guard let control else { return }
            if context.coordinator.ticks { Haptics.play(.selection) }
            context.coordinator.selected.wrappedValue = control.selectedSegmentIndex
        }, for: .valueChanged)
        control.setContentHuggingPriority(.required, for: .vertical)
        DesktopSegments.macTitles(control)   // [ui-sizing] its titles at the UI Scale (iOS's 13 pt at 100 %)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.selected = $selected
        context.coordinator.ticks = ticks
        if control.selectedSegmentIndex != selected { control.selectedSegmentIndex = selected }
        // [ui-sizing] A UI Scale change redraws the strip (`WholeLabelSegments` reads the theme): the titles follow it.
        let before = control.titleTextAttributes(for: .normal)?[.font] as? UIFont
        DesktopSegments.macTitles(control)
        if (control.titleTextAttributes(for: .normal)?[.font] as? UIFont) !== before { control.setNeedsLayout(); control.invalidateIntrinsicContentSize() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selected: $selected, ticks: ticks) }

    final class Coordinator {
        var selected: Binding<Int>
        var ticks: Bool
        init(selected: Binding<Int>, ticks: Bool) { self.selected = selected; self.ticks = ticks }
    }
}

// MARK: - Skills

struct SkillsSections: View {
    @Bindable var model: CapabilitiesModel
    let router: SettingsRouter

    var body: some View {
        if let skills = model.skills {
            let shown = model.shownSkills
            let available = model.available
            let notices = model.installNotices.filter { $0.profile == model.profile }
            if !model.query.isEmpty, shown.isEmpty, available.isEmpty {
                Section { Text("No Results for “\(model.query)”").foregroundStyle(Color.hqLabel2).padding(.vertical, 12) }
                HubSection(model: model)
            } else {
                Section {
                    if let notice = model.skillsNotice {
                        NoticeRow(text: notice, symbol: "checkmark.circle.fill").accessibilityIdentifier("skills.notice")
                    }
                    if skills.isEmpty, model.query.isEmpty {
                        // UX study #55: what an empty list means and where skills come from, with a way to find them.
                        let words = SkillsEmptyWords.make(botName: model.botName, hasAvailable: !available.isEmpty)
                        ContentUnavailableView {
                            UnavailableTitle(words.title, systemImage: "sparkles")
                        } description: {
                            Text(words.text).hqMacFont(MacType.emptyBodyFont)   // [mac] Stress test 2026-10-28 #52
                        } actions: {
                            if let action = words.action, model.openSearch != nil {
                                Button(action) { model.openSearch?() }
                                    .hqBorderedButtonStyle()
                                    .accessibilityIdentifier("skills.empty.search")
                            }
                        }
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("skills.empty")
                    }
                    ForEach(shown) { skill in
                        SkillRow(skill: skill, busy: model.toggling.contains(skill.name),
                                 toggle: { model.setSkill(skill, enabled: $0) },
                                 open: { router.push(SkillPageController(model: model, skill: skill)) })
                    }
                } header: {
                    // No "Installed" over the empty state that says nothing is installed (UX study #99).
                    if !(skills.isEmpty && model.query.isEmpty) { HQSectionLabel { Text("Installed") } }
                } footer: { HQSectionFooter {
                    if let progress = model.disabling {
                        Text("Turning off \(progress.done) of \(progress.total)…").accessibilityIdentifier("skills.disabling")
                    } else if available.isEmpty && notices.isEmpty && !skills.isEmpty { Text("Changes apply to new chats.") }
                } }
                if !available.isEmpty || !notices.isEmpty {
                    Section {
                        ForEach(notices) { notice in
                            InstallNoticeRow(notice: notice)
                                .onAppear { model.seen(notice) }
                                .onTapGesture { if notice.done { model.installNotices.removeAll { $0.id == notice.id } } }
                                // A finished notice is a button to VoiceOver too (UX study #170).
                                .accessibilityAddTraits(notice.done ? .isButton : [])
                                .accessibilityHint(notice.done ? "Dismisses" : "")
                                .accessibilityAction { if notice.done { model.installNotices.removeAll { $0.id == notice.id } } }
                        }
                        ForEach(available) { skill in
                            OfficialSkillRow(skill: skill, installing: model.running.contains(skill.identifier)) { model.install(skill) }
                        }
                    } header: { HQSectionLabel {
                        Text("Available from Hermes")
                    } } footer: { HQSectionFooter {
                        Text("Changes apply to new chats.")
                    } }
                }
                HubSection(model: model)
                SkillsMarketplaceSection(model: model, router: router)   // [marketplace]
            }
        } else if let error = model.skillsError {
            LoadErrorSection(title: "Couldn’t Load Skills", reason: error) { Task { await model.reloadSkills() } }
        } else if !model.isConnected {
            Section { Text("Waiting for your gateway…").foregroundStyle(Color.hqLabel2).padding(.vertical, 12) }
        } else {
            Section { ForEach(0..<3, id: \.self) { _ in SkeletonLine() } }
        }
    }
}

extension View {
    /// [mac] Stress test 2026-10-28 round 6: a row's trailing switch with its label hidden takes only the switch's
    /// width on the Mac. The Mac's switch style gives its (empty) label all the room it can, so the row's subtitle
    /// stopped at about half the row ("Search the web an…") with ~300 pt free before the switch. Elsewhere nothing.
    @ViewBuilder func hqMacRowSwitch() -> some View {
        if DeviceWord.isMac { self.fixedSize() } else { self }
    }
}

/// [mac] Stress test 2026-10-28 round 8: a skill row's gap between its lines and room above and under. The Desktop Look's
/// 3 and 3 made Skills' two-line rows 84 pt against the iOS look's 76, while every other page's rows match in both looks
/// (their text is one size on the Mac). The Mac takes the iOS look's in both; the iPhone and iPad keep each look's own.
enum SkillRowMetrics {
    @MainActor static var lineGap: CGFloat { Theme.isDesktop && !DeviceWord.isMac ? 3 : 1 }
    @MainActor static var pad: CGFloat { Theme.isDesktop && !DeviceWord.isMac ? 3 : 0 }
    /// [mac-audit] Owner 2026-11-02 (round-4 #10): on the Mac a skill's name is regular, as every other two-line row's
    /// title is (Vault, Bot Profiles, Connectors' settings); the iPhone keeps its semibold.
    @MainActor static var titleWeight: Font.Weight { DeviceWord.isMac ? .regular : .semibold }
}

struct SkillRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let skill: SkillInfo
    let busy: Bool
    let toggle: (Bool) -> Void
    let open: () -> Void

    /// Stress test 2026-10-28 #59, round 2 (both): "Research · Used 30 times", not the slug and "used 30×".
    var caption: String {
        let category = DisplayName.title(skill.category ?? "general")
        let used = skill.usage ?? 0
        return used > 0 ? "\(category) · Used \(used) \(used == 1 ? "time" : "times")" : category
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: SkillRowMetrics.lineGap) {
                    Text(DisplayName.title(skill.name)).font(Font.hq(.body).weight(SkillRowMetrics.titleWeight)).foregroundStyle(Color.hqLabel)
                    if DeviceWord.isMac {
                        // [mac] Stress test 2026-10-28 #59, round 2: one subtitle line (category and use, then what it
                        // does), not three lines in two sizes; the whole description is the row's tooltip.
                        Text([caption, skill.description].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                            .help(skill.description)
                    } else {
                    if !skill.description.isEmpty {
                        Text(skill.description).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : Density.compact ? 1 : 2)   // [ui-sizing] Compact: one line
                    }
                    Text(caption).font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("skill-row-\(skill.name)")
            Toggle("", isOn: Binding(get: { skill.enabled }, set: { toggle($0) }))
                .labelsHidden()
                .hqMacRowSwitch()   // [mac] Stress test 2026-10-28 round 6
                .disabled(busy)
                .accessibilityLabel(skill.name)
                .accessibilityIdentifier("skill-switch-\(skill.name)")
        }
        .padding(.vertical, SkillRowMetrics.pad) // [compact] iOS look: the list row's own inset only
    }
}

struct OfficialSkillRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let skill: OfficialSkill
    let installing: Bool
    let install: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: SkillRowMetrics.lineGap) {
                Text(DisplayName.title(skill.name)).font(Font.hq(.body).weight(SkillRowMetrics.titleWeight)).foregroundStyle(Color.hqLabel)
                if DeviceWord.isMac {
                    // [mac] Stress test 2026-10-28 round 6: one subtitle line as an installed skill's (category, then
                    // what it does), not the description with the category on a line of its own under it.
                    let line = [skill.category.map(DisplayName.title) ?? "", skill.description].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !line.isEmpty {
                        Text(line)
                            .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                            .help(skill.description)
                    }
                } else {
                if !skill.description.isEmpty {
                    Text(skill.description).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : Density.compact ? 1 : 2)   // [ui-sizing] Compact: one line
                }
                if let category = skill.category { Text(DisplayName.title(category)).font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if installing {
                ProgressView().frame(minWidth: 52)
                    .accessibilityLabel("Installing \(skill.name)")
            } else {
                Button("Get", action: install)
                    .hqRowActionButtonStyle()
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .accessibilityLabel("Get \(skill.name)")
                    .accessibilityIdentifier("skill-get-\(skill.name)")
            }
        }
        .padding(.vertical, SkillRowMetrics.pad) // [compact] iOS look: the list row's own inset only
    }
}

struct LoadErrorSection: View {
    var title: String
    var reason: String
    var retry: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                Text(reason).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: retry).hqBorderedButtonStyle().padding(.top, 4)
            }
            .padding(.vertical, 12)
        }
    }
}

struct SkeletonLine: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 6).fill(Color.hqFill3).frame(width: 120, height: 15)
            RoundedRectangle(cornerRadius: 6).fill(Color.hqFill3).frame(height: 12)
        }
        .padding(.vertical, SkillRowMetrics.pad) // [compact] iOS look: the list row's own inset only
        .accessibilityHidden(true)
    }
}

/// A one-line inline notice (3x §3: the app has no cross-page toast; notices live where they mean something).
struct NoticeRow: View {
    var text: String
    var symbol: String = "info.circle.fill"
    var tint: Color = .green
    var action: String?
    var run: (() -> Void)?
    var close: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                if let action, let run { Button(action, action: run).hqBorderedButtonStyle().font(Font.hq(.subheadline).weight(.semibold)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let close {
                Button(action: close) { Image(systemName: "xmark").font(Font.hq(.footnote).weight(.semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Color.hqLabel2).frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Close")
            }
        }
        .padding(.vertical, 3)
    }
}

struct InstallNoticeRow: View {
    let notice: InstallNotice

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title).font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel)
                Text(notice.message).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if notice.done {
                Image(systemName: "checkmark.circle.fill").font(Font.hq(.title3)).foregroundStyle(.green).accessibilityHidden(true)
            } else {
                ProgressView()
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("skill-install-progress-\(notice.name)")
    }
}
