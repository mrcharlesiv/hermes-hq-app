import UIKit

/// The commands sheet (spec 1x §7.3; S:ui-chat/commands-sheet.tsx), opened by the composer's ☰: the chat's slash
/// commands by section, then Skills, with search. Nothing touches the field or the keyboard until a pick; the sheet
/// closes first, then the pick sends, opens the Models sheet, or goes into the field. A star per row puts the command
/// in Favorites at the top (docs/spec/3x-composer.md §9.7), as the Models sheet does for models.
final class CommandsSheetViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate,
    UISearchResultsUpdating {
    /// A plain controller around the table, so the error and empty states are reachable by VoiceOver (a table
    /// controller's content-unavailable view sits inside the table, which only exposes its rows).
    let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let loader: (_ fresh: Bool) async throws -> CommandsCatalog
    private let onPick: (_ row: SlashCatalog.Row, _ action: SlashCatalog.PickAction) -> Void
    /// This profile's list from an earlier read: shown at once, then replaced by the fresh answer (spec 1x §7.1).
    private let cached: CommandsCatalog?
    /// The bot's own chat: no /title (it keeps its name).
    private let isBotChat: Bool
    private let favorites: CommandFavorites?

    private enum State: Equatable { case loading, failed(String, words: String), loaded }
    private var state: State = .loading
    private var catalog: CommandsCatalog?
    private var all: [SlashCatalog.Section] = []
    private var shown: [SlashCatalog.Section] = []
    private var query = ""
    private var loadTask: Task<Void, Never>?
    private var searchField: UISearchController?

    init(cached: CommandsCatalog? = nil, isBotChat: Bool = false, favorites: CommandFavorites? = nil,
         loader: @escaping (_ fresh: Bool) async throws -> CommandsCatalog,
         onPick: @escaping (_ row: SlashCatalog.Row, _ action: SlashCatalog.PickAction) -> Void) {
        self.cached = cached
        self.isBotChat = isBotChat
        self.favorites = favorites
        self.loader = loader
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func make(cached: CommandsCatalog? = nil, isBotChat: Bool = false, favorites: CommandFavorites? = nil,
                     loader: @escaping (_ fresh: Bool) async throws -> CommandsCatalog,
                     onPick: @escaping (_ row: SlashCatalog.Row, _ action: SlashCatalog.PickAction) -> Void) -> UINavigationController {
        MenusSheet.wrap(CommandsSheetViewController(cached: cached, isBotChat: isBotChat, favorites: favorites, loader: loader, onPick: onPick),
                        title: "Commands", closeWord: .done)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.sheetPage
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.accessibilityIdentifier = "commands.sheet"
        tableView.backgroundColor = HQPalette.sheetPage
        tableView.register(CommandRowCell.self, forCellReuseIdentifier: CommandRowCell.reuse)
        tableView.register(MenusSkeletonCell.self, forCellReuseIdentifier: MenusSkeletonCell.reuse)
        tableView.register(MenusSectionHeader.self, forHeaderFooterViewReuseIdentifier: MenusSectionHeader.reuse)
        tableView.estimatedRowHeight = 64
        tableView.rowHeight = UITableView.automaticDimension
        tableView.keyboardDismissMode = .onDrag
        let search = MenusSheet.searchController(placeholder: "Search Commands", autocorrect: false, delegate: self)
        searchField = search
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .stacked
        load(fresh: false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true { loadTask?.cancel() }
    }

    private func load(fresh: Bool) {
        loadTask?.cancel()
        if !fresh, catalog == nil, let cached {
            show(cached)
        } else if state != .loaded {
            state = .loading
            applyState()
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = try await self.loader(fresh)
                guard !Task.isCancelled else { return }
                self.show(catalog)
            } catch is CancellationError {
                return
            } catch {
                // A list already showing stays (the cached one); only an empty sheet says it failed.
                guard !Task.isCancelled, self.state != .loaded else { return }
                self.state = .failed(MenusError.details(error), words: CommandsLoad.words(for: error))
                self.refilter()
            }
        }
    }

    private func show(_ catalog: CommandsCatalog) {
        self.catalog = catalog
        let sections = SlashCatalog.sections(catalog, isBotChat: isBotChat)
        let changed = state != .loaded || sections != all
        all = sections
        state = .loaded
        if changed { refilter() }
    }

    /// Favorites leads while nothing is searched (a search finds the starred rows in their own sections).
    private func refilter() {
        shown = SlashCatalog.filter(all, query: query)
        if query.isEmpty, !shown.isEmpty, let starred = SlashCatalog.favoritesSection(all, favorites: favorites?.commands ?? []) {
            shown.insert(starred, at: 0)
        }
        applyState()
    }

    static let emptyTitle = "No Commands Available"
    static let emptyText = "Hermes sent no commands or skills for this chat. Skills added on \(HostWord.phrase) show up here."

    private func applyState() {
        switch state {
        case .loading:
            contentUnavailableConfiguration = nil
            tableView.accessibilityLabel = "Loading Commands"
        case .failed(let reason, let words):
            // [glass-design] The sheets' one state: solid actions, never glass on the glass (GlassSheetKit).
            let retry = UIAction(title: "Try Again") { [weak self] _ in self?.load(fresh: true) }
            let details = UIAction(title: "Show Details") { [weak self] _ in
                self?.present(ChatErrorDetailsSheet.make(details: reason), animated: true)
            }
            contentUnavailableConfiguration = PageStates.sheetState(
                symbol: GlassSheetKit.designed ? "exclamationmark.triangle" : nil, title: "Couldn’t Load Commands",
                text: words, actions: [retry, details])
            tableView.accessibilityLabel = nil
        case .loaded:
            tableView.accessibilityLabel = nil
            if shown.isEmpty, query.isEmpty {
                // Mac stress #48: the title alone gave no reason and no way on. Hermes answered with an empty list
                // (no commands, no skills); Try Again reads it fresh.
                // item 10: ⌘ means nothing on an iPhone; it stays only on the Mac, where ⌘ opens Commands.
                // Stress test 2026-10-31: Check Again, as the pages' own (#20): nothing failed here to try again.
                let retry = UIAction(title: "Check Again") { [weak self] _ in self?.load(fresh: true) }
                #if targetEnvironment(macCatalyst)
                contentUnavailableConfiguration = PageStates.sheetState(symbol: "command", title: Self.emptyTitle, text: Self.emptyText,
                                                                        actions: [retry])
                #else
                contentUnavailableConfiguration = PageStates.sheetState(symbol: "slash.circle", title: Self.emptyTitle, text: Self.emptyText,
                                                                        desktopTitleFont: HQFont.preferred(.title3).pagesWeight(.bold),
                                                                        actions: [retry])
                #endif
            } else if shown.isEmpty {
                var config = UIContentUnavailableConfiguration.search().hqScaled()
                config.text = "No Results for “\(query)”"
                contentUnavailableConfiguration = config
            } else {
                contentUnavailableConfiguration = nil
            }
        }
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #71: a search field stood over a list that had nothing in it. It goes while
        // there is nothing to search (the error, an empty answer) and comes back with the rows.
        let searchable = state == .loading || !all.isEmpty
        if (navigationItem.searchController != nil) != searchable { navigationItem.searchController = searchable ? searchField : nil }
        #endif
        tableView.reloadData()
    }

    // MARK: Search

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != query else { return }
        query = text
        refilter()
    }

    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) { MenusSheet.expand(self) }

    // MARK: Table

    func numberOfSections(in tableView: UITableView) -> Int { state == .loading ? 1 : (state == .loaded ? shown.count : 0) }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        state == .loading ? 5 : shown[section].rows.count
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard state == .loaded, section < shown.count else { return nil }
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: MenusSectionHeader.reuse) as? MenusSectionHeader
        header?.configure(shown[section].title)
        return header
    }

    // [glass] Rows keep a solid card while the sheet sits on glass.
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        cell.hqSolidOnGlass()
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if state == .loading {
            let cell = tableView.dequeueReusableCell(withIdentifier: MenusSkeletonCell.reuse, for: indexPath) as! MenusSkeletonCell
            cell.configure(fraction: [0.45, 0.57, 0.69, 0.45, 0.57][indexPath.row % 5])
            return cell
        }
        let section = shown[indexPath.section]
        let row = section.rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: CommandRowCell.reuse, for: indexPath) as! CommandRowCell
        cell.configure(row, favorite: favorites?.contains(row.command), inFavorites: indexPath.section == 0 && isFavoritesSection(section))
        cell.onStar = { [weak self, weak cell] in
            guard let self, let cell else { return }
            self.toggleStar(row, from: cell, section: section.title)
        }
        return cell
    }

    private func isFavoritesSection(_ section: SlashCatalog.Section) -> Bool {
        section.title == SlashCatalog.favoritesTitle && shown.first == section && query.isEmpty && favorites != nil
    }

    /// Stars or unstars without picking. The tapped row stays where it was on screen while Favorites grows or shrinks
    /// above it (the Models sheet's way).
    private func toggleStar(_ row: SlashCatalog.Row, from cell: UITableViewCell, section title: String) {
        guard let favorites else { return }
        Haptics.play(.selection)
        let before = cell.convert(cell.bounds, to: nil).minY
        favorites.toggle(row.command)
        refilter()
        // Unstarred in Favorites, the row leaves it: nothing to hold.
        guard let s = shown.firstIndex(where: { $0.title == title }), let r = shown[s].rows.firstIndex(of: row) else { return }
        tableView.hqHoldRow(at: IndexPath(row: r, section: s), onScreenAt: before)
    }

    #if DEBUG
    /// The on-screen top of a command's row in a section (UI checks hold the starred row in place).
    func debugRowTop(_ command: String, section title: String) -> CGFloat? {
        guard let s = shown.firstIndex(where: { $0.title == title }),
              let r = shown[s].rows.firstIndex(where: { $0.command == command }) else { return nil }
        return tableView.convert(tableView.rectForRow(at: IndexPath(row: r, section: s)), to: nil).minY
    }
    #endif

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool { state == .loaded }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard state == .loaded, indexPath.section < shown.count else { return }
        let row = shown[indexPath.section].rows[indexPath.row]
        let action = SlashCatalog.pickAction(row, catalog: catalog)
        let pick = onPick
        // The sheet closes first in every case; no haptic (owner: command picks stay silent).
        MenusSheet.close(self) { pick(row, action) }
    }
}

/// A command row: the command in Body semibold, its description in Subheadline label-2 under it (wraps), 12 pt above and
/// below (owner: wrapping rows get real padding), and a 44 pt star button 6 pt from the trailing edge (the Models
/// sheet's row).
final class CommandRowCell: UITableViewCell {
    static let reuse = "commands.row"
    var onStar: (() -> Void)?

    private let title = UILabel()
    private let detail = UILabel()
    private let star = UIButton(type: .system)
    private var starred = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        title.font = .menusFont(.body, weight: .semibold)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        detail.font = HQFont.preferred(.subheadline)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = ChatPalette.label2
        detail.numberOfLines = 0
        detail.isAccessibilityElement = false
        let labels = UIStackView(arrangedSubviews: [title, detail])
        labels.axis = .vertical
        labels.spacing = 2
        star.addAction(UIAction { [weak self] _ in self?.onStar?() }, for: .primaryActionTriggered)
        for v in [labels, star] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }
        NSLayoutConstraint.activate([
            labels.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            labels.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            labels.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            labels.trailingAnchor.constraint(equalTo: star.leadingAnchor, constant: -4),
            star.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            star.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            star.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            star.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            star.heightAnchor.constraint(lessThanOrEqualTo: contentView.heightAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        star.setContentHuggingPriority(.required, for: .horizontal)
        star.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `favorite`: nil hides the star (no store to keep it in). `inFavorites`: the row in the Favorites section.
    func configure(_ row: SlashCatalog.Row, favorite: Bool?, inFavorites: Bool = false) {
        backgroundConfiguration = defaultBackgroundConfiguration()   // its own card each time, as ModelRowCell
        title.text = row.command
        detail.text = row.description
        detail.isHidden = row.description.isEmpty
        star.isHidden = favorite == nil
        starred = favorite ?? false
        // Body-sized, so it grows with Dynamic Type (the 44 pt button stays the touch target).
        star.setImage(UIImage(systemName: starred ? "star.fill" : "star",
                              withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .medium)), for: .normal)
        star.tintColor = starred ? ChatPalette.tint : ChatPalette.label3   // the theme's colour, as ModelRowCell
        star.accessibilityLabel = "Favorite \(row.command)"
        star.accessibilityTraits = starred ? [.button, .selected] : .button
        star.accessibilityIdentifier = "commands.star.\(inFavorites ? "fav." : "")\(row.command)"
        // The row reads as one button ("/status, Show session status"); the star is its own.
        isAccessibilityElement = false
        title.accessibilityLabel = row.description.isEmpty ? row.command : "\(row.command), \(row.description)"
        title.accessibilityTraits = .button
        accessibilityIdentifier = "commands.row.\(inFavorites ? "fav." : "")\(row.command)"
    }
}
