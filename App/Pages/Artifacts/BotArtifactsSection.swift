// Bot Info › Artifacts (tester, 2026-10-31: "if the Bot's menu could show its artifacts like iMessage shows
// links/attachments"), as iMessage's details list a chat's photos, links and documents: the bot's newest pages and
// pictures as a grid of small pictures, its newest files and links as rows, and All Artifacts, which opens Artifacts
// for this bot alone inside the sheet. Read from the Artifacts index already kept on the device (no transcript is read
// to draw it); All Artifacts reads the chats that changed since.
// [tabs] 2026-11-01: its own tab (Bot Info was "getting really busy"), so the strip became a grid, and the bot's pins
// lead it.

import SwiftUI
import UIKit

@MainActor @Observable
final class BotArtifactsModel {
    let profile: String
    private(set) var records: [ArtifactRecord] = []
    private(set) var loaded = false
    /// Bumped when a picture lands.
    private(set) var tick = 0
    /// [tabs] The bot's pins, in the order Pinned shows them.
    private(set) var pinned: [ArtifactPin] = []
    @ObservationIgnored let pictures: PinPictures
    @ObservationIgnored private let store: ArtifactsStore
    @ObservationIgnored private let pins: ArtifactPins
    @ObservationIgnored private var asked = false
    @ObservationIgnored private var pinsObserver: NSObjectProtocol?
    @ObservationIgnored private var hiddenObserver: NSObjectProtocol?
    private var hidden: ArtifactHidden { store.hidden }

    init(store: ArtifactsStore, profile: String) {
        self.store = store
        self.profile = profile
        pins = ArtifactPins.of(accountId: store.account.id)
        pictures = PinPictures(account: store.account, previews: ArtifactPreviews(client: store.client, account: store.account))
        pictures.onUpdate = { [weak self] id in
            self?.tick += 1
            self?.notePage(id)
        }
        readPins()
        pinsObserver = NotificationCenter.default.addObserver(forName: ArtifactPins.didChange, object: pins, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readPins() }
        }
        // Removed in Artifacts (or See All): gone here too.
        hiddenObserver = NotificationCenter.default.addObserver(forName: ArtifactHidden.didChange, object: store.hidden, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.readPins()
                self.records = self.hidden.visible(self.records)
            }
        }
    }

    isolated deinit {
        if let pinsObserver { NotificationCenter.default.removeObserver(pinsObserver) }
        if let hiddenObserver { NotificationCenter.default.removeObserver(hiddenObserver) }
    }

    private func readPins() { pinned = hidden.visible(pins.pins).filter { $0.profile == profile } }

    /// Mac polish #45: each pin's name as Tiles shows it (it was the file's, "index.html"), by its record's id.
    var tileNames: [String: String] {
        Dictionary(pinned.map { ($0.record.id, pins.name($0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Mac polish #45: a pinned page just pictured here names itself from its title from now on, as on Tiles.
    private func notePage(_ id: String) {
        guard let pin = pinned.first(where: { $0.id == id }), pin.isPage, let path = pin.gatewayPath,
              let head = PageSnapshots.shared.head(path: path, context: pictures.context(pin)) else { return }
        pins.notePage(id: id, head: head)
    }

    /// The pages and pictures for the grid, newest first (three rows of three).
    /// An icon-sized picture already seen (`ArtifactThumbs.isTiny`) is left out.
    var visual: [ArtifactRecord] {
        Array(unpinned.filter { ($0.kind == .image && !ArtifactThumbs.shared.isTiny(store.account, $0.id)) || Self.isPage($0) }.prefix(9))
    }
    /// The newest files and links.
    var others: [ArtifactRecord] { Array(unpinned.filter { $0.kind != .image && !Self.isPage($0) }.prefix(5)) }

    /// Mac polish #111: what is on Tiles shows once, under On Tiles (it showed again under Pages & Pictures, with no pin).
    private var unpinned: [ArtifactRecord] {
        let tiles = Set(pinned.map(\.id))
        return records.filter { !tiles.contains(ArtifactPin.key(profile: $0.profile, value: $0.value)) }
    }

    static func isPage(_ record: ArtifactRecord) -> Bool {
        record.kind == .file && ["html", "htm"].contains(ArtifactFiles.fileExtension(record.value))
    }

    func load() {
        guard !asked else { return }
        asked = true
        Task { [weak self] in
            guard let self else { return }
            await self.store.index.ready()
            let mine = self.store.index.entries.values.flatMap(\.artifacts).filter { ($0.profile ?? "default") == self.profile }
            self.records = self.hidden.visible(ArtifactCollector.unique(mine)).filter { !self.store.unavailable.contains($0.id) }
            self.loaded = true
            AppLog.trace("pages", "bot info artifacts: \(self.records.count) for one bot")
        }
    }

    func picture(_ record: ArtifactRecord, dark: Bool) -> UIImage? {
        _ = tick
        return pictures.picture(ArtifactPin(record), dark: dark, pixels: 120 * 3, shape: .box(aspect: 1))
    }
}

/// The Artifacts tab in Bot Info: Pinned (the bot's pins), Pages & Pictures, Files & Links, then All Artifacts.
struct BotArtifactsSection: View {
    var model: BotArtifactsModel
    var botName: String
    var open: (ArtifactRecord) -> Void
    var seeAll: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Three across a phone's sheet (two at the accessibility sizes), more where the sheet is wider.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 140 : 92, maximum: 160), spacing: 10, alignment: .top)]
    }

    var body: some View {
        Group {
            if model.loaded && model.records.isEmpty && model.pinned.isEmpty {
                Section {
                    Button(action: seeAll) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Artifacts").foregroundStyle(Color.hqLabel)
                                Text("Pages, pictures, files and links from \(botName)’s chats")
                                    .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            }
                            Spacer(minLength: 8)
                            SettingsChevron()
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("bot-info.artifacts.find")
                }
            } else {
                if !model.pinned.isEmpty {
                    Section {
                        grid(model.pinned.map(\.record), names: model.tileNames, identifier: "bot-info.pin-tile")
                    } header: { HQSectionLabel { Text("On Tiles") } }
                }
                if !model.visual.isEmpty {
                    Section {
                        grid(model.visual, identifier: "bot-info.artifact-tile")
                    } header: { HQSectionLabel { Text("Pages & Pictures") } }
                }
                if !model.others.isEmpty {
                    Section {
                        ForEach(model.others, id: \.id) { record in
                            Button { open(record) } label: { row(record) }
                                .accessibilityIdentifier("bot-info.artifact-row")
                        }
                    } header: { HQSectionLabel { Text("Files & Links") } }
                }
                Section {
                    if model.loaded {
                        Button(action: seeAll) {
                            HStack {
                                Text("All Artifacts").foregroundStyle(Color.hqLabel)
                                Spacer(minLength: 8)
                                Text("\(model.records.count)").foregroundStyle(Color.hqLabel2).monospacedDigit()
                                SettingsChevron()
                            }
                        }
                        .accessibilityIdentifier("bot-info.artifacts.all")
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }
            }
        }
        .onAppear { model.load() }
    }

    /// `names`: a tile's own name by record id (On Tiles); otherwise the file's.
    private func grid(_ records: [ArtifactRecord], names: [String: String] = [:], identifier: String) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(records, id: \.id) { record in
                let name = names[record.id] ?? record.label
                Button { open(record) } label: { tile(record, name: name) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Self.kindWord(record)), \(name)")
                    .accessibilityIdentifier(identifier)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .listRowInsets(EdgeInsets())
    }

    private static func kindWord(_ record: ArtifactRecord) -> String {
        BotArtifactsModel.isPage(record) ? "Page" : record.kind == .image ? "Image" : record.kind == .link ? "Link" : "File"
    }

    private func tile(_ record: ArtifactRecord, name: String) -> some View {
        let picture = model.picture(record, dark: scheme == .dark)
        let page = BotArtifactsModel.isPage(record)
        let fill = picture.flatMap { page ? PinPictures.edgeColor($0) : nil }.map { Color(uiColor: $0) } ?? Color.hqFill3
        let shape = RoundedRectangle(cornerRadius: HQShape.radius(10, .card), style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Rectangle().fill(fill)
                        .overlay {
                            if let picture {
                                if page {
                                    PagePictureView(picture: picture, padding: 4)
                                } else {
                                    Image(uiImage: picture).resizable().scaledToFill()
                                }
                            } else {
                                Image(systemName: PinCardView.glyph(ArtifactPin(record)))
                                    .hqSymbolFont(20, weight: .light, cap: 30).foregroundStyle(Color.hqLabel3)
                            }
                        }
                }
                .clipShape(shape)
                .overlay { shape.strokeBorder(Color.hqStroke, lineWidth: Theme.isDesktop ? 1 : 0.5) }
                .overlay(alignment: .bottomLeading) {
                    if page {
                        Image(systemName: "safari").hqSymbolFont(10, weight: .semibold, cap: 14).foregroundStyle(.white)
                            .padding(4).background(Circle().fill(Color.black.opacity(0.45))).padding(5)
                    }
                }
            // The name stops growing at the largest standard size (VoiceOver reads it whole).
            Text(name)
                .font(typeSize.isAccessibilitySize ? Font(HQFont.style(.caption2, cap: 15) as CTFont) : Font.hq(.caption2))
                .foregroundStyle(Color.hqLabel2)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private func row(_ record: ArtifactRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ArtifactRowView.glyph(record))
                .hqSymbolFont(15, cap: 22)
                .foregroundStyle(Color.hqTint)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: HQShape.radius(8, .card), style: .continuous).fill(Color.hqFill3))
            VStack(alignment: .leading, spacing: 1) {
                Text(record.label).foregroundStyle(Color.hqLabel).lineLimit(1).truncationMode(.middle)
                Text(ArtifactListWords.subtitle(sessionTitle: record.sessionTitle, timestamp: record.timestamp))
                    .font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

extension PagesTabs {
    /// Bot Info › Artifacts, for the signed-in gateway (none in previews and tests without one).
    func botArtifactsSection(_ bot: Bot, host: UIViewController) -> AnyView? {
        guard let store = artifactsStore else { return nil }
        let model = BotArtifactsModel(store: store, profile: bot.id)
        return AnyView(BotArtifactsSection(model: model, botName: bot.name, open: { [weak self, weak host] record in
            guard let self, let host else { return }
            self.openBotArtifact(record, model: model, from: host)
        }, seeAll: { [weak self, weak host] in
            guard let self, let navigation = host?.navigationController, let page = self.makeBotArtifacts(profile: bot.id) else { return }
            PagesHaptics.selection()
            navigation.pushViewController(page, animated: true)
        }))
    }

    /// A page live, a picture or file as the chat opens it, a link in the browser; a relative path (resolved against
    /// its chat's folder) goes through the bot's Artifacts page.
    private func openBotArtifact(_ record: ArtifactRecord, model: BotArtifactsModel, from host: UIViewController) {
        if record.kind == .link || ArtifactFiles.opening(record) == .link {
            if let url = URL(string: record.value) { UIApplication.shared.open(url) }
            return
        }
        let pin = ArtifactPin(record)
        if let path = pin.gatewayPath, path.hasPrefix("/") || path.hasPrefix("~") {
            AppLog.trace("pages", "bot info artifact opened (\(record.kind.rawValue))")
            FilePreviewPresenter.shared.open(path: path, name: record.label, context: model.pictures.context(pin), from: host, row: nil)
            return
        }
        guard let navigation = host.navigationController, let page = makeBotArtifacts(profile: model.profile) else { return }
        navigation.pushViewController(page, animated: true)
        page.loadViewIfNeeded()
        page.open(record)
    }

    /// Artifacts for one bot, pushed inside Bot Info: its own store, starting from the shared index's entries for the
    /// bot (in memory: it never writes the shared file). Show in Chat closes the sheet and opens the chat behind it.
    func makeBotArtifacts(profile: String) -> ArtifactsViewController? {
        guard let main = artifactsStore, let scope, let services else { return nil }
        let store = ArtifactsStore(client: main.client, account: main.account, directory: nil, scope: profile)
        store.profilesProvider = main.profilesProvider
        store.displayName = main.displayName
        let prefix = ArtifactIndex.key(profile: profile, id: "")
        store.index.seed(main.index.entries.filter { $0.key.hasPrefix(prefix) })
        let page = ArtifactsViewController(store: store, scope: scope, services: services, fixedProfile: profile, makeChat: makeChat)
        page.navigationItem.largeTitleDisplayMode = .never
        page.showInChatOverride = { [weak page] record in
            guard let sheet = page?.navigationController else { return }
            let session = SessionSummary(id: record.sessionId, profile: record.profile ?? "default", title: record.sessionTitle,
                                         preview: nil, lastActive: nil, source: nil, unread: false, isRunning: false)
            sheet.dismiss(animated: true) {
                BotExtras.botsList()?.push(services.chat(for: session))
            }
        }
        return page
    }
}

#if DEBUG
extension PagesTabs {
    /// [pins] `-HQDebugMacShotsPins` (MacShots): Artifacts with its newest artifacts pinned, as cards, rows and
    /// [dashboard] a grid; the Pinned page each way (Grid with sizes, and without names), then [tabs] each of Deploys'
    /// Bot Info tabs. `shoot` photographs the window under a name.
    func debugPinsTour(root: MainTabController, shoot: (String) async -> Void) async {
        guard let store = artifactsStore, let stack = more?.navigationController else { return }
        ArtifactPins.view = .cards
        ArtifactPins.showsNames = true
        root.select(.more)
        stack.pushViewController(makeArtifacts(), animated: false)
        await store.index.ready()
        try? await Task.sleep(for: .seconds(5))
        let pins = ArtifactPins.of(accountId: store.account.id)
        let newest = ArtifactCollector.unique(store.index.entries.values.flatMap(\.artifacts)).sorted { $0.timestamp > $1.timestamp }
        // Pages and pictures first: a dashboard's tiles.
        let visual = newest.filter { $0.kind == .image || BotArtifactsModel.isPage($0) }
        for record in (visual + newest).prefix(6) where !pins.isPinned(record) { _ = pins.toggle(record) }
        for pin in pins.pins { pins.setSize(.small, id: pin.id) }
        try? await Task.sleep(for: .seconds(5))
        await shoot("pins-shelf")
        ArtifactPins.view = .list
        try? await Task.sleep(for: .seconds(2))
        await shoot("pins-shelf-list")
        ArtifactPins.view = .grid
        try? await Task.sleep(for: .seconds(3))
        await shoot("pins-shelf-grid")
        stack.pushViewController(makePinned(), animated: false)
        try? await Task.sleep(for: .seconds(4))
        await shoot("pins-page-grid")
        let sizes: [PinTileSize] = [.medium, .small, .small, .large, .small, .medium]
        for (pin, size) in zip(pins.pins, sizes) { pins.setSize(size, id: pin.id) }
        try? await Task.sleep(for: .seconds(4))
        await shoot("pins-page-grid-sizes")
        ArtifactPins.showsNames = false
        try? await Task.sleep(for: .seconds(2))
        await shoot("pins-page-grid-bare")
        ArtifactPins.showsNames = true
        ArtifactPins.view = .list
        try? await Task.sleep(for: .seconds(3))
        await shoot("pins-page-list")
        ArtifactPins.view = .cards
        try? await Task.sleep(for: .seconds(4))
        await shoot("pins-page")
        ArtifactPins.view = .grid
        guard let bot = root.services.bots.first(where: { $0.id == "deploys" }) ?? root.services.bots.first else {
            AppLog.trace("pages", "pins tour: no bot"); return
        }
        for tab in BotInfoTab.allCases {
            BotInfoSheet.present(bot: bot, from: root.view.window?.rootViewController ?? root, services: root.services, tab: tab)
            try? await Task.sleep(for: .seconds(tab == .artifacts ? 6 : 4))
            await shoot("pins-bot-info-\(tab.rawValue)")
            // The rest of a long tab, a sheet's height at a time.
            var top = root.view.window?.rootViewController
            while let next = top?.presentedViewController { top = next }
            func scroller(_ view: UIView) -> UIScrollView? {
                if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { return scroll }
                return view.subviews.lazy.compactMap(scroller).first
            }
            if let sheet = top?.view, let scroll = scroller(sheet) {
                for page in 1...3 {
                    let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                    if scroll.contentOffset.y >= bottom - 1 { break }
                    scroll.setContentOffset(CGPoint(x: 0, y: min(bottom, scroll.contentOffset.y + scroll.bounds.height * 0.8)), animated: false)
                    try? await Task.sleep(for: .seconds(2))
                    await shoot("pins-bot-info-\(tab.rawValue)-\(page)")
                }
            }
            top?.dismiss(animated: false)
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
#endif

/// Installs the group once; it reads the signed-in gateway's pages each time Bot Info draws.
@MainActor
enum BotArtifactsHook {
    static weak var pages: PagesTabs?
    private static var installed = false

    static func attach(_ pages: PagesTabs) {
        self.pages = pages
        guard !installed else { return }
        installed = true
        // [tabs] Bot Info's Artifacts tab.
        BotInfoHooks.artifacts = { bot, host in Self.pages?.botArtifactsSection(bot, host: host) }
    }
}
