// Connect Apps (docs/spec/3x-capabilities.md §10.1, §10.4–§10.9): the sheet, key setup, Home, Bots, an app's page and
// the account menu. Real app logos (logos.composio.dev) are the rule; a monogram tile is the failure fallback only.

import SwiftUI
import UIKit

@MainActor enum ConnectAppsScreens {
    /// More › Connect Apps pushes this on More's own stack (DECISION: a pushed page instead of a second sheet over the
    /// tab, so the sign-in sheet and the chat hand-off have one presenter; the content is the spec's).
    static func makeRoot(services: any AppServices) -> UIViewController { ConnectAppsController(services: services) }
}

final class ConnectAppsController: UIHostingController<HQScaledRoot<ConnectAppsRootView>> {
    let model: ComposioModel

    init(services: any AppServices) {
        model = ComposioModel(services: services)
        super.init(rootView: HQScaledRoot(ConnectAppsRootView(model: model)))
        title = "Composio"   // [connect-find] owner 2026-11-11: the page is named as the row that opens it
        navigationItem.largeTitleDisplayMode = .never
        model.presenter = self
        rootView.push = { [weak self] controller in
            controller.navigationItem.largeTitleDisplayMode = .never
            self?.navigationController?.pushViewController(controller, animated: true)
        }
        installMenu()
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await model.start() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if model.phase == .ready { Task { await model.loadHome() } }
    }

    /// §10.9: the Composio account menu, built when it opens so the hint is current.
    private func installMenu() {
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            MainActor.assumeIsolated { done(self?.menuItems() ?? []) }
        }])
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: menu)
        item.accessibilityLabel = "Account Options"
        item.accessibilityIdentifier = "connect-apps.account"
        navigationItem.rightBarButtonItem = item
    }

    private func menuItems() -> [UIMenuElement] {
        guard model.phase == .ready else {
            return [UIAction(title: "Open Composio", image: UIImage(systemName: "safari")) { _ in
                UIApplication.shared.open(URL(string: "https://platform.composio.dev")!)
            }]
        }
        let status = model.keys.status()
        let key = UIAction(title: "Composio Key", subtitle: status.hint.isEmpty ? "Saved on this \(DeviceWord.name)" : "•••• \(status.hint)",
                           image: UIImage(systemName: "key"), attributes: .disabled) { _ in }
        let open = UIAction(title: "Open Composio", image: UIImage(systemName: "safari")) { _ in
            UIApplication.shared.open(URL(string: "https://platform.composio.dev")!)
        }
        let remove = UIAction(title: "Remove Composio", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            guard let self else { return }
            TextPrompt.confirm(title: "Remove Composio?",
                               message: "Your bots lose these apps, and this \(DeviceWord.name) forgets the key. Connected accounts stay in your Composio project.",
                               action: "Remove", style: .actionSheet, from: self) {
                Task {
                    _ = await self.model.remove()
                    self.navigationController?.popToViewController(self, animated: true)
                }
            }
        }
        return [key, open, UIMenu(options: .displayInline, children: [remove])]
    }
}

struct ConnectAppsRootView: View {
    @Bindable var model: ComposioModel
    var push: (UIViewController) -> Void = { _ in }

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                VStack(spacing: 12) { ProgressView(); Text("Loading…").foregroundStyle(Color.hqLabel2) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .setup:
                ConnectAppsSetupView(model: model)
            case .ready:
                ConnectAppsHomeView(model: model, push: push)
            case .failed(let reason):
                // The real reason as the body, as on the other More pages; the connection advice only for a network
                // failure (ComposioModel.start) (UX study #103).
                MoreErrorState(title: "Couldn’t Load Composio", reason: reason) { Task { await model.start() } }
            }
        }
        .background(Color.hqGroupedPage)
    }
}

// MARK: - Logos

@MainActor final class ComposioLogoStore {
    static let shared = ComposioLogoStore()
    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    init() { cache.countLimit = 64 }

    /// https on logos.composio.dev or the toolkit's own https logo host (DEBUG: the stand-in's loopback base). No key header, ever.
    nonisolated static func url(slug: String, logo: String) -> URL? {
        #if DEBUG
        let base = ComposioClient.base
        if base != ComposioClient.productionBase {
            return URL(string: "/__mock/logo/\(slug.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")", relativeTo: base)?.absoluteURL
        }
        #endif
        if let url = URL(string: logo), url.scheme == "https", url.host != nil, url.user == nil { return url }
        return URL(string: "https://logos.composio.dev/api/\(slug.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")
    }

    func image(slug: String, logo: String) async -> UIImage? {
        if let hit = cache.object(forKey: slug as NSString) { return hit }
        guard let url = Self.url(slug: slug, logo: logo), let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 256 * 1024,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().hasPrefix("image/"),
              let image = await SVGLogo.decode(data) else { return nil }
        cache.setObject(image, forKey: slug as NSString)
        return image
    }
}

struct AppLogo: View {
    let slug: String
    let name: String
    var logo = ""
    var size: CGFloat = 34
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(size * 0.12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: size * 0.24))
            } else {
                Text(String(name.prefix(1)).uppercased()).font(Font.hqSystem(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Color.hqTint, in: RoundedRectangle(cornerRadius: size * 0.24))
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.24).strokeBorder(Color.hqFill3, lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: slug) { image = await ComposioLogoStore.shared.image(slug: slug, logo: logo) }
    }
}

struct ConnectNotice: View {
    let notice: ComposioModel.Notice
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: notice.isError ? "exclamationmark.circle.fill" : "info.circle.fill").foregroundStyle(notice.isError ? Color.red : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title).font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(Color.hqLabel)
                Text(notice.message).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Setup (§10.4)

struct ConnectAppsSetupView: View {
    @Bindable var model: ComposioModel
    @State private var key = ""
    @State private var pasteNotice: ComposioModel.Notice?
    /// The last try was Use the Key on Your Gateway: what it ran into shows under that button, not by the key field
    /// further down (out of view on a phone).
    @State private var triedGatewayKey = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        ForEach(ComposioCatalog.hero, id: \.self) { AppLogo(slug: $0, name: $0, size: 48) }
                    }
                    Text("Let your bots use your apps").font(Font.hq(.title2).weight(.bold)).foregroundStyle(Color.hqLabel).multilineTextAlignment(.center)
                    // [connect-find] Owner 2026-11-11: say first that a Composio API key is all this takes.
                    Text(Self.blurb)
                        .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }
            // The one-tap way when the gateway already has a key, ahead of the field for another one (UX study #104).
            if model.gatewayKeyProfile != nil {
                Section {
                    Button { triedGatewayKey = true; pasteNotice = nil; model.setUp(typed: nil) } label: {
                        Text(model.settingUp ? "Setting Up…" : "Use the Key on Your Gateway").font(Font.hq(.body).weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .hqProminentButtonStyle()
                    .disabled(model.settingUp)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("connect-apps.use-gateway-key")
                } footer: { HQSectionFooter {
                    Text("Your gateway already has a Composio key. To use a different one, paste it below.")
                } }
                if triedGatewayKey, let notice = model.setupNotice {
                    Section { ConnectNotice(notice: notice).accessibilityIdentifier("connect-apps.notice") }
                }
            }
            // [connect-find] The key field leads (it was step 2, under "Get a free Composio key"): someone who has a
            // key pastes it and is done; getting one is the row under Continue.
            Section {
                HStack(spacing: 12) {
                    SecureField("Composio API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.go)
                        .onSubmit { if !key.isEmpty { triedGatewayKey = false; model.setUp(typed: key) } }
                        .accessibilityLabel("Composio API key")
                        .accessibilityIdentifier("connect-apps.key")
                    Button("Paste") { paste() }.hqBorderedButtonStyle().accessibilityIdentifier("connect-apps.paste")
                }
                .padding(.vertical, 3)
            } header: { HQSectionLabel { Text(Self.keyHeader) } }
            // DECISION 10.4-b: the notice sits by the key field and Continue, where the keyboard leaves it in view
            // (at the top of the page it scrolls under the bar while the field has the keyboard).
            if let notice = (model.gatewayKeyProfile != nil && triedGatewayKey ? nil : model.setupNotice) ?? pasteNotice {
                Section { ConnectNotice(notice: notice).accessibilityIdentifier("connect-apps.notice") }
            }
            Section {
                Button {
                    triedGatewayKey = false
                    model.setUp(typed: key)
                } label: {
                    HStack(spacing: 8) {
                        if model.settingUp { ProgressView().accessibilityLabel("Checking your key") }
                        Text("Continue").font(Font.hq(.body).weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .hqProminentButtonStyle()
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || model.settingUp)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("connect-apps.continue")
            } footer: { HQSectionFooter {
                Label("Your key stays in this \(DeviceWord.name)’s Keychain. Nothing changes on your gateway until you turn on a bot.", systemImage: "lock.fill")
                    .font(Font.hq(.footnote))
            } }
            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Self.noKeyTitle).foregroundStyle(Color.hqLabel)
                        Text(Self.noKeyDetail).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open") { UIApplication.shared.open(URL(string: "https://platform.composio.dev")!) }
                        .hqRowActionButtonStyle()
                        .accessibilityIdentifier("connect-apps.open-composio")
                }
                .padding(.vertical, 3)
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("connect-apps.setup")
        .onChange(of: model.phase) { key = "" }
    }

    static let blurb = "All it takes is your Composio API key. Paste it to connect Gmail, Calendar, GitHub and hundreds more, then choose which bots can use them."
    static let keyHeader = "Your Composio API Key"
    static let noKeyTitle = "Don’t have a key?"
    static let noKeyDetail = "Composio is free. Sign up, then copy a key from Settings › API Keys."

    private func paste() {
        model.setupNotice = nil
        triedGatewayKey = false
        guard UIPasteboard.general.hasStrings else {
            pasteNotice = .init(title: "Nothing to Paste", message: "Copy your key in Composio first, then \(DeviceWord.tap) Paste.", isError: false); return
        }
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            pasteNotice = .init(title: "Couldn’t Paste", message: "\(DeviceWord.Tap) the field and paste the key there instead.", isError: false); return
        }
        pasteNotice = nil
        key = text
    }
}

// MARK: - Home (§10.5)

struct ConnectAppsHomeView: View {
    @Bindable var model: ComposioModel
    let push: (UIViewController) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The plus tile grows with the text, so the glyph keeps room in its circle at large sizes.
    @ScaledMetric(relativeTo: .body) private var plusSide: CGFloat = 32

    private func open(_ toolkit: ComposioToolkit) { push(ConnectAppController(model: model, toolkit: toolkit, push: push)) }

    var body: some View {
        List {
            if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                results
            } else {
                header
                Section {
                    Button { push(UIHostingController(rootView: ConnectAppsBotsView(model: model)).titled("Bots")) } label: { botsRow }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("connect-apps.bots-row")
                }
                if let error = model.connectedError {
                    Section {
                        ConnectNotice(notice: .init(title: "Couldn’t Load Your Apps", message: error, isError: true))
                        Button("Try Again") { Task { await model.loadHome() } }
                    }
                }
                connectedSection
                popularSection
                Section {
                    ForEach(ComposioCatalog.categories) { category in
                        Button { push(SearchPageHost(rootView: ConnectCategoryView(model: model, category: category, push: push)).titled(category.title)) } label: {
                            browseRow(category.title, symbol: category.symbol, color: Color(uiColor: UIColor(rgb: category.color)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("connect-category-\(category.id)")
                    }
                    Button { push(SearchPageHost(rootView: ConnectAllAppsView(model: model, push: push)).titled("All Apps")) } label: {
                        browseRow("All Apps", symbol: "square.grid.2x2.fill", color: Color(uiColor: UIColor(rgb: 0x636366)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("connect-apps.all")
                } header: { HQSectionLabel { Text("Browse") } }
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .searchable(text: $model.query, prompt: "Search apps")
        .refreshable { await model.loadHome(); await model.loadBots() }
        .accessibilityIdentifier("connect-apps.home")
    }

    @ViewBuilder private var header: some View {
        Section {
            if let connected = model.connected {
                if connected.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connect your first app").font(Font.hq(.title3).weight(.semibold)).foregroundStyle(Color.hqLabel)
                        Text("\(DeviceWord.Tap) an app below to sign in to it. Then choose which bots can use it.").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                } else {
                    HStack(spacing: 10) {
                        HStack(spacing: -8) { ForEach(connected.prefix(3)) { AppLogo(slug: $0.slug, name: $0.name, logo: $0.logo, size: 34) } }
                        Text(connected.count == 1 ? "1 app connected" : "\(connected.count) apps connected").font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                    }
                    .padding(.vertical, 3)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("connect-apps.count")
                }
            } else {
                SkeletonLine()
            }
        }
    }

    private var botsRow: some View {
        let words = model.botsRow
        return HStack(spacing: 12) {
            if model.onBots.isEmpty {
                Image(systemName: "plus").font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqTint).frame(width: plusSide, height: plusSide)
                    .background(Color.hqFill3, in: Circle()).accessibilityHidden(true)
            } else {
                HStack(spacing: -8) { ForEach(model.onBots.prefix(3)) { HeadImage(raw: $0.head, profile: $0.id, size: 30) } }.accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(words.title).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                if !words.subtitle.isEmpty { Text(words.subtitle).font(Font.hq(.subheadline)).foregroundStyle(words.choose ? Color.hqTint : Color.hqLabel2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsChevron()
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var connectedSection: some View {
        if let connected = model.connected {
            if !connected.isEmpty {
                Section { ForEach(connected) { ConnectAppRow(toolkit: $0, style: .connected) { open($0) } } } header: { HQSectionLabel { Text("Connected") } }
            }
        } else {
            Section { SkeletonLine(); SkeletonLine() } header: { HQSectionLabel { Text("Connected") } }
        }
    }

    @ViewBuilder private var popularSection: some View {
        let columns = typeSize.isAccessibilitySize ? 2 : typeSize >= .xLarge ? 3 : 4
        Section {
            if model.popular == nil {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 12) {
                    ForEach(0..<8, id: \.self) { _ in RoundedRectangle(cornerRadius: 12).fill(Color.hqFill3).frame(height: 70).accessibilityHidden(true) }
                }
                .padding(.vertical, 6)
            } else if model.popularShown.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("You’ve connected every popular app").foregroundStyle(Color.hqLabel)
                    Text("Find more under Browse.").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                }
                .padding(.vertical, 3)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: columns), spacing: 12) {
                    ForEach(model.popularShown) { toolkit in
                        Button { open(toolkit) } label: {
                            VStack(spacing: 6) {
                                AppLogo(slug: toolkit.slug, name: toolkit.name, logo: toolkit.logo, size: 44)
                                Text(toolkit.name).font(Font.hq(.caption)).foregroundStyle(Color.hqLabel).multilineTextAlignment(.center)
                                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                            }
                            .frame(maxWidth: .infinity, minHeight: 70)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(toolkit.name)
                        .accessibilityIdentifier("connect-app-tile-\(toolkit.slug)")
                    }
                }
                .padding(.vertical, 6)
            }
        } header: { HQSectionLabel { Text("Popular") } }
    }

    private func browseRow(_ title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(Font.hqSystem(size: 14, weight: .semibold)).foregroundStyle(.white).frame(width: 29, height: 29)
                .background(color, in: RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
            Text(title).foregroundStyle(Color.hqLabel).frame(maxWidth: .infinity, alignment: .leading)
            SettingsChevron()
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var results: some View {
        Section {
            if let error = model.searchError {
                ConnectNotice(notice: .init(title: "Couldn’t Search", message: error, isError: true))
            } else if let results = model.results {
                if results.isEmpty { Text("No Results for “\(model.query.trimmingCharacters(in: .whitespaces))”").foregroundStyle(Color.hqLabel2).padding(.vertical, 12) }
                ForEach(results) { ConnectAppRow(toolkit: $0, style: .list) { open($0) } }
            } else {
                SkeletonLine(); SkeletonLine(); SkeletonLine()
            }
        } header: { HQSectionLabel { Text("Results") } }
    }
}

extension UIViewController {
    func titled(_ title: String) -> Self { self.title = title; navigationItem.largeTitleDisplayMode = .never; return self }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

struct ConnectAppRow: View {
    enum Style { case connected, list }
    let toolkit: ComposioToolkit
    let style: Style
    let open: (ComposioToolkit) -> Void

    var body: some View {
        Button { open(toolkit) } label: {
            HStack(spacing: 12) {
                AppLogo(slug: toolkit.slug, name: toolkit.name, logo: toolkit.logo, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(toolkit.name).foregroundStyle(Color.hqLabel)
                    if toolkit.needsSignIn {
                        Text("Needs a new sign-in").font(Font.hq(.subheadline)).foregroundStyle(Color.hqOrange)
                    } else if style == .connected {
                        let date = ComposioCatalog.connectedDate(toolkit.account?.createdAt ?? "", short: true)
                        Text(date.isEmpty ? "Connected" : "Connected \(date)").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                    } else if !toolkit.description.isEmpty {
                        Text(toolkit.description).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if style == .list, toolkit.connected, !toolkit.needsSignIn { Text("Connected").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2) }
                SettingsChevron()
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connect-app-row-\(toolkit.slug)")
    }
}

// MARK: - Category and All Apps

struct ConnectCategoryView: View {
    @Bindable var model: ComposioModel
    let category: ComposioCatalog.Category
    let push: (UIViewController) -> Void
    @State private var items: [ComposioToolkit]?
    @State private var error: String?
    @State private var filter = ""

    var body: some View {
        List {
            Section {
                if let error {
                    ConnectNotice(notice: .init(title: "Couldn’t Load Apps", message: error, isError: true))
                    Button("Try Again") { Task { await load() } }
                } else if let items {
                    let shown = (model.shown(items) ?? []).filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
                    if shown.isEmpty { Text(filter.isEmpty ? "No Apps" : "No Results for “\(filter)”").foregroundStyle(Color.hqLabel2).padding(.vertical, 12) }
                    ForEach(shown) { ConnectAppRow(toolkit: $0, style: .list) { push(ConnectAppController(model: model, toolkit: $0, push: push)) } }
                } else {
                    SkeletonLine(); SkeletonLine(); SkeletonLine()
                }
            } footer: { HQSectionFooter {
                Text("\(DeviceWord.Tap) an app to see what your bots can do with it, then connect it.")
            } }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(category.title)")
        .task { await load() }
    }

    private func load() async {
        guard let session = model.session else { return }
        error = nil
        Task { await model.loadSignInRules() }
        do {
            let page = try await model.client.toolkits(session: session.id, slugs: category.slugs, limit: 30)
            let order = Dictionary(uniqueKeysWithValues: category.slugs.enumerated().map { ($1, $0) })
            items = page.items.sorted { (order[$0.slug] ?? 99) < (order[$1.slug] ?? 99) }
            AppLog.trace("connect", "composio category page loaded: \(items?.count ?? 0)")
        } catch {
            self.error = error.message
            AppLog.note("connect", "composio category page load failed: \(error.kind)")
        }
    }
}

struct ConnectAllAppsView: View {
    @Bindable var model: ComposioModel
    let push: (UIViewController) -> Void
    @State private var items: [ComposioToolkit]?
    @State private var next = ""
    @State private var error: String?
    @State private var loadingMore = false
    @State private var query = ""
    @State private var generation = 0

    var body: some View {
        List {
            Section {
                if let error, items == nil {
                    ConnectNotice(notice: .init(title: "Couldn’t Load Apps", message: error, isError: true))
                    Button("Try Again") { Task { await load(reset: true) } }
                } else if let items = model.shown(items) {
                    if items.isEmpty {
                        Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? "No Apps" : "No Results for “\(query.trimmingCharacters(in: .whitespaces))”")
                            .foregroundStyle(Color.hqLabel2).padding(.vertical, 12)
                    }
                    ForEach(items) { ConnectAppRow(toolkit: $0, style: .list) { push(ConnectAppController(model: model, toolkit: $0, push: push)) } }
                    if loadingMore {
                        HStack(spacing: 10) { ProgressView(); Text("Loading more").foregroundStyle(Color.hqLabel2) }
                    } else if !next.isEmpty {
                        Button("Show More") { Task { await load(reset: false) } }.accessibilityIdentifier("connect-apps.show-more")
                    }
                } else {
                    SkeletonLine(); SkeletonLine(); SkeletonLine()
                }
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search apps")
        .accessibilityIdentifier("connect-apps.all-list")
        .task { await load(reset: true) }
        .onChange(of: query) {
            generation += 1
            let mine = generation
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                if mine == generation { await load(reset: true) }
            }
        }
    }

    /// A new search starts over and drops late answers; duplicates by slug are dropped; a second tap while a page loads does nothing.
    private func load(reset: Bool) async {
        guard let session = model.session, reset || !loadingMore else { return }
        let mine = generation
        if reset { items = nil; next = ""; error = nil } else { loadingMore = true }
        do {
            let page = try await model.client.toolkits(session: session.id, search: query.trimmingCharacters(in: .whitespaces), cursor: reset ? "" : next, limit: 30)
            guard mine == generation else { return }
            let have = Set((reset ? [] : items ?? []).map(\.slug))
            items = (reset ? [] : items ?? []) + page.items.filter { !have.contains($0.slug) }
            next = page.next
            AppLog.trace("connect", "composio apps page loaded: \(page.items.count), reset=\(reset), more=\(!next.isEmpty)")
        } catch {
            guard mine == generation else { return }
            self.error = error.message
            AppLog.note("connect", "composio apps page load failed: \(error.kind)")
        }
        loadingMore = false
    }
}

// MARK: - Bots (§10.7)

struct ConnectAppsBotsView: View {
    @Bindable var model: ComposioModel

    var body: some View {
        List {
            if model.readOnly {
                Section { Text("This gateway is read-only. Turn bots on from a gateway you can change.").foregroundStyle(Color.hqLabel2).padding(.vertical, 3) }
            } else {
                if let notice = model.botsNotice { Section { ConnectNotice(notice: notice).accessibilityIdentifier("connect-apps.bots-notice") } }
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "person.2.fill").font(Font.hqSystem(size: 14, weight: .semibold)).foregroundStyle(.white).frame(width: 29, height: 29)
                            .background(Color.hqTint, in: RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("All Bots").foregroundStyle(Color.hqLabel)
                            Text("Includes bots you create later").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if model.applyingAll {
                            ProgressView().accessibilityLabel("Updating bots")
                        } else {
                            Toggle("", isOn: Binding(get: { model.allBots }, set: { model.setAllBots($0) }))
                                .labelsHidden().disabled(model.botStates == nil)
                                .accessibilityLabel("All bots can use your apps")
                                .accessibilityIdentifier("connect-apps.all-bots")
                        }
                    }
                    .padding(.vertical, 3)
                } footer: { HQSectionFooter {
                    Text(model.allBots
                         ? "Every bot can use your apps. When you add a bot, Hermes HQ gives it your apps too; a bot made on another computer gets them the next time Hermes HQ opens."
                         : "Or choose bots one by one. A bot that’s on can use every app you connect.")
                } }
            }
            Section {
                if model.botStates == nil {
                    ForEach(0..<min(max(model.bots.count, 3), 5), id: \.self) { _ in SkeletonLine() }
                } else {
                    ForEach(model.bots) { bot in row(bot) }
                }
            } header: { HQSectionLabel {
                Text(model.bots.count == 1 ? "1 bot" : "\(model.bots.count) bots")
            } } footer: { HQSectionFooter {
                if !model.readOnly {
                    Text("Turning a bot on adds Composio to it on your gateway. Turning it off takes Composio away again; your connected apps stay.")
                }
            } }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("connect-apps.bots")
        .task { if model.botStates == nil { await model.loadBots() } }
    }

    @ViewBuilder private func row(_ bot: Bot) -> some View {
        let state = model.botStates?[bot.id] ?? .off
        HStack(alignment: .center, spacing: 16) {
            HeadImage(raw: bot.head, profile: bot.id, size: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(bot.name).foregroundStyle(Color.hqLabel)
                if case .failed(let on, let reason) = state {
                    Text("Couldn’t turn \(on ? "on" : "off"): \(reason)").font(Font.hq(.caption)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    if !model.readOnly {
                        Button("Try Again") { model.setBot(bot, on: on) }.hqBorderedButtonStyle().font(Font.hq(.footnote).weight(.semibold))
                            .accessibilityIdentifier("connect-bot-retry-\(bot.id)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.botBusy.contains(bot.id) {
                ProgressView()
            } else if model.readOnly {
                if state == .on { Image(systemName: "checkmark").foregroundStyle(Color.hqTint).accessibilityLabel("On") }
            } else if model.allBots, state == .on {
                Image(systemName: "checkmark").font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqTint).accessibilityLabel("On")
            } else {
                Toggle("", isOn: Binding(get: { state == .on }, set: { model.setBot(bot, on: $0) }))
                    .labelsHidden()
                    .accessibilityLabel("\(bot.name) can use your apps")
                    .accessibilityIdentifier("connect-bot-switch-\(bot.id)")
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - App page (§10.8)

final class ConnectAppController: UIHostingController<HQScaledRoot<ConnectAppView>> {
    private let connect = ComposioConnect()

    init(model: ComposioModel, toolkit: ComposioToolkit, push: @escaping (UIViewController) -> Void) {
        super.init(rootView: HQScaledRoot(ConnectAppView(model: model, toolkit: toolkit, connect: connect, push: push)))
        model.readIdentities()
        title = toolkit.name
        navigationItem.largeTitleDisplayMode = .never
        rootView.host = { [weak self] in self }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent { connect.cancel() }
    }
}

struct ConnectAppView: View {
    @Bindable var model: ComposioModel
    @State var toolkit: ComposioToolkit
    @Bindable var connect: ComposioConnect
    let push: (UIViewController) -> Void
    var host: () -> UIViewController? = { nil }
    @State private var tools: [ComposioTool]?
    @State private var disconnecting = false
    @State private var disconnectError: String?
    @State private var asking: String?
    /// Every account of this app, oldest first (§10.11); nil until read or when the read failed. Kept on the model so
    /// an account's own page sees the same list.
    private var accounts: [ComposioAccount]? {
        get { model.appAccounts[toolkit.slug] }
        nonmutating set { model.setAccounts(toolkit.slug, newValue) }
    }
    /// The last connect was Add Another Account: its outcome shows under that button.
    @State private var adding = false
    @State private var accountNotice: String?
    @State private var busyAccount: String?

    private var fine: Bool { toolkit.account?.isActive ?? false }
    private var name: String { toolkit.name }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    AppLogo(slug: toolkit.slug, name: name, logo: toolkit.logo, size: 88)
                        .overlay(alignment: .bottomTrailing) {
                            if fine { badge("checkmark.circle.fill", .green) } else if toolkit.needsSignIn { badge("exclamationmark.triangle.fill", .orange) }
                        }
                    Text(name).font(Font.hq(.title2).weight(.bold)).foregroundStyle(Color.hqLabel)
                    if fine {
                        Text("Connected").font(Font.hq(.headline)).foregroundStyle(Color.hqGreen).accessibilityIdentifier("connect-app.connected")
                        Text(model.allBots ? "All your bots can use it now."
                             : model.onBots.isEmpty ? "No bots use your apps yet." : "\(ComposioCatalog.nameList(model.onBots.map(\.name))) can use it now.")
                            .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).multilineTextAlignment(.center)
                    } else if toolkit.needsSignIn {
                        Text("Needs a new sign-in").font(Font.hq(.headline)).foregroundStyle(Color.hqOrange)
                        Text((toolkit.account?.reason ?? "").isEmpty ? "Your bots can’t use \(name) until you sign in again." : toolkit.account?.reason ?? "")
                            .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).multilineTextAlignment(.center)
                    } else if !toolkit.description.isEmpty {
                        Text(toolkit.description).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            if !fine { connectSection }
            if fine, let bot = model.onBots.first { tryIt(bot) }
            actions
            if !fine { willUse }
            if let account = toolkit.account, toolkit.connected { accountSection(account) }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("connect-app.page")
        .interactiveDismissDisabled(connect.phase == .signIn)
        .task {
            if tools == nil { tools = (try? await model.client.tools(toolkit: toolkit.slug)) ?? [] }
            await refresh()
        }
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol).font(Font.hq(.title3)).foregroundStyle(color).background(Color.hqGroupedPage, in: Circle()).offset(x: 6, y: 6)
            .accessibilityHidden(true)
    }

    private func refresh() async {
        guard let session = model.session, let page = try? await model.client.toolkits(session: session.id, slugs: [toolkit.slug], limit: 5),
              let fresh = page.items.first(where: { $0.slug == toolkit.slug }) else { return }
        toolkit = fresh
        await loadAccounts()
    }

    private func loadAccounts() async {
        guard toolkit.connected else { accounts = nil; return }
        do {
            accounts = try await model.accounts(toolkit.slug)
            AppLog.trace("connect", "composio \(toolkit.slug) accounts loaded: \(accounts?.count ?? 0)")
            await model.loadIdentities(toolkit.slug, accounts: accounts ?? [])
        } catch {
            AppLog.note("connect", "composio \(toolkit.slug) accounts load failed: \(error.kind)")
        }
    }

    @ViewBuilder private var connectSection: some View {
        Section {
            if toolkit.noAuth {
                Text("No sign-in needed. Bots that use your apps can use \(name) already.").foregroundStyle(Color.hqLabel2).padding(.vertical, 3)
            } else {
                Button { signIn() } label: {
                    HStack(spacing: 8) {
                        if connect.phase != .idle { ProgressView() }
                        Text(connect.label ?? (toolkit.needsSignIn ? "Sign In to \(name) Again" : "Connect \(name)")).font(Font.hq(.body).weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .hqProminentButtonStyle()
                .disabled(connect.phase != .idle)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("connect-app.connect")
            }
        } footer: { HQSectionFooter {
            if !toolkit.noAuth {
                switch adding ? nil : connect.outcome {
                case .failed(let reason): Text(reason).foregroundStyle(.red).accessibilityIdentifier("connect-app.outcome")
                case .unfinished: Text("Sign-in not finished. \(DeviceWord.Tap) Connect to try again.").accessibilityIdentifier("connect-app.outcome")
                case .needsOwnApp: ownAppNotice
                default:
                    Label("You sign in to \(name) in a secure Safari sheet. Composio keeps the sign-in; Hermes HQ never sees your password.", systemImage: "lock.fill")
                        .font(Font.hq(.footnote))
                }
            }
        } }
    }

    /// §10.13: Composio has no sign-in for this app; the owner can add their own in Composio's dashboard.
    private var ownAppNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ComposioSignIn.ownAppMessage(name)).foregroundStyle(.red)
            Link("Open Composio Dashboard", destination: ComposioSignIn.dashboard).font(Font.hq(.footnote).weight(.semibold))
                .accessibilityIdentifier("connect-app.open-dashboard")
        }
        .accessibilityIdentifier("connect-app.outcome")
    }

    /// Connect, or sign in again: Composio's sign-in for this app (§10.8).
    private func signIn(window: UIWindow? = nil) {
        guard let session = model.session else { return }
        adding = false
        Task {
            await connect.run(client: model.client, session: session.id, slug: toolkit.slug, window: window ?? host()?.view.window)
            await refresh()
            await model.loadHome()
        }
    }

    @ViewBuilder private func tryIt(_ bot: Bot) -> some View {
        Section {
            ForEach(ComposioCatalog.tryIt(slug: toolkit.slug, name: name), id: \.self) { prompt in
                Button {
                    asking = prompt
                    ConnectAppsChat.open(bot: bot, prefill: prompt, from: host()) { asking = nil }
                } label: {
                    HStack(spacing: 12) {
                        Text("“\(prompt)”").foregroundStyle(Color.hqLabel).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        if asking == prompt { ProgressView().accessibilityLabel("Opening chat") }
                        else { Text("Ask \(bot.name)").font(Font.hq(.subheadline)).foregroundStyle(Color.hqTint) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(asking != nil)
                .accessibilityIdentifier("connect-app.try-\(ComposioCatalog.tryIt(slug: toolkit.slug, name: name).firstIndex(of: prompt) ?? 0)")
            }
        } header: { HQSectionLabel { Text("Try It") } }
    }

    @ViewBuilder private var actions: some View {
        Section {
            if let tools {
                if tools.isEmpty { Text("Composio lists no actions for this app yet").foregroundStyle(Color.hqLabel2) }
                ForEach(tools.prefix(3)) { tool in
                    Label(tool.name, systemImage: "checkmark").foregroundStyle(Color.hqLabel)
                }
                if tools.count > 3 {
                    Button {
                        push(SearchPageHost(rootView: ConnectActionsView(tools: tools)).titled("\(name) Actions"))
                    } label: {
                        HStack {
                            Text("See All Actions").foregroundStyle(Color.hqLabel)
                            Spacer()
                            Text("\(tools.count)").foregroundStyle(Color.hqLabel2)
                            SettingsChevron()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("connect-app.actions")
                }
            } else {
                SkeletonLine(); SkeletonLine(); SkeletonLine()
            }
        } header: { HQSectionLabel { Text("What Your Bots Can Do") } }
    }

    @ViewBuilder private var willUse: some View {
        Section {
            if model.botStates == nil {
                SkeletonLine()
            } else if model.onBots.isEmpty {
                Button { push(UIHostingController(rootView: ConnectAppsBotsView(model: model)).titled("Bots")) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No bots use your apps yet").foregroundStyle(Color.hqLabel)
                        Text("Choose Bots").font(Font.hq(.subheadline)).foregroundStyle(Color.hqTint)
                    }
                }
                .buttonStyle(.plain)
            } else {
                ForEach(model.onBots) { bot in
                    HStack(spacing: 12) { HeadImage(raw: bot.head, profile: bot.id, size: 28); Text(bot.name).foregroundStyle(Color.hqLabel) }
                }
            }
        } header: { HQSectionLabel {
            Text("Bots That Will Use It")
        } } footer: { HQSectionFooter {
            if !model.onBots.isEmpty { Text("These are the bots you turned on. Change them under Bots on the Composio page.") }
        } }
    }

    /// §10.11: every account by its name, each with a menu to name it (and disconnect it when there are several), and
    /// Add Another Account. With one account the Disconnect row below stays as it was.
    @ViewBuilder private func accountSection(_ account: ComposioAccount) -> some View {
        let list = accounts ?? [account]
        Section {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in accountRow(item, number: index + 1, several: list.count > 1) }
            if !toolkit.noAuth {
                Button { addAccount(list) } label: {
                    HStack(spacing: 8) {
                        if adding, connect.phase != .idle { ProgressView() } else { Image(systemName: "plus.circle.fill").accessibilityHidden(true) }
                        Text(adding ? connect.label ?? "Add Another Account" : "Add Another Account")
                    }
                }
                .disabled(connect.phase != .idle || busyAccount != nil)
                .accessibilityIdentifier("connect-app.add-account")
            }
        } header: { HQSectionLabel {
            Text(list.count == 1 ? "Account" : "Accounts")
        } } footer: { HQSectionFooter {
            if let accountNotice {
                Text(accountNotice).foregroundStyle(.red).accessibilityIdentifier("connect-app.account-notice")
            } else if adding, case .failed(let reason) = connect.outcome {
                Text(reason).foregroundStyle(.red).accessibilityIdentifier("connect-app.outcome")
            } else if adding, connect.outcome == .needsOwnApp {
                ownAppNotice
            } else if adding, connect.outcome == .unfinished {
                Text("Sign-in not finished. \(DeviceWord.Tap) Add Another Account to try again.").accessibilityIdentifier("connect-app.outcome")
            } else if list.count > 1 {
                Text("Your bots pick an account by its name.")
            } else if !toolkit.noAuth {
                Text("Add a second \(name) account, like a work one, under its own name.")
            }
        } }
        if list.count == 1 { disconnectSection(list[0]) }
    }

    @ViewBuilder private func accountRow(_ account: ComposioAccount, number: Int, several: Bool) -> some View {
        let identity = model.identities[account.id]
        let title = account.title(number: number, identity: identity)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(Color.hqLabel).lineLimit(1).truncationMode(.middle)
                if let email = account.emailLine(identity: identity) {
                    Text(email).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(1).truncationMode(.middle)
                }
                if account.needsSignIn {
                    Text("Needs a new sign-in").font(Font.hq(.subheadline)).foregroundStyle(Color.hqOrange)
                } else {
                    let date = ComposioCatalog.connectedDate(account.createdAt)
                    Text(date.isEmpty ? "Connected" : "Connected \(date)").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { openAccount(account) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openAccount(account) }
            .accessibilityIdentifier("connect-app.account-\(number)")
            if busyAccount == account.id {
                ProgressView()
            } else {
                Menu {
                    Button(account.alias.isEmpty ? "Name This Account…" : "Rename…", systemImage: "pencil") { rename(account, number: number) }
                    if several {
                        Button("Disconnect", systemImage: "minus.circle", role: .destructive) { disconnect(account, title: title) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(Font.hq(.title3)).foregroundStyle(Color.hqTint)
                        .frame(minWidth: 30, minHeight: 30).contentShape(Rectangle())
                }
                .accessibilityLabel("\(title) options")
                .accessibilityIdentifier("connect-app.account-menu-\(number)")
            }
            SettingsChevron()
                .onTapGesture { openAccount(account) }
                .accessibilityHidden(true)
        }
        .padding(.vertical, 3)
    }

    /// The account's own page (§10.12).
    private func openAccount(_ account: ComposioAccount) {
        let page = ConnectAccountController(model: model, toolkit: toolkit, accountID: account.id, connect: connect,
                                            signIn: { window in signIn(window: window) },
                                            changed: { await refresh(); await model.loadHome() })
        push(page)
    }

    @ViewBuilder private func disconnectSection(_ account: ComposioAccount) -> some View {
        Section {
            Button(disconnecting ? "Disconnecting…" : "Disconnect \(name)", role: .destructive) {
                TextPrompt.confirm(title: "Disconnect \(name)?", message: "Your bots lose access to this \(name) account. You can connect it again anytime.",
                                   action: "Disconnect", style: .actionSheet, from: host()) {
                    disconnecting = true
                    disconnectError = nil
                    let start = ContinuousClock.now
                    Task {
                        defer { disconnecting = false }
                        do {
                            try await model.client.disconnect(account.id)
                            Haptics.play(.success)
                            toolkit.account = nil
                            accounts = nil
                            await refresh()
                            await model.loadHome()
                            AppLog.trace("connect", "composio disconnect \(toolkit.slug) ok in \(AppLog.ms(since: start)) ms")
                        } catch {
                            Haptics.play(.error)
                            disconnectError = (error as? ComposioError)?.message ?? ComposioError.problem.message
                            AppLog.note("connect", "composio disconnect \(toolkit.slug) failed after \(AppLog.ms(since: start)) ms: \(disconnectError ?? "")")
                        }
                    }
                }
            }
            .disabled(disconnecting)
            .accessibilityIdentifier("connect-app.disconnect")
        } footer: { HQSectionFooter {
            if let disconnectError { Text("Couldn’t disconnect: \(disconnectError)").foregroundStyle(.red) }
            else { Text("Your bots lose access to this account. You can connect it again anytime.") }
        } }
    }

    /// Asks for the new account's name, then (moving to a multi-account session first if needed) signs in to it.
    private func addAccount(_ list: [ComposioAccount]) {
        accountNotice = nil
        TextPrompt.present(title: "Add Another \(name) Account", message: "Give it a short name, like “work”. Your bots use the name to pick the account.",
                           placeholder: "work", action: "Continue", maxLength: ComposioAlias.maxLength, identifier: "connect-app.alias",
                           autocapitalization: .none, autocorrection: .no, from: host()) { typed in
            guard let alias = ComposioAlias.normalized(typed) else { accountNotice = "Use letters or numbers in the name."; return }
            guard !list.contains(where: { $0.alias == alias }) else {
                accountNotice = "You already have a \(name) account named “\(ComposioAlias.shown(alias))”."; return
            }
            guard let session = model.session else { return }
            adding = true
            AppLog.trace("connect", "composio add another \(toolkit.slug) account started, \(list.count) already")
            Task {
                await connect.run(client: model.client, session: session.id, slug: toolkit.slug, alias: alias, window: host()?.view.window) {
                    try await model.multiAccountSession().id
                }
                await refresh()
                await model.loadHome()
            }
        }
    }

    private func rename(_ account: ComposioAccount, number: Int) {
        accountNotice = nil
        ConnectAccountNaming.prompt(account, number: number, model: model, toolkit: toolkit, others: accounts ?? [], from: host(),
                                    busy: { busyAccount = $0 ? account.id : nil }, notice: { accountNotice = $0 })
    }

    /// One of several accounts (with one, the Disconnect row does it).
    private func disconnect(_ account: ComposioAccount, title: String) {
        TextPrompt.confirm(title: "Disconnect “\(title)”?", message: "Your bots lose access to this \(name) account. You can connect it again anytime.",
                           action: "Disconnect", style: .actionSheet, from: host()) {
            accountNotice = nil
            busyAccount = account.id
            let start = ContinuousClock.now
            Task {
                defer { busyAccount = nil }
                do {
                    try await model.client.disconnect(account.id)
                    Haptics.play(.success)
                    await refresh()
                    await model.loadHome()
                    AppLog.trace("connect", "composio disconnect one \(toolkit.slug) account ok in \(AppLog.ms(since: start)) ms")
                } catch {
                    Haptics.play(.error)
                    accountNotice = "Couldn’t disconnect: \((error as? ComposioError)?.message ?? ComposioError.problem.message)"
                    AppLog.note("connect", "composio disconnect one \(toolkit.slug) account failed after \(AppLog.ms(since: start)) ms")
                }
            }
        }
    }
}

// MARK: - An account's own page (§10.12)

/// Naming (or renaming) one account of an app, from its row's menu or its own page. An unnamed account's prompt
/// starts with a name made from its address ("work" for an address at work.com).
@MainActor enum ConnectAccountNaming {
    static func prompt(_ account: ComposioAccount, number: Int, model: ComposioModel, toolkit: ComposioToolkit, others: [ComposioAccount],
                       from host: UIViewController?, busy: @escaping (Bool) -> Void, notice: @escaping (String?) -> Void) {
        let identity = model.identities[account.id]
        let taken = Set(others.filter { $0.id != account.id }.map(\.alias).filter { !$0.isEmpty })
        let suggested = account.alias.isEmpty ? identity.flatMap { ComposioAlias.suggestion(email: $0.email, taken: taken) } : nil
        TextPrompt.present(title: account.alias.isEmpty ? "Name This Account" : "Rename \(account.title(number: number, identity: identity))",
                           message: "A short name, like “work”. Your bots use the name to pick the account.", text: suggested ?? account.alias,
                           placeholder: "work", action: "Save", maxLength: ComposioAlias.maxLength, requireChange: suggested == nil,
                           identifier: "connect-app.alias", selectText: true, autocapitalization: .none, autocorrection: .no,
                           from: host) { typed in
            guard let alias = ComposioAlias.normalized(typed) else { notice("Use letters or numbers in the name."); return }
            guard !taken.contains(alias) else {
                notice("You already have a \(toolkit.name) account named “\(ComposioAlias.shown(alias))”."); return
            }
            busy(true)
            let start = ContinuousClock.now
            Task {
                defer { busy(false) }
                do throws(ComposioError) {
                    try await model.client.rename(account.id, alias: alias)
                    Haptics.play(.success)
                    if let fresh = try? await model.accounts(toolkit.slug) { model.setAccounts(toolkit.slug, fresh) }
                    AppLog.trace("connect", "composio \(toolkit.slug) account named in \(AppLog.ms(since: start)) ms, suggested=\(suggested != nil)")
                } catch {
                    Haptics.play(.error)
                    notice("Couldn’t save the name: \(error.message)")
                    AppLog.note("connect", "composio \(toolkit.slug) account naming failed after \(AppLog.ms(since: start)) ms: \(error.kind)")
                }
            }
        }
    }
}

final class ConnectAccountController: UIHostingController<HQScaledRoot<ConnectAccountView>> {
    init(model: ComposioModel, toolkit: ComposioToolkit, accountID: String, connect: ComposioConnect,
         signIn: @escaping (UIWindow?) -> Void, changed: @escaping () async -> Void) {
        super.init(rootView: HQScaledRoot(ConnectAccountView(model: model, toolkit: toolkit, accountID: accountID, connect: connect, signIn: signIn, changed: changed)))
        title = "Account"
        navigationItem.largeTitleDisplayMode = .never
        rootView.host = { [weak self] in self }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// One account of an app: its name, who it is signed in as, its state and date, Composio's code for it, and
/// Disconnect. The account comes from the model's list, so a rename here shows on the app page too.
struct ConnectAccountView: View {
    @Bindable var model: ComposioModel
    let toolkit: ComposioToolkit
    let accountID: String
    @Bindable var connect: ComposioConnect
    let signIn: (UIWindow?) -> Void
    let changed: () async -> Void
    var host: () -> UIViewController? = { nil }
    @State private var busy = false
    @State private var notice: String?
    @State private var disconnecting = false
    @State private var asked = false

    private var list: [ComposioAccount] { model.appAccounts[toolkit.slug] ?? [] }
    private var number: Int { (list.firstIndex { $0.id == accountID } ?? 0) + 1 }
    private var account: ComposioAccount? { list.first { $0.id == accountID } }

    var body: some View {
        List {
            if let account {
                content(account)
            } else {
                Section { Text("This account is no longer connected.").foregroundStyle(Color.hqLabel2) }
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("connect-account.page")
        .task {
            // Asked again on open: a renamed or re-signed account may have changed.
            guard !asked, let account else { return }
            asked = true
            await model.loadIdentities(toolkit.slug, accounts: [account], again: model.identities[account.id] == nil)
        }
    }

    @ViewBuilder private func content(_ account: ComposioAccount) -> some View {
        let identity = model.identities[account.id]
        let title = account.title(number: number, identity: identity)
        Section {
            VStack(spacing: 8) {
                AppLogo(slug: toolkit.slug, name: toolkit.name, logo: toolkit.logo, size: 64)
                Text(title).font(Font.hq(.title3).weight(.bold)).foregroundStyle(Color.hqLabel).multilineTextAlignment(.center)
                    .lineLimit(2).truncationMode(.middle).accessibilityIdentifier("connect-account.title")
                if account.needsSignIn {
                    Text("Needs a new sign-in").font(Font.hq(.headline)).foregroundStyle(Color.hqOrange)
                    if !account.reason.isEmpty {
                        Text(account.reason).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).multilineTextAlignment(.center)
                    }
                } else {
                    Text(account.isActive ? "Connected" : account.status.capitalized).font(Font.hq(.headline))
                        .foregroundStyle(account.isActive ? .green : Color.hqLabel2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
        }
        if account.needsSignIn, !toolkit.noAuth {
            Section {
                Button { signIn(host()?.view.window) } label: {
                    HStack(spacing: 8) {
                        if connect.phase != .idle { ProgressView() }
                        Text(connect.label ?? "Sign In Again").font(Font.hq(.body).weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .hqProminentButtonStyle()
                .disabled(connect.phase != .idle || busy)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("connect-account.sign-in")
            } footer: { HQSectionFooter {
                if case .failed(let reason) = connect.outcome { Text(reason).foregroundStyle(.red) }
                else if connect.outcome == .needsOwnApp { Text(ComposioSignIn.ownAppMessage(toolkit.name)).foregroundStyle(.red) }
                else { Text("You sign in to \(toolkit.name) again in a secure Safari sheet.") }
            } }
        }
        Section {
            HStack(spacing: 12) {
                field("Name", account.alias.isEmpty ? "Not named" : ComposioAlias.shown(account.alias), dim: account.alias.isEmpty)
                if busy { ProgressView() } else {
                    Button(account.alias.isEmpty ? "Name This Account…" : "Rename…") {
                        notice = nil
                        ConnectAccountNaming.prompt(account, number: number, model: model, toolkit: toolkit, others: list, from: host(),
                                                    busy: { busy = $0 }, notice: { notice = $0 })
                    }
                    .font(Font.hq(.body))
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("connect-account.rename")
                }
            }
            if let identity, !identity.email.isEmpty { field("Email", identity.email).accessibilityIdentifier("connect-account.email") }
            if let identity, !identity.name.isEmpty { field("Name in \(toolkit.name)", identity.name).accessibilityIdentifier("connect-account.person") }
            let date = ComposioCatalog.connectedDate(account.createdAt)
            if !date.isEmpty { field("Connected", date) }
        } footer: { HQSectionFooter {
            VStack(alignment: .leading, spacing: 4) {
                if let notice { Text(notice).foregroundStyle(.red).accessibilityIdentifier("connect-account.notice") }
                else { Text("Your bots pick an account by its name.") }
                if !account.wordID.isEmpty {
                    Text("Composio code: \(account.wordID)").font(Font.hq(.caption2)).foregroundStyle(Color.hqLabel3).textSelection(.enabled)
                        .accessibilityIdentifier("connect-account.code")
                }
            }
        } }
        Section {
            Button(disconnecting ? "Disconnecting…" : "Disconnect This Account", role: .destructive) { disconnect(account, title: title) }
                .disabled(disconnecting || busy)
                .accessibilityIdentifier("connect-account.disconnect")
        } footer: { HQSectionFooter {
            Text("Your bots lose access to this \(toolkit.name) account. You can connect it again anytime.")
        } }
    }

    private func field(_ label: String, _ value: String, dim: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
            Text(value).foregroundStyle(dim ? Color.hqLabel2 : Color.hqLabel).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func disconnect(_ account: ComposioAccount, title: String) {
        TextPrompt.confirm(title: list.count > 1 ? "Disconnect “\(title)”?" : "Disconnect \(toolkit.name)?",
                           message: "Your bots lose access to this \(toolkit.name) account. You can connect it again anytime.",
                           action: "Disconnect", style: .actionSheet, from: host()) {
            notice = nil
            disconnecting = true
            let start = ContinuousClock.now
            Task {
                defer { disconnecting = false }
                do {
                    try await model.client.disconnect(account.id)
                    Haptics.play(.success)
                    AppLog.trace("connect", "composio disconnect \(toolkit.slug) account from its page ok in \(AppLog.ms(since: start)) ms")
                    host()?.navigationController?.popViewController(animated: true)
                    await changed()
                } catch {
                    Haptics.play(.error)
                    notice = "Couldn’t disconnect: \((error as? ComposioError)?.message ?? ComposioError.problem.message)"
                    AppLog.note("connect", "composio disconnect \(toolkit.slug) account from its page failed after \(AppLog.ms(since: start)) ms")
                }
            }
        }
    }
}

struct ConnectActionsView: View {
    let tools: [ComposioTool]
    @State private var filter = ""

    var body: some View {
        let shown = tools.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.description.localizedCaseInsensitiveContains(filter) }
        List {
            if shown.isEmpty { Text("No Results for “\(filter)”").foregroundStyle(Color.hqLabel2) }
            ForEach(shown) { tool in
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.name).foregroundStyle(Color.hqLabel)
                    if !tool.description.isEmpty { Text(tool.description).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(.vertical, 3)
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search actions")
        .accessibilityIdentifier("connect-app.actions-list")
    }
}

// MARK: - Try It: open a bot's chat with the prompt in the composer, not sent (§10.8, DECISION 10.8-a)

@MainActor enum ConnectAppsChat {
    static func open(bot: Bot, prefill: String, from host: UIViewController?, done: @escaping () -> Void) {
        // [m9/ipad] the signed-in tabs in either layout (the window root is the two-pane root).
        guard let tabs = MainTabController.current ?? host?.tabBarController as? MainTabController else {
            done()
            FailureAlert.present(title: "Couldn’t Open \(bot.name)", reason: "Couldn’t open \(bot.name)’s chat.", from: host)
            return
        }
        tabs.select(.bots)
        let bots = tabs.botsViewController
        bots.navigationController?.popToRootViewController(animated: false)
        bots.open(bot.id)
        settle(tabs, bot: bot.id, attempts: 40) { chat in
            done()
            guard let chat else {
                FailureAlert.present(title: "Couldn’t Open \(bot.name)", reason: "Couldn’t put the message in \(bot.name)’s chat.", from: tabs)
                return
            }
            // An existing draft is kept: the prompt goes on a new line under it.
            let existing = chat.composer.text
            chat.composer.text = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? prefill : existing + "\n" + prefill
        }
    }

    /// The chat on show in either layout (two panes put it on the right), this bot's, with its push finished.
    private static func settle(_ tabs: MainTabController, bot: String, attempts: Int, _ work: @escaping (ChatViewController?) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let chat = tabs.chatOnShow, chat.session.profile == bot, chat.view.window != nil,
               chat.navigationController?.transitionCoordinator == nil {
                work(chat)
            } else if attempts > 0 {
                // The Bots list ignores `open` while it has no rows yet: ask again every half second.
                if attempts % 5 == 0, tabs.chatOnShow == nil { tabs.botsViewController.open(bot) }
                settle(tabs, bot: bot, attempts: attempts - 1, work)
            } else {
                work(nil)
            }
        }
    }
}
