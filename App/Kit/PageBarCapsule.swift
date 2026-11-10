// A list page's actions as ONE trailing glass capsule in the navigation bar, as the web's roster bar draws them
// (`S/ui-bots/roster-bar.tsx`, `S/ui-nav/bar-items.tsx`): [Filter] [Search] [Compose]. iOS 26 groups adjacent
// trailing bar items into one shared Liquid Glass capsule, so the capsule is just those items, in that order.
//
// Search folds away (`S/ui-nav/page-search.ts`): the page has no field until the magnifier is tapped; the field
// then shows (a native `UISearchController` on the page's navigation item) with the keyboard up, and folds away
// again when it is cancelled or left empty. A typed query stays across tab changes (`S/ui-nav/search-mode.ts`);
// the magnifier shows "on" while one is typed.
//
// Used by the Bots and Sessions pages, whose Filter is the same control (`BarItemButton`), so it does not move between
// the two.

import UIKit

@MainActor final class PageBarCapsule: NSObject, UISearchControllerDelegate, UISearchBarDelegate {
    /// What the compose button does: a plain action, or a pull-down (Bots' +: New Bot / Group Chat / Section).
    enum Compose {
        case action(() -> Void)
        case menu(() -> [UIMenuElement])
    }

    struct Configuration {
        /// The page's name, for identifiers ("sessions" → `sessions.filter`, `sessions.search`, `sessions.compose`).
        var page: String
        /// Filter's menu, read when it opens; nil: no Filter button.
        var filterMenu: (() -> [UIMenuElement])?
        /// The search controller the magnifier unfolds; nil: no Search button.
        var search: UISearchController?
        var compose: Compose?
        var composeLabel = "New Chat"
        /// [bots-plus] The pencil only ever means a new chat (Sessions); a page whose button makes something else passes
        /// "plus" (Bots, Webhooks). Owner 2026-11-03, menu review #3.
        var composeSymbol = "square.and.pencil"
        // [sessions-m9] The Filter button's own words (Sessions: "Filter and Sort"). Its menu can be redrawn while it is
        // open (docs/spec/3x-sessions.md §5.4): the button is a real UIButton in the same capsule, whose
        // `contextMenuInteraction` takes `updateVisibleMenu`. Bots has the same button, so the two pages' Filters sit in
        // the same place (owner 2026-10-24: Bots' plain bar item sat 2.7 pt left of Sessions' button).
        var filterLabel = "Filter"
        // [/sessions-m9]
    }

    private weak var host: UIViewController?
    private let configuration: Configuration
    private(set) var filterItem: UIBarButtonItem?
    private(set) var searchItem: UIBarButtonItem?
    private(set) var composeItem: UIBarButtonItem?
    private var filterActive = false
    /// [sessions-m9] The Filter control (`filterItem`'s view).
    private(set) var filterButton: UIButton?
    static let filterMenuIdentifier = UIMenu.Identifier("page.filter.root")
    /// What iOS 26's bar gives its own items' glyphs (body, medium, large: read off `_UIModernBarButton`'s image view).
    /// A plain UIButton in the bar draws regular weight without it, so Sessions' Filter read thinner than Bots' (owner
    /// 2026-10-24). The bar holds its items at this size whatever the text size, and so does the button.
    static let barGlyph = UIImage.SymbolConfiguration(textStyle: .body, scale: .large)
        .applying(UIImage.SymbolConfiguration(weight: .medium))
    /// [mac] Stress test 2026-10-28 #58: the Filter's three hairlines one weight step heavier on the Mac
    /// (`DesktopBars.macThinStep`), so they read as heavy as the magnifier and compose beside them. `barGlyph` elsewhere.
    @MainActor static var filterGlyph: UIImage.SymbolConfiguration {
        barGlyph.applying(UIImage.SymbolConfiguration(weight: DesktopBars.macThinStep(.medium)))
    }

    init(host: UIViewController, configuration: Configuration) {
        self.host = host
        self.configuration = configuration
        super.init()
        let page = configuration.page
        if let menu = configuration.filterMenu {
            // [sessions-m9] A UIButton in the bar: the same symbol, size and room as its neighbours, in the same glass group.
            let button = BarItemButton(type: .system)
            button.setImage(UIImage(systemName: "line.3.horizontal.decrease"), for: .normal)
            button.setPreferredSymbolConfiguration(Self.filterGlyph, forImageIn: .normal)   // [mac] Stress test 2026-10-28 #58
            button.showsMenuAsPrimaryAction = true
            button.menu = UIMenu(identifier: Self.filterMenuIdentifier, children: [
                UIDeferredMenuElement.uncached { completion in completion(menu()) },
            ])
            button.tintColor = .label                       // as the plain bar items beside it draw (system-ink-ok: system bar glass)
            button.isPointerInteractionEnabled = true       // the hover a plain item gets on the iPad and the Mac
            button.accessibilityLabel = configuration.filterLabel
            button.accessibilityIdentifier = "\(page).filter"
            filterButton = button
            let item = UIBarButtonItem(customView: button)
            button.item = item
            filterItem = item
        }
        if let search = configuration.search {
            search.delegate = self
            search.searchBar.delegate = self
            objc_setAssociatedObject(host, Self.hostKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)   // [keys] `on(_:)`
            let item = UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"),
                                       primaryAction: UIAction { [weak self] _ in self?.openSearch() })
            item.accessibilityLabel = "Search"
            // [mac] Stress test 2026-10-28 #66: the pointer's tip (the label) names what this magnifier searches, as
            // its field's placeholder does ("Search Jobs"), since up to three showed at once.
            if DeviceWord.isMac, let words = search.searchBar.placeholder, words.hasPrefix("Search "), words.count > 7 {
                item.accessibilityLabel = words
            }
            item.accessibilityIdentifier = "\(page).search"
            searchItem = item
        }
        if let compose = configuration.compose {
            let item: UIBarButtonItem
            switch compose {
            case .action(let run):
                item = UIBarButtonItem(image: UIImage(systemName: configuration.composeSymbol), primaryAction: UIAction { _ in run() })
            case .menu(let make):
                item = UIBarButtonItem(image: UIImage(systemName: configuration.composeSymbol), menu: UIMenu(children: [
                    UIDeferredMenuElement.uncached { completion in completion(make()) },
                ]))
            }
            item.accessibilityLabel = configuration.composeLabel
            item.accessibilityIdentifier = "\(page).compose"
            composeItem = item
        }
    }

    /// Puts the capsule on the page's bar (trailing, after any items already there).
    func install() {
        guard let host else { return }
        host.definesPresentationContext = true          // an active search stays with its page across tab changes
        let items = [filterItem, searchItem, composeItem].compactMap { $0 }
        // UIKit lays trailing items out from the edge inward: reversed, they read Filter · Search · Compose.
        host.navigationItem.rightBarButtonItems = (host.navigationItem.rightBarButtonItems ?? []) + items.reversed()
        host.navigationItem.hidesSearchBarWhenScrolling = false
        host.navigationItem.preferredSearchBarPlacement = .stacked
    }

    // MARK: - Filter

    /// The Filter button: three lines, as wide as the magnifier beside them (the circled lines read a size smaller; owner
    /// 2026-10-24), and a filled circle while a filter is on (Recent Logs, Star Map). `token` names it for
    /// VoiceOver ("Filter, Archived on").
    /// [sessions-m9] `label`: the page's own words for the button ("Filter and Sort, 2 filters on"), the token its value.
    func setFilterActive(_ active: Bool, token: String?, label: String? = nil) {
        filterActive = active
        let image = UIImage(systemName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        let words = label ?? (active ? "Filter, \(token ?? "") on" : "Filter")
        filterButton?.setImage(image, for: .normal)
        filterButton?.accessibilityLabel = words
        filterButton?.accessibilityValue = active ? token : nil
    }

    /// [sessions-m9] Redraws the Filter menu while it is open (nothing when it is closed):
    /// `rebuilt` gets the menu on screen (the root, or the submenu the user is in) and returns what it should show now.
    func updateFilterMenu(_ rebuilt: @escaping (UIMenu) -> UIMenu) {
        filterButton?.contextMenuInteraction?.updateVisibleMenu(rebuilt)
    }

    /// Shows or hides Filter after `install()`. The capsule keeps its order; nothing changes when it already shows (or not).
    /// [filters-only] No page hides it today: Bots' Filter is always on the bar too (owner 2026-11-03).
    func setFilterShown(_ shown: Bool) {
        guard let host, let filterItem else { return }
        var items = host.navigationItem.rightBarButtonItems ?? []
        let index = items.firstIndex { $0 === filterItem }
        guard shown != (index != nil) else { return }
        if let index {
            items.remove(at: index)
        } else {
            // Items read right to left: Filter goes just inside Search (or Compose).
            let inner = [composeItem, searchItem].compactMap { $0 }.compactMap { item in items.firstIndex { $0 === item } }.max()
            items.insert(filterItem, at: inner.map { $0 + 1 } ?? items.count)
        }
        host.navigationItem.rightBarButtonItems = items
    }

    // MARK: - Search

    var query: String { configuration.search?.searchBar.text ?? "" }
    var isSearchShown: Bool { host?.navigationItem.searchController != nil }

    /// The magnifier: the field unfolds under the title with the keyboard up.
    func openSearch() {
        guard let host, let search = configuration.search else { return }
        if host.navigationItem.searchController !== search { host.navigationItem.searchController = search }
        DispatchQueue.main.async {
            search.isActive = true
            search.searchBar.becomeFirstResponder()
        }
    }

    /// Fold the field away (nothing typed in it).
    func foldSearch() {
        guard let host, let search = configuration.search, host.navigationItem.searchController === search else { return }
        if search.isActive { search.isActive = false }
        host.navigationItem.searchController = nil
        updateSearchState()
    }

    /// The magnifier reads "on" while a query is typed (call on every text change).
    func updateSearchState() {
        let on = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        searchItem?.isSelected = on
        searchItem?.accessibilityValue = on ? query : nil
    }

    // [morepages] 3x-morepages §5: the pages that own their bar (Jobs, Kanban, Artifacts, Capabilities) take the search
    // item and place it themselves; a typed query comes back with the page.
    var searchController: UISearchController? { configuration.search }

    /// Sets the page up for a folding search without touching its bar items (`install()` appends the capsule's).
    func prepareSearchOnly() {
        guard let host else { return }
        host.definesPresentationContext = true
        host.navigationItem.hidesSearchBarWhenScrolling = false
        host.navigationItem.preferredSearchBarPlacement = .stacked
        configuration.search?.searchBar.searchTextField.accessibilityIdentifier = "\(configuration.page).search.field"
    }

    /// The page shows again (another tab, or back from a pushed page) holding a query: its field is there with it.
    func restoreIfTyped() {
        guard let host, let search = configuration.search else { return }
        updateSearchState()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if host.navigationItem.searchController !== search { host.navigationItem.searchController = search }
    }

    /// Clears the query and folds the field (a page changed what it lists: another board).
    func clearSearch() {
        guard let search = configuration.search else { return }
        search.searchBar.text = ""
        if search.isActive { search.isActive = false }
        foldSearch()
    }
    // [/morepages]

    // MARK: - [keys] Find

    private static let hostKey = malloc(1)!

    /// [keys] Mac polish #17: the search capsule a page shows on its bar, when its magnifier is there now (a page takes
    /// it off while it has nothing to search) or its field is open. Edit › Find (⌘F) opens it as a click on the
    /// magnifier does, on every page that has one (Jobs, Kanban, Tasks, Artifacts, Tiles, Settings…), not only the
    /// lists that open their own (`KeySearchable`): there Find was dimmed.
    static func on(_ page: UIViewController?) -> PageBarCapsule? {
        guard let page, let capsule = objc_getAssociatedObject(page, hostKey) as? PageBarCapsule, capsule.host === page,
              let item = capsule.searchItem else { return nil }
        let items = (page.navigationItem.rightBarButtonItems ?? []) + (page.navigationItem.leftBarButtonItems ?? [])
        return capsule.isSearchShown || (!item.isHidden && items.contains { $0 === item }) ? capsule : nil
    }

    /// Left with nothing typed: the field folds away (`page-search.ts`: focus or typed text keeps it open).
    func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.foldSearch() }
    }

    func didDismissSearchController(_ searchController: UISearchController) {
        // Cancel (which clears the text) or a dismissal with nothing typed folds the field away.
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DispatchQueue.main.async { [weak self] in self?.foldSearch() }
        }
    }
}

/// The Filter's UIButton, taking the room iOS 26's bar gives a plain item: 36 tall in the glass capsule, its glyph with
/// 7 pt either side (8⅔ at Extra Large text, 10⅙ from XXL up); without the glass (the Desktop Look) 44 tall, the glyph
/// with 6 pt either side and never under 44 wide. Read off `_UIButtonBarButton` on an iPhone (iOS 27; the Mac's are the
/// same). The bar asks a custom view `sizeThatFits`, and a bare UIButton answers with its glyph, so the capsule was 5 pt
/// narrower than with a plain item. Both pages draw this button, so they match even where these numbers are off.
private final class BarItemButton: UIButton {
    /// The bar item holding the button: the look takes its glass away (`DesktopBars`).
    weak var item: UIBarButtonItem?

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        // The glyph as the button lays it out (UIButton's own answer, and its image view's, grow past it at larger text).
        let glyph = imageRect(forContentRect: CGRect(x: 0, y: 0, width: 1000, height: 1000)).size
        if item?.hidesSharedBackground == true { return CGSize(width: max(44, glyph.width + 12), height: 44) }
        let text = traitCollection.preferredContentSizeCategory
        let side: CGFloat = text > .extraLarge ? 61 / 6 : text == .extraLarge ? 26 / 3 : 7
        return CGSize(width: glyph.width + 2 * side, height: 36)
    }
}
