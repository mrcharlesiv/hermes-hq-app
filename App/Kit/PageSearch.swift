// Search behind the bar's magnifier for a page that lays out its own bar items (docs/spec/3x-morepages.md §5): Jobs,
// Kanban, Artifacts and Capabilities get the same folding field as Bots and Sessions (`PageBarCapsule`). No field at
// rest; the magnifier unfolds it with the keyboard up; Cancel, or leaving it empty, folds it; a typed query stays with
// its page across tabs and pushes.

import SwiftUI
import UIKit

extension PageBarCapsule {
    /// A capsule holding only Search for `host`. The page puts `searchItem` among its own trailing items.
    static func search(on host: UIViewController, page: String, placeholder: String, updater: UISearchResultsUpdating) -> PageBarCapsule {
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = updater
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = placeholder
        let capsule = PageBarCapsule(host: host, configuration: .init(page: page, search: search))
        capsule.prepareSearchOnly()
        return capsule
    }
}

/// A pushed list page's always-there search field (All Apps, Find Plugins, Nous Apps, a Table): it sits under the title
/// at the top of the list, rides up out of sight as the list scrolls down, and comes back at the top or with a small
/// pull, as in Settings, Mail and Files. While it holds the keyboard or a query it stays. Owner 2026-11-03: pinned, it
/// "feels like it's in the way when I'm scrolling down". Short pick-one sheets (Models, Commands, Model Prices) keep
/// theirs pinned: there the search is the job.
enum PageSearchField {
    static func hidesOnScroll(_ item: UINavigationItem) {
        item.hidesSearchBarWhenScrolling = wanted
    }

    /// A hosted SwiftUI list with a UIKit search controller (All Apps, Find Plugins, Nous Apps): the bar can't find the
    /// list's scroll view at push time, so a hiding field started out of sight there too (UI test M1). The page starts
    /// with the field shown and, as a `SearchPageHost`, lets go of it once it is in.
    static func shownUntilIn(_ item: UINavigationItem) {
        item.hidesSearchBarWhenScrolling = false
    }

    /// The Mac keeps its search where a Mac window does, always there at the top: it costs the list no room there.
    static var wanted: Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        true
        #endif
    }
}

/// A pushed SwiftUI page with `.searchable` (Connect Apps' categories, All Apps, an app's actions). SwiftUI's own
/// hiding field arrives after the page is laid out and so starts out of sight on a page with a small title: you had to
/// know to pull the list down. The page asks for an always-shown field (`.navigationBarDrawer(displayMode: .always)`)
/// so it starts under the title, and once the page is in, it hides as the list scrolls like `PageSearchField.hidesOnScroll`.
/// A hosted list with a UIKit search controller (the catalogs) does the same with `PageSearchField.shownUntilIn`.
class SearchPageHost<Content: View>: UIHostingController<Content> {
    private var appeared = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        letGo()
    }

    /// SwiftUI puts its own setting back when the page updates (the list loading): let go again each time.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if appeared { letGo() }
    }

    private func letGo() {
        guard PageSearchField.wanted, !navigationItem.hidesSearchBarWhenScrolling else { return }
        navigationItem.hidesSearchBarWhenScrolling = true
    }
}
