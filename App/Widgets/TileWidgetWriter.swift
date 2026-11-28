// [tile-widgets] The app's side of the Tile widget (docs/spec/1x-pages.md §5.8): writes the index of the signed-in
// account's page tiles and draws each wanted tile's picture at each placed widget's own size, light and dark, into the
// store the widget reads (HomeWidgetsKit/TileWidgetStore.swift). The pictures are drawn by `PageSnapshots` in the
// widget's own window (`Shape.frame`, exact points, no zoom), so a kit page lays out at the size it shows, as it does in
// a Grid tile. Drawing waits behind the pictures the screen asks for, one web view at a time (PageSnapshots' own line).
//
// Written when the pins change (a pin, an unpin, a rename, a page, a version), the bots' names change, the app comes
// to the front, a tile's job runs, a chat's turn ends, Tiles is pulled to refresh, and from the background refresh
// (`WidgetRefresh`). A write that changes no byte reloads no widget. On the Mac, and in an identity without the widget
// extension (`native`), it does nothing.

import SwiftUI
import UIKit
import WidgetKit

@MainActor
final class TileWidgetWriter {
    static let shared = TileWidgetWriter()

    /// The widget extension is in this build (only the `original` identity embeds it; never the Mac).
    static let enabled: Bool = {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HQDebugTileWidgetsOff") { return false }
        #endif
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugins.appending(path: "HermesHQTalkActivity.appex").path)
        #endif
    }()

    private var account: GatewayAccount?
    /// The signed-in account's key (`TileWidgetIndex.key`), as the widgets' links carry it; nil signed out.
    var accountKey: String? { account.map { TileWidgetIndex.key($0.id) } }
    private var pins: ArtifactPins?
    private var bots: () -> [Bot] = { [] }
    private var observers: [NSObjectProtocol] = []
    /// Tiles asked for by Add to Home Screen… this run: drawn at Small, Medium and Large too.
    private var asked: [String] = []
    /// Pictures that may be out of date (their page may have changed since): all of them at the next pass when nil.
    private var stale: Set<String>? = nil
    private var passTask: Task<Void, Never>?
    private var again = false
    /// When each spec was last drawn this run (`<tile>|<family>|<w>x<h>`).
    private var drawn: [String: Date] = [:]
    /// [tiles-v2] Last `<sha256>|<themeSignature>` drawn for each spec key so unchanged HTML + theme skips re-encoding.
    private var drawnHashes: [String: String] = [:]
    /// [tiles-v2] Whether the current gateway answered 404/501 for `/api/tiles/widget-snapshot` (resets on account switch).
    private var remoteSnapshotUnsupported = false
    /// The account key of the last index written (a different account's pictures all go).
    private var writtenAccount: String?
    /// Last theme signature drawn for widgets (light + dark).
    private var lastThemeKey: String?
    /// Serial background queue for all Keychain widget store I/O so `@MainActor` never blocks on IPC/encoding.
    nonisolated private static let ioQueue = DispatchQueue(label: "ai.hermes.hq.tile-widget-io", qos: .utility)

    private nonisolated static func onIO<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: work()) }
        }
    }

    /// The widgets' own page context per bot: its generation moves with the widgets' redraws alone.
    private func context(_ pin: ArtifactPin) -> MediaContext {
        MediaContext(accountId: account?.id ?? "", profile: pin.profile, storedSessionId: Self.contextTag)
    }
    static let contextTag = "hq-widget"

    // MARK: Signed in and out

    /// The Pages tabs were made for this account (sign-in, launch, a gateway switch).
    func attach(account: GatewayAccount, bots: @escaping () -> [Bot]) {
        guard Self.enabled else { return }
        detachObservers()
        passTask?.cancel()
        passTask = nil
        again = false
        self.account = account
        pins = ArtifactPins.of(accountId: account.id)
        self.bots = bots
        stale = nil
        drawn = [:]
        drawnHashes = [:]
        remoteSnapshotUnsupported = false
        lastThemeKey = Self.themeSignature()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ArtifactPins.didChange, object: pins, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        })
        observers.append(center.addObserver(forName: SessionStrip.listChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(drawing: false) }   // a bot renamed: the index's bot names
        })
        observers.append(center.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.themeChanged() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageMayHaveChanged(nil) }
        })
        observers.append(center.addObserver(forName: TileUpdates.ran, object: nil, queue: .main) { [weak self] note in
            let id = note.object as? String
            MainActor.assumeIsolated { self?.pageMayHaveChanged(id.map { [$0] }) }
        })
        observers.append(center.addObserver(forName: PageSnapshots.turnEnded, object: nil, queue: .main) { [weak self] note in
            let context = (note.object as? ContextBox)?.context
            MainActor.assumeIsolated {
                guard let self, let context, context.storedSessionId != Self.contextTag, context.accountId == self.account?.id else { return }
                // A chat's turn ended, or Tiles was pulled to refresh: that bot's tiles may have changed.
                let ids = self.pins?.pins.filter { $0.profile == context.profile }.map(\.id) ?? []
                if !ids.isEmpty { self.pageMayHaveChanged(ids) }
            }
        })
        schedule()
    }

    /// Sign-out (or a launch with nobody signed in, a gateway switch): the widgets say "Open Hermes HQ", every
    /// picture and want goes. Nothing of the account stays.
    func signedOut() {
        guard Self.enabled else { return }
        detachObservers()
        passTask?.cancel()
        passTask = nil
        again = false
        account = nil
        pins = nil
        asked = []
        drawn = [:]
        drawnHashes = [:]
        remoteSnapshotUnsupported = false
        writtenAccount = nil
        lastThemeKey = nil
        let scheme = AppIdentity.current.urlScheme
        Self.ioQueue.async {
            TileWidgetStore.signOut(scheme: scheme)
            Self.reload()
            AppLog.note("widgets", "tile widgets: signed out")
            #if DEBUG
            Task { @MainActor in Self.showProbe() }
            #endif
        }
    }

    private func detachObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    // MARK: Asking

    /// Add to Home Screen…: this tile's Small, Medium and Large pictures, drawn now.
    func prepare(_ pin: ArtifactPin) {
        guard Self.enabled else { return }
        let key = TileWidgetIndex.key(pin.id)
        if !asked.contains(key) { asked.append(key) }
        pageMayHaveChanged([pin.id])
    }

    /// The pages of `ids` (nil: all) may have changed: their pictures are drawn again at the next pass.
    func pageMayHaveChanged(_ ids: [String]?) {
        guard account != nil else { return }
        if let ids {
            if stale != nil { stale?.formUnion(ids.map(TileWidgetIndex.key)) }
        } else {
            stale = nil
        }
        schedule()
    }

    private static func themeSignature() -> String {
        PageSnapshots.themeKey(dark: false) + "|" + PageSnapshots.themeKey(dark: true)
    }

    private func themeChanged() {
        let next = Self.themeSignature()
        guard next != lastThemeKey else {
            schedule(drawing: false)   // only the tint/non-page tokens changed
            return
        }
        lastThemeKey = next
        drawn = [:]
        drawnHashes = [:]
        stale = nil
        schedule(drawing: true)
    }

    /// One pass soon (several asks in a moment make one).
    private func schedule(drawing: Bool = true) {
        guard Self.enabled, account != nil else { return }
        if passTask != nil { again = true; return }
        passTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, self.account != nil else { return }
            await self.pass(drawing: drawing)
            guard !Task.isCancelled, self.account != nil else { return }
            self.passTask = nil
            if self.again { self.again = false; self.schedule() }
        }
    }

    /// The background refresh's and a push's pass (`WidgetRefresh`); true when a byte changed. `drawing` false (the app
    /// is in the background): the index alone (names, order, a tile unpinned), and every picture is drawn again at the
    /// next pass on screen. A page's picture can't be drawn in the background: WebKit draws nothing for an app off the
    /// screen (seen 2026-11-19: a background pass drew no picture in 25 s, against 1.5 s each on screen).
    func refreshAll(drawing: Bool) async -> Bool {
        guard Self.enabled, account != nil else { return false }
        passTask?.cancel()
        passTask = nil
        stale = nil
        drawn = [:]
        drawnHashes = [:]
        remoteSnapshotUnsupported = false   // every placed picture read again, even one drawn a minute ago
        return await pass(drawing: drawing)
    }

    // MARK: The pass

    /// Returns whether an in-flight widget pass still belongs to the active account (pure guard for sign-out / switch races).
    nonisolated static func shouldPersist(cancelled: Bool, currentAccountId: String?, expectedAccountId: String) -> Bool {
        !cancelled && currentAccountId == expectedAccountId
    }

    private func isStillCurrent(_ account: GatewayAccount) -> Bool {
        Self.shouldPersist(cancelled: Task.isCancelled, currentAccountId: self.account?.id, expectedAccountId: account.id)
    }

    /// Writes the index, draws what is wanted and stale, removes what isn't wanted; reloads the widgets once if any byte
    /// changed. Returns whether it did.
    @discardableResult
    private func pass(drawing: Bool) async -> Bool {
        guard let account, let pins else { return false }
        let index = Self.index(pins: pins, bots: bots(), account: account, scheme: AppIdentity.current.urlScheme,
                               tint: Self.tints())
        let prevWrittenAccount = writtenAccount
        let placed = await Self.placed()
        guard isStillCurrent(account) else { return false }
        writtenAccount = index.account
        let sizes = Self.fallbackSizes(), now = Date(), askedSnapshot = asked
        let prep: (changed: Bool, live: [TilePictureSpec], specs: [TilePictureSpec], aheadOnly: Set<TilePictureSpec>, existingPictures: Set<String>) = await Self.onIO {
            var changed = false
            if prevWrittenAccount != index.account, let kept = TileWidgetStore.loadIndex(), kept.account != index.account {
                changed = TileWidgetStore.keepPictures([]) || changed   // another account's pictures go
            }
            if TileWidgetStore.loadIndex() != index {
                changed = TileWidgetStore.saveIndex(index) || changed
            }
            let wants = TileWidgetStore.wants()
            let live = TileWidgetPlan.wanted(index: index, wants: wants, placed: placed, asked: askedSnapshot, fallback: sizes, now: now)
            // [tile-widgets] Every tile's three sizes are kept too, so one picked in Edit Widget shows at once.
            let specs = TileWidgetPlan.wanted(index: index, wants: wants, placed: placed, asked: askedSnapshot,
                                              ahead: TileWidgetPlan.aheadTiles, fallback: sizes, now: now)
            let aheadOnly = TileWidgetPlan.aheadOnly(all: specs, live: live)
            changed = TileWidgetStore.keepPictures(specs) || changed
            let existingPictures = Set(WidgetVault.accounts(service: TileWidgetStore.pictureService))
            return (changed, live, specs, aheadOnly, existingPictures)
        }
        guard isStillCurrent(account) else { return false }
        var changed = prep.changed
        var existingPictures = prep.existingPictures
        let live = prep.live, specs = prep.specs, aheadOnly = prep.aheadOnly
        let themeSig = Self.themeSignature()
        if drawing {
            let due = Self.due(specs, stale: stale, drawn: drawn, aheadOnly: aheadOnly, has: { spec in
                existingPictures.contains(TileWidgetStore.pictureAccount(spec.tile, spec.family, dark: false))
                    && existingPictures.contains(TileWidgetStore.pictureAccount(spec.tile, spec.family, dark: true))
            })
            stale = []
            var freshened = Set<MediaContext>()
            for spec in due {
                guard isStillCurrent(account),
                      let tile = index.tiles.first(where: { $0.id == spec.tile }),
                      let pin = pins.pins.first(where: { $0.id == tile.pin }), let path = pin.gatewayPath else { continue }
                // Read again once a pass, for each bot: the bot may have rewritten its page.
                let context = context(pin)
                if freshened.insert(context).inserted { PageSnapshots.shared.freshen(context) }
                let key = Self.specKey(spec)
                let hadBoth = existingPictures.contains(TileWidgetStore.pictureAccount(spec.tile, spec.family, dark: false))
                    && existingPictures.contains(TileWidgetStore.pictureAccount(spec.tile, spec.family, dark: true))
                var unchangedSkip = false
                for dark in [false, true] {
                    guard isStillCurrent(account) else { return false }
                    await Self.waitForTheScreen()
                    guard isStillCurrent(account) else { return false }
                    guard let image = await Self.draw(pin, path: path, spec: spec, dark: dark, context: context) else { continue }
                    guard isStillCurrent(account) else { return false }
                    if !dark, hadBoth,
                       let htmlHash = PageSnapshots.shared.lastHash(path: path, context: context),
                       drawnHashes[key] == "\(htmlHash)|\(themeSig)" {
                        unchangedSkip = true
                        break
                    }
                    let tileId = spec.tile, family = spec.family
                    let saved = await Self.onIO { TileWidgetStore.savePicture(image, tile: tileId, family: family, dark: dark) }
                    guard isStillCurrent(account) else { return false }
                    if saved != .refused { existingPictures.insert(TileWidgetStore.pictureAccount(tileId, family, dark: dark)) }
                    if saved == .written { changed = true }
                    AppLog.trace("widgets", "tile picture \(spec.family.rawValue) \(spec.width)x\(spec.height) pt \(dark ? "dark" : "light"): "
                                 + "\(Int(image.width * image.scale)) by \(Int(image.height * image.scale)) px drawn, \(image.jpeg.count / 1024) KB, \(saved)")
                }
                guard isStillCurrent(account) else { return false }
                if let hash = PageSnapshots.shared.lastHash(path: path, context: context), !unchangedSkip {
                    drawnHashes[key] = "\(hash)|\(themeSig)"
                }
                drawn[key] = Date()
            }
        } else if !remoteSnapshotUnsupported, let client = JobsStore.current?.client, client.account.id == account.id {
            // [tiles-v2] Background refresh path (1x-pages.md §5.8 rule 10): fetch gateway/add-on pre-rendered widget
            // JPEGs for placed widgets with zero WKWebView work. Short-circuits on 404/501 for older gateways.
            let scale = Int(max(1, min(3, (UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.scale }.first ?? 3).rounded())))
            for spec in live {
                guard isStillCurrent(account), !remoteSnapshotUnsupported,
                      let tile = index.tiles.first(where: { $0.id == spec.tile }),
                      let pin = pins.pins.first(where: { $0.id == tile.pin }), let path = pin.gatewayPath else { continue }
                for dark in [false, true] {
                    guard isStillCurrent(account) else { return false }
                    let outcome = await TileWidgetRemote.fetch(client: client, path: path, profile: pin.profile,
                                                               width: spec.width, height: spec.height, dark: dark,
                                                               scale: scale, maxBytes: TileWidgetStore.maxPictureBytes)
                    guard isStillCurrent(account) else { return false }
                    switch outcome {
                    case .picture(let jpeg, let pxW, let pxH):
                        let points = CGSize(width: Double(pxW) / Double(scale), height: Double(pxH) / Double(scale))
                        let pic = TilePicture(drawnAt: Date(), width: Double(spec.width), height: Double(spec.height),
                                              scale: Double(scale),
                                              fills: TileWidgetPlan.fills(points, in: CGSize(width: spec.width, height: spec.height)),
                                              edge: nil, jpeg: jpeg)
                        let tileId = spec.tile, family = spec.family
                        if await Self.onIO({ TileWidgetStore.savePicture(pic, tile: tileId, family: family, dark: dark) }) == .written {
                            changed = true
                        }
                        guard isStillCurrent(account) else { return false }
                    case .unsupported:
                        remoteSnapshotUnsupported = true
                        AppLog.trace("widgets", "tile widgets: gateway has no remote widget snapshot route; skipping background fetch")
                    case .unavailable:
                        break
                    }
                    if remoteSnapshotUnsupported { break }
                }
            }
        }
        guard isStillCurrent(account) else { return false }
        if changed { Self.reload() }
        AppLog.trace("widgets", "tile widgets: \(index.tiles.count) tile(s), \(specs.count) picture size(s)\(changed ? ", reloaded" : "")")
        #if DEBUG
        Self.showProbe()
        #endif
        return changed
    }

    #if DEBUG
    private static weak var probeView: UIView?

    /// `-HQDebugWidgetProbe YES` (UI tests): what the widget store holds, read back from it, on a 1 pt element
    /// `debug.widgets`: "tiles=<n> pictures=<n> account=<key> first=<key> state=<live|signedOut>".
    static func showProbe() {
        guard UserDefaults.standard.bool(forKey: "HQDebugWidgetProbe") else { return }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        guard let window else { return }
        let view = probeView ?? {
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = "debug.widgets"
            probeView = view
            return view
        }()
        if view.superview !== window { window.addSubview(view) }
        let index = TileWidgetStore.loadIndex()
        let pictures = WidgetVault.accounts(service: TileWidgetStore.pictureService).count
        view.accessibilityValue = "tiles=\(index?.tiles.count ?? 0) pictures=\(pictures) account=\(index?.account ?? "-") "
            + "first=\(index?.defaultTile?.id ?? "-") state=\(index.map { "\($0.state)" } ?? "-")"
            + tasksProbe()
    }

    /// [tasks-widget] " tasks=<state> taskviews=<n> today=<count> rows=<n> firsttask=<id> firsttitle=<words, escaped>"
    /// (the fixture's made-up tasks; never task text in the log).
    private static func tasksProbe() -> String {
        let index = TasksWidgetStore.loadIndex()
        let today = TasksWidgetStore.loadView(TasksWidgetIndex.defaultView)?.frame(at: Date())
        let first = today?.sections.first?.rows.first
        let title = first?.title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "-"
        return " tasks=\(index.map { $0.state.rawValue } ?? "-") taskviews=\(index?.views.count ?? 0) today=\(today?.count ?? -1)"
            + " rows=\(today?.rowCount ?? -1) firsttask=\(first?.id ?? "-") firsttitle=\(title) taskaccount=\(index?.account ?? "-")"
    }
    #endif

    static func specKey(_ spec: TilePictureSpec) -> String { "\(spec.tile)|\(spec.family.rawValue)|\(spec.width)x\(spec.height)" }

    /// The specs to draw this pass: those with no picture in a look yet, and those whose page may have changed
    /// (`stale` nil: all of them), unless drawn in the last minute.
    /// `aheadOnly` (kept ahead of a choice, on no widget yet): drawn only while they have no picture.
    static func due(_ specs: [TilePictureSpec], stale: Set<String>?, drawn: [String: Date],
                    aheadOnly: Set<TilePictureSpec> = [], has: (TilePictureSpec) -> Bool,
                    now: Date = Date()) -> [TilePictureSpec] {
        specs.filter { spec in
            if !has(spec) { return true }
            if aheadOnly.contains(spec) { return false }
            if let at = drawn[specKey(spec)], now.timeIntervalSince(at) < 60 { return false }
            return stale.map { $0.contains(spec.tile) } ?? true
        }
    }

    /// The index the widget reads: the account's page tiles in the Tiles page's order, named as Tiles names them.
    static func index(pins: ArtifactPins, bots: [Bot], account: GatewayAccount, scheme: String, tint: (Int?, Int?)) -> TileWidgetIndex {
        let pageNames = Dictionary(pins.pages.map { ($0.id, $0.name) }) { a, _ in a }
        let tiles = pins.pins.filter { $0.isPage && $0.gatewayPath != nil }.map { pin in
            let page = pins.pageId(of: pin)
            return TileWidgetIndex.Tile(id: TileWidgetIndex.key(pin.id), pin: pin.id, name: pins.name(pin),
                                        bot: PagesNames.botName(pin.profile, bots: bots), profile: pin.profile,
                                        page: page == DashboardPage.mainId ? TileWidgetIndex.mainPage : page,
                                        pageName: pageNames[page] ?? DashboardPage.main.name, order: 0)
        }
        let pages = pins.pages.map { $0.id == DashboardPage.mainId ? TileWidgetIndex.mainPage : $0.id }
        return TileWidgetIndex(state: .live, scheme: scheme, account: TileWidgetIndex.key(account.id), tint: tint.0,
                               tintDark: tint.1, tiles: TileWidgetIndex.ordered(tiles, pages: pages))
    }

    // MARK: Drawing one picture

    /// One picture: the page drawn at the widget's size in points × the screen's scale, both looks apart; a page that
    /// isn't made for its window comes back as its best part, fitted inside the widget's pixels.
    private static func draw(_ pin: ArtifactPin, path: String, spec: TilePictureSpec, dark: Bool,
                             context: MediaContext) async -> TilePicture? {
        let shape = PageSnapshots.Shape.frame(width: spec.width, height: spec.height, zoom: 100)
        let image: UIImage? = await withCheckedContinuation { continuation in
            PageSnapshots.shared.picture(path: path, name: pin.label, context: context, dark: dark, shape: shape,
                                         priority: .background) {
                continuation.resume(returning: $0)
            }
        }
        guard let image, let cg = image.cgImage else { return nil }
        let scale = Double(image.scale)
        #if DEBUG
        let oversize = UserDefaults.standard.double(forKey: "HQDebugWidgetOversize")
        #else
        let oversize = 0.0
        #endif
        return await Task.detached(priority: .utility) {
            let pixels = CGSize(width: Double(spec.width) * scale, height: Double(spec.height) * scale)
            var fitted = TilePictureEncoding.fitted(cg, inside: pixels)
            #if DEBUG
            if oversize > 1, let space = CGColorSpace(name: CGColorSpace.sRGB),
               let big = CGContext(data: nil, width: Int(Double(fitted.width) * oversize), height: Int(Double(fitted.height) * oversize),
                                   bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                big.draw(fitted, in: CGRect(x: 0, y: 0, width: big.width, height: big.height))
                if let made = big.makeImage() { fitted = made }
            }
            #endif
            guard let jpeg = TilePictureEncoding.jpeg(fitted) else {
                AppLog.note("widgets", "tile widgets: a picture over the cap was left out")
                return nil
            }
            let points = CGSize(width: Double(fitted.width) / scale, height: Double(fitted.height) / scale)
            return TilePicture(drawnAt: Date(), width: Double(spec.width), height: Double(spec.height), scale: scale,
                               fills: TileWidgetPlan.fills(points, in: CGSize(width: spec.width, height: spec.height)),
                               edge: Self.edgeHex(cg), jpeg: jpeg)
        }.value
    }

    /// Samples the bottom edge color of a drawn tile image (pure CGContext, safe off the main actor).
    nonisolated private static func edgeHex(_ cg: CGImage) -> Int? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 1 - CGFloat(cg.height), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        guard px[3] > 200 else { return nil }
        return Int(px[0]) << 16 | Int(px[1]) << 8 | Int(px[2])
    }

    /// Waits while the screen's own pictures draw (at most 20 s), so a widget's never holds a visible tile back.
    private static func waitForTheScreen() async {
        for _ in 0..<100 where PageSnapshots.shared.isBusy {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: The system's side

    nonisolated static func reload() {
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    nonisolated static let kind = "ai.hermes.hq.tile"

    /// The Tile widgets on the Home Screen now, by tile and family (nil when the system can't say).
    static func placed() async -> [(tile: String?, family: TileFamily)]? {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                guard case .success(let infos) = result else { return continuation.resume(returning: nil) }
                let tiles = infos.filter { $0.kind == kind }.compactMap { info -> (tile: String?, family: TileFamily)? in
                    guard let family = family(info.family) else { return nil }
                    return (info.widgetConfigurationIntent(of: TileWidgetIntent.self)?.tile?.id, family)
                }
                continuation.resume(returning: tiles)
            }
        }
    }

    nonisolated static func family(_ family: WidgetFamily) -> TileFamily? {
        switch family {
        case .systemSmall: .small
        case .systemMedium: .medium
        case .systemLarge: .large
        case .systemExtraLarge: .extraLarge
        default: nil
        }
    }

    static func fallbackSizes() -> [TileFamily: CGSize] {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }.first
            ?? CGSize(width: 402, height: 874)
        return TileWidgetPlan.fallbackSizes(screen: screen, pad: UIDevice.current.userInterfaceIdiom == .pad)
    }

    /// The theme's tint in each look, 0xRRGGBB.
    static func tints() -> (Int?, Int?) {
        let tint = UIColor(Color.hqTint)
        return (hex(tint.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))),
                hex(tint.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))))
    }

    static func hex(_ color: UIColor) -> Int {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}
