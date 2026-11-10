// ⋯ › Model Prices: every model of the signed-in providers with what it costs per million tokens, the chat's provider
// first and its model checked; a search field under the bar. Prices are the gateway's, else models.dev's list prices
// (`ModelPricesModel`); subscriptions say "Included".

import SwiftUI
import UIKit

@MainActor
enum ModelPricesSheet {
    static func make(context: ModelMenuContext) -> UINavigationController {
        let model = ModelPricesPageModel(context: context)
        let page = MorePageController(title: "Model Prices", identifier: "prices.page", ModelPricesView(model: model))
        let search = PricesSearch(model: model, page: page)
        // [mac] Stress test 2026-10-28 #74: the Mac's field is the list's first row (`PricesMacSearch`), not a bar search:
        // the bar's drew a glass capsule in the iOS look and sat 4 pt left of the cards, and the sheet's height now
        // follows one list.
        if !DeviceWord.isMac {
            page.navigationItem.searchController = MenusSheet.searchController(placeholder: "Search Models", autocorrect: false, delegate: search)
            page.navigationItem.hidesSearchBarWhenScrolling = false
            page.navigationItem.preferredSearchBarPlacement = .stacked
        }
        model.host = page
        page.retained = [model, search]
        page.onAppear = { [weak model] in model?.appear() }
        page.keyRefresh = { [weak model] in Task { await model?.reload() } }   // ⌘R, as a pull
        return ChatSheet.wrap(page, title: "Model Prices", detents: [.large()])
    }
}

/// The search field's text into the page's query; focusing it opens the sheet to large.
final class PricesSearch: NSObject, UISearchBarDelegate, UISearchResultsUpdating {
    private weak var model: ModelPricesPageModel?
    private weak var page: UIViewController?

    init(model: ModelPricesPageModel, page: UIViewController) {
        self.model = model
        self.page = page
    }

    func updateSearchResults(for searchController: UISearchController) {
        model?.query = searchController.searchBar.text ?? ""
    }

    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        if let page { MenusSheet.expand(page) }
    }
}

@MainActor @Observable
final class ModelPricesPageModel {
    enum Load: Equatable { case loading, ready, failed(String) }

    @ObservationIgnored let context: ModelMenuContext
    @ObservationIgnored weak var host: UIViewController?
    private(set) var load: Load = .loading
    private(set) var options: ModelOptions?
    private(set) var fallback: ModelsDevPrices?
    private(set) var fallbackBusy = false
    /// models.dev was asked and couldn't be reached, with no copy kept: the sections say so and offer Try Again.
    private(set) var fallbackFailed = false
    var query = ""
    @ObservationIgnored private var started = false
    @ObservationIgnored private var askedAgain = false

    init(context: ModelMenuContext) {
        self.context = context
        options = context.options
        fallback = ModelsDevCache.shared.stored()
        if options != nil { load = .ready }
    }

    var sections: [PriceSection] {
        guard let options else { return [] }
        let current = context.current()
        return ModelPricesModel.sections(options, fallback: fallback, fallbackFailed: fallbackFailed, query: query,
                                         current: (current.id, current.provider))
    }

    func appear() {
        guard !started else { return }
        started = true
        Task { await reload() }
    }

    func reload() async {
        do {
            _ = try await context.load(reread: true)
            options = context.options
            load = .ready
        } catch {
            if options == nil { load = .failed(MenusError.text(error)) }
        }
        guard let options else { return }
        if ModelPricesModel.needsFallback(options) { await readFallback() }
        // The gateway warms prices in the background after a read: once, a moment later, what it found.
        if !askedAgain, ModelPricesModel.worthAskingAgain(options) {
            askedAgain = true
            try? await Task.sleep(for: .seconds(3))
            if (try? await context.load(reread: true)) != nil { self.options = context.options }
        }
    }

    private func readFallback() async {
        fallbackBusy = fallback == nil
        defer { fallbackBusy = false }
        if let prices = await ModelsDevCache.shared.load() {
            fallback = prices
            fallbackFailed = false
        } else {
            fallbackFailed = fallback == nil
        }
    }

    /// Try Again under "Couldn’t reach models.dev" (a pull, or ⌘R, asks again too).
    func retryFallback() {
        guard !fallbackBusy else { return }
        Task { await readFallback() }
    }

    /// A row's Copy: on the pasteboard, then "Copied" as everywhere else.
    func copy(_ text: String) {
        UIPasteboard.general.string = text
        Haptics.play(.success)
        MenusHUD.show("Copied", in: host?.view)
    }

    func retry() {
        load = .loading
        Task { await reload() }
    }
}

struct ModelPricesView: View {
    @Bindable var model: ModelPricesPageModel

    var body: some View {
        let sections = model.sections
        List {
            if sections.isEmpty {
                empty
            }
            // At the top: the list can be long, and the reason some prices are missing should be seen first.
            if model.fallbackFailed && !model.fallbackBusy && !sections.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        Text("List prices couldn’t be reached.").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                        Spacer(minLength: 8)
                        Button("Try Again") { model.retryFallback() }.hqBorderedButtonStyle()
                    }
                    .accessibilityIdentifier("prices.fallbackFailed")
                }
            }
            if model.fallbackBusy {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Looking up list prices…").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    }
                }
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in PriceRowView(row: row, copy: model.copy) }
                } header: {
                    HQSectionLabel { Text(section.title) }
                } footer: { HQSectionFooter {
                    if let footer = section.footer {
                        Text(footer).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    }
                } }
                .accessibilityIdentifier("prices.section.\(section.id)")
            }
        }
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .modifier(PricesMacSearchPlacement(text: $model.query))
        .refreshable { await model.reload() }
        .accessibilityIdentifier("prices.list")
    }

    @ViewBuilder private var empty: some View {
        switch model.load {
        case .loading:
            Section {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading models…").foregroundStyle(Color.hqLabel2)
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("prices.loading")
            }
        case .failed(let reason):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn’t load the models.").foregroundStyle(Color.hqLabel)
                    Text(reason).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    Button("Try Again") { model.retry() }.hqBorderedButtonStyle()
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("prices.failed")
            }
        case .ready:
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section { Text("No signed-in provider lists models.").foregroundStyle(Color.hqLabel2) }
            } else {
                ContentUnavailableView.search(text: model.query)
                    .listRowBackground(Color.clear)
            }
        }
    }
}

struct PriceRowView: View {
    var row: PriceRow
    var copy: (String) -> Void = { UIPasteboard.general.string = $0 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).foregroundStyle(Color.hqLabel).lineLimit(2)
                // Mac polish #68: "No price listed" in the second grey too; the faintest (about 2.1:1 in the iOS look) is
                // for glyphs and dividers, not words.
                Text(row.detail)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            if row.current {
                // [mac] Stress test 2026-10-28 #74: a lone ✓ on a price list didn't say what it marked. On the Mac it
                // says so, in the words Usage & Limits uses for the chat's own provider.
                if DeviceWord.isMac {
                    Text("This Chat").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).accessibilityHidden(true)
                } else {
                    Image(systemName: "checkmark").foregroundStyle(Color.hqTint).accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button { copy(row.model) } label: { Label("Copy Model ID", systemImage: "doc.on.doc") }
            if row.priced { Button { copy("\(row.name): \(row.detail)") } label: { Label("Copy Price", systemImage: "dollarsign.circle") } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.name)
        .accessibilityValue(row.current ? "\(row.detail), current model" : row.detail)
        .accessibilityIdentifier("prices.row.\(row.id)")
    }
}

/// [mac] Stress test 2026-10-28 round 6: the search field sits over the list, under the sheet's bar, not in the list.
/// As the list's first row the Desktop Look boxed it in an outlined section (a frame round the field's own frame) and
/// the list's top margin left about 50 pt between the bar and the field. Elsewhere nothing (the bar has the search).
private struct PricesMacSearchPlacement: ViewModifier {
    @Binding var text: String

    func body(content: Content) -> some View {
        let _ = Theme.touch()
        if DeviceWord.isMac && Theme.isDesktop {
            content
                .contentMargins(.top, 4, for: .scrollContent)
                .safeAreaInset(edge: .top, spacing: 0) {
                    PricesMacSearch(text: $text)
                        .padding(.horizontal, MacInset.side)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                        .background(Color.hqGroupedPage)   // solid-ok: the Desktop Look has no glass
                }
        } else if DeviceWord.isMac {
            // [glass-mac] Owner 2026-10-30 "more Liquid Glass": in the iOS look the field is a glass capsule over the
            // list, as an iOS 26 search field; the list scrolls under it behind the system's scroll edge effect.
            content
                .contentMargins(.top, 4, for: .scrollContent)
                .safeAreaBar(edge: .top, spacing: 0) {
                    PricesMacSearch(text: $text)
                        .padding(.horizontal, MacInset.side)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                }
        } else {
            content
        }
    }
}

/// [mac] Stress test 2026-10-28 #74: a plain Mac search field on the cards' edges: a rounded box with a magnifier, the
/// words, and an ⓧ only over words. Typing narrows the list as the bar's field did.
struct PricesMacSearch: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.hqLabel2).accessibilityHidden(true)
            // Mac polish #69: the hint words in the second grey, as the bar's search fields (not the system's faint one).
            TextField("Search Models", text: $text, prompt: Text("Search Models").foregroundStyle(Color.hqLabel2))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("sheet.search")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.hqLabel3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Text")
                .help("Clear Text")
            }
        }
        .font(Font.hq(.body))
        .modifier(PricesMacSearchBox())
        .padding(.vertical, 4)
    }
}

/// [glass-mac] The Mac search field's box: a glass capsule in the iOS look (`hqGlassEffect`, untinted), and in the
/// Desktop Look the solid rounded box with its line it always had.
private struct PricesMacSearchBox: ViewModifier {
    func body(content: Content) -> some View {
        let _ = Theme.touch()
        if Theme.isDesktop {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.hqGroupedCard))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.hqStroke, lineWidth: 1))
        } else {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .hqGlassEffect(in: Capsule())
        }
    }
}
