import UIKit

/// More Models… (spec 1x §6; S:ui-chat/model-sheet.tsx): the catalog by provider, Favorites first, search, a star per
/// row that keeps its row under the finger, the current model checked. A pick closes the sheet, then switches.
/// A provider's heading folds its section (tester 2026-11-09), as the Chats list's headings do; its hold
/// menu folds or opens them all. Folds are kept per account; a search shows every match, folded or not.
final class ModelSheetViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate,
    UISearchResultsUpdating {
    /// A plain controller around the table, so the error and empty states are reachable by VoiceOver (a table
    /// controller's content-unavailable view sits inside the table, which only exposes its rows).
    let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let context: ModelMenuContext
    private let onPick: (ModelChoice) -> Void
    private var initialQuery: String?
    /// [model-scope] What a pick changes, under the search field (`ModelPanelModel.switchScope`).
    private let scope: String

    /// `failed`: the details Show Details opens, and the line under the title (`ModelLoad.words`; nil = title alone).
    private enum State: Equatable { case loading, failed(String, words: String?), loaded }
    private var state: State = .loading
    private var models: [ModelChoice] = []
    private var sections: [ModelSection] = []
    private var query = ""
    /// The provider slugs folded to their heading (`ModelPrefs.foldedProviders`).
    private lazy var folded = context.prefs.foldedProviders
    private var loadTask: Task<Void, Never>?
    private var positioned = false
    /// The sheet follows the connection while it is up (the web's `context.watch`): offline rows disable, stars stay.
    private var offlineWatch: Timer?
    private var shownOffline = false
    /// The width the status header was last sized at.
    private var headerWidth: CGFloat = 0
    /// [model-facts] Each row's context and price (`ModelPanelModel.rowFact`), worked out as its row first shows (the
    /// list prices are a large table) and kept until the catalog is read again. A model with neither keeps an empty entry.
    private var facts: [String: (text: String, spoken: String)?] = [:]
    private lazy var listedPrices = ModelsDevCache.shared.stored()
    private var anyPriceShown = false
    private let footNote = UILabel()
    private var footerWidth: CGFloat = 0

    private func fact(for model: ModelChoice) -> (text: String, spoken: String)? {
        if let known = facts[model.key] { return known }
        let found = ModelPanelModel.rowFact(model, options: context.options, listed: listedPrices)
        facts[model.key] = found
        if let found, found.text.contains("$"), !anyPriceShown {
            anyPriceShown = true
            DispatchQueue.main.async { [weak self] in self?.updateFootNote() }
        }
        return found
    }
    private lazy var refreshItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), primaryAction: UIAction { [weak self] _ in
            self?.load(refresh: true)
        })
        item.accessibilityLabel = "Refresh Models"
        item.accessibilityIdentifier = "models.refresh"
        return item
    }()

    init(context: ModelMenuContext, query: String?, bot: String? = nil, onPick: @escaping (ModelChoice) -> Void) {
        self.context = context
        self.initialQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scope = ModelPanelModel.switchScope(bot: bot)
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `bot`: the chat's bot's name, for where its own default is changed.
    static func make(context: ModelMenuContext, query: String? = nil, bot: String? = nil, onPick: @escaping (ModelChoice) -> Void) -> UINavigationController {
        MenusSheet.wrap(ModelSheetViewController(context: context, query: query, bot: bot, onPick: onPick), title: "Models")
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
        view.accessibilityIdentifier = "models.sheet"
        tableView.backgroundColor = HQPalette.sheetPage
        tableView.register(ModelRowCell.self, forCellReuseIdentifier: ModelRowCell.reuse)
        tableView.register(MenusSkeletonCell.self, forCellReuseIdentifier: MenusSkeletonCell.reuse)
        tableView.register(MenusSectionHeader.self, forHeaderFooterViewReuseIdentifier: MenusSectionHeader.reuse)
        tableView.register(ModelProviderHeader.self, forHeaderFooterViewReuseIdentifier: ModelProviderHeader.reuse)
        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.keyboardDismissMode = .onDrag
        navigationItem.rightBarButtonItem = refreshItem
        let search = MenusSheet.searchController(placeholder: "Search Models", autocorrect: true, delegate: self)
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .stacked
        if let initialQuery, !initialQuery.isEmpty {
            search.searchBar.text = initialQuery
            query = initialQuery
        }
        updateOfflineHeader()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (sheet: ModelSheetViewController, _) in
            sheet.view.layoutIfNeeded()
            sheet.sizeHeader()
        }
        // The cached catalog paints at once (a second open shows rows instantly); a stale one is read again.
        if context.hasCatalog {
            models = context.models()
            state = .loaded
            rebuild()
        }
        load(refresh: false)
        // [model-facts] The list prices (models.dev, a day's copy on the phone) are read here too: until now only the
        // model panel and Model Prices asked for them, so a first open of this sheet had none to show.
        if listedPrices == nil {
            Task { [weak self] in
                guard let fresh = await ModelsDevCache.shared.load(), let self else { return }
                self.listedPrices = fresh
                self.facts = [:]
                if self.state == .loaded { self.tableView.reloadData() }
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let initialQuery, !initialQuery.isEmpty { MenusSheet.expand(self) }
        shownOffline = context.offline
        offlineWatch?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.connectionChanged() } }
        RunLoop.main.add(timer, forMode: .common)
        offlineWatch = timer
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        offlineWatch?.invalidate()
        offlineWatch = nil
        if isBeingDismissed || navigationController?.isBeingDismissed == true { loadTask?.cancel() }
    }

    private func connectionChanged() {
        let offline = context.offline
        guard offline != shownOffline else { return }
        shownOffline = offline
        updateOfflineHeader()
        tableView.reloadData()
    }

    // MARK: Loading

    private func load(refresh: Bool) {
        loadTask?.cancel()
        if models.isEmpty || refresh {
            if models.isEmpty { state = .loading }
            applyState()
        }
        updateOfflineHeader()
        refreshItem.isEnabled = false
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let rows = try await self.context.load(refresh: refresh)
                guard !Task.isCancelled else { return }
                self.models = rows
                self.facts = [:]   // [model-facts] prices may have come with this read
                self.state = .loaded
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // With rows already shown, a failed refresh keeps them.
                // [m9/composer] The failure shows only after the second try (`ModelMenuContext.load`), in words.
                if self.models.isEmpty {
                    self.state = .failed(MenusError.details(error), words: ModelLoad.words(for: error, offline: self.context.offline))
                }
            }
            self.refreshItem.isEnabled = !self.context.offline
            self.updateOfflineHeader()
            self.rebuild()
        }
    }

    private func updateOfflineHeader() {
        refreshItem.isEnabled = state != .loading && !context.offline
        // [m9/composer] While the list is being read (both tries) the sheet says so above its placeholder rows. Offline
        // says why the rows are greyed; the scope line says what a pick changes.
        let words = context.offline ? Self.offlineWords : state == .loading ? ModelLoad.loadingWords : nil
        let lines = UIStackView()
        lines.axis = .vertical
        lines.spacing = 2
        if let words { lines.addArrangedSubview(Self.headerLabel(words, id: "models.status")) }
        // [model-facts] Owner 2026-11-10: the scope line sits at the list's foot, so the models start right under the
        // search field. With no list to stand under (loading, a failure, a search) it keeps its old place here.
        if !showsFoot { lines.addArrangedSubview(Self.headerLabel(scope, id: "models.scope")) }
        guard !lines.arrangedSubviews.isEmpty else {
            tableView.tableHeaderView = nil
            return
        }
        lines.translatesAutoresizingMaskIntoConstraints = false
        let header = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 28))
        header.addSubview(lines)
        NSLayoutConstraint.activate([
            lines.topAnchor.constraint(equalTo: header.topAnchor, constant: 4),
            lines.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6),
            lines.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            lines.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
        ])
        tableView.tableHeaderView = header
        sizeHeader()
    }

    static let offlineWords = "You’re offline. Models can be changed when you reconnect."

    private static func headerLabel(_ text: String, id: String) -> UILabel {
        let label = UILabel()
        label.accessibilityIdentifier = id
        label.text = text
        label.font = HQFont.preferred(.footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = HQPalette.label2
        label.numberOfLines = 0
        label.accessibilityTraits = .staticText
        return label
    }

    /// The header is as tall as its lines at the table's width (they wrap at the largest text sizes).
    private func sizeHeader() {
        guard let header = tableView.tableHeaderView else { return }
        headerWidth = tableView.bounds.width
        let fitted = header.systemLayoutSizeFitting(CGSize(width: headerWidth, height: UIView.layoutFittingCompressedSize.height),
                                                    withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        header.frame = CGRect(x: 0, y: 0, width: headerWidth, height: ceil(fitted.height))
        tableView.tableHeaderView = header
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if tableView.tableHeaderView != nil, abs(tableView.bounds.width - headerWidth) > 0.5 { sizeHeader() }
        if tableView.tableFooterView != nil, abs(tableView.bounds.width - footerWidth) > 0.5 { sizeFooter() }
        if abs(rowWidth - laidOutRowWidth) > 0.5 {
            let first = laidOutRowWidth == 0
            laidOutRowWidth = rowWidth
            if !first, state == .loaded { tableView.reloadData() }   // a new width: which rows stack their fact may change
        }
    }

    /// A row's width as the table lays it out (the inset list's margins off each side): a row whose name and fact
    /// don't fit side by side puts the fact under the name.
    private var rowWidth: CGFloat { tableView.bounds.width - tableView.layoutMargins.left - tableView.layoutMargins.right }
    private var laidOutRowWidth: CGFloat = 0

    /// The list's foot is up: models are listed and nothing is being searched for.
    private var showsFoot: Bool { state == .loaded && !sections.isEmpty && query.isEmpty }

    private func updateFootNote() {
        footNote.text = anyPriceShown ? scope + "\n" + ModelPanelModel.rowFactLegend : scope
        if tableView.tableFooterView != nil { sizeFooter() }
    }

    private func sizeFooter() {
        guard let footer = tableView.tableFooterView else { return }
        footerWidth = tableView.bounds.width
        let fitted = footer.systemLayoutSizeFitting(CGSize(width: footerWidth, height: UIView.layoutFittingCompressedSize.height),
                                                    withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        footer.frame = CGRect(x: 0, y: 0, width: footerWidth, height: ceil(fitted.height))
        tableView.tableFooterView = footer
    }

    // MARK: Sections

    private var favorites: [ModelChoice] {
        guard query.isEmpty else { return [] }
        return ModelSheetModel.favoriteRows(models, keys: context.prefs.favorites)
    }

    private func rebuild() {
        let current = context.current()
        var out = ModelSheetModel.sections(models, query: query, current: (current.id, current.provider))
        if !out.isEmpty, !favorites.isEmpty { out.insert(ModelSection(provider: "", title: "Favorites", models: favorites), at: 0) }
        sections = out
        applyState()
    }

    private func applyState() {
        switch state {
        case .loading:
            contentUnavailableConfiguration = nil
            tableView.accessibilityLabel = "Loading Models"
        case .failed(let reason, let words):
            // [glass-design] The sheets' one state: solid actions, never glass on the glass (GlassSheetKit).
            let retry = UIAction(title: "Try Again") { [weak self] _ in self?.load(refresh: true) }
            let details = UIAction(title: "Show Details") { [weak self] _ in
                self?.present(ChatErrorDetailsSheet.make(details: reason), animated: true)
            }
            contentUnavailableConfiguration = PageStates.sheetState(
                symbol: GlassSheetKit.designed ? "exclamationmark.triangle" : nil, title: ModelLoad.failureTitle, text: words,
                actions: [retry, details])
            tableView.accessibilityLabel = nil
        case .loaded:
            tableView.accessibilityLabel = nil
            if sections.isEmpty {
                // A search that found nothing reads like the system's own search (magnifier, spelling hint).
                if query.isEmpty {
                    // [glass-design] The sheets' one empty state (GlassSheetKit); off the iOS look, the title alone as before.
                    contentUnavailableConfiguration = PageStates.sheetState(
                        symbol: GlassSheetKit.designed ? "cpu" : nil, title: "No Models Available",
                        // Check Again, as the Commands sheet's empty list: nothing failed here to try again.
                        text: GlassSheetKit.designed ? "Hermes sent no models for this chat. Check Again asks it once more." : nil,
                        actions: GlassSheetKit.designed ? [UIAction(title: "Check Again") { [weak self] _ in self?.load(refresh: true) },
                                                           addProviderAction] : [])
                } else {
                    var config = UIContentUnavailableConfiguration.search().hqScaled()
                    config.text = "No Results for “\(query)”"
                    contentUnavailableConfiguration = config
                }
            } else {
                contentUnavailableConfiguration = nil
            }
        }
        // [provider-add] Under the last provider's models (not while searching): Add Provider….
        let hadFoot = tableView.tableFooterView != nil
        tableView.tableFooterView = showsFoot ? addProviderFooter : nil
        if showsFoot { updateFootNote() }
        if hadFoot != showsFoot { updateOfflineHeader() }   // the scope line moves between the head and the foot
        tableView.reloadData()
        positionOnce()
    }

    /// [provider-add] Owner 2026-11-04 ("more easily add them"): the list closes and Settings › Providers opens with
    /// Add Provider over it; a provider added there is in this list the next time it opens.
    private lazy var addProviderAction = UIAction(title: "Add Provider…", image: UIImage(systemName: "plus")) { [weak self] _ in
        self?.openAddProvider()
    }

    private lazy var addProviderFooter: UIView = {
        var config = UIButton.Configuration.plain()
        config.title = "Add Provider…"
        config.image = UIImage(systemName: "plus")
        config.imagePadding = 8
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = HQFont.preferred(.body)
            return attributes
        }
        let button = UIButton(configuration: config, primaryAction: addProviderAction)
        button.contentHorizontalAlignment = .leading
        button.accessibilityIdentifier = "models.add-provider"
        // [model-facts] Under Add Provider…, the scope line (and what the prices are, once a row shows one).
        footNote.accessibilityIdentifier = "models.scope"
        footNote.font = HQFont.preferred(.footnote)
        footNote.adjustsFontForContentSizeCategory = true
        footNote.textColor = HQPalette.label2
        footNote.numberOfLines = 0
        footNote.text = scope
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 96))
        for v in [button, footNote] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(v)
        }
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: footer.topAnchor),
            button.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            footNote.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 2),
            footNote.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 20),
            footNote.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -20),
            footNote.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -16),
        ])
        return footer
    }()

    private func openAddProvider() {
        let presenter = navigationController?.presentingViewController
        AppLog.note("chatui", "models: add provider")
        dismiss(animated: true) {
            guard let presenter else { return }
            ProviderAdd.openFromChat(from: presenter)
        }
    }

    /// With favourites the list opens at its top; without, the current model's provider section starts at the top
    /// when the current row isn't fully visible (spec 1x §6 "Opening position").
    private func positionOnce() {
        guard !positioned, state == .loaded, !sections.isEmpty, query.isEmpty else { return }
        positioned = true
        guard favorites.isEmpty else { return }
        let current = context.current()
        guard let s = sections.firstIndex(where: { $0.models.contains { $0.id == current.id && $0.provider == current.provider } }),
              !isFolded(s),
              let r = sections[s].models.firstIndex(where: { $0.id == current.id && $0.provider == current.provider }) else { return }
        tableView.layoutIfNeeded()
        let row = tableView.rectForRow(at: IndexPath(row: r, section: s))
        let visibleTop = tableView.contentOffset.y + tableView.adjustedContentInset.top
        let visibleHeight = tableView.bounds.height - tableView.adjustedContentInset.top - tableView.adjustedContentInset.bottom
        if row.minY >= visibleTop && row.maxY <= visibleTop + visibleHeight { return }
        let header = tableView.rectForHeader(inSection: s)
        let maxOffset = max(0, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
        tableView.contentOffset.y = min(maxOffset, header.minY - tableView.adjustedContentInset.top)
    }

    // MARK: Search

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != query else { return }
        query = text
        rebuild()
    }

    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) { MenusSheet.expand(self) }

    // MARK: Table

    func numberOfSections(in tableView: UITableView) -> Int { state == .loading ? 1 : sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        state == .loading ? 5 : isFolded(section) ? 0 : sections[section].models.count
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard state != .loading, section < sections.count else { return nil }
        let provider = sections[section].provider
        // Favorites, and every heading while searching, stay plain: nothing to fold there.
        guard !provider.isEmpty, query.isEmpty else {
            let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: MenusSectionHeader.reuse) as? MenusSectionHeader
            header?.configure(sections[section].title)
            return header
        }
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: ModelProviderHeader.reuse) as? ModelProviderHeader
        configure(header, section: section)
        return header
    }

    /// A folded section keeps no gap under its heading: the headings stack like a list.
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        isFolded(section) ? .leastNormalMagnitude : UITableView.automaticDimension
    }

    private func configure(_ header: ModelProviderHeader?, section: Int) {
        guard let header else { return }
        let provider = sections[section].provider
        let foldable = sections.filter { !$0.provider.isEmpty }.map(\.provider)
        header.configure(sections[section].title, provider: provider, count: sections[section].models.count,
                         folded: folded.contains(provider), afterFold: section > 0 && isFolded(section - 1),
                         canFoldAll: foldable.contains { !folded.contains($0) }, canOpenAll: foldable.contains { folded.contains($0) })
        header.onToggle = { [weak self] in self?.toggleFold(provider) }
        header.onAll = { [weak self] fold in self?.setAllFolded(fold) }
    }

    // MARK: Folding

    /// A provider's section shows its heading alone (never while searching, never Favorites).
    private func isFolded(_ section: Int) -> Bool {
        query.isEmpty && section < sections.count && !sections[section].provider.isEmpty && folded.contains(sections[section].provider)
    }

    private func toggleFold(_ provider: String) {
        Haptics.play(.selection)
        var next = folded
        if !next.insert(provider).inserted { next.remove(provider) }
        applyFolds(next)
    }

    private func setAllFolded(_ fold: Bool) {
        let providers = Set(sections.map(\.provider).filter { !$0.isEmpty })
        applyFolds(fold ? folded.union(providers) : folded.subtracting(providers))
    }

    /// Folds or opens the sections that changed in place, the headings staying put.
    private func applyFolds(_ next: Set<String>) {
        let changed = sections.indices.filter { !sections[$0].provider.isEmpty && folded.contains(sections[$0].provider) != next.contains(sections[$0].provider) }
        folded = next
        context.prefs.setFoldedProviders(next)
        AppLog.note("chatui", "models: \(next.count) provider(s) folded")
        guard state == .loaded, query.isEmpty, !changed.isEmpty else { return }
        tableView.performBatchUpdates {
            for s in changed {
                let rows = (0..<sections[s].models.count).map { IndexPath(row: $0, section: s) }
                if folded.contains(sections[s].provider) { tableView.deleteRows(at: rows, with: .fade) } else { tableView.insertRows(at: rows, with: .fade) }
            }
        }
        for s in sections.indices { configure(tableView.headerView(forSection: s) as? ModelProviderHeader, section: s) }
    }

    // [glass] Rows keep a solid card while the sheet sits on glass.
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        cell.hqSolidOnGlass()
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if state == .loading {
            let cell = tableView.dequeueReusableCell(withIdentifier: MenusSkeletonCell.reuse, for: indexPath) as! MenusSkeletonCell
            cell.configure(fraction: [0.55, 0.67, 0.79, 0.55, 0.67][indexPath.row % 5])
            return cell
        }
        let section = sections[indexPath.section]
        let model = section.models[indexPath.row]
        let current = context.current()
        let cell = tableView.dequeueReusableCell(withIdentifier: ModelRowCell.reuse, for: indexPath) as! ModelRowCell
        cell.configure(model, subtitle: section.provider.isEmpty ? (model.providerName ?? model.provider) : nil,
                       fact: fact(for: model), rowWidth: rowWidth,
                       selected: model.id == current.id && model.provider == current.provider,
                       favorite: context.prefs.isFavorite(model), offline: context.offline)
        cell.onStar = { [weak self, weak cell] in
            guard let self, let cell else { return }
            self.toggleStar(model, from: cell, section: section.provider)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        state == .loaded && !context.offline
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard state == .loaded, !context.offline, indexPath.section < sections.count else { return }
        let model = sections[indexPath.section].models[indexPath.row]
        let pick = onPick
        MenusSheet.close(self) { pick(model) }
    }

    /// Stars or unstars without picking (works offline: favourites live on this phone). The tapped row stays where it
    /// was on screen while Favorites grows or shrinks above it.
    private func toggleStar(_ model: ModelChoice, from cell: UITableViewCell, section provider: String) {
        Haptics.play(.selection)
        let before = cell.convert(cell.bounds, to: nil).minY
        context.prefs.toggleFavorite(provider: model.provider, model: model.id)
        rebuild()
        tableView.layoutIfNeeded()
        guard let s = sections.firstIndex(where: { $0.provider == provider }),
              let r = sections[s].models.firstIndex(where: { $0.key == model.key }) else { return }
        tableView.hqHoldRow(at: IndexPath(row: r, section: s), onScreenAt: before)
    }

    #if DEBUG
    /// The on-screen top of a model's row in a section (UI checks hold the starred row in place).
    func debugRowTop(_ key: String, provider: String) -> CGFloat? {
        guard let s = sections.firstIndex(where: { $0.provider == provider }),
              let r = sections[s].models.firstIndex(where: { $0.key == key }) else { return nil }
        return tableView.convert(tableView.rectForRow(at: IndexPath(row: r, section: s)), to: nil).minY
    }
    #endif
}

/// A provider's heading in the Models sheet: its name with the Chats list's caret after it (down while open, right
/// while folded) and, folded, how many models it holds. A tap folds or opens it; the hold menu does all of them.
final class ModelProviderHeader: UITableViewHeaderFooterView, UIContextMenuInteractionDelegate {
    static let reuse = "models.provider"
    var onToggle: (() -> Void)?
    /// true: fold every provider; false: open them all.
    var onAll: ((Bool) -> Void)?
    private var canFoldAll = false
    private var canOpenAll = false

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addInteraction(UIContextMenuInteraction(delegate: self))
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `afterFold`: the heading above is folded too, so this one sits close under it.
    func configure(_ title: String, provider: String, count: Int, folded: Bool, afterFold: Bool, canFoldAll: Bool, canOpenAll: Bool) {
        self.canFoldAll = canFoldAll
        self.canOpenAll = canOpenAll
        // MenusSectionHeader's type and grey, drawn as attributed words for the count and caret.
        var content = UIListContentConfiguration.header().hqScaled()
        content.textProperties.transform = .none
        let font = DeviceWord.isMac && !Theme.isDesktop ? MacType.sectionHeader : HQFont.preferred(.footnote)
        let words = NSMutableAttributedString(string: title, attributes: [.font: font, .foregroundColor: ChatPalette.label2])
        if folded {
            words.append(NSAttributedString(string: "  \(count)", attributes: [.font: font, .foregroundColor: ChatPalette.label3]))
        }
        let caret = UIImage(systemName: folded ? "chevron.forward" : "chevron.down",
                            withConfiguration: UIImage.SymbolConfiguration(font: HQFont.system(ofSize: font.pointSize * 0.7, weight: .semibold)))
        if let caret {
            words.append(NSAttributedString(string: "  "))
            words.append(NSAttributedString(attachment: NSTextAttachment(image: caret.withTintColor(ChatPalette.label3, renderingMode: .alwaysOriginal))))
        }
        content.attributedText = words
        // Folded, the heading sits close to the next one (no card under it to clear).
        if folded { content.directionalLayoutMargins.bottom = min(content.directionalLayoutMargins.bottom, 4) }
        if afterFold { content.directionalLayoutMargins.top = min(content.directionalLayoutMargins.top, 4) }
        contentConfiguration = content
        accessibilityIdentifier = "models.provider.\(provider)"
        accessibilityLabel = title
        accessibilityValue = folded ? "Collapsed, \(count) model\(count == 1 ? "" : "s")" : "Expanded"
        accessibilityTraits = [.header, .button]
        accessibilityHint = "Double tap to \(folded ? "show" : "hide") this provider’s models."
        var actions: [UIAccessibilityCustomAction] = []
        if canFoldAll { actions.append(UIAccessibilityCustomAction(name: "Collapse All") { [weak self] _ in self?.onAll?(true); return true }) }
        if canOpenAll { actions.append(UIAccessibilityCustomAction(name: "Expand All") { [weak self] _ in self?.onAll?(false); return true }) }
        accessibilityCustomActions = actions
    }

    @objc private func tapped() { onToggle?() }

    override func accessibilityActivate() -> Bool {
        onToggle?()
        return true
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard canFoldAll || canOpenAll else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var items: [UIMenuElement] = []
            if self?.canFoldAll == true {
                items.append(UIAction(title: "Collapse All", image: UIImage(systemName: "rectangle.compress.vertical")) { [weak self] _ in self?.onAll?(true) })
            }
            if self?.canOpenAll == true {
                items.append(UIAction(title: "Expand All", image: UIImage(systemName: "rectangle.expand.vertical")) { [weak self] _ in self?.onAll?(false) })
            }
            return UIMenu(children: items)
        }
    }
}

/// A model row: its name (Body) with the provider under it in Favorites, and a 44 pt star button 6 pt from the
/// trailing edge.
/// [model-facts] Owner 2026-11-10 (design pick 3): the current model's checkmark has a column of its own at the leading
/// edge and its name is semibold (beside the star the two marks read as a pair); the row's context and price stand
/// before the star in Footnote label-2 ("1M · $5 / $25"); and a one-line row is 40 pt, not 46. At the accessibility
/// text sizes the fact joins the line under the name, so the name keeps the row's width.
final class ModelRowCell: UITableViewCell {
    static let reuse = "models.row"
    var onStar: (() -> Void)?

    private let title = UILabel()
    private let subtitle = UILabel()
    private let fact = UILabel()
    private let check = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .medium)))
    private let star = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        title.font = HQFont.preferred(.body)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        subtitle.font = HQFont.preferred(.footnote)
        subtitle.adjustsFontForContentSizeCategory = true
        subtitle.textColor = ChatPalette.label2
        subtitle.numberOfLines = 0
        let labels = UIStackView(arrangedSubviews: [title, subtitle])
        labels.axis = .vertical
        labels.spacing = 2
        check.tintColor = ChatPalette.tint
        check.setContentHuggingPriority(.required, for: .horizontal)
        check.setContentCompressionResistancePriority(.required, for: .horizontal)
        check.isAccessibilityElement = false
        fact.font = HQFont.preferred(.footnote)
        fact.adjustsFontForContentSizeCategory = true
        fact.textColor = ChatPalette.label2
        fact.isAccessibilityElement = false
        fact.setContentHuggingPriority(.required, for: .horizontal)
        fact.setContentCompressionResistancePriority(.required, for: .horizontal)
        star.addAction(UIAction { [weak self] _ in self?.onStar?() }, for: .primaryActionTriggered)
        for v in [labels, check, fact, star] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }
        // 9 pt top and bottom: a one-line row is 40 pt, and titles still wrap at the larger text sizes.
        NSLayoutConstraint.activate([
            labels.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 9),
            labels.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -9),
            check.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor, constant: -4),
            check.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: Self.checkColumn),
            labels.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 6),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: fact.leadingAnchor, constant: -10),
            fact.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            fact.trailingAnchor.constraint(equalTo: star.leadingAnchor, constant: -2),
            star.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            star.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            star.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            // The star keeps its 44 pt reach in a 40 pt row: it may stand 2 pt past the row above and below.
            star.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        check.contentMode = .center
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The checkmark's column: every name starts at the same place, checked or not.
    static let checkColumn: CGFloat = 20

    /// What a row's fixed parts take of its width: the margins, the checkmark's column, the gaps and the star.
    static let rowChrome: CGFloat = 108

    func configure(_ model: ModelChoice, subtitle provider: String?, fact found: (text: String, spoken: String)? = nil,
                   rowWidth: CGFloat = 0, selected: Bool, favorite: Bool, offline: Bool) {
        title.font = selected ? HQFont.preferred(.headline) : HQFont.preferred(.body)
        title.text = model.name
        fact.text = found?.text
        // The fact stands beside the name only when both fit on one line; otherwise (a long name, the larger text
        // sizes) it joins the line under the name, so a name never wraps to make room for its price.
        let beside = found != nil && !traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            && (rowWidth <= 0 || title.intrinsicContentSize.width + fact.intrinsicContentSize.width + Self.rowChrome <= rowWidth)
        let text = beside ? provider : [provider, found?.text].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        if !beside { fact.text = nil }
        fact.isHidden = !beside
        title.textColor = offline ? ChatPalette.label2 : ChatPalette.label
        // The row draws its own card each time (tester 2026-10-26: some rows showed the page through them
        // after the list reloaded; never reproduced). Left to the table, a reused row can come back without one.
        backgroundConfiguration = defaultBackgroundConfiguration()
        subtitle.text = text
        subtitle.isHidden = text == nil
        check.isHidden = !selected
        let symbol = favorite ? "star.fill" : "star"
        // Body-sized, so it grows with Dynamic Type (the 44 pt button stays the touch target).
        star.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .medium)), for: .normal)
        // The theme's own colour, not a copy of the row's tint: a row built before it is on screen copied iOS's blue.
        star.tintColor = favorite ? ChatPalette.tint : ChatPalette.label3
        star.accessibilityLabel = "Favorite \(model.name)"
        star.accessibilityTraits = favorite ? [.button, .selected] : .button
        star.accessibilityIdentifier = "models.star.\(model.provider)::\(model.id)"
        selectionStyle = offline ? .none : .default
        isAccessibilityElement = false
        title.accessibilityTraits = selected ? [.button, .selected] : .button
        accessibilityIdentifier = "models.row.\(model.provider)::\(model.id)"
        title.accessibilityLabel = model.name + (provider.map { ", \($0)" } ?? "") + (found.map { ", \($0.spoken)" } ?? "")
        title.accessibilityValue = selected ? "Current" : nil
    }
}
