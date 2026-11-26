// [quick-actions] Add Action and Set Up (docs/spec/3x-morepages.md §25 Q4, Q5). Add Action lists what a tile can be,
// in three groups (Chats, Work, Pages) with a search field; a choice opens Set Up: what the action needs (bot,
// project, words, job), then its Look (name, icon, colour), with the tile drawn live at the top. Editing a tile reopens
// Set Up with Save.
// [favorites-live-tiles] Add Action also lists the Dashboard's tiles (3x-morepages Q15): one opens Set Up with the real
// tile drawn at the top, and only Name and Size (a tile is a picture: no icon, colour or Height).

import SwiftUI
import UIKit

// MARK: - Add Action

/// One thing a tile can be.
struct QuickActionChoice: Identifiable {
    var id: String
    var kind: QuickTileKind
    var title: String
    /// What Set Up asks for ("bot · project · words"), or the page's group.
    var detail: String
    var symbol: String
    var color: UIColor
    var page: (id: String, title: String)? = nil
    /// [favorites-live-tiles] A Dashboard tile: its pin (named as the Dashboard names it).
    var pin: ArtifactPin? = nil

    static let chats: [QuickActionChoice] = [
        choice(.newChat, "New Chat", "bot · project · words"),
        choice(.memo, "Voice Memo", "bot"),
        choice(.talk, "Talk", "bot"),
        choice(.send, "Send a Message", "bot · words"),
        choice(.openChat, "Open a Chat", "bot"),
    ]
    static let work: [QuickActionChoice] = [
        choice(.addTask, "Add Task", "bot"),
        choice(.runJob, "Run Job", "job"),
    ]

    private static func choice(_ kind: QuickTileKind, _ title: String, _ detail: String) -> QuickActionChoice {
        QuickActionChoice(id: kind.rawValue, kind: kind, title: title, detail: detail, symbol: kind.defaultLook.symbol,
                          color: QuickTileLook.color(kind.defaultLook.color))
    }

    /// Every page (`PagesTabs.quickActionChoices`), then Search Chats.
    static func pages(_ sections: [MoreSection]) -> [QuickActionChoice] {
        var out: [QuickActionChoice] = []
        for section in sections {
            for row in section.rows() {
                out.append(QuickActionChoice(id: "page." + row.id, kind: .page, title: row.title, detail: section.header ?? "page",
                                             symbol: row.symbol ?? QuickTileKind.page.defaultLook.symbol, color: row.tile,
                                             page: (row.id, row.title)))
            }
        }
        out.append(QuickActionChoice(id: QuickTileKind.search.rawValue, kind: .search, title: "Search Chats", detail: "page",
                                     symbol: QuickTileKind.search.defaultLook.symbol,
                                     color: QuickTileLook.color(QuickTileKind.search.defaultLook.color)))
        return out
    }

    /// [favorites-live-tiles] The Dashboard's tiles in its order (`names`: each pin's name as the Dashboard shows it),
    /// less those already on Favorites (`list`).
    static func dashboardTiles(_ pins: [ArtifactPin], names: [String: String], on list: QuickTileList) -> [QuickActionChoice] {
        let added = list.pins
        return pins.filter { !added.contains($0.id) }.map { pin in
            var named = pin
            named.title = names[pin.id] ?? pin.name
            return QuickActionChoice(id: "tile." + pin.id, kind: .dashboardTile, title: named.name, detail: "tile",
                                     symbol: PinCardView.glyph(pin), color: HQPalette.tint, pin: named)
        }
    }

    /// The row's identifier (a pin's id holds a separator character: its file's name stands in).
    var identifier: String { pin.map { "quick.add.tile.\($0.label)" } ?? "quick.add.\(id)" }

    /// The new tile this choice starts Set Up with.
    func newTile() -> QuickTile {
        var tile = QuickTile(kind: kind)
        if let pin {
            tile.pin = pin.id
            tile.pinName = pin.name
            tile.name = pin.name
            tile.symbol = QuickTileLook.symbol(symbol)
        }
        if let page {
            tile.page = page.id
            tile.pageName = page.title
            tile.name = page.title
            tile.symbol = QuickTileLook.symbol(symbol)
        }
        if kind == .newChat { tile.flag = true }
        if kind == .send { tile.flag = false }
        if kind.needsBot, let first = MainTabController.current?.services.bots.first {
            tile.bot = first.id
            tile.botName = first.name
            if kind == .openChat { tile.name = first.name }
        }
        if kind == .runJob, let job = JobShortcutCatalog.jobs().first {
            tile.job = job.key
            tile.jobName = job.name
            tile.name = job.name
        }
        return tile
    }

    func matches(_ words: String) -> Bool {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(words) || detail.localizedCaseInsensitiveContains(words)
    }
}

enum QuickActionAddSheet {
    /// Add Action in its own sheet; `onAdd` takes the tile Set Up made (the sheet then closes).
    /// `tiles`: [favorites-live-tiles] the Dashboard's tiles not on Favorites yet, and their pictures.
    static func make(choices: @escaping () -> [MoreSection], tiles: [QuickActionChoice] = [], source: FavoriteTiles? = nil,
                     onAdd: @escaping (QuickTile) -> Void) -> UINavigationController {
        let host = QuickActionAddHost(pages: QuickActionChoice.pages(choices()), tiles: tiles, source: source, onAdd: onAdd)
        let navigation = ChatSheet.wrap(host, title: "Add Action", detents: [.large()])
        navigation.view.accessibilityIdentifier = "quick-actions.add-sheet"
        return navigation
    }
}

final class QuickActionAddHost: UIHostingController<HQScaledRoot<QuickActionAddView>> {
    init(pages: [QuickActionChoice], tiles: [QuickActionChoice] = [], source: FavoriteTiles? = nil, onAdd: @escaping (QuickTile) -> Void) {
        let pictures = source.map(FavoriteTilePictures.init)
        var view = QuickActionAddView(pages: pages, tiles: tiles, pictures: pictures)
        weak var weakSelf: QuickActionAddHost?
        view.choose = { choice in weakSelf?.setUp(choice) }
        self.onAdd = onAdd
        self.pictures = pictures
        super.init(rootView: HQScaledRoot(view))
        weakSelf = self
    }

    private let onAdd: (QuickTile) -> Void
    private let pictures: FavoriteTilePictures?

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func setUp(_ choice: QuickActionChoice) {
        PagesHaptics.selection()
        let setup = QuickActionSetup.page(tile: choice.newTile(), isNew: true, pictures: pictures) { [weak self] tile in
            guard let self else { return }
            PagesHaptics.success()
            self.onAdd(tile)
            // From the sheet's presenter: after a search the search controller is what this page presents, and a plain
            // `dismiss` would close only that, leaving the sheet up.
            let sheet = self.navigationController ?? self
            (sheet.presentingViewController ?? sheet).dismiss(animated: true)
        }
        navigationController?.pushViewController(setup, animated: true)
    }
}

struct QuickActionAddView: View {
    var pages: [QuickActionChoice]
    /// [favorites-live-tiles] The Dashboard's tiles (none: no section).
    var tiles: [QuickActionChoice] = []
    var pictures: FavoriteTilePictures? = nil
    var choose: (QuickActionChoice) -> Void = { _ in }
    @State private var words = ""

    var body: some View {
        List {
            group("Chats", QuickActionChoice.chats)
            group("Work", QuickActionChoice.work)
            group("Dashboard Tiles", tiles)
            group("Pages", pages)
            if [QuickActionChoice.chats, QuickActionChoice.work, tiles, pages].allSatisfy({ $0.allSatisfy { !$0.matches(words) } }) {
                Text("No actions or pages match “\(words)”.")
                    .font(Font.hq(.body))
                    .foregroundStyle(Color.hqLabel2)
                    .listRowBackground(Color.clear)
            }
        }
        .searchable(text: $words, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search actions and pages")
        .hqGroupedPage()
    }

    @ViewBuilder private func group(_ title: String, _ choices: [QuickActionChoice]) -> some View {
        let shown = choices.filter { $0.matches(words) }
        if !shown.isEmpty {
            Section {
                ForEach(shown) { choice in
                    Button { choose(choice) } label: {
                        HStack(spacing: 12) {
                            if let pin = choice.pin {
                                DashboardTileThumb(pin: pin, pictures: pictures, side: HQFont.scaled(29))
                            } else {
                                QuickTileIcon(symbol: choice.symbol, color: choice.color, side: HQFont.scaled(29))
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(choice.title).font(Font.hq(.body)).foregroundStyle(Color.hqLabel)
                                Text(choice.detail).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.forward").font(Font.hq(.footnote).weight(.semibold))
                                .foregroundStyle(Color.hqLabel3)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(choice.title), \(choice.detail)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier(choice.identifier)
                }
            } header: { HQSectionLabel { Text(title) } }
            .hqSheetRows()
        }
    }
}

// MARK: - Set Up

@MainActor @Observable
final class QuickActionDraft {
    var tile: QuickTile
    let original: QuickTile
    let isNew: Bool
    /// The name was typed: it no longer follows the bot, job or page.
    var nameTouched: Bool

    let bots: [(id: String, name: String)]
    let jobs: [JobShortcutRecord]
    /// [favorites-live-tiles] A Dashboard tile's pin and pictures, for the preview.
    @ObservationIgnored let pictures: FavoriteTilePictures?

    init(tile: QuickTile, isNew: Bool, pictures: FavoriteTilePictures? = nil) {
        var tile = tile
        self.pictures = pictures
        // [favorites-live-tiles] A name that follows its pin starts as the pin's name now (renamed on the Dashboard).
        if tile.known == .dashboardTile, tile.name == tile.pinName, let now = pictures?.source.pin(tile.pin).map({ pictures?.source.pins.name($0) ?? $0.name }) {
            tile.name = now
            tile.pinName = now
        }
        self.tile = tile
        original = tile
        self.isNew = isNew
        nameTouched = !isNew && !(tile.known == .dashboardTile && tile.name == tile.pinName)
        let roster = MainTabController.current?.services.bots.map { (id: $0.id, name: $0.name) } ?? []
        // A tile's bot that isn't on this gateway stays choosable (named as it was saved).
        if let bot = tile.bot, !bot.isEmpty, !roster.contains(where: { $0.id == bot }) {
            bots = roster + [(id: bot, name: tile.botName ?? bot)]
        } else {
            bots = roster
        }
        var seen = Set<String>()
        var jobs = JobShortcutCatalog.jobs().filter { seen.insert($0.key).inserted }
        if let job = tile.job, !job.isEmpty, !jobs.contains(where: { $0.key == job }) {
            jobs.append(JobShortcutRecord(key: job, id: job, owner: "", name: tile.jobName ?? tile.name, account: ""))
        }
        self.jobs = jobs
    }

    var kind: QuickTileKind? { tile.known }

    /// The chosen bot's projects (this sign-in's), each once.
    var projects: [ProjectShortcutRecord] {
        let account = tile.bot.flatMap(QuickActionsRouter.voiceRecord)?.account
        var seen = Set<String>()
        return ProjectShortcutCatalog.projects().filter { (account == nil || $0.account == account) && seen.insert($0.key).inserted }
    }

    var bot: String {
        get { tile.bot ?? "" }
        set {
            tile.bot = newValue.isEmpty ? nil : newValue
            tile.botName = bots.first { $0.id == newValue }?.name
            if !nameTouched, kind == .openChat { tile.name = tile.botName ?? tile.name }
            if let project = tile.project, !projects.contains(where: { $0.key == project }) {
                tile.project = nil
                tile.projectName = nil
            }
        }
    }

    var project: String {
        get { tile.project ?? "" }
        set {
            tile.project = newValue.isEmpty ? nil : newValue
            tile.projectName = projects.first { $0.key == newValue }?.name
        }
    }

    var job: String {
        get { tile.job ?? "" }
        set {
            tile.job = newValue.isEmpty ? nil : newValue
            tile.jobName = jobs.first { $0.key == newValue }?.name
            if !nameTouched { tile.name = tile.jobName ?? tile.name }
        }
    }

    var name: String {
        get { tile.name }
        set {
            tile.name = newValue
            nameTouched = true
        }
    }

    var message: String {
        get { tile.message ?? "" }
        set { tile.message = newValue.isEmpty ? nil : newValue }
    }

    var flag: Bool {
        get { tile.flag ?? false }
        set { tile.flag = newValue }
    }

    var canSave: Bool {
        guard !tile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let kind else { return false }
        if kind.needsBot, (tile.bot ?? "").isEmpty { return false }
        if kind == .send, (tile.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if kind == .runJob, (tile.job ?? "").isEmpty { return false }
        if kind == .page, (tile.page ?? "").isEmpty { return false }
        if kind == .dashboardTile, (tile.pin ?? "").isEmpty { return false }
        return true
    }

    var hasChanges: Bool { tile != original }

    /// The tile as saved: the name trimmed, words without trailing space.
    var finished: QuickTile {
        var tile = tile
        tile.name = tile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let words = tile.message?.trimmingCharacters(in: .whitespacesAndNewlines) { tile.message = words.isEmpty ? nil : words }
        // [favorites-live-tiles] Never typed over: it keeps following the pin's name.
        if tile.known == .dashboardTile, !nameTouched { tile.pinName = tile.name }
        return tile
    }
}

enum QuickActionSetup {
    /// Set Up as a page pushed in Add Action (Back, Add).
    static func page(tile: QuickTile, isNew: Bool, pictures: FavoriteTilePictures? = nil,
                     onSave: @escaping (QuickTile) -> Void) -> UIViewController {
        QuickActionSetupHost(draft: QuickActionDraft(tile: tile, isNew: isNew, pictures: pictures), onSave: onSave)
    }

    /// Set Up for a tile on the page, in its own sheet (Cancel, Save).
    static func sheet(editing tile: QuickTile, pictures: FavoriteTilePictures? = nil,
                      onSave: @escaping (QuickTile) -> Void) -> UINavigationController {
        let host = QuickActionSetupHost(draft: QuickActionDraft(tile: tile, isNew: false, pictures: pictures), onSave: onSave)
        let navigation = ChatSheet.wrap(host, title: "Edit Action", detents: [.large()])
        host.installCancel()
        SheetEditGuard.install(on: navigation)
        navigation.view.accessibilityIdentifier = "quick-actions.setup-sheet"
        return navigation
    }
}

final class QuickActionSetupHost: UIHostingController<HQScaledRoot<QuickActionSetupView>>, EditingPage {
    let draft: QuickActionDraft
    private let onSave: (QuickTile) -> Void
    private var saveItem: UIBarButtonItem!

    init(draft: QuickActionDraft, onSave: @escaping (QuickTile) -> Void) {
        self.draft = draft
        self.onSave = onSave
        super.init(rootView: HQScaledRoot(QuickActionSetupView(draft: draft)))
        title = draft.isNew ? "Set Up" : "Edit Action"
        navigationItem.largeTitleDisplayMode = .never
        saveItem = UIBarButtonItem(title: draft.isNew ? "Add" : "Save", primaryAction: UIAction { [weak self] _ in self?.save() })
        saveItem.style = .prominent
        saveItem.accessibilityIdentifier = "quick.setup.save"
        navigationItem.rightBarButtonItem = saveItem
        updateSave()
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var hasChanges: Bool { !draft.isNew && draft.hasChanges }

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + (draft.canSave ? [.save(draft.isNew ? "Add" : "Save", #selector(saveFromKeyboard))] : [])
    }
    override var canBecomeFirstResponder: Bool { true }
    @objc private func saveFromKeyboard() { save() }

    func installCancel() {
        let close = UIBarButtonItem.hqClose(.cancel, action: UIAction { [weak self] _ in
            guard let self else { return }
            self.view.endEditing(true)
            self.confirmLeaving { [weak self] in self?.dismiss(animated: true) }
        })
        close.accessibilityIdentifier = "sheet.close"
        navigationItem.hqPlaceFormClose(close)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "quick.setup"
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = draft.tile
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.updateSave(); self?.observe() }
        }
    }

    private func updateSave() {
        saveItem.setProminentEnabled(draft.canSave)
        if let navigation = navigationController { EditingGuard.refreshLock(navigation) }
    }

    private func save() {
        guard draft.canSave else { return }
        view.endEditing(true)
        let tile = draft.finished
        if draft.isNew {
            onSave(tile)   // Add Action's sheet closes itself
        } else {
            PagesHaptics.success()
            onSave(tile)
            dismiss(animated: true)
        }
    }
}

struct QuickActionSetupView: View {
    @Bindable var draft: QuickActionDraft
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Form {
            Section {
                preview
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                    .hqDesktopBareRow()
            }
            if let kind = draft.kind { details(kind) }
            look
        }
        .hqGroupedPage()
    }

    /// The tile as it will look on the page (half the width, as a Small tile; all of it, as a Wide one).
    @ViewBuilder private var preview: some View {
        if draft.kind == .dashboardTile {
            DashboardTilePreview(tile: draft.tile, pictures: draft.pictures, stacked: typeSize >= .accessibility3)
        } else {
            actionPreview
        }
    }

    private var actionPreview: some View {
        let tile = draft.tile
        let subtitle = tile.subtitle(botName: draft.bots.first { $0.id == tile.bot }?.name)
        return HStack {
            Spacer(minLength: 0)
            QuickTileFace(name: tile.name, subtitle: subtitle, symbol: tile.symbol, color: QuickTileLook.color(tile.tint),
                          stacked: typeSize >= .accessibility3, short: tile.short)
                .background(RoundedRectangle(cornerRadius: QuickTileCell.radius, style: .continuous)
                    .fill(Color(uiColor: HQPalette.sheetCard)))
                .overlay {
                    if Theme.isDesktop {
                        RoundedRectangle(cornerRadius: QuickTileCell.radius, style: .continuous)
                            .stroke(Color(uiColor: HQPalette.cardEdge), lineWidth: 1)
                    }
                }
                .frame(maxWidth: tile.wide || typeSize >= .accessibility3 ? .infinity : HQFont.scaled(176))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview: \(tile.name), \(subtitle)")
        .accessibilityIdentifier("quick.setup.preview")
    }

    @ViewBuilder private func details(_ kind: QuickTileKind) -> some View {
        if kind.needsBot || kind == .addTask {
            Section {
                Picker("Bot", selection: $draft.bot) {
                    if kind == .addTask { Text("None").tag("") }
                    ForEach(draft.bots, id: \.id) { bot in Text(bot.name).tag(bot.id) }
                }
                .hqMenuPicker()
                .accessibilityIdentifier("quick.setup.bot")
                if kind == .newChat {
                    Picker("Project", selection: $draft.project) {
                        Text("None").tag("")
                        ForEach(draft.projects, id: \.key) { project in Text(project.name).tag(project.key) }
                    }
                    .hqMenuPicker()
                    .accessibilityIdentifier("quick.setup.project")
                }
            } header: { HQSectionLabel { Text(kind == .addTask ? "Task For" : "Bot") } }
            .hqSheetRows()
        }
        if kind == .newChat || kind == .send {
            Section {
                TextField(kind == .send ? "Message" : "First Message (Optional)", text: $draft.message, axis: .vertical)
                    .lineLimit(1...5)
                    .accessibilityIdentifier("quick.setup.message")
                if kind == .newChat, !draft.message.isEmpty {
                    Toggle("Send It", isOn: $draft.flag).accessibilityIdentifier("quick.setup.send")
                }
                if kind == .send {
                    Toggle("Open the Chat", isOn: $draft.flag).accessibilityIdentifier("quick.setup.open")
                }
            } header: { HQSectionLabel { Text("Message") } }
            .hqSheetRows()
        }
        if kind == .runJob {
            Section {
                Picker("Job", selection: $draft.job) {
                    if draft.job.isEmpty { Text("Choose").tag("") }
                    ForEach(draft.jobs, id: \.key) { job in Text(job.name).tag(job.key) }
                }
                .hqMenuPicker()
                .accessibilityIdentifier("quick.setup.job")
                if draft.jobs.isEmpty {
                    Text("Open Jobs once, and its jobs are listed here.")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                }
            } header: { HQSectionLabel { Text("Job") } }
            .hqSheetRows()
        }
    }

    private var look: some View {
        Group {
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: $draft.name)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("quick.setup.name")
                }
                // [quick-actions] Owner 2026-11-21: "There isn't a way to change the size of the card."
                LabeledContent("Size") {
                    // The app's segments (the system's on iOS, the Desktop Look's strip there), not .segmented alone.
                    HQSegmentedPicker("Size", options: [("Small", false), ("Wide", true)], selection: $draft.tile.wide,
                                      wholeLabels: true)
                    .fixedSize()
                    .accessibilityIdentifier("quick.setup.size")
                }
                // [quick-actions] Owner 2026-11-21: "I also want to be able to change the height to make them shorter."
                // [favorites-live-tiles] Not for a Dashboard tile: a picture has no one-line form.
                if draft.kind?.isPicture != true {
                    LabeledContent("Height") {
                        HQSegmentedPicker("Height", options: [("Tall", false), ("Short", true)], selection: $draft.tile.short,
                                          wholeLabels: true)
                        .fixedSize()
                        .accessibilityIdentifier("quick.setup.height")
                    }
                }
            } header: { HQSectionLabel { Text("Look") } }
            .hqSheetRows()
            if draft.kind?.isPicture != true { iconAndColor }
        }
    }

    /// The icon grid and the colours (not for a Dashboard tile).
    private var iconAndColor: some View {
        Group {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: HQFont.scaled(44)), spacing: 8)], spacing: 8) {
                    ForEach(QuickTileLook.symbols, id: \.self) { symbol in symbolButton(symbol) }
                }
                .padding(.vertical, 6)
            } header: { HQSectionLabel { Text("Icon") } }
            .hqSheetRows()
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: HQFont.scaled(40)), spacing: 8)], spacing: 8) {
                    ForEach(QuickTileColor.allCases, id: \.self) { color in colorButton(color) }
                }
                .padding(.vertical, 6)
            } header: { HQSectionLabel { Text("Color") } }
            .hqSheetRows()
        }
    }

    private func symbolButton(_ symbol: String) -> some View {
        let chosen = draft.tile.symbol == symbol
        return Button {
            if !chosen { PagesHaptics.selection() }
            draft.tile.symbol = symbol
        } label: {
            Image(systemName: symbol)
                .font(Font.hq(.title3))
                .foregroundStyle(chosen ? Color.white : Color.hqLabel)
                .frame(width: HQFont.scaled(44), height: HQFont.scaled(44))
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(chosen ? Color(uiColor: QuickTileLook.color(draft.tile.tint)) : Color.hqFill3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " "))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("quick.setup.symbol.\(symbol)")
    }

    private func colorButton(_ color: QuickTileColor) -> some View {
        let chosen = draft.tile.tint == color
        return Button {
            if !chosen { PagesHaptics.selection() }
            draft.tile.color = color.rawValue
        } label: {
            Circle()
                .fill(Color(uiColor: QuickTileLook.color(color)))
                .frame(width: HQFont.scaled(32), height: HQFont.scaled(32))
                .padding(3)
                .overlay { if chosen { Circle().stroke(Color.hqLabel, lineWidth: 2) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(QuickTileLook.colorName(color))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("quick.setup.color.\(color.rawValue)")
    }
}
