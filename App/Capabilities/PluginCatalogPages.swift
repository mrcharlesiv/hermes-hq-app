// [find-plugins] Find Plugins: the Hermes plugin catalog (`PluginCatalogStore`, ~900 plugins Nous has reviewed) on the
// Plugins tab and its own pages. The tab shows the most-starred plugins this bot doesn't have and, while its search has
// words, the catalog plugins that match them. Find Plugins has the kinds, Popular and Recently Added, and a search over
// all of them. A plugin's page says what it does, what it sends where and who made it, and installs it for the bot
// with `plugins.manage install {catalog_name}`: Hermes downloads the commit Nous reviewed.
// Owner 2026-11-02: "Do we have a place to add, search, or manage Hermes plugins?" … "Yes work on both."

import SwiftUI
import UIKit

extension CapabilitiesModel {
    /// The bot's plugin installed from `entry` (by its catalog name, else a plugin of the same name).
    func installedPlugin(for entry: PluginCatalogEntry) -> PluginInfo? {
        plugins?.first { $0.catalogName == entry.name } ?? plugins?.first { $0.name == entry.name }
    }

    /// Catalog plugins this bot doesn't have, most stars first.
    var pluginCatalogAvailable: [PluginCatalogEntry] {
        let installed = Set((plugins ?? []).flatMap { [$0.name, $0.catalogName].compactMap(\.self) })
        return (PluginCatalogStore.shared.entries ?? []).filter { !installed.contains($0.name) }
    }

    /// The tab's few picks: most stars first, at most two of a kind (the five most-starred were all memory providers).
    var pluginCatalogPicks: [PluginCatalogEntry] { PluginCatalogEntry.picks(pluginCatalogAvailable, count: 5) }

    /// The notice on the Plugins list after an install (Install from Git and Find Plugins say the same).
    func noteInstalled(_ result: PluginResult, name: String) {
        var text: String
        if !result.missingEnv.isEmpty {
            text = "\(name) is installed but needs a key before it can work: \(result.missingEnv.joined(separator: ", ")). Add it now, or the plugin’s tools will fail."
            pluginNoticeAction = .setUp(plugin: name)
        } else {
            text = "Installed “\(name)”." + (result.needsRestart ? " Restart your gateway to finish." : "")
            pluginNoticeAction = nil
        }
        if !result.warnings.isEmpty {
            var lines = result.warnings.prefix(5).map { McpEntryMask.phone.text($0) }
            if result.warnings.count > 5 { lines.append("and \(result.warnings.count - 5) more") }
            text += "\n" + lines.joined(separator: "\n")
        }
        pluginNeedsKeys = false
        pluginNotice = text
    }
}

// MARK: - On the Plugins tab

struct PluginFindSection: View {
    @Bindable var model: CapabilitiesModel
    let router: SettingsRouter
    private var catalog: PluginCatalogStore { .shared }

    private var query: String { model.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        if let entries = catalog.entries {
            if query.isEmpty {
                let popular = model.pluginCatalogPicks
                Section {
                    ForEach(popular) { entry in
                        PluginCatalogRow(entry: entry, installed: false) { open(entry) }
                    }
                    Button { router.push(MarketplaceController(model: model, router: router, kind: .plugins)) } label: {
                        BrowseRowLabel(title: "Open the Marketplace", count: entries.count)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open the Marketplace, \(entries.count) plugins")
                    .accessibilityIdentifier("plugins.find.all")
                } header: { HQSectionLabel {
                    Text("Find Plugins")
                } } footer: { HQSectionFooter {
                    Text("Popular plugins from the Hermes Marketplace. Nous reviews every one before it is listed.")
                } }
            } else {
                let matches = PluginCatalogEntry.search(entries, query)
                Section {
                    if matches.isEmpty {
                        Text("No plugin in the Hermes catalog matches “\(query)”.").foregroundStyle(Color.hqLabel2).padding(.vertical, 4)
                            .accessibilityIdentifier("plugins.find.none")
                    }
                    ForEach(matches.prefix(8)) { entry in
                        PluginCatalogRow(entry: entry, installed: model.installedPlugin(for: entry) != nil) { open(entry) }
                    }
                    if matches.count > 8 {
                        Button { router.push(MarketplaceController(model: model, router: router, kind: .plugins, query: query)) } label: {
                            BrowseRowLabel(title: "See All Results", count: matches.count)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("plugins.find.more")
                    }
                } header: { HQSectionLabel { Text("Hermes Marketplace") } }
            }
        } else if let error = catalog.error {
            Section {
                Text(error).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
                Button("Try Again") { Task { await catalog.load(force: true) } }
                    .accessibilityIdentifier("plugins.find.retry")
            } header: { HQSectionLabel { Text("Find Plugins") } }
        } else if query.isEmpty {
            Section { ForEach(0..<3, id: \.self) { _ in SkeletonLine() } } header: { HQSectionLabel { Text("Find Plugins") } }
        }
    }

    private func open(_ entry: PluginCatalogEntry) {
        router.push(PluginCatalogEntryController(model: model, entry: entry, router: router))
    }
}

// MARK: - Rows

struct PluginCatalogRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let entry: PluginCatalogEntry
    var installed: Bool
    /// [mac-tools] No chevron on a card of the Mac's Marketplace grid.
    var chevron = true
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                ConnectorSymbolTile(name: entry.name, symbol: entry.category.symbol, size: 34)
                // [plugin-rows] Owner 2026-11-10 (design pick 6): the maker and the stars share the name's line (the
                // maker after the name, the stars or "Installed" at the trailing edge), so the row is the name and
                // its two lines of summary with no third line of small print, and it has no arrow: the whole row is
                // the button, as on Jobs and Bots. At the accessibility text sizes the byline keeps its own line.
                let edged = !typeSize.isAccessibilitySize
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.title).font(Font.hq(.body).weight(SkillRowMetrics.titleWeight)).foregroundStyle(Color.hqLabel)   // [mac] regular on the Mac, as Skills' names (Mac polish #95)
                            .lineLimit(edged ? 1 : nil).layoutPriority(2)
                        if let tier = entry.tierWord { PluginTierBadge(words: tier).layoutPriority(1) }
                        if edged {
                            if !entry.maintainer.isEmpty {
                                Text(entry.maintainer).font(Font.hq(.caption)).foregroundStyle(Color(uiColor: HQPalette.cardNote))
                                    .lineLimit(1).truncationMode(.tail)
                            }
                            Spacer(minLength: 4)
                            Group {
                                if installed {
                                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
                                } else if let stars = entry.stars {
                                    Text("\(Image(systemName: "star.fill")) \(stars.starWords)").foregroundStyle(Color(uiColor: HQPalette.cardNote))
                                }
                            }
                            .font(Font.hq(.caption)).lineLimit(1).fixedSize().layoutPriority(3)
                        }
                    }
                    let summary = entry.summary
                    if !summary.isEmpty {
                        Text(PluginCatalogEntry.styled(summary)).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : Density.compact ? 1 : 2)   // [ui-sizing] Compact: one line
                    }
                    if !edged {
                        if installed {
                            Label("Installed", systemImage: "checkmark.circle.fill").font(Font.hq(.caption)).foregroundStyle(.green)
                                .labelStyle(.titleAndIcon)
                        } else if let line = byline {
                            // Mac polish #68: label 2 in the iOS look (label 3 read about 2.2:1); the Desktop Look's 3.
                            line.font(Font.hq(.caption)).foregroundStyle(Color(uiColor: HQPalette.cardNote)).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if chevron && !edged { SettingsChevron() }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("plugin-catalog-row-\(entry.name)")
    }

    /// "mem0ai · ★ 68k"
    private var byline: Text? {
        let maker = entry.maintainer.isEmpty ? nil : Text(entry.maintainer)
        let stars = entry.stars.map { Text("\(Image(systemName: "star.fill")) \($0.starWords)") }
        switch (maker, stars) {
        case let (maker?, stars?): return Text("\(maker)  ·  \(stars)")
        case let (maker?, nil): return maker
        case let (nil, stars?): return stars
        default: return nil
        }
    }
}

struct PluginTierBadge: View {
    var words: String

    /// [marketplace] Certified wears green with a check, as on the site; the rest the tint.
    private var certified: Bool { words == "Certified" }
    private var color: Color { certified ? .green : Color.hqTint }

    var body: some View {
        HStack(spacing: 2) {
            if certified { Image(systemName: "checkmark.seal.fill").accessibilityHidden(true) }
            Text(words)
        }
        .font(Font.hq(.caption2).weight(.semibold)).foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(color.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

extension PluginCatalogEntry {
    /// Catalog words with their inline Markdown (`hermes memory setup` as code, links), as the website shows them.
    static func styled(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Find Plugins page

// MARK: - A plugin's page

final class PluginCatalogEntryController: UIHostingController<HQScaledRoot<PluginCatalogEntryView>> {
    init(model: CapabilitiesModel, entry: PluginCatalogEntry, router: SettingsRouter) {
        let page = PluginCatalogEntryModel(parent: model, entry: entry)
        super.init(rootView: HQScaledRoot(PluginCatalogEntryView(page: page, router: router)))
        title = entry.title
        navigationItem.largeTitleDisplayMode = .never
        page.host = self
        self.page = page
        self.router = router
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var page: PluginCatalogEntryModel!
    private var router: SettingsRouter!
    private var installOnAppear = false

    /// [marketplace] A Featured card's Install, or an install link once its sheet is up: install as the page shows.
    func installWhenShown(router: SettingsRouter) { installOnAppear = true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if installOnAppear {
            installOnAppear = false
            page.install(router: router)
        }
    }
}

@MainActor @Observable
final class PluginCatalogEntryModel {
    let parent: CapabilitiesModel
    let entry: PluginCatalogEntry
    /// [marketplace] The bot in Install To (the page's own picker changes it).
    var profile: String { parent.profile }
    var installing = false
    var error: String?
    var uncertain = false
    var banner: UIImage?
    var expanded = false
    @ObservationIgnored weak var host: UIViewController?

    init(parent: CapabilitiesModel, entry: PluginCatalogEntry) {
        self.parent = parent
        self.entry = entry
    }

    var installed: PluginInfo? { parent.profile == profile ? parent.installedPlugin(for: entry) : nil }
    var canInstall: Bool {
        !installing && !uncertain && installed == nil && !parent.readOnly && !parent.pluginsUnavailable && parent.store != nil
            && !PluginInstallState.running
    }

    func install(router: SettingsRouter) {
        guard canInstall, let store = parent.store else { return }
        Haptics.play(.light)
        installing = true
        PluginInstallState.running = true
        error = nil
        let profile = self.profile, entry = self.entry, parent = self.parent
        let start = ContinuousClock.now
        AppLog.trace("plugins", "catalog install \(entry.name) for \(AppLog.tag(profile)) started")
        Task {
            defer { installing = false; PluginInstallState.running = false }
            do {
                let result: PluginResult
                do {
                    result = try await store.plugin(.installCatalog(name: entry.name, enable: true), profile: profile)
                } catch where Self.predatesCatalogName(error) {
                    // A Hermes from before `catalog_name` (2026-09): the same reviewed commit, by its address and pin.
                    AppLog.note("plugins", "catalog install \(entry.name): gateway predates catalog_name, installing by repo at the pin")
                    result = try await store.plugin(.install(identifier: entry.installIdentifier, force: false, enable: true,
                                                             ref: entry.sha.isEmpty ? nil : entry.sha), profile: profile)
                }
                let name = result.name ?? entry.name
                parent.noteInstalled(result, name: name)
                Haptics.play(.success)
                await parent.reloadPlugins()
                AppLog.trace("plugins", "catalog install \(entry.name) ok in \(AppLog.ms(since: start)) ms, missingEnv=\(result.missingEnv.count), needsRestart=\(result.needsRestart)")
                // Straight on to the plugin's own page (its switch and settings), as a catalog connector goes to its page.
                if parent.profile == profile, let plugin = parent.plugins?.first(where: { $0.name == name || $0.catalogName == entry.name }),
                   let host, let navigation = host.navigationController {
                    let page = PluginPageController(model: parent, plugin: plugin, router: router)
                    var stack = navigation.viewControllers
                    if let index = stack.firstIndex(of: host) { stack[index] = page } else { stack.append(page) }
                    navigation.setViewControllers(stack, animated: true)
                }
            } catch {
                let detail = CapabilitiesStore.detail(error)
                let lower = detail.lowercased()
                if (error as? RPCError)?.code == 4090 || lower.contains("already installed") {
                    await parent.reloadPlugins()
                    if installed == nil { self.error = "\(entry.title) is already on \(HostWord.phrase) for \(parent.botName). Open Plugins to turn it on." }
                    AppLog.note("plugins", "catalog install \(entry.name) refused after \(AppLog.ms(since: start)) ms: already installed")
                } else if lower.contains("timed out") || lower.contains("took too long") || error is CancellationError {
                    uncertain = true
                    AppLog.note("plugins", "catalog install \(entry.name) ended with no status after \(AppLog.ms(since: start)) ms")
                    Task {
                        try? await Task.sleep(for: .seconds(30))
                        await parent.reloadPlugins()
                        uncertain = false
                    }
                } else {
                    Haptics.play(.error)
                    self.error = String(McpEntryMask.phone.text(detail).prefix(600))
                    AppLog.note("plugins", "catalog install \(entry.name) failed after \(AppLog.ms(since: start)) ms: \(detail)")
                }
            }
        }
    }

    nonisolated static func predatesCatalogName(_ error: Error) -> Bool {
        guard let rpc = error as? RPCError else { return false }
        return rpc.code == 4019 && rpc.message.contains("identifier")
    }

    func openInstalled(router: SettingsRouter) {
        guard let plugin = installed else { return }
        router.push(PluginPageController(model: parent, plugin: plugin, router: router))
    }

    /// [marketplace] The maintainer's other plugins, most stars first (the website's "More by …").
    var moreByMaker: [PluginCatalogEntry] { Array(allByMaker.filter { $0.name != entry.name }.prefix(4)) }

    /// Everything the maintainer has in the catalog, this one too (the site's "All 29 by NousResearch").
    var allByMaker: [PluginCatalogEntry] {
        guard !entry.maintainer.isEmpty else { return [] }
        return (PluginCatalogStore.shared.entries ?? []).filter { $0.maintainer == entry.maintainer }
    }

    /// [marketplace] The README at the reviewed commit, formatted.
    func readReadme(_ url: URL) {
        guard let navigation = host?.navigationController else { return }
        let page = ArtifactTextViewController(title: "\(entry.title) README", markdown: true, language: nil) {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.cachePolicy = .returnCacheDataElseLoad
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.fileDoesNotExist) }
            return String(decoding: data.prefix(2 * 1024 * 1024), as: UTF8.self)
        }
        navigation.pushViewController(page, animated: true)
    }

    /// The listing's picture, when it has one (GitHub-hosted, pinned to the reviewed commit).
    func loadBanner() async {
        guard banner == nil, let url = entry.image else { return }
        let request = URLRequest(url: url, timeoutInterval: 15)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 6 * 1024 * 1024 else { return }
        let image = await Task.detached(priority: .utility) { UIImage(data: data)?.preparingForDisplay() }.value
        if let image, image.size.width >= 64 { banner = image }
    }
}

struct PluginCatalogEntryView: View {
    @Bindable var page: PluginCatalogEntryModel
    let router: SettingsRouter

    private var entry: PluginCatalogEntry { page.entry }

    var body: some View {
        List {
            if let banner = page.banner {   // [marketplace] the listing's picture leads, as on the website
                Section {
                    Image(uiImage: banner).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Picture of \(entry.title)")
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
            header
            installSection
            if let readme = entry.readmeURL {
                Section {
                    Button { page.readReadme(readme) } label: {
                        HStack {
                            Label("Read the README", systemImage: "doc.text")
                            Spacer()
                            SettingsChevron()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("plugin-catalog.readme")
                }
            }
            if let disclosure = entry.disclosure {
                Section {
                    Text(PluginCatalogEntry.styled(disclosure)).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.vertical, 3)
                        .accessibilityIdentifier("plugin-catalog.shares")
                } header: { HQSectionLabel { Text("What It Shares") } } footer: { HQSectionFooter {
                    Text("From the plugin’s catalog listing, which Nous checks.")
                } }
            }
            detailsSection
            let more = page.moreByMaker
            if !more.isEmpty {
                Section {
                    ForEach(more) { other in
                        PluginCatalogRow(entry: other, installed: page.parent.installedPlugin(for: other) != nil) {
                            router.push(PluginCatalogEntryController(model: page.parent, entry: other, router: router))
                        }
                    }
                    let all = page.allByMaker.count
                    if all > more.count + 1 {
                        Button {
                            router.push(MarketplaceController(model: page.parent, router: router, kind: .plugins, query: entry.maintainer))
                        } label: {
                            BrowseRowLabel(title: "All by \(entry.maintainer)", count: all)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("plugin-catalog.all-by-maker")
                    }
                } header: { HQSectionLabel { Text("More by \(entry.maintainer)") } } footer: { HQSectionFooter {
                    Text("\(page.allByMaker.count) \(page.allByMaker.count == 1 ? "plugin" : "plugins") by \(entry.maintainer) in the catalog.")
                } }
            }
        }
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .task { await page.loadBanner() }
        .accessibilityIdentifier("plugin-catalog.page")
    }

    // MARK: Header

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    ConnectorSymbolTile(name: entry.name, symbol: entry.category.symbol, size: 56)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.title).font(Font.hq(.title3).weight(.bold)).foregroundStyle(Color.hqLabel)
                            .fixedSize(horizontal: false, vertical: true)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) { badge; kindText }
                            VStack(alignment: .leading, spacing: 4) { badge; kindText }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                let about = entry.about
                if !about.isEmpty {
                    let long = about.count > 420
                    Text(PluginCatalogEntry.styled(about)).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                        .lineLimit(long && !page.expanded ? 6 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if long {
                        Button(page.expanded ? "Less" : "More") { HQMotion.withAnimation(.snappy) { page.expanded.toggle() } }
                            .font(Font.hq(.subheadline).weight(.semibold))
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.hqTint)
                            .accessibilityIdentifier("plugin-catalog.more")
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder private var badge: some View {
        if let tier = entry.tierWord { PluginTierBadge(words: tier) }
    }

    private var kindText: some View {
        Text(entry.maintainer.isEmpty ? entry.category.title : "\(entry.category.title) · by \(entry.maintainer)")
            .font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2).lineLimit(1)
    }

    // MARK: Install

    // [marketplace] Install To stands in its own card: in the same section as the clear button row, the card ended
    // half-drawn with Desktop Look off.
    @ViewBuilder private var installSection: some View {
        if page.parent.bots.count > 1 {
            Section { MarketplaceInstallTo(model: page.parent).disabled(page.installing) }
        }
        Section {
            VStack(spacing: 10) {
                if let installed = page.installed {
                    Label("Installed for \(page.parent.botName)", systemImage: "checkmark.circle.fill")
                        .font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(.green)
                        .accessibilityIdentifier("plugin-catalog.installed")
                    if let shown = page.parent.dashboardPage(for: installed) {
                        // [plugin-pages] A plugin that adds a page opens it first; Plugins is still a tap away.
                        Button { PluginPagesSection.open(shown, model: page.parent, router: router) } label: {
                            Text("Open \(shown.label)").font(Font.hq(.body).weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 34)
                        }
                        .hqGlassProminentButtonStyle()
                        .accessibilityIdentifier("plugin-catalog.open-page")
                        Button { page.openInstalled(router: router) } label: {
                            Text("Open in Plugins").font(Font.hq(.subheadline).weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.hqTint)
                        .accessibilityIdentifier("plugin-catalog.open")
                    } else {
                        Button { page.openInstalled(router: router) } label: {
                            Text("Open in Plugins").font(Font.hq(.body).weight(.semibold)).frame(maxWidth: .infinity, minHeight: 34)
                        }
                        .hqBorderedButtonStyle()
                        .accessibilityIdentifier("plugin-catalog.open")
                    }
                } else {
                    Button { page.install(router: router) } label: {
                        HStack(spacing: 8) {
                            if page.installing { ProgressView().tint(Color.hqOnTint) }
                            Text(page.installing ? "Installing…" : "Install for \(page.parent.botName)")
                                .font(Font.hq(.body).weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .hqGlassProminentButtonStyle()
                    .disabled(!page.canInstall)
                    .accessibilityIdentifier("plugin-catalog.install")
                    if let note = installNote {
                        Text(note.words).font(Font.hq(.subheadline)).foregroundStyle(note.color)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("plugin-catalog.note")
                    }
                }
                MarketplaceCommand(command: entry.installCommand)   // [marketplace]
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
        }
    }

    private var installNote: (words: String, color: Color)? {
        if let error = page.error { return (error, .red) }
        if page.uncertain {
            return ("Hermes is still working on it, or the install stopped. The Plugins list will show it once it’s done.", .orange)
        }
        if page.parent.pluginsUnavailable { return ("This gateway’s Hermes is too old to install plugins here. Update Hermes on \(HostWord.updateTarget).", Color.hqLabel2) }
        if page.parent.readOnly { return ("This gateway is read-only. Install from a gateway you can change.", Color.hqLabel2) }
        if page.installing { return ("Hermes is downloading the version Nous reviewed. This can take a minute.", Color.hqLabel2) }
        // [plugin-pages] A page for the dashboard opens in Hermes HQ too.
        if entry.addsDashboardPage { return ("It adds a page you can open in Hermes HQ.", Color.hqLabel2) }
        if entry.category == .desktop { return ("This one adds to the Hermes desktop app on \(HostWord.phrase). It won’t show in Hermes HQ.", Color.hqLabel2) }
        if !entry.requiresEnv.isEmpty {
            let keys = entry.requiresEnv.prefix(3).joined(separator: ", ")
            return ("It needs \(entry.requiresEnv.count == 1 ? "a key" : "keys") once it’s installed: \(keys).", Color.hqLabel2)
        }
        return nil
    }

    // MARK: Details

    private var detailsSection: some View {
        Section {
            if !entry.maintainer.isEmpty { detail("Made by", entry.maintainer) }
            if !entry.version.isEmpty || !entry.sha.isEmpty {
                detail("Version", [entry.version, entry.sha.isEmpty ? "" : "commit \(entry.sha.prefix(7))"].filter { !$0.isEmpty }.joined(separator: " · "))
            }
            if let stars = entry.stars { detail("GitHub stars", stars.formatted()) }
            detail("Works on", entry.platformWords ?? "Every system Hermes runs on")
            if let hermes = entry.hermesWords { detail("Needs Hermes", hermes) }
            if !entry.requiresEnv.isEmpty { detail(entry.requiresEnv.count == 1 ? "Key it needs" : "Keys it needs", entry.requiresEnv.joined(separator: ", ")) }
            if !entry.providesTools.isEmpty {
                let tools = entry.providesTools.prefix(10).joined(separator: ", ")
                detail("Tools it adds", entry.providesTools.count > 10 ? "\(tools) and \(entry.providesTools.count - 10) more" : tools)
            }
            if let updated = entry.updatedAt ?? entry.addedAt {
                detail(entry.updatedAt != nil && entry.updatedAt != entry.addedAt ? "Updated" : "Listed", updated.formatted(date: .abbreviated, time: .omitted))
            }
            if let docs = entry.docsURL { link("Learn More", docs, id: "plugin-catalog.learn-more") }
            if let site = entry.pageURL { link("See in the Hermes Marketplace", site, id: "plugin-catalog.website") }
        } header: { HQSectionLabel { Text("Details") } } footer: { HQSectionFooter {
            Text(trustWords)
        } }
    }

    private var trustWords: String {
        if entry.isOfficial { return "An official plugin, made by Nous. Hermes installs the exact version listed here." }
        if entry.isVerified { return "Certified: made by the company behind the service, checked by Nous. Hermes installs the exact version Nous reviewed." }
        return "Made by the Hermes community. Nous reviewed this exact version before listing it, and Hermes installs only that version."
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
            Text(value).foregroundStyle(Color.hqLabel).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func link(_ title: String, _ url: URL, id: String) -> some View {
        Button {
            if let host = page.host { LinkOpener.open(url, from: host) }
        } label: {
            HStack {
                Text(title).foregroundStyle(Color.hqTint)
                Spacer()
                Image(systemName: "arrow.up.right").font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqLabel3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
