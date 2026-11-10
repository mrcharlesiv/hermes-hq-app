// Browse every managed app (the desktop's Connectors directory: "Search N apps", a category filter and the
// Connected / Available / Turned off groups). Connect starts the sign-in from the row and opens the app's page.

import SwiftUI
import UIKit

@MainActor @Observable final class ManagedCatalogState {
    var query: String
    var category: String?
    @ObservationIgnored var onClear: (() -> Void)?
    init(query: String) { self.query = query }

    func clear() { query = ""; category = nil; onClear?() }
}

final class ManagedCatalogController: SearchPageHost<HQScaledRoot<ManagedCatalogView>>, UISearchResultsUpdating {
    let state: ManagedCatalogState
    private let model: CapabilitiesModel

    init(model: CapabilitiesModel, router: SettingsRouter, query: String = "") {
        self.model = model
        let state = ManagedCatalogState(query: query)
        self.state = state
        super.init(rootView: HQScaledRoot(ManagedCatalogView(model: model, state: state, router: router)))
        title = "Apps"
        navigationItem.largeTitleDisplayMode = .never
        let search = UISearchController(searchResultsController: nil)
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.placeholder = CapabilitiesModel.searchApps(model.managed?.apps.count ?? 0)
        search.searchBar.text = query
        search.searchBar.searchTextField.accessibilityIdentifier = "managed.catalog.search"
        navigationItem.searchController = search
        PageSearchField.shownUntilIn(navigationItem)   // [main-e2e] hides on scroll once the page is in
        state.onClear = { [weak search] in search?.searchBar.text = "" }
        installMenu()
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func installMenu() {
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            MainActor.assumeIsolated { done(self?.menuItems() ?? []) }
        }])
        let item = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease"), menu: menu)
        item.accessibilityLabel = "Category"
        item.accessibilityIdentifier = "managed.catalog.category"
        navigationItem.rightBarButtonItem = item
    }

    private func menuItems() -> [UIMenuElement] {
        let state = self.state
        let categories = ManagedJoin.categories(model.managed?.apps ?? [])
        let all = UIAction(title: "All Categories", state: state.category == nil ? .on : .off) { _ in state.category = nil }
        let picks = categories.map { name in
            UIAction(title: name, state: state.category == name ? .on : .off) { _ in state.category = name }
        }
        let refresh = UIAction(title: "Refresh", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.model.managed?.load(force: true) }
        return [UIMenu(title: "Category", options: .displayInline, children: [all] + picks), refresh]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.managed?.presenter = self
        model.managed?.load()   // [perf] a reconnect skipped while hidden reads now (a no-op when read under 30 s ago)
    }

    func updateSearchResults(for searchController: UISearchController) {
        state.query = searchController.searchBar.text ?? ""
    }
}

struct ManagedCatalogView: View {
    @Bindable var model: CapabilitiesModel
    @Bindable var state: ManagedCatalogState
    let router: SettingsRouter

    var body: some View {
        List {
            if let managed = model.managed {
                switch managed.phase {
                case .ready: groups(managed)
                case .loading: Section { ForEach(0..<4, id: \.self) { _ in SkeletonLine() } }
                default: Section { ManagedAppsSection(model: model, router: router) }
                }
            }
        }
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("managed.catalog")
        .refreshable { await model.managed?.reload() }
    }

    @ViewBuilder private func groups(_ managed: ManagedAppsModel) -> some View {
        let apps = managed.apps.filter { $0.matches(state.query) && (state.category == nil || $0.category == state.category) }
        let mine = ManagedJoin.mine(apps).filter { $0.state != .off }
        let off = apps.filter { $0.state == .off }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let available = apps.filter { !$0.isMine && $0.state != .off }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let category = state.category {
            Section {
                HStack {
                    Text(category).foregroundStyle(Color.hqLabel)
                    Spacer()
                    Button("All Categories") { state.category = nil }.accessibilityIdentifier("managed.catalog.clear-category")
                }
            }
        }
        if let failure = managed.catalogFailure {
            Section {
                NoticeRow(text: failure.words(fallback: "The app catalog is unavailable right now. Try again later."), symbol: "exclamationmark.circle.fill",
                          tint: .orange, action: "Try Again") { managed.load(force: true) }
            }
        }
        if apps.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No matching apps").font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel)
                    if !state.query.isEmpty || state.category != nil {
                        Button("Clear the Search") { state.clear() }
                            .accessibilityIdentifier("managed.catalog.clear")
                    }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("managed.catalog.empty")
            }
        }
        if !mine.isEmpty {
            Section { rows(mine, managed) } header: { HQSectionLabel { Text("Connected") } } footer: { HQSectionFooter { Text("Broken connections first.") }}
        }
        if !available.isEmpty {
            Section { rows(available, managed) } header: { HQSectionLabel { Text("Available") } }
        }
        if !off.isEmpty {
            Section { rows(off, managed) } header: { HQSectionLabel { Text("Turned Off") } } footer: { HQSectionFooter { Text("Sign-ins are kept.") }}
        }
    }

    private func rows(_ apps: [ManagedApp], _ managed: ManagedAppsModel) -> some View {
        ForEach(apps) { app in
            ManagedAppRow(app: app, busy: managed.busy.contains(app.slug), connecting: managed.waiting(app.slug),
                          showDescription: true,
                          connect: managed.readOnly ? nil : {
                              managed.connect(app.slug)
                              router.push(ManagedAppController(model: model, slug: app.slug, router: router))
                          }) {
                router.push(ManagedAppController(model: model, slug: app.slug, router: router))
            }
        }
    }
}
