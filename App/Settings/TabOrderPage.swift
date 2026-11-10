// [taborder] Settings › Appearance › Tabs (HermesKit/Settings/TabOrder.swift): the tabs in the bar, in its order, each
// with a drag handle (the list is always editing) and a switch; below them the tabs and More pages that can be added
// ([customtabs]). A change takes effect at once, in the bar and the Mac sidebar. [kanban-tab-one] Between them, the one
// Kanban Tab picker: whether Kanban or Artifacts has the tab they share (owner 2026-11-03: one home per page; it was
// also a Settings › Bots & Tools row).

import SwiftUI

struct TabOrderPage: View {
    /// [kanban-tab-one] The gateway whose Kanban Tab choice the page shows (nil: no picker).
    var account: GatewayAccount?
    /// [kanban-tab-one] Opened from a search for the picker: the list scrolls to it and marks it a moment.
    var revealKanban = false
    @State private var shown = TabOrder.tabs
    /// [kanban-tab-one] The Kanban Tab choice; nil while there is none to make (`kanbanChoice`).
    @State private var kanban: KanbanTabOverride?
    /// [kanban-tab-one] The row a search result marks, as the Settings root marks its own (UX study #108).
    @State private var revealed: String?
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28
    /// The drawn Bots and Kanban glyphs at the height of the row's symbols (body size), as the system bar draws them
    /// beside its symbols (`TabIcons`: 23.5 there, where its symbols are a little larger than a row's).
    @ScaledMetric(relativeTo: .body) private var glyphPoints: CGFloat = 22

    init(account: GatewayAccount? = nil, revealKanban: Bool = false) {
        self.account = account
        self.revealKanban = revealKanban
        _kanban = State(initialValue: Self.kanbanChoice(account))
    }

    var body: some View {
        let pages = Self.pageChoices()
        let more = HQTab.movable.map(TabChoice.main).filter { !shown.contains($0) } + pages.map { TabChoice.page($0.id) }.filter { !shown.contains($0) }
        let full = shown.count >= TabOrder.limit
        ScrollViewReader { proxy in
            List { Group {
                Section {
                    ForEach(shown, id: \.self) { tab in
                        row(tab, pages: pages, isOn: true, enabled: TabOrder.canHide(tab, from: shown))
                    }
                    .onMove { from, to in
                        var next = shown
                        next.move(fromOffsets: from, toOffset: to)
                        save(next)
                    }
                } header: { HQSectionLabel {
                    Text(Self.barName)
                } } footer: { HQSectionFooter {
                    Text(barFooter)
                } }
                kanbanSection
                if !more.isEmpty {
                    Section {
                        // Ids of their own: a row turned on is a new row in the bar, with its drag handle (one that kept
                        // its id moved across without one).
                        ForEach(more, id: \.addRowID) { tab in
                            row(tab, pages: pages, isOn: false, enabled: !full)
                        }
                    } header: { HQSectionLabel {
                        Text(DeviceWord.isMac ? "Add to Sidebar" : "Add a Tab")
                    } } footer: { HQSectionFooter {
                        Text(addFooter(full: full))
                    } }
                }
                if shown != TabOrder.defaultTabs {
                    Section {
                        Button("Use Default Tabs") { save(TabOrder.defaultTabs) }
                            .accessibilityIdentifier("tab-order.default")
                    }
                }
            }.hqMacSettingsRowInsets() }
            .settingsList()
            .environment(\.editMode, .constant(.active))
            .task {
                // [kanban-tab-one] A beat for the push to land before the list scrolls, then the mark for a moment.
                guard revealKanban, kanban != nil else { return }
                try? await Task.sleep(for: .milliseconds(350))
                HQMotion.withAnimation { proxy.scrollTo(Self.kanbanRowID, anchor: .center) }
                revealed = Self.kanbanRowID
                try? await Task.sleep(for: .seconds(1.4))
                revealed = nil
            }
        }
    }

    // MARK: Kanban Tab ([kanban-tab-one])

    static let kanbanRowID = "row:kanban"

    /// The choice to show, nil while there is none to make: the gateway's Kanban API hasn't answered yet, or it has
    /// none (a picker then would do nothing; §3.9). The Settings and More searches leave the picker's result out then.
    static func kanbanChoice(_ account: GatewayAccount?) -> KanbanTabOverride? {
        guard let account, let availability = SettingsHooks.kanbanAvailability?(account), availability != "absent" else { return nil }
        return KanbanTabOverride.value(for: account)
    }

    /// The footer for the choice: what Automatic chose, and where Artifacts is.
    private func kanbanFooter(_ choice: KanbanTabOverride, account: GatewayAccount) -> String {
        let shows = switch choice {
        case .on: true
        case .off: false
        case .auto: SettingsHooks.kanbanAvailability?(account) == "on"
        }
        return SettingsWords.kanbanFooter(automatic: choice == .auto, showsTab: shows, tabHidden: !shown.contains(.main(.workspace)))
    }

    /// Kanban Tab: Automatic, On or Off, in a section of its own under the bar's tabs (those rows move; this one
    /// doesn't). Drawn as the Settings root drew it: the Menu over the row on the iPhone and iPad (#107), the form's
    /// pop-up on the Mac. The pages stream applies a change at once (never under the finger on that tab), and the
    /// rows above then name the tab as the bar does.
    @ViewBuilder
    private var kanbanSection: some View {
        if let account, let kanban {
            let choice = Binding(get: { kanban }, set: { (value: KanbanTabOverride) in
                Haptics.play(.selection)
                KanbanTabOverride.set(value, for: account)
                self.kanban = value
            })
            let label = Label {
                Text(Self.kanbanName).foregroundStyle(Color.hqLabel)
            } icon: {
                Image(uiImage: kanbanGlyph).foregroundStyle(Color.hqLabel).frame(width: iconColumn, height: DeviceWord.isMac ? iconColumn : nil)
            }
            Section {
                Group {
                    if DeviceWord.isMac {
                        HStack(spacing: 12) {
                            label
                            Spacer(minLength: 16)
                            MacPopUp(label: Self.kanbanName, selection: choice, options: KanbanTabOverride.allCases) { $0.title }
                                .accessibilityIdentifier("settings.kanban")
                                .hqMacSettingsControl()
                        }
                    } else {
                        SettingsMenuRowFace(label: label, value: kanban.title)
                            .overlay {
                                Menu {
                                    Picker("Kanban Tab", selection: choice) {
                                        ForEach(KanbanTabOverride.allCases) { Text($0.title).tag($0) }
                                    }
                                } label: {
                                    Color.clear.contentShape(Rectangle())
                                }
                                .accessibilityLabel("Kanban Tab")
                                .accessibilityValue(kanban.title)
                                .accessibilityIdentifier("settings.kanban")
                            }
                    }
                }
                .revealRow(Self.kanbanRowID, revealed)
            } header: { HQSectionLabel {
                Text("Kanban or Artifacts")
            } } footer: { HQSectionFooter {
                Text(kanbanFooter(kanban, account: account)).accessibilityIdentifier("tab-order.kanban-footer")
            } }
        }
    }

    /// [mac] The Mac shows the tabs in its sidebar, not a bar (stress test 2026-10-31).
    private static var barName: String { DeviceWord.isMac ? "Sidebar" : "Tab Bar" }
    /// [mac] Mac polish #131: the control is "Kanban" on the Mac, which has places, not tabs.
    private static var kanbanName: String { DeviceWord.isMac ? "Kanban" : "Kanban Tab" }
    private static var barWord: String { DeviceWord.isMac ? "sidebar" : "bar" }

    /// [mac-sidebar] The Mac's sidebar has no cap: every page can join it, from here or from the sidebar itself.
    private func addFooter(full: Bool) -> String {
        if DeviceWord.isMac {
            // [mac-layout] No More on the Mac: a page not placed opens from the sidebar's Tools or the Settings window.
            // Mac polish #135: `DeviceWord.hold`'s hyphen doesn't break, so a line never ends "Control-".
            return "Turn a page on to give it a place in the sidebar. Until then it opens from Tools or Settings. "
                + "You can also \(DeviceWord.hold) a row under Tools and choose Move to Places."
        }
        return full ? "The \(Self.barWord) holds \(TabOrder.limit) tabs, then More. Turn one off to add another."
                    : "Turn a page on to give it a tab of its own. Until then it opens from More."
    }

    private var barFooter: String {
        var words = DeviceWord.isMac
            ? "Drag a row by its handle, or in the sidebar itself, to move it. Bots or Sessions always stays: chats open there."
            : "Drag a tab by its handle to move it. More always stays last. Bots or Sessions always stays: chats open there."
        if !shown.contains(.main(.bots)) { words += " With Bots hidden, a bot’s chat opens on Sessions." }
        if !shown.contains(.main(.sessions)) { words += " With Sessions hidden, a chat opens on Bots." }
        return words
    }

    private func save(_ next: [TabChoice]) {
        Haptics.play(.selection)
        TabOrder.tabs = next
        shown = TabOrder.tabs
    }

    private func row(_ tab: TabChoice, pages: [PageChoice], isOn: Bool, enabled: Bool) -> some View {
        let page: PageChoice? = if case .page(let id) = tab { pages.first { $0.id == id } ?? Self.fallback(id) } else { nil }
        return Toggle(isOn: Binding(get: { isOn }, set: { on in
            save(on ? shown + [tab] : shown.filter { $0 != tab })
        })) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(page?.title ?? Self.title(tab)).foregroundStyle(Color.hqLabel)
                    if case .page(let id) = tab, isOn, !pages.contains(where: { $0.id == id }) {
                        Text("Not on this gateway").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    }
                }
            } icon: {
                icon(tab, page: page).foregroundStyle(Color.hqLabel).frame(width: iconColumn, height: DeviceWord.isMac ? iconColumn : nil)
            }
        }
        .tint(Color.hqTint)
        .disabled(!enabled)
        .accessibilityIdentifier("tab-order.\(tab.key)")
    }

    /// Tab 3 is named as the bar names it now (Kanban or Artifacts).
    static func title(_ tab: TabChoice) -> String {
        switch tab {
        case .main(.bots): "Bots"
        case .main(.sessions): "Sessions"
        case .main(.jobs): "Jobs"
        case .main(.workspace): workspaceTitle ?? "Kanban or Artifacts"
        case .main(.more): "More"
        case .page(let id): fallback(id).title
        }
    }

    static var workspaceTitle: String? {
        guard let pages = MainTabController.current?.pages else { return nil }
        return pages.workspaceRowID == "kanban" ? "Kanban" : "Artifacts"
    }

    /// The tab's own glyph, at a row's size.
    @ViewBuilder
    private func icon(_ tab: TabChoice, page: PageChoice?) -> some View {
        switch tab {
        case .main(.bots): Image(uiImage: botGlyph)
        case .main(.sessions): symbol("bubble.left.and.bubble.right")
        case .main(.jobs): symbol("calendar.badge.clock")
        case .main(.workspace):
            if Self.workspaceTitle == "Kanban" { Image(uiImage: kanbanGlyph) } else { symbol("photo.on.rectangle") }
        case .main(.more): symbol("ellipsis")
        case .page(let id):
            if id == "kanban" { Image(uiImage: kanbanGlyph) }
            else { symbol(page?.symbol ?? "square.dashed") }
        }
    }

    // [mac] Mac polish #99: on the Mac every icon sits in the Settings list's one box (`MacIcon`), the symbols fitted
    // to it as its rows fit theirs (`SettingsRowLabel.fittedFont`) and the drawn glyphs' pictures (1.35 × their point
    // size) filling it, with the symbols' line, Kanban's at 0.9 as the sidebar draws it: Sessions', Jobs' and
    // Artifacts' symbols came out bigger and wider than Bots'. The drawn glyphs take the fitted symbols' own point size,
    // as the sidebar draws the robot at its symbols' (`MacSidebar.rowIcon`): a fixed share of the box still left the
    // robot about a fifth narrower than Sessions and Jobs beside it.
    private var iconColumn: CGFloat { DeviceWord.isMac ? MacIcon.rowColumn : iconWidth }
    private var macGlyphPoints: CGFloat {
        // `SettingsRowLabel.fittedFont`'s size for Jobs' symbol: the row size, shrunk only when the symbol is wider than the box.
        let column = MacIcon.rowColumn, size = MacIcon.rowSize
        let wide = UIImage(systemName: "calendar.badge.clock", withConfiguration: MacIcon.row)?.size.width ?? 0
        let fitted = wide > column ? (size * column / wide * 10).rounded(.down) / 10 : size
        // The drawn robot's ink is about four fifths of a symbol's at one point size (measured in the Settings window:
        // 22 px wide beside Sessions' 30 and Jobs' 28), so it is drawn a fifth larger to sit level with them.
        return max(column / 1.35, fitted) * 1.2
    }
    private var botGlyph: UIImage {
        DeviceWord.isMac ? TabIcons.bot(pointSize: macGlyphPoints, line: 0.07) : TabIcons.bot(pointSize: glyphPoints, line: 0.09)
    }
    private var kanbanGlyph: UIImage {
        DeviceWord.isMac ? TabIcons.kanban(pointSize: macGlyphPoints * 0.9, line: 0.07) : TabIcons.kanban(pointSize: glyphPoints, line: 0.09)
    }

    @ViewBuilder
    private func symbol(_ name: String) -> some View {
        if DeviceWord.isMac {
            Image(systemName: name).font(SettingsRowLabel.fittedFont(name, column: MacIcon.rowColumn))
        } else {
            Image(systemName: name)
        }
    }

    // MARK: More pages

    struct PageChoice {
        var id: String
        var title: String
        var symbol: String?
    }

    /// The More pages that can be tabs on this gateway now, in More's order. Tab 3's own page (Kanban or Artifacts)
    /// is that tab, not a page of its own; the gateway card and a hidden Jobs tab's row are not pages.
    static func pageChoices() -> [PageChoice] {
        guard let pages = MainTabController.current?.pages else { return [] }
        var seen = Set<String>()
        return pages.moreSections().flatMap { $0.rows() }.compactMap { row in
            guard TabChoice.pageIDs.contains(row.id), row.id != pages.workspaceRowID, row.card == nil,
                  seen.insert(row.id).inserted else { return nil }
            #if targetEnvironment(macCatalyst)
            // [mac] Mac polish #28: Settings is a window of its own (as a place it only opened that window). A Tool is
            // offered too since Mac 919 (owner 2026-11-09: "I don't see tasks or tiles as options to add"; Tools sit
            // at the sidebar's foot, where a short window pushes them out of sight): added, it moves up to the places.
            guard row.id != PagesTabs.settingsRowID else { return nil }
            #endif
            return PageChoice(id: row.id, title: row.title, symbol: row.symbol.map(PagesTabs.outlineSymbol))
        }
    }

    /// A chosen page this gateway doesn't list now: its name from the More pages' table.
    static func fallback(_ id: String) -> PageChoice {
        if let page = MorePages.pages.first(where: { $0.id == id }) {
            return PageChoice(id: id, title: page.title, symbol: PagesTabs.outlineSymbol(page.symbol))
        }
        let known: [String: (String, String)] = ["settings": ("Settings", "gearshape"), "capabilities": ("Capabilities", "square.grid.2x2"),
                                                  "connectors": ("Connectors", "powerplug"), "artifacts": ("Artifacts", "photo.on.rectangle"),
                                                  "kanban": ("Kanban", "rectangle.split.3x1"), "pinned": ("Tiles", "rectangle.3.group"),
                                                  "marketplace": ("Marketplace", "bag")]
        let (title, symbol) = known[id] ?? (id.capitalized, "square.dashed")
        return PageChoice(id: id, title: title, symbol: symbol)
    }
}

private extension TabChoice {
    var addRowID: String { "add." + key }
}
