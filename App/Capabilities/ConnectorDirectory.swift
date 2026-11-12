// [directory] Connectors laid out as the desktop's Connectors page and our Connect Apps page: what this bot has
// connected (with logos and switches), the Nous-managed apps, a Popular grid and every app in Hermes' own catalog
// (`optional-mcps/`, ~65 apps), each with a page that installs it for the bot. Then the other ways in: Add Your Own
// and Connect Apps (your own Composio key). The owner (2026-10-15): "I don't see like the native Hermes agent
// connectors in a way that mirrors how they are in the desktop app."

import SwiftUI
import UIKit

extension CapabilitiesModel {
    func reloadCatalog() async {
        guard let store, isConnected else { return }
        let profile = self.profile
        let start = ContinuousClock.now
        do {
            let entries = try await QueryRetry.read { try await store.mcpCatalog(profile) }
            guard profile == self.profile else { return }
            catalogUnsupported = entries == nil
            catalog = entries.map(McpCatalog.ordered) ?? []
            catalogCache[profile] = catalog
            stamp("catalog", profile)   // also when unsupported: an old gateway is not asked again on every visit
            if entries == nil {
                AppLog.trace("connect", "catalog unsupported by this gateway")
            } else {
                AppLog.trace("connect", "catalog loaded \(catalog?.count ?? 0) app(s) in \(AppLog.ms(since: start)) ms")
            }
        } catch {
            guard profile == self.profile else { return }
            if catalog == nil { catalog = [] }   // the servers above still show; the catalog just stays away
            AppLog.note("connect", "catalog load failed after \(AppLog.ms(since: start)) ms: \(CapabilitiesStore.detail(error))")
        }
    }

    /// The catalog entry a configured server came from (same name), for its logo and title.
    func catalogEntry(for server: McpServer) -> McpCatalogEntry? {
        catalog?.first { $0.name == server.name }
    }

    func title(of server: McpServer) -> String {
        catalogEntry(for: server)?.title ?? DisplayName.title(server.name)
    }

    /// Catalog apps this bot hasn't installed (a server of the same name counts as installed).
    var catalogAvailable: [McpCatalogEntry] {
        let names = Set((servers ?? []).map(\.name))
        return (catalog ?? []).filter { !$0.installed && !names.contains($0.name) }
    }

    var catalogPopular: [McpCatalogEntry] { Array(catalogAvailable.prefix(8)) }
}

// MARK: - The sections

struct ConnectorsSections: View {
    @Bindable var model: CapabilitiesModel
    let router: SettingsRouter
    /// [capabilities] 3x §17.5 e: opened from an issue, VoiceOver lands on the failing connector.
    @AccessibilityFocusState private var spoken: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var query: String { model.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        if let notice = model.serversNotice {
            Section {
                NoticeRow(text: notice, symbol: "checkmark.circle.fill", close: { model.serversNotice = nil })
                    .accessibilityIdentifier("connectors.notice")
            }
        }
        connectedSection
        // [connect-find] Owner 2026-11-11 ("it feels buried"): Composio is the second thing on the page, named, saying
        // that a key is all it takes. It was the last row, under More Ways to Connect, two screens down.
        if query.isEmpty { ComposioSection(model: model, router: router) }
        let quietManaged = ManagedAppsSection.isQuiet(model)
        if !quietManaged { ManagedAppsSection(model: model, router: router) }   // [connectors] the Nous apps, as on the desktop
        // [connectors-ux] Popular ends in See All Apps (its own page): the ~65 catalog rows made this page about 7,000 pt
        // long, with Popular's apps listed twice. A search still lists every matching app here.
        if query.isEmpty { popularSection } else { catalogMatches }
        // A search that Hermes' own apps may not answer (Gmail, Slack): Composio stays one tap away under the matches.
        if !query.isEmpty { ComposioSection(model: model, router: router, searching: true) }
        otherWays
        if quietManaged { ManagedAppsSection(model: model, router: router) }    // just a footer line: below the rows that work
    }

    // MARK: Connected

    @ViewBuilder private var connectedSection: some View {
        if let servers = model.servers {
            let shown = model.shownServers
            if !servers.isEmpty, !(shown.isEmpty && !query.isEmpty) {
                Section {
                    ForEach(shown) { server in
                        ConnectorRow(server: server, title: model.title(of: server), entry: model.catalogEntry(for: server),
                                     busy: model.mcpToggling.contains(server.name), readOnly: model.readOnly,
                                     toggle: { model.setMcp(server, enabled: $0) },
                                     open: { router.push(ConnectorPageController(model: model, server: server, router: router)) })
                            .accessibilityFocused($spoken, equals: server.name)
                    }
                } header: { HQSectionLabel {
                    Text("Connected")
                        .onChange(of: model.spokenServer) { _, name in
                            guard let name else { return }
                            spoken = name
                            model.spokenServer = nil
                        }
                } } footer: { HQSectionFooter {
                    Text("Changes apply to \(model.botName)’s new chats.")   // [connectors-ux] the rows say where they run
                } }
            }
            else if servers.isEmpty, query.isEmpty {
                // Nothing connected yet: say so, and where to start when there are apps below to pick (UX study #56).
                Section {
                    Text(model.readOnly ? "No connectors yet."
                         : !model.catalogAvailable.isEmpty ? "No connectors yet. Pick an app below to connect it to \(model.botName)."
                         : "No connectors yet. Add one below.")
                        .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("connectors.none")
                } header: { HQSectionLabel { Text("Connected") } }
            }
        } else if let error = model.serversError {
            LoadErrorSection(title: "Couldn’t Load Connectors", reason: error) { Task { await model.reloadServers() } }
        } else if !model.isConnected {
            Section { Text("Waiting for your gateway…").foregroundStyle(Color.hqLabel2).padding(.vertical, 12) }
        } else {
            Section { ForEach(0..<3, id: \.self) { _ in SkeletonLine() } } header: { HQSectionLabel { Text("Connected") } }
        }
    }

    // MARK: Popular

    @ViewBuilder private var popularSection: some View {
        let columns = typeSize.isAccessibilitySize ? 2 : typeSize >= .xLarge ? 3 : 4
        if model.catalog == nil, model.isConnected {
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 12) {
                    ForEach(0..<8, id: \.self) { _ in RoundedRectangle(cornerRadius: 12).fill(Color.hqFill3).frame(height: 70).accessibilityHidden(true) }
                }
                .padding(.vertical, 6)
            } header: { HQSectionLabel { Text("Popular") } }
        } else if !model.catalogPopular.isEmpty {
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: columns), spacing: 12) {
                    ForEach(model.catalogPopular) { entry in
                        Button { open(entry) } label: {
                            VStack(spacing: 6) {
                                CatalogLogo(entry: entry, size: 44)
                                Text(entry.title).font(Font.hq(.caption)).foregroundStyle(Color.hqLabel).multilineTextAlignment(.center)
                                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                            }
                            .frame(maxWidth: .infinity, minHeight: 70)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(entry.title)
                        .accessibilityIdentifier("catalog-tile-\(entry.name)")
                    }
                }
                .padding(.vertical, 6)
                let all = model.catalogAvailable.count
                if all > model.catalogPopular.count {
                    Button { router.push(CatalogBrowseController(model: model, router: router)) } label: {
                        BrowseRowLabel(title: "See All Apps", count: all)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("See all \(all) apps")
                    .accessibilityIdentifier("connectors.all-apps")
                }
            } header: { HQSectionLabel { Text("Popular") } }
        }
    }

    // MARK: Search matches

    /// With a search, the catalog apps that match (every app, not only Popular's).
    @ViewBuilder private var catalogMatches: some View {
        let all = model.catalogAvailable
        let shown = all.filter { $0.matches(query) }
        if model.catalog != nil, !all.isEmpty {
            Section {
                if shown.isEmpty {
                    Text("No app matches “\(query)”.").foregroundStyle(Color.hqLabel2).padding(.vertical, 4)
                }
                ForEach(shown) { entry in
                    CatalogRow(entry: entry) { open(entry) }
                }
            } header: { HQSectionLabel { Text("Apps") } }
        }
    }

    // MARK: Other ways

    @ViewBuilder private var otherWays: some View {
        if query.isEmpty, !model.readOnly, model.servers != nil || model.catalog != nil {
            Section {
                Button { (model.presenter as? CapabilitiesViewController)?.addConnector() } label: {
                    ConnectorWayRow(title: "Add Your Own", detail: "By web address or command", symbol: "plus")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("connectors.add")
            } header: { HQSectionLabel { Text("More Ways to Connect") } }
        }
    }

    private func open(_ entry: McpCatalogEntry) {
        router.push(CatalogAppController(model: model, entry: entry, router: router))
    }
}

/// [connector-rows] Owner 2026-11-10 (design pick 26): the two details are short enough for a line or two (they
/// ran to three and four); the page each opens says the rest.
/// [connectors-ux] The symbol on the quiet tile a connector without a logo has (UX study #173 kept colour tiles for
/// More's own index), in the logos' 34 pt column: one icon treatment down the page, not tiles above and bare
/// outline glyphs here.
struct ConnectorWayRow: View {
    var title: String
    var detail: String
    var symbol: String

    var body: some View {
        HStack(spacing: 12) {
            ConnectorSymbolTile(name: title, symbol: symbol, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Font.hq(.body).weight(SkillRowMetrics.titleWeight)).foregroundStyle(Color.hqLabel)   // [mac] regular on the Mac, as Skills' names (Mac polish #95)
                Text(detail).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsChevron()
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// [connect-find] Composio's own place on Connectors and in the Marketplace's Connectors: one row that says a
/// Composio API key is all it takes, then (once a key is saved) that the apps are a tap away. It opens Connect Apps:
/// the key page first, your apps after. Hidden with the feature (`ConnectAppsFeature`).
struct ComposioSection: View {
    let model: CapabilitiesModel
    let router: SettingsRouter
    /// Under a search's matches: the row says where else to look.
    var searching = false
    /// Read when the row shows (and again on the way back from the key page): the Keychain is not read per redraw.
    @State private var keySaved = false

    static let header = "Composio"
    static func title(keySaved: Bool) -> String { keySaved ? "Your Composio Apps" : "Use Your Composio API Key" }
    static func detail(keySaved: Bool, searching: Bool) -> String {
        if searching { return keySaved ? "Not here? Look in your Composio apps" : "Not here? Composio has hundreds more apps" }
        return keySaved ? "Add apps, choose which bots use them" : "Gmail, Slack and hundreds more"
    }

    var body: some View {
        if ConnectAppsFeature.isOn {
            Section {
                Button { router.push(ConnectAppsScreens.makeRoot(services: model.services)) } label: {
                    ConnectorWayRow(title: Self.title(keySaved: keySaved), detail: Self.detail(keySaved: keySaved, searching: searching),
                                    symbol: "key")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("connectors.connect-apps")
                .onAppear { keySaved = ComposioKeychain().status().saved }
            } header: { HQSectionLabel { Text(Self.header) } }
        }
    }
}

struct CatalogRow: View {
    let entry: McpCatalogEntry
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                CatalogLogo(entry: entry, size: 34)
                // [connectors-ux] the names semibold as every other row on Connectors, and the description without the
                // name it often repeats ("GitLab: issues, …")
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(Font.hq(.body).weight(SkillRowMetrics.titleWeight)).foregroundStyle(Color.hqLabel)   // [mac] regular on the Mac, as Skills' names (Mac polish #95)
                    let words = entry.shortDescription
                    if !words.isEmpty {
                        Text(words).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SettingsChevron()
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("catalog-row-\(entry.name)")
    }
}

// MARK: - All apps

/// [connectors-ux] Popular › See All Apps: every catalog app this bot hasn't installed, A to Z, with its own search (as
/// Managed Apps' Browse Apps page has).
final class CatalogBrowseController: SearchPageHost<HQScaledRoot<CatalogBrowseView>>, UISearchResultsUpdating {
    private let state = CatalogBrowseState()

    init(model: CapabilitiesModel, router: SettingsRouter) {
        let state = self.state
        super.init(rootView: HQScaledRoot(CatalogBrowseView(model: model, state: state, router: router)))
        title = "All Apps"
        navigationItem.largeTitleDisplayMode = .never
        let search = UISearchController(searchResultsController: nil)
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.placeholder = CapabilitiesModel.searchApps(model.catalogAvailable.count)
        search.searchBar.searchTextField.accessibilityIdentifier = "catalog.all.search"
        navigationItem.searchController = search
        PageSearchField.shownUntilIn(navigationItem)   // [main-e2e] hides on scroll once the page is in
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func updateSearchResults(for searchController: UISearchController) {
        state.query = searchController.searchBar.text ?? ""
    }
}

@MainActor @Observable final class CatalogBrowseState {
    var query = ""
}

struct CatalogBrowseView: View {
    @Bindable var model: CapabilitiesModel
    @Bindable var state: CatalogBrowseState
    let router: SettingsRouter

    var body: some View {
        let all = model.catalogAvailable.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let shown = all.filter { $0.matches(state.query) }
        List {
            Section {
                if shown.isEmpty {
                    Text(all.isEmpty ? "Every app here is installed for \(model.botName)." : "No app matches “\(state.query)”.")
                        .foregroundStyle(Color.hqLabel2).padding(.vertical, 4)
                }
                ForEach(shown) { entry in
                    CatalogRow(entry: entry) { router.push(CatalogAppController(model: model, entry: entry, router: router)) }
                }
            } footer: { HQSectionFooter {
                Text("Apps Hermes ships with, approved by Nous. Installing one adds it to \(model.botName) on \(HostWord.phrase).")
            } }
        }
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("catalog.all")
    }
}

// MARK: - Logos

/// A catalog app's logo: the vendor's mark from logos.composio.dev under the first slug it knows (an unknown slug
/// answers a grey placeholder with a 200, so the answer is compared with that placeholder), else the product site's
/// touch icon, else a letter tile (the desktop's `ConnectorLogo` ladder).
@MainActor final class CatalogLogoStore {
    static let shared = CatalogLogoStore()
    private let cache = NSCache<NSString, UIImage>()
    private var misses: Set<String> = []
    /// A key no source gave a definite answer for (offline, a timeout) is not asked again before this time, so a row
    /// scrolled back into view while offline does not send its requests again.
    private var retryAfter: [String: Date] = [:]
    var retryGap: TimeInterval = 30   // tests shorten it
    /// The placeholder's bytes, read once for every row that asks at the same time; dropped when the read fails so a
    /// later lookup tries again (not before 30 s).
    private var placeholderTask: Task<Data?, Never>?
    private var placeholderFailedAt: Date?
    private let session: URLSession

    /// What one logo request came back with: a picture, a definite answer that is not one (another status, not an
    /// image), or no answer at all (offline, a timeout, a cancelled row), which is tried again next time.
    enum Fetched: Equatable { case image(Data), answered, failed }

    init(session: URLSession? = nil) {
        cache.countLimit = 160
        self.session = session ?? {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.httpCookieStorage = nil
            return URLSession(configuration: config)
        }()
    }

    func image(key: String, slugs: [String], site: URL?) async -> UIImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if misses.contains(key) { return nil }
        if let until = retryAfter[key], Date() < until { return nil }
        #if DEBUG
        if ComposioClient.base != ComposioClient.productionBase {   // the stand-in serves the logos (UI tests)
            if let slug = slugs.first, let image = await ComposioLogoStore.shared.image(slug: slug, logo: "") {
                cache.setObject(image, forKey: key as NSString)
                return image
            }
            misses.insert(key)
            return nil
        }
        #endif
        // Only a key every source answered for is remembered as having no logo; one cut off by the network stays
        // retryable, so a row seen offline gets its logo once the network is back.
        var definite = true
        if let placeholder = await placeholder() {
            for slug in slugs {
                guard let url = URL(string: "https://logos.composio.dev/api/\(slug.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? slug)")
                else { continue }
                switch await fetch(url) {
                case .failed: definite = false
                case .answered: continue
                case .image(let data):
                    guard data != placeholder, let image = await SVGLogo.decode(data) else { continue }
                    cache.setObject(image, forKey: key as NSString)
                    retryAfter[key] = nil
                    return image
                }
            }
        } else {
            definite = false   // nothing to compare with: a grey placeholder would pass as the app's logo
        }
        if let site {
            for path in ["/apple-touch-icon.png", "/favicon.ico"] {
                guard let url = URL(string: path, relativeTo: site)?.absoluteURL else { continue }
                switch await fetch(url) {
                case .failed: definite = false
                case .answered: continue
                case .image(let data):
                    guard let image = UIImage(data: data), image.size.width >= 16 else { continue }
                    cache.setObject(image, forKey: key as NSString)
                    retryAfter[key] = nil
                    return image
                }
            }
        }
        // A cancelled row (scrolled away mid-read) starts no wait: it loads when it comes back.
        if !Task.isCancelled {
            if definite { misses.insert(key) } else { retryAfter[key] = Date().addingTimeInterval(retryGap) }
        }
        return nil
    }

    private func placeholder() async -> Data? {
        if placeholderTask == nil {
            if let at = placeholderFailedAt, Date().timeIntervalSince(at) < 30 { return nil }
            let url = URL(string: "https://logos.composio.dev/api/hq-no-such-app-0")!
            placeholderTask = Task { if case .image(let data) = await self.fetch(url) { data } else { nil } }
        }
        guard let task = placeholderTask else { return nil }
        let data = await task.value
        if data == nil, placeholderTask == task { placeholderTask = nil; placeholderFailedAt = Date() }
        return data
    }

    func fetch(_ url: URL) async -> Fetched {
        guard let (data, response) = try? await session.data(from: url), let http = response as? HTTPURLResponse else { return .failed }
        if http.statusCode >= 500 || http.statusCode == 429 { return .failed }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard http.statusCode == 200, data.count <= 256 * 1024, type.hasPrefix("image/") else { return .answered }
        return .image(data)
    }
}

struct CatalogLogo: View {
    var key: String
    var name: String
    var slugs: [String]
    var site: URL?
    var size: CGFloat = 34
    @State private var image: UIImage?

    private init(key: String, name: String, slugs: [String], site: URL?, size: CGFloat) {
        self.key = key; self.name = name; self.slugs = slugs; self.site = site; self.size = size
    }

    /// [connectors-ux] An app known only by its name and slugs (a managed app without a logo of its own).
    init(name: String, slugs: [String], size: CGFloat = 34) {
        self.init(key: "slug:\(slugs.first ?? name)", name: name, slugs: slugs, site: nil, size: size)
    }

    init(entry: McpCatalogEntry, size: CGFloat = 34) {
        self.init(key: entry.name, name: entry.title, slugs: McpCatalog.logoSlugs(entry), site: McpCatalog.site(entry), size: size)
    }

    /// A configured server: its catalog entry's logo, else a guess from its name and address.
    init(server: McpServer, entry: McpCatalogEntry?, size: CGFloat = 34) {
        if let entry { self.init(entry: entry, size: size); return }
        let base = server.name.lowercased()
        let site = server.url.flatMap { McpCatalog.site(McpCatalogEntry(name: server.name, description: "", source: $0, transport: "http", authType: "none",
                                                                        requiredEnv: [], args: [], postInstall: "", installed: true, enabled: true)) }
        self.init(key: "server:\(server.name)", name: server.name,
                  slugs: [base, base.replacingOccurrences(of: "[_-]", with: "", options: .regularExpression)], site: site, size: size)
    }

    var body: some View {
        // [ui-sizing 2026-11-09] × UI Scale, as the row's text beside it.
        let size = HQFont.scaled(self.size)
        Group {
            // [ui-sizing] The iPhone too: a logo on a bright white tile sat beside the plugs' quiet grey ones in the same
            // card (Connectors: GitHub's white box beside Browser's and Files' grey tiles).
            if let image {
                // [mac] Stress test 2026-10-28 round 6: a logo sits on the plug's quiet tile, as every connector row's
                // mark does. On a white tile it was a white box in the Desktop Look dark and no tile at all on the iOS
                // look's white card. A dark one-colour mark (GitHub's) is drawn in the label colour in dark appearance,
                // so it shows on the dark tile.
                // [mac] Stress test 2026-10-28 round 7: a one-colour mark filled about 70 % of its tile at full contrast
                // beside the plugs' grey ~40 %. In both appearances it is now drawn as the plug is: the label 2 grey, at
                // the plug's share of the tile. A coloured logo keeps its colours and room.
                let mono = CatalogLogoTone.isDarkMark(image)
                Image(uiImage: mono ? image.withRenderingMode(.alwaysTemplate) : image)
                    .resizable().scaledToFit()
                    .foregroundStyle(mono ? Color.hqLabel2 : Color.hqLabel)
                    .padding(size * (mono ? 0.28 : 0.18))
                    .frame(width: size, height: size)
                    .background(Color.hqFill3, in: RoundedRectangle(cornerRadius: size * 0.24))
            } else {
                // [mac] Stress test 2026-10-28 #59: a connector with no logo of its own shows a quiet tile, the same for
                // every one. [connectors-ux] On the iPhone too (it was a blue tile with the first letter, which the
                // owner ruled out), and with a symbol for what it does where its name says (a globe for Browser).
                ConnectorSymbolTile(name: name, size: self.size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24))
        .overlay(RoundedRectangle(cornerRadius: size * 0.24).strokeBorder(Color.hqFill3, lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: key) { image = await CatalogLogoStore.shared.image(key: key, slugs: slugs, site: site) }
    }
}

/// [mac] Stress test 2026-10-28 round 6: whether a logo is a dark one-colour mark (GitHub's black cat), which vanishes on
/// a dark tile. Read once per image from a 16 × 16 copy: its drawn pixels are dark and nearly grey.
@MainActor enum CatalogLogoTone {
    private static var known: [ObjectIdentifier: Bool] = [:]

    static func isDarkMark(_ image: UIImage) -> Bool {
        let id = ObjectIdentifier(image)
        if let answer = known[id] { return answer }
        let answer = measure(image)
        known[id] = answer
        return answer
    }

    private static func measure(_ image: UIImage) -> Bool {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let cgImage = image.cgImage,
                  let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        var count = 0, dark = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            guard alpha > 0.5 else { continue }
            let r = Double(pixels[i]) / 255 / alpha, g = Double(pixels[i + 1]) / 255 / alpha, b = Double(pixels[i + 2]) / 255 / alpha
            count += 1
            let spread = max(r, g, b) - min(r, g, b)
            if (r + g + b) / 3 < 0.3, spread < 0.15 { dark += 1 }
        }
        // Mostly dark grey drawn pixels, and the mark doesn't fill its square (a logo on its own opaque box keeps it).
        return count > 0 && count < side * side * 9 / 10 && Double(dark) / Double(count) > 0.8
    }
}

// MARK: - App page

final class CatalogAppController: UIHostingController<HQScaledRoot<CatalogAppView>> {
    init(model: CapabilitiesModel, entry: McpCatalogEntry, router: SettingsRouter) {
        let page = CatalogAppModel(parent: model, entry: entry)
        super.init(rootView: HQScaledRoot(CatalogAppView(page: page, router: router)))
        title = entry.title
        navigationItem.largeTitleDisplayMode = .never
        page.host = self
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

@MainActor @Observable
final class CatalogAppModel {
    let parent: CapabilitiesModel
    let entry: McpCatalogEntry
    let profile: String
    var values: [String: String] = [:]
    var installing = false
    var error: String?
    @ObservationIgnored weak var host: UIViewController?

    init(parent: CapabilitiesModel, entry: McpCatalogEntry) {
        self.parent = parent
        self.entry = entry
        profile = parent.profile
    }

    var missing: [String] {
        entry.requiredEnv.filter { $0.required && (values[$0.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.map(\.prompt)
    }
    var canInstall: Bool { !installing && !parent.readOnly && missing.isEmpty }

    func install(router: SettingsRouter) {
        guard canInstall, let store = parent.store else { return }
        Haptics.play(.light)
        installing = true
        error = nil
        let env = values.compactMapValues { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let start = ContinuousClock.now
        Task {
            defer { installing = false }
            do {
                try await store.installCatalog(entry.name, env: env, profile: profile)
            } catch {
                Haptics.play(.error)
                self.error = CapabilitiesStore.detail(error)
                AppLog.note("connect", "catalog install \(entry.name) failed after \(AppLog.ms(since: start)) ms: \(self.error ?? "")")
                return
            }
            AppLog.trace("connect", "catalog install \(entry.name) ok in \(AppLog.ms(since: start)) ms, \(env.count) key(s) set")
            Haptics.play(.success)
            await parent.reloadServers()
            await parent.reloadCatalog()
            parent.serversNotice = "\(entry.title) is installed for \(parent.botName)."
                + (entry.needsSignIn ? " Sign in to it below to finish." : "")
            // Straight on to the connector's own page: it probes the server and offers Sign In when it asks.
            if parent.profile == profile, let server = parent.servers?.first(where: { $0.name == entry.name }),
               let navigation = host?.navigationController, let host {
                let page = ConnectorPageController(model: parent, server: server, router: router)
                page.title = entry.title
                var stack = navigation.viewControllers
                if let index = stack.firstIndex(of: host) { stack[index] = page } else { stack.append(page) }
                navigation.setViewControllers(stack, animated: true)
            } else {
                host?.navigationController?.popViewController(animated: true)
            }
        }
    }
}

struct CatalogAppView: View {
    @Bindable var page: CatalogAppModel
    let router: SettingsRouter

    private var entry: McpCatalogEntry { page.entry }

    var body: some View {
        List {
            // [connectors-ux] the header every Connectors page has (it was a centred 88 pt hero here alone)
            ConnectorHeader(title: entry.title, kind: "From Hermes’s app catalog", description: entry.description) {
                CatalogLogo(entry: entry, size: 56)
            }
            if !entry.requiredEnv.isEmpty { keysSection }
            installSection
            detailsSection
        }
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("catalog-app.page")
    }

    private var keysSection: some View {
        Section {
            ForEach(entry.requiredEnv, id: \.name) { key in
                VStack(alignment: .leading, spacing: 4) {
                    Text(key.prompt).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                        .fixedSize(horizontal: false, vertical: true)
                    let value = Binding(get: { page.values[key.name] ?? "" }, set: { page.values[key.name] = $0 })
                    // [connectors-ux] the field says whether it's needed, not the setting's name (ASANA_CLIENT_ID)
                    let hint = key.required ? "Required" : "Optional"
                    Group {
                        // An address (n8n's server URL) isn't a secret: shown as typed, with the URL keyboard.
                        if McpCatalog.isAddress(key) {
                            TextField(hint, text: value).keyboardType(.URL)
                        } else {
                            SecureField(hint, text: value)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("catalog-key-\(key.name)")
                }
                .padding(.vertical, 3)
            }
        } header: { HQSectionLabel { Text(entry.requiredEnv.count == 1 ? "Key" : "Keys") } } footer: { HQSectionFooter {
            Text("Saved in \(page.parent.botName)’s settings on \(HostWord.phrase), never on this \(DeviceWord.name).")
        } }
    }

    private var installSection: some View {
        Section {
            VStack(spacing: 10) {
                Button { page.install(router: router) } label: {
                    HStack(spacing: 8) {
                        if page.installing { ProgressView().tint(Color.hqOnTint) }
                        Text(page.installing ? (entry.needsBuild ? "Installing… (this can take a few minutes)" : "Installing…") : "Install for \(page.parent.botName)")
                            .font(Font.hq(.body).weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .hqGlassProminentButtonStyle()
                .disabled(!page.canInstall)
                .accessibilityIdentifier("catalog-app.install")
                if let error = page.error {
                    Text(error).font(Font.hq(.subheadline)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("catalog-app.error")
                } else if page.parent.readOnly {
                    Text("This gateway is read-only. Install from a gateway you can change.").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                } else if entry.needsSignIn {
                    Text("After it installs, you’ll sign in to \(entry.title) in your browser.").font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
        }
    }

    private var detailsSection: some View {
        Section {
            if let url = entry.url, entry.transport == "http" {
                detail("Connects to", URL(string: url)?.host ?? url)
            } else if let command = entry.command {
                detail("Runs on \(HostWord.phrase)", ([command] + entry.args).joined(separator: " "))
            }
            if let repo = entry.installURL { detail("Downloads and builds", repo) }
            detail("Sign-in", entry.needsSignIn ? "In your browser" : entry.requiredEnv.isEmpty ? "None needed" : "With the key above")
            if let source = URL(string: entry.source), source.scheme == "https" {
                Button {
                    if let host = page.host { LinkOpener.open(source, from: host) }
                } label: {
                    HStack {
                        Text("Learn More").foregroundStyle(Color.hqTint)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqLabel3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("catalog-app.learn-more")
            }
        } header: { HQSectionLabel { Text("Details") } } footer: { HQSectionFooter {
            Text("Reviewed and approved by Nous for Hermes’s app catalog.")
        } }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
            Text(value).foregroundStyle(Color.hqLabel).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
