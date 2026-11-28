import CryptoKit
import UIKit
import WebKit

// An HTML page a bot made, opened from a chat (a page card, a `MEDIA:` page, a file row): drawn live with its scripts
// running, the way the desktop app draws `::preview` in the reply
// (`V:components/assistant-ui/inline-preview-directive.tsx`). Quick Look shows HTML without running scripts, so a chart
// drawn by script opened blank or frozen (owner, a bot's follow-up chart, 2026-10-31). This overrides D-P8 ("no
// WKWebView") for pages; a web view is made only when a page opens or is pictured.
//
// Locked down like the desktop's sandboxed frame: no cookies or storage kept (a non-persistent store), the page reads
// only its own folder, and a tapped link leaves for the in-app Safari view instead of replacing the page.
//
// Widgets talk back as on the desktop: `window.hermes.send(prompt)` or `data-hermes-send="prompt"` on anything
// clickable sends the prompt to the chat's bot as a hidden turn (no bubble), and the page reloads when that turn ends,
// since the bot answers by rewriting the file. A sentence, not a payload (500 characters), at human speed.

final class HTMLPageSheet: UIViewController, WKNavigationDelegate, WKScriptMessageHandler {
    /// Where the page lives on the bot's computer, so it can be read again; nil for a file already on the phone.
    struct Source {
        var path: String
        var context: MediaContext
        /// Sends a prompt to the chat's bot with no bubble; nil when the page wasn't opened from a chat.
        var send: ((String) -> Void)?
        var botName: String
        /// [tasks] A page that isn't a file (a task's Task Page, drawn by the add-on): reads it again, in place of
        /// downloading `path`.
        var read: (@MainActor () async throws -> URL)? = nil
        /// [page-comment] Sends a comment on the page to the chat's bot as your message: what the bot gets, and what
        /// the bubble shows. nil when the page wasn't opened from a chat.
        var comment: ((_ text: String, _ display: String) -> Void)? = nil
    }

    /// [tiles] A page opened from Tiles: its name as the title and the file under it (owner 2026-11-03: a plain name,
    /// "show that it's an HTML file if you click it"), with when it was updated, and a clock button for its Updates.
    struct Tile {
        var name: String
        var fileName: String
        /// "Updated 5 min ago · hourly", nil when no job keeps it updated.
        var status: () async -> String?
        var menu: (UIViewController) -> UIMenu
        /// [live-tiles] The tile's buttons go to its bot (prompt, the sheet, done when the bot is): false when refused
        /// (it says why). A page opened from Tiles has no chat to send in.
        var send: ((String, UIViewController, @escaping () -> Void) -> Bool)? = nil
        var botName: String? = nil
        /// [tile-versions] The page is an earlier version of a tile, opened from Versions: no Updates button; `verb`
        /// ("Roll Back", nil for the version that shows) puts it back on the tile.
        struct Version {
            var verb: String?
            var rollBack: (UIViewController) -> Void
        }
        var version: Version? = nil
        /// [tiles] The tile's pin: when its job runs (`TileUpdates.ran`), the open page is read again in place.
        var id: String? = nil
        /// [tiles] The page's own background as its tile's picture shows it: the sheet opens in it.
        var backdrop: UIColor? = nil
        /// [tile-chats] Opens the tile's own chat (in no list): a chat button on the bar; nil when it has none.
        var openChat: ((UIViewController) -> Void)? = nil
    }

    static let maxIntentLength = 500
    private static let intentGap: TimeInterval = 1.0

    /// nil while a tile opened before its page was on this Mac is still being read (`openTile`).
    private var file: URL?
    private let source: Source?
    private let tile: Tile?
    private var webView: WKWebView?
    private let webBox = UIView()
    /// [page-comment] Holds the web view inside `webBox`: moved up while a comment's box is open (`lift`), clipped by the box.
    private let webLift = UIView()
    /// [tiles] The page has drawn once: until then the web view is hidden behind a spinner, so the sheet never shows
    /// its own empty colour and then the page's (Mac pass 2026-11-14: a black sheet, then a white page snapping in).
    private var painted = false
    /// [page-refine] The wait is drawn as the shape of a page (`PageSkeletonView`), not a spinner in an empty sheet.
    private let skeleton = PageSkeletonView()
    /// [page-refine] The page's own text (Source), made the first time it is asked for.
    private var sourceView: UITextView?
    private var showsSource = false
    /// [page-comment] Comment is on: a click on the page picks the part to comment on.
    private var commenting = false
    private var commentItem: UIBarButtonItem?
    private var moreItem: UIBarButtonItem?
    private var modeControl: UISegmentedControl?
    /// The ink that reads on the page's own colour (`inkBar`): the Source view takes it too.
    private var pageInk: UIUserInterfaceStyle = .unspecified
    private let status = UILabel()
    /// [glass-audit] Floating over the page: Liquid Glass (flattened in the Desktop Look by ThemeChrome).
    private let statusBar = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    /// [live-update-pill] Tappable glass pill shown when the bot rewrites this open page from chat/background;
    /// tapping loads the new file while preserving the current scroll position (`keptScroll`).
    private let updatePill = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let updateButton = UIButton(type: .system)
    private(set) var pendingUpdateURL: URL?
    private var checkingUpdate = false
    private var lastIntent = Date.distantPast
    private var waitingForReply = false
    /// The theme key the page was handed (`themeKey`), so a change of look or mode hands it the new one.
    private var handedThemeKey: String?
    /// [tiles] Where the page was scrolled when it was drawn again (the bot rewrote it, a look change): put back once
    /// it has drawn, so an update in place doesn't throw the reader to the top.
    private var keptScroll: [Double]?
    /// [tiles] The tile's page was read from the bot's computer (nil: not yet, or it failed with no copy to show).
    private var tileRead: (() -> Void)?
    private var statusClock: Task<Void, Never>?
    private var sourceLoadTask: Task<Void, Never>?

    /// The page's buttons can send: opened from a chat, or as a tile.
    private var talks: Bool { source?.send != nil || source?.comment != nil || tile?.send != nil }

    static func opens(_ url: URL) -> Bool { opens(name: url.lastPathComponent) }

    nonisolated static func opens(name: String) -> Bool {
        ["html", "htm"].contains((name as NSString).pathExtension.lowercased())
    }

    @discardableResult
    static func present(_ url: URL, source: Source? = nil, tile: Tile? = nil, title: String? = nil,
                        from vc: UIViewController) -> HTMLPageSheet {
        show(url, source: source, tile: tile, title: title ?? tile?.name ?? titleInPage(url) ?? url.lastPathComponent, from: vc,
             key: source?.path ?? url.standardizedFileURL.path)
    }

    /// `key`: what names the page among the Mac's page windows (its path on the bot's computer, a tile's pin), so the
    /// same page opened again takes the window it has.
    private static func show(_ url: URL?, source: Source?, tile: Tile?, title: String, from vc: UIViewController, key: String) -> HTMLPageSheet {
        let page = HTMLPageSheet(file: url, source: source, tile: tile)
        AppLog.trace("chatui", "html page opened live, talk-back \(source?.send != nil || tile?.send != nil ? "on" : "off")\(tile != nil ? ", as a tile" : "")\(url == nil ? ", page still reading" : "")")
        #if targetEnvironment(macCatalyst)
        // [mac-pages] Owner 2026-11-16: "If you click an HTML file, you can't enlarge it because it's too small to
        // actually be able to fully utilize and see." A page opens in a window of its own on the Mac, as a spreadsheet
        // or a PDF does (`MacFileWindow`): it can be resized, made full screen and set beside the chat, and its bar
        // zooms the page. An earlier version of a tile stays a sheet over Versions, where its Roll Back asks.
        if tile?.version == nil {
            page.title = title
            page.navigationItem.largeTitleDisplayMode = .never
            page.inOwnWindow = true
            if MacFileWindow.open(page: page, title: title, key: key) { return page }
            page.inOwnWindow = false
        }
        #endif
        let sheet = ChatSheet.wrap(page, title: title, detents: [.large()])
        // [ipad-polish] A page made for a browser, not a phone's width. [tiles] On the Mac: the document page size
        // (`SheetStyle.macPage`, the size a note's sheet takes too), 960 wide at most, as tall as the window allows, the
        // same every time; `macFit` below keeps it with the window as the window is resized.
        #if targetEnvironment(macCatalyst)
        SheetStyle.macPage(sheet, width: 960, from: vc)
        #else
        SheetStyle.widen(sheet, to: 960, from: vc)
        #endif
        vc.present(sheet, animated: true)
        return page
    }

    #if targetEnvironment(macCatalyst)
    // MARK: A window of its own, and zoom (Mac)

    /// [mac-pages] The page is a page window's root (`MacFileWindow.open(page:)`), not a sheet.
    fileprivate(set) var inOwnWindow = false

    /// Closing a page that has its own window closes the window (Change… and Versions from an opened tile, ⌘W).
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        guard inOwnWindow, presentedViewController == nil, let scene = viewIfLoaded?.window?.windowScene else {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        MacFileWindow.close(scene)
        if let completion { DispatchQueue.main.async(execute: completion) }
    }

    /// [mac-pages] − 100 % + in the bar (`PageZoom`).
    private lazy var zoomControls = PageZoom.Controls { [weak self] in self?.viewIfLoaded?.setNeedsLayout() }

    /// View › Make Text Bigger / Smaller / Actual Size (⌘+ ⌘− ⌘0) zoom the page in front, as they size the Terminal's
    /// text while it is in front, not the app's.
    @objc func hqTextBigger(_ sender: Any?) { PageZoom.change(by: 1) }
    @objc func hqTextSmaller(_ sender: Any?) { PageZoom.change(by: -1) }
    @objc func hqTextNormal(_ sender: Any?) { PageZoom.change(by: 0) }

    override func validate(_ command: UICommand) {
        super.validate(command)
        PageZoom.validate(command)
    }

    /// The page's size in a window this size: `SheetStyle.macPage`'s (960 wide at most, 80 a side; as tall as the
    /// window allows, never past it), so a resize keeps the size it opened at.
    private static func macFit(_ window: CGSize) -> CGSize {
        CGSize(width: max(620, min(960, window.width - 160)),
               height: min(window.height - 80, max(480, min(window.height - 180, 1100))))
    }

    /// [tiles] Mac pass 2026-11-14: the size was worked out once, when the page opened, so a page opened in a small
    /// window stayed small when the window grew, and one opened in a big window ran past a window made smaller. It
    /// follows the window now.
    private var windowWatch: WindowSizeProbe?

    /// [tiles] Mac pass round 6: ⌘W did nothing over a page (the menu's Close Chat looks past a sheet for a chat to
    /// close), while Escape and Done closed it. The page holds the keyboard, as the browser viewer does, and takes ⌘W.
    override var canBecomeFirstResponder: Bool { true }

    /// ⌘W (the menu's Close Chat) closes the page, as Done does.
    @objc func hqCloseChat(_ sender: Any?) { dismiss(animated: true) }

    /// Not while something is up over the page: the app's own ladder closes that first.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == KeyCommands.closeChat { return presentedViewController == nil && !isBeingDismissed }
        return super.canPerformAction(action, withSender: sender)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if presentedViewController == nil { becomeFirstResponder() }
        guard !inOwnWindow, windowWatch == nil, let sheet = navigationController, sheet.modalPresentationStyle == .formSheet,
              let container = sheet.presentationController?.containerView else { return }
        // The sheet's container is the window's size; a probe filling it hears every resize (UIWindowScene's
        // effectiveGeometry wasn't reported to an observer on the Mac).
        let probe = WindowSizeProbe(frame: container.bounds)
        probe.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        probe.isUserInteractionEnabled = false
        probe.changed = { [weak sheet] size in
            guard let sheet, size.width > 0, size.height > 0 else { return }
            let fit = Self.macFit(size)
            if sheet.preferredContentSize != fit { sheet.preferredContentSize = fit }
        }
        container.insertSubview(probe, at: 0)
        windowWatch = probe
    }
    #endif

    /// [tiles] A tile or pinned page opens at once: from the copy already on this Mac (the Tiles page drew it), read
    /// again behind it and drawn again only if the bot changed it. It used to wait, with nothing on screen, for the page
    /// to download again before the sheet even started to open (Mac pass 2026-11-14: three seconds of nothing on a slow
    /// gateway, and a second click cancelled it). Never read yet: the sheet opens with a spinner, and says why if the
    /// page can't be read, with Try Again.
    @discardableResult
    static func openTile(path: String, name: String, context: MediaContext, tile: Tile, from vc: UIViewController) -> HTMLPageSheet {
        let store = MediaLoader.shared.store(for: context.accountId)
        let kept = store.cachedFile(MediaStore.gatewayKey(accountId: context.accountId, profile: context.profile, path: path), name: name)
        let page = show(kept, source: FilePreviewPresenter.pageSource(path, context, from: vc), tile: tile, title: tile.name, from: vc,
                        key: tile.id.map { "tile:" + $0 } ?? path)
        page.tileRead = { [weak page] in
            if let page, !page.painted, let backdrop = tile.backdrop { page.view.backgroundColor = backdrop; page.inkBar(for: backdrop) }
            page?.skeleton.appear(after: 0)
            page?.readTile(path: path, name: name, context: context)
        }
        page.readTile(path: path, name: name, context: context)
        return page
    }

    /// The tile's page from the bot's computer; drawn again only when it differs from the copy shown.
    private func readTile(path: String, name: String, context: MediaContext) {
        contentUnavailableConfiguration = nil
        let currentFile = file
        Task { [weak self] in
            let shownFingerprint: FileFingerprint? = if let currentFile {
                await Task.detached(priority: .utility) { Self.fileFingerprint(currentFile) }.value
            } else {
                nil
            }
            do {
                // A copy already showing stays on a failure, and says so (below): the loader's own fall-back to it was silent.
                let url = try await MediaLoader.shared.file(path: path, name: name, context: context, progressKey: "page|" + path,
                                                            fresh: true, keptOnFailure: currentFile == nil)
                let freshFingerprint = await Task.detached(priority: .utility) { Self.fileFingerprint(url) }.value
                guard let self else { return }
                let changed = shownFingerprint == nil || url != self.file || freshFingerprint != shownFingerprint
                self.file = url
                if changed { self.load() }
                AppLog.trace("chatui", "tile page read again, \(changed ? "changed: drawn again" : "unchanged")")
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                if self.file != nil {
                    // A kept copy shows: it stays, and says it may be old (Mac pass 2026-11-14: nothing said so).
                    AppLog.note("chatui", "tile page could not be read again, the kept copy stays")
                    self.show(Self.lastCopyNotice(error), for: 5)
                    return
                }
                AppLog.note("chatui", "tile page could not be read: \((error as? MediaLoadError).map { String(describing: $0) } ?? "\(type(of: error))")")
                self.skeleton.vanish()
                // [tiles] Mac pass round 3: the notice sat on the tile's own colour (a light page in dark mode), its
                // words in the app's light ink, all but unreadable. Nothing of the page shows: the sheet's own colour.
                self.view.backgroundColor = ChatPalette.page
                self.navigationController?.navigationBar.overrideUserInterfaceStyle = .unspecified
                var notice = UIContentUnavailableConfiguration.empty()
                notice.image = UIImage(systemName: "exclamationmark.triangle")
                notice.text = "Couldn’t Open \(self.tile?.name ?? name)"
                notice.secondaryText = (error as? MediaLoadError)?.fileMessage ?? MediaLoadError.unreachable.fileMessage
                var button = UIButton.Configuration.bordered()
                button.title = "Try Again"
                notice.button = button
                notice.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.tileRead?() }
                self.contentUnavailableConfiguration = notice
            }
        }
    }

    /// [tiles] A page that couldn't be read again while its last copy shows.
    private static func lastCopyNotice(_ error: any Error) -> String {
        error as? MediaLoadError == .notFound ? "This page isn’t on your gateway anymore · showing the last copy"
                                              : "Couldn’t reach your gateway · showing the last copy"
    }

    init(file: URL?, source: Source?, tile: Tile? = nil) {
        self.file = file
        self.source = source
        self.tile = tile
        super.init(nibName: nil, bundle: nil)
    }

    deinit {
        statusClock?.cancel()
        sourceLoadTask?.cancel()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A page's web view: the theme prelude and `window.hermes` first, nothing kept. `handler` takes the page's sends;
    /// without one `send` answers that it can't send from here.
    static func makeWebView(traits: UITraitCollection, handler: WKScriptMessageHandler? = nil) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let content = config.userContentController
        content.addUserScript(WKUserScript(source: prelude(traits, talks: handler != nil), injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))
        if let handler { content.add(WeakHandler(handler), name: "hermes") }
        let web = WKWebView(frame: .zero, configuration: config)
        if traits.userInterfaceStyle != .unspecified { web.overrideUserInterfaceStyle = traits.userInterfaceStyle }
        web.isFindInteractionEnabled = true   // [page-refine] Find in Page (the system's bar)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        return web
    }

    // MARK: A ready web view

    /// [tiles] A web view made ahead, its page process already running, for the next page to open on. A new web view
    /// spent most of a second starting its process before the page could draw: a second of black sheet and a spinner
    /// on every tile opened (Mac pass 2026-11-14, measured: paint about 1 s after the click). Mac only: the iPhone
    /// opens pages full screen, one at a time.
    private static var spare: WKWebView?

    static func prewarm(traits: UITraitCollection) {
        #if targetEnvironment(macCatalyst)
        guard spare == nil else { return }
        let web = makeWebView(traits: traits)
        web.loadHTMLString("<!doctype html><html></html>", baseURL: nil)
        spare = web
        #endif
    }

    /// The ready web view (nil when there is none), its sends handed to `handler`.
    private static func takeSpare(traits: UITraitCollection, handler: WKScriptMessageHandler?) -> WKWebView? {
        guard let web = spare else { return nil }
        spare = nil
        if traits.userInterfaceStyle != .unspecified { web.overrideUserInterfaceStyle = traits.userInterfaceStyle }
        let content = web.configuration.userContentController
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(source: prelude(traits, talks: handler != nil), injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))
        if let handler { content.add(WeakHandler(handler), name: "hermes") }
        // The next one, once this sheet has opened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { prewarm(traits: traits) }
        return web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = tile?.backdrop ?? ChatPalette.page
        let web = Self.takeSpare(traits: traitCollection, handler: talks ? self : nil)
            ?? Self.makeWebView(traits: traitCollection, handler: talks ? self : nil)
        web.navigationDelegate = self
        web.accessibilityIdentifier = "html.page"
        // The page's window is the part of the sheet that shows, from under the title bar to above the home bar: a
        // tile fills its window exactly (100vh, no scrolling), so a window running up under the bar hid its top (owner
        // 2026-11-03, the revenue tile opened from Tiles: its headline cut off).
        // [mac-pages] The web view sits in a box that has that window; the box lays it out over the Mac's zoom
        // (`layoutWeb`). Elsewhere it fills the box.
        webBox.translatesAutoresizingMaskIntoConstraints = false
        webBox.clipsToBounds = true
        view.addSubview(webBox)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.alpha = 0   // [tiles] shown once the page has drawn (`didFinish`)
        webLift.frame = webBox.bounds
        webLift.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webBox.addSubview(webLift)
        webLift.addSubview(web)
        skeleton.translatesAutoresizingMaskIntoConstraints = false
        skeleton.compact = false
        skeleton.over = tile?.backdrop
        view.addSubview(skeleton)
        NSLayoutConstraint.activate([
            skeleton.topAnchor.constraint(equalTo: webBox.topAnchor),
            skeleton.bottomAnchor.constraint(equalTo: webBox.bottomAnchor),
            skeleton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            { let c = skeleton.widthAnchor.constraint(equalTo: view.widthAnchor); c.priority = .defaultHigh; return c }(),
            skeleton.widthAnchor.constraint(lessThanOrEqualToConstant: 860),
            webBox.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webBox.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            webBox.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webBox.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        webView = web
        // Not loaded yet: the sheet takes the app's own look (Appearance, a skin) only once it is on screen, and a
        // page handed the phone's look kept it (2026-11-05: white cards, dark words on the dark sheet with the app set
        // to Dark and the phone to Light). `viewIsAppearing` hands it the theme and loads it.

        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.cornerConfiguration = .capsule()
        updatePill.translatesAutoresizingMaskIntoConstraints = false
        updatePill.cornerConfiguration = .capsule()
        updatePill.isHidden = true
        shadeStatusBar()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitAccessibilityContrast.self]) { (page: HTMLPageSheet, _) in
            page.shadeStatusBar()
            page.handTheme()
        }
        statusBar.isHidden = status.text == nil   // [tiles] a read that failed before the sheet loaded has said so already
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = HQFont.preferred(.footnote)
        status.adjustsFontForContentSizeCategory = true
        // [glass-audit] the label's own ink, as BrowserPill: the glass flips it light or dark for the page behind.
        status.numberOfLines = 2
        status.textAlignment = .center
        statusBar.contentView.addSubview(status)
        view.addSubview(statusBar)

        var pillConfig = UIButton.Configuration.plain()
        pillConfig.title = "New updates available"
        pillConfig.image = UIImage(systemName: "arrow.clockwise")
        pillConfig.imagePadding = 6
        pillConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote)
        pillConfig.baseForegroundColor = HQPalette.label
        pillConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        pillConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var out = attrs
            out.font = HQFont.style(.footnote, weight: .semibold)
            return out
        }
        updateButton.configuration = pillConfig
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        updateButton.accessibilityLabel = "New updates available"
        updateButton.accessibilityHint = "Reloads the page at your current scroll position"
        updateButton.accessibilityIdentifier = "page.updatePill"
        updateButton.addAction(UIAction { [weak self] _ in self?.applyPendingUpdate() }, for: .primaryActionTriggered)
        #if targetEnvironment(macCatalyst)
        PointerEffects.button(updateButton)
        #endif
        updatePill.contentView.addSubview(updateButton)
        view.addSubview(updatePill)

        NSLayoutConstraint.activate([
            statusBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            statusBar.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
            status.leadingAnchor.constraint(equalTo: statusBar.contentView.leadingAnchor, constant: 14),
            status.trailingAnchor.constraint(equalTo: statusBar.contentView.trailingAnchor, constant: -14),
            status.topAnchor.constraint(equalTo: statusBar.contentView.topAnchor, constant: 8),
            status.bottomAnchor.constraint(equalTo: statusBar.contentView.bottomAnchor, constant: -8),
            updatePill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            updatePill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            updatePill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
            updateButton.leadingAnchor.constraint(equalTo: updatePill.contentView.leadingAnchor),
            updateButton.trailingAnchor.constraint(equalTo: updatePill.contentView.trailingAnchor),
            updateButton.topAnchor.constraint(equalTo: updatePill.contentView.topAnchor),
            updateButton.bottomAnchor.constraint(equalTo: updatePill.contentView.bottomAnchor),
            updateButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])

        // [page-refine] The bar, as Grok Bot's page has it: Comment by itself, the rest (Find, Reload, Share…) under
        // one ⋯, and on the Mac Preview | Source and the zoom beside them. Share and Reload each had a button of their
        // own, which left no room for anything else on a phone's bar.
        var items = navigationItem.rightBarButtonItems ?? []
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in done(self?.moreActions() ?? []) },
        ]))
        more.accessibilityLabel = "More"
        more.accessibilityIdentifier = "page.more"
        moreItem = more
        items.append(more)
        // [tiles] Its Updates on a clock button; the file and when it was updated under its name.
        if let tile {
            if let version = tile.version {
                // [tile-versions] An earlier version: Roll Back where the tile has its Updates.
                if let verb = version.verb {
                    let back = UIBarButtonItem(title: verb, primaryAction: UIAction { [weak self] _ in
                        guard let self else { return }
                        version.rollBack(self)
                    })
                    back.style = .prominent
                    back.accessibilityIdentifier = "tile.version.rollback"
                    items.insert(back, at: 0)
                }
            } else {
                let updates = UIBarButtonItem(image: UIImage(systemName: "clock.arrow.circlepath"), menu: tile.menu(self))
                updates.accessibilityLabel = "Updates"
                updates.accessibilityIdentifier = "tile.updates.button"
                items.append(updates)
                // [tile-chats] Owner 2026-11-21: "an easy way to be able to open the session attached to a Tile".
                if let openChat = tile.openChat {
                    let chat = UIBarButtonItem(image: UIImage(systemName: "bubble.left.and.bubble.right"), primaryAction: UIAction { [weak self] _ in
                        guard let self else { return }
                        openChat(self)
                    })
                    chat.accessibilityLabel = "Open Chat"
                    chat.accessibilityIdentifier = "tile.chat.button"
                    items.append(chat)
                }
            }
            navigationItem.subtitle = tile.fileName
            // [tiles] "updated 5 min ago" kept current while it's open, not frozen at the moment it opened.
            statusClock = Task { [weak self] in
                while !Task.isCancelled {
                    self?.readStatus()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        } else {
            nameFromPage()
        }
        // [page-comment] Comment, where the page has a bot to hear it (an earlier version of a tile has none).
        // [tile-chats] A tile with its chat button has Comment under ⋯: four buttons left the bar no room for the
        // tile's name (owner 2026-11-21: "Comment moves under ⋯").
        if canComment && !commentsUnderMore {
            let comment = UIBarButtonItem(image: UIImage(systemName: "bubble.left"), primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                self.setCommenting(!self.commenting)
            })
            comment.accessibilityLabel = "Comment on the Page"
            comment.accessibilityIdentifier = "page.comment"
            commentItem = comment
            items.append(comment)
        }
        #if targetEnvironment(macCatalyst)
        items += zoomControls.items   // [mac-pages]
        // Preview | Source in the bar, as a Mac window's choice is (`ArtifactTextViewController`); the Desktop Look
        // keeps it under ⋯ (the system's control draws neither half chosen there).
        if !Theme.isDesktop {
            let modes = UISegmentedControl(items: ["Preview", "Source"])
            modes.selectedSegmentIndex = 0
            modes.addAction(UIAction { [weak self, weak modes] _ in
                guard let self, let modes else { return }
                self.setSource(modes.selectedSegmentIndex == 1)
            }, for: .valueChanged)
            modes.accessibilityIdentifier = "page.mode"
            modes.translatesAutoresizingMaskIntoConstraints = false
            modes.widthAnchor.constraint(lessThanOrEqualToConstant: (220 * HQFont.scale).rounded()).isActive = true
            modeControl = modes
            let item = UIBarButtonItem(customView: modes)
            item.hidesSharedBackground = true   // its own capsule: the bar's glass drew a second ring around it
            items.append(item)
        }
        #endif
        navigationItem.rightBarButtonItems = items

        if source != nil {
            NotificationCenter.default.addObserver(self, selector: #selector(turnEnded(_:)), name: PageSnapshots.turnEnded, object: nil)
        }
        if tile?.id != nil {
            NotificationCenter.default.addObserver(self, selector: #selector(tileRan(_:)), name: TileUpdates.ran, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(tileMakerChanged(_:)), name: TileMaker.changed, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(tileDidChange(_:)), name: TileMaker.tileChanged, object: nil)
        }
        #if DEBUG
        if UserDefaults.standard.string(forKey: "HQDebugTour") == "htmlstatus" { show("Sent to Hermes — waiting for a reply…") }
        if UserDefaults.standard.string(forKey: "HQDebugTour") == "htmlupdate" { noteExternalUpdateAvailable(url: file) }
        #endif
        // [tiles] A spinner only when drawing takes a moment: a page from this Mac's copy draws before it would show.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.painted, self.contentUnavailableConfiguration == nil else { return }
            self.skeleton.appear(after: 0)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutWeb()
    }

    /// The web view in its box: filling it, or on the Mac laid out in the box's size over the zoom and drawn grown by
    /// it ([mac-pages], `PageZoom`).
    private func layoutWeb() {
        if let webView { PageZoom.place(webView, in: webBox.bounds) }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if !painted, let backdrop = tile?.backdrop { inkBar(for: backdrop) }   // [tiles] the bar reads on the page's colour at once
        handTheme()
    }

    /// The theme for the look the sheet shows now, and the page drawn with it (again, when the look changed).
    private func handTheme() {
        guard let webView, viewIfLoaded?.window != nil else { return }
        let key = Self.themeKey(traitCollection)
        guard key != handedThemeKey else { return }
        handedThemeKey = key
        if traitCollection.userInterfaceStyle != .unspecified {
            webView.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
        }
        let content = webView.configuration.userContentController
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(source: Self.prelude(traitCollection, talks: talks), injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))
        guard painted else { load(); return }
        webView.evaluateJavaScript(Self.applyThemeScript(traitCollection)) { [weak self, weak webView] value, error in
            guard let self, let webView, webView === self.webView, Self.themeKey(self.traitCollection) == key else { return }
            if error != nil || (value as? String) == "reload" || (value as? Bool) == true {
                self.load()
                return
            }
            self.refreshBackdropColor(for: webView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak webView] in
                guard let self, let webView, webView === self.webView, Self.themeKey(self.traitCollection) == key else { return }
                self.refreshBackdropColor(for: webView)
            }
        }
    }

    private func load() {
        // The first load waits for the theme (`handTheme`); a tile still being read loads when it lands (`readTile`).
        guard handedThemeKey != nil, let file, let webView else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HQDebugPageSkeleton") { return }   // the wait, held for a picture
        #endif
        guard painted else { webView.loadPageFile(file); return }
        // [tiles] Drawn again in place: where it was scrolled is put back once it has drawn (`didFinish`).
        webView.evaluateJavaScript("[scrollX, scrollY]") { [weak self, weak webView] value, _ in
            guard let self, let webView, let file = self.file else { return }
            if let at = value as? [Double], at.contains(where: { $0 > 0 }) { self.keptScroll = at }
            webView.loadPageFile(file)
        }
    }

    /// [tiles] The tile's line under its name: its file, and when its job last updated it.
    private func readStatus() {
        guard let tile else { return }
        Task { [weak self] in
            guard let status = await tile.status(), let self else { return }
            self.navigationItem.subtitle = tile.fileName + " · " + status
        }
    }

    /// [tiles] The tile's job has just run (the Tiles page saw it, `TileUpdates.refresh`): the open page is read again
    /// and drawn in place, and its line says so (Mac pass 2026-11-14: it kept the old numbers until ↻).
    @objc private func tileRan(_ note: Notification) {
        guard let id = tile?.id, note.object as? String == id else { return }
        AppLog.trace("chatui", "open tile's job ran: read again in place")
        readAgain(note: "Updated")
        readStatus()
    }

    /// [tiles-v2] Show an unobtrusive status pill while a Change… / button turn runs on this opened tile.
    @objc private func tileMakerChanged(_ note: Notification) {
        guard let id = tile?.id, let accountId = source?.context.accountId else { return }
        if let maker = TileMaker.working(on: id, accountId: accountId) {
            show(maker.tileWords)
        }
    }

    /// [tiles-v2] Reload the opened tile in place when a Change… or rollback finishes over it.
    @objc private func tileDidChange(_ note: Notification) {
        guard let id = tile?.id, note.userInfo?["id"] as? String == id else { return }
        show(nil)
        readAgain(note: note.userInfo?["done"] as? Bool == true ? "Updated" : nil)
        readStatus()
    }

    @objc private func turnEnded(_ note: Notification) {
        guard (note.object as? ContextBox)?.context == source?.context else { return }
        if waitingForReply {
            waitingForReply = false
            clearUpdatePill()
            readAgain(note: "Updated")
        } else {
            checkForBackgroundUpdate()
        }
    }

    /// Checks whether the bot rewrote the open page during an external chat turn; if bytes changed, surfaces the
    /// "New updates available" pill instead of yanking the reader's view out from under them.
    private func checkForBackgroundUpdate() {
        guard !checkingUpdate, let source, let currentFile = file else { return }
        checkingUpdate = true
        Task { [weak self] in
            defer { self?.checkingUpdate = false }
            let shownFingerprint = await Task.detached(priority: .utility) { Self.fileFingerprint(currentFile) }.value
            let freshURL: URL?
            if let read = source.read {
                freshURL = try? await read()
            } else {
                freshURL = try? await MediaLoader.shared.file(path: source.path, name: currentFile.lastPathComponent,
                                                              context: source.context, progressKey: "page|" + source.path,
                                                              fresh: true, keptOnFailure: false)
            }
            guard let self, let freshURL else { return }
            let freshFingerprint = await Task.detached(priority: .utility) { Self.fileFingerprint(freshURL) }.value
            guard let freshFingerprint, freshFingerprint != shownFingerprint else { return }
            self.noteExternalUpdateAvailable(url: freshURL)
        }
    }

    /// Surfaces the floating "New updates available" pill (exposed for background checks, DEBUG tours, and unit tests).
    func noteExternalUpdateAvailable(url: URL?) {
        pendingUpdateURL = url
        guard updatePill.isHidden else { return }
        updatePill.isHidden = false
        if HQMotion.reduced {
            updatePill.alpha = 1
            updatePill.transform = .identity
        } else {
            updatePill.alpha = 0
            updatePill.transform = CGAffineTransform(translationX: 0, y: -8)
            UIView.animate(withDuration: HQMotion.quick) {
                self.updatePill.alpha = 1
                self.updatePill.transform = .identity
            }
        }
        HQAnnounce.say("New updates available")
    }

    /// Whether the live-update pill is currently visible (tests).
    var isUpdatePillVisible: Bool { !updatePill.isHidden }

    /// Applies the staged update in place, preserving the user's current scroll position (`keptScroll`).
    func applyPendingUpdate() {
        let nextURL = pendingUpdateURL
        clearUpdatePill()
        Haptics.play(.light)
        if let nextURL {
            file = nextURL
            load()
            show("Updated", for: 2)
            HQAnnounce.say("Page updated")
        } else {
            readAgain(note: "Updated")
        }
    }

    private func clearUpdatePill() {
        pendingUpdateURL = nil
        updatePill.isHidden = true
    }

    /// The page from the bot's computer again (the bot may have rewritten it), then drawn again.
    func readAgain(note: String?) {
        // [tiles] A tile that couldn't be read yet: ↻ is Try Again.
        if file == nil, let tileRead { tileRead(); return }
        guard let source else { load(); return }
        let showing = file != nil
        Task { [weak self] in
            let url: URL?
            var failure: (any Error)?
            if let read = source.read {
                url = try? await read()
            } else {
                // [tiles] A failure says so: ↻ on a gateway that can't be reached drew the same copy and said "Updated"
                // (Mac pass 2026-11-14).
                do {
                    url = try await MediaLoader.shared.file(path: source.path, name: self?.file?.lastPathComponent ?? "",
                                                            context: source.context, progressKey: "page|" + source.path,
                                                            fresh: true, keptOnFailure: !showing)
                } catch {
                    url = nil
                    failure = error
                }
            }
            guard let self else { return }
            if let failure, showing, !(failure is CancellationError) {
                self.show(Self.lastCopyNotice(failure), for: 5)
                return
            }
            if let url { self.file = url }
            self.load()
            if let note { self.show(note, for: 2) }
        }
    }

    /// [glass-audit] Dark glass turns light grey over a bright page, and white words on it measured 2.5:1: in dark the
    /// glass is shaded black 35 %, as the chat's pills were (thinking-row backing, round 3).
    private func shadeStatusBar() {
        let effect = UIGlassEffect(style: .regular)
        if traitCollection.userInterfaceStyle == .dark { effect.tintColor = UIColor.black.withAlphaComponent(0.35) }
        statusBar.effect = effect
        let pillEffect = UIGlassEffect(style: .regular)
        if traitCollection.userInterfaceStyle == .dark { pillEffect.tintColor = UIColor.black.withAlphaComponent(0.35) }
        updatePill.effect = pillEffect
    }

    private func show(_ text: String?, for seconds: Double? = nil) {
        status.text = text
        statusBar.isHidden = text == nil
        guard let seconds, let text else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if self?.status.text == text { self?.show(nil) }
        }
    }

    // MARK: The bar's actions

    /// Under ⋯, read each time it opens (the file may have landed since, the view may have changed).
    private func moreActions() -> [UIMenuElement] {
        var out: [UIMenuElement] = []
        if canComment && commentsUnderMore {   // [tile-chats] checked while commenting; again turns it off
            out.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Comment on the Page", image: UIImage(systemName: "bubble.left"),
                         attributes: painted && !showsSource ? [] : .disabled, state: commenting ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    self.setCommenting(!self.commenting)
                },
            ]))
        }
        if modeControl == nil {
            // Preview | Source as a choice of one, where the bar has no switch for it (a phone, the Desktop Look).
            out.append(UIMenu(options: [.displayInline, .singleSelection], children: [
                UIAction(title: "Preview", image: UIImage(systemName: "eye"), state: showsSource ? .off : .on) { [weak self] _ in self?.setSource(false) },
                UIAction(title: "Source", image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"),
                         attributes: file == nil ? .disabled : [], state: showsSource ? .on : .off) { [weak self] _ in self?.setSource(true) },
            ]))
        }
        var page: [UIMenuElement] = [
            UIAction(title: "Find in Page", image: UIImage(systemName: "magnifyingglass"), attributes: painted || showsSource ? [] : .disabled) { [weak self] _ in self?.find() },
        ]
        if source != nil || tileRead != nil {
            page.append(UIAction(title: "Reload", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.readAgain(note: nil) })
        }
        out.append(UIMenu(options: .displayInline, children: page))
        var away: [UIMenuElement] = []
        #if targetEnvironment(macCatalyst)
        if let file, let app = MacFileWindow.defaultApp(for: file) {
            away.append(UIAction(title: "Open in \(app)", image: UIImage(systemName: "safari")) { _ in _ = MacFileWindow.openInDefaultApp(file) })
        }
        #endif
        away.append(UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up"), attributes: file == nil ? .disabled : []) { [weak self] _ in self?.share() })
        out.append(UIMenu(options: .displayInline, children: away))
        return out
    }

    private func share() {
        guard let file else { return }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = moreItem   // from its button, not the page's corner
        present(sheet, animated: true)
    }

    /// The system's find bar over the page (or over its Source). ⌘F on the Mac while the page has the keys.
    private func find() {
        let interaction = showsSource ? sourceView?.findInteraction : webView?.findInteraction
        interaction?.presentFindNavigator(showingReplace: false)
    }

    @objc func hqFind(_ sender: Any?) { find() }

    /// [page-refine] A page opened from a chat is named by its own title, with the file under it: "followups.html"
    /// is the bot's working name, "Replies per 100 follow-ups" is what the page is. A tile keeps the name it was given.
    static func titleInPage(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64_000)) ?? Data()
        guard let found = TileNames.head(String(decoding: data, as: UTF8.self)).title, !found.isEmpty,
              found.caseInsensitiveCompare(file.lastPathComponent) != .orderedSame else { return nil }
        return found
    }

    /// The file under the page's title, when the bar shows the title and not the file's name.
    private func nameFromPage() {
        guard tile == nil, let name = file?.lastPathComponent, let shown = navigationItem.title ?? title, shown != name else { return }
        navigationItem.subtitle = name
    }

    // MARK: Preview | Source

    /// The page's own text in place of the page (or back). Comment is put away first: there is nothing to point at.
    private func setSource(_ on: Bool) {
        guard on != showsSource else { return }
        if on, commenting { setCommenting(false) }
        if on {
            guard let file else { modeControl?.selectedSegmentIndex = 0; return }
            let text = sourceView ?? makeSourceView()
            fillSource(text, from: file)
        }
        showsSource = on
        Haptics.play(.selection)
        modeControl?.selectedSegmentIndex = on ? 1 : 0
        commentItem?.isEnabled = !on
        sourceView?.isHidden = !on
        webBox.isHidden = on
        if on { skeleton.vanish(animated: false) }
        AppLog.trace("chatui", "html page shows its \(on ? "source" : "preview")")
    }

    private func makeSourceView() -> UITextView {
        let text = UITextView()
        text.isEditable = false
        text.alwaysBounceVertical = true
        text.backgroundColor = .clear   // the sheet's own colour (the page's) shows through
        text.textColor = HQPalette.label
        text.overrideUserInterfaceStyle = pageInk
        text.isFindInteractionEnabled = true
        text.textContainerInset = UIEdgeInsets(top: 14, left: 14, bottom: 24, right: 14)
        text.accessibilityIdentifier = "html.page.source"
        text.isHidden = true
        text.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(text, aboveSubview: webBox)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: webBox.topAnchor),
            text.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            text.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        sourceView = text
        return text
    }

    /// The most of a file shown as text: past this the view says it shows the start (a page of a few megabytes of
    /// inlined data made the text view crawl).
    nonisolated static let sourceLimit = 400_000

    /// Byte count + streaming SHA-256 digest so large pages are compared off the main thread without buffering whole files.
    nonisolated struct FileFingerprint: Equatable, Sendable {
        var size: Int64
        var digest: Data
    }

    nonisolated static func fileFingerprint(_ url: URL) -> FileFingerprint? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            total += Int64(chunk.count)
            hasher.update(data: chunk)
        }
        return FileFingerprint(size: total, digest: Data(hasher.finalize()))
    }

    /// Reads at most `limit` bytes from `file` (off-main), trimming any split UTF-8 codepoint at the boundary.
    nonisolated static func readSourcePrefix(from file: URL, limit: Int = sourceLimit) -> (text: String, truncated: Bool) {
        guard limit > 0, let handle = try? FileHandle(forReadingFrom: file) else { return ("", false) }
        defer { try? handle.close() }
        guard let raw = try? handle.read(upToCount: limit + 1), !raw.isEmpty else { return ("", false) }
        let truncated = raw.count > limit
        let slice = truncated ? raw.prefix(limit) : raw[...]
        if let utf8 = String(data: slice, encoding: .utf8) {
            return (utf8, truncated)
        }
        if truncated {
            for drop in 1...min(3, slice.count) {
                if let utf8 = String(data: slice.dropLast(drop), encoding: .utf8) {
                    return (utf8, true)
                }
            }
        }
        return (String(data: slice, encoding: .isoLatin1) ?? "", truncated)
    }

    private func fillSource(_ text: UITextView, from file: URL) {
        sourceLoadTask?.cancel()
        // The Mac draws the app at 77 %: 13 pt code came out near 10 pt on the screen (owner 2026-11-16: Mac text too small).
        #if targetEnvironment(macCatalyst)
        let size: CGFloat = 16
        #else
        let size: CGFloat = 13
        #endif
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: HQFont.mono(ofSize: size, weight: .regular))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        sourceLoadTask = Task { [weak self, weak text] in
            let loaded = await Task.detached(priority: .userInitiated) { Self.readSourcePrefix(from: file) }.value
            guard !Task.isCancelled, let self, let text, self.file == file else { return }
            let code = loaded.text
            text.attributedText = NSAttributedString(string: code,
                                                     attributes: [.font: font, .foregroundColor: HQPalette.label, .paragraphStyle: paragraph])
            if loaded.truncated { self.show("Showing the start of this file", for: 4) }
            // Coloured as code is in a reply, off the main thread (a big page takes a moment).
            let tokens = await Task.detached(priority: .userInitiated) { SyntaxHighlighter.tokens(code, language: "html") }.value
            guard !Task.isCancelled, let tokens, text.attributedText.string == code else { return }
            let coloured = NSMutableAttributedString(attributedString: text.attributedText)
            SyntaxHighlighter.apply(tokens, to: coloured)
            let at = text.contentOffset
            text.attributedText = coloured
            text.setContentOffset(at, animated: false)
        }
    }

    // MARK: Comment

    /// The page has someone to hear a comment: the chat it was opened from, or its tile's bot.
    private var canComment: Bool { tile?.version == nil && (source?.comment != nil || tile?.send != nil) }
    /// [tile-chats] Comment is under ⋯, not on the bar: the tile's chat button took its place.
    private var commentsUnderMore: Bool { tile?.version == nil && tile?.openChat != nil }

    private func setCommenting(_ on: Bool) {
        guard on != commenting, !on || (painted && !showsSource) else { return }
        commenting = on
        Haptics.play(.selection)
        commentItem?.isSelected = on
        commentItem?.image = UIImage(systemName: on ? "bubble.left.fill" : "bubble.left")
        commentItem?.accessibilityValue = on ? "On" : nil
        webView?.evaluateJavaScript("window.__hqComment&&window.__hqComment.set(\(on))")
        if on {
            show("\(DeviceWord.Tap) anything on the page to comment", for: 4)   // a hint, then out of the page's way
        } else {
            if let box = presentedViewController as? PageCommentBox { box.dismiss(animated: true) }
            if !waitingForReply, status.text?.hasSuffix("to comment") == true { show(nil) }
        }
        AppLog.trace("chatui", "html page comment mode \(on ? "on" : "off")")
    }

    /// The page named the part that was clicked: the box asks what to say about it.
    private func comment(on body: [String: Any]) {
        if body["kind"] as? String == "escape" { setCommenting(false); return }
        guard commenting, presentedViewController == nil, let webView, let target = PageComment.Target(body) else { return }
        Haptics.play(.light)
        let box = PageCommentBox(target: target, onSend: { [weak self] note in
            self?.lift(0)
            self?.send(note, about: target)
        }, onClose: { [weak self] in
            self?.lift(0)
            self?.webView?.evaluateJavaScript("window.__hqComment&&window.__hqComment.release()")
        })
        let frame = target.frame(in: webView)
        #if !targetEnvironment(macCatalyst)
        // A part in the lower half would sit under the keyboard, and a page too short to scroll can't bring it up
        // itself: the page is lifted while the box is open, so the part being talked about stays in view.
        let room = webBox.bounds.height
        if frame.minY > room * 0.38 { lift(frame.minY - room * 0.2) }
        #endif
        box.present(from: self, at: frame, in: webView)
    }

    /// The page moved up by `by` points (0: back where it belongs).
    private func lift(_ by: CGFloat) {
        let move = by > 0 ? CGAffineTransform(translationX: 0, y: -by) : .identity
        guard webLift.transform != move else { return }
        guard by == 0, !HQMotion.reduced else { webLift.transform = move; return }   // up at once: the box points at it
        UIView.animate(withDuration: HQMotion.pane) { self.webLift.transform = move }   // motion-ok: the page settling back
    }

    private func send(_ note: String, about target: PageComment.Target) {
        let name = file?.lastPathComponent ?? tile?.fileName ?? "the page"
        let message = PageComment.message(note, about: target, file: name)
        var sent = true
        if let send = tile?.send {
            // [live-tiles] As the tile's own buttons: its bot rewrites the file, read again when it is done.
            sent = send(message.text, self) { [weak self] in
                guard let self, self.waitingForReply else { return }
                self.waitingForReply = false
                self.readAgain(note: "Updated")
            }
        } else if let comment = source?.comment {
            comment(message.text, message.display)
        } else {
            sent = false
        }
        guard sent else {
            webView?.evaluateJavaScript("window.__hqComment&&window.__hqComment.release()")
            show("Couldn’t send the comment", for: 3)
            return
        }
        AppLog.trace("chatui", "html page comment sent (\(note.count) chars, on \(target.kind.rawValue))")
        webView?.evaluateJavaScript("window.__hqComment&&window.__hqComment.sent()")
        waitingForReply = true
        show("Sent to \(tile?.botName ?? source?.botName ?? "the bot") · the page updates when it answers")
    }

    #if DEBUG
    /// The loaded page's title (tests read what a page's script left there).
    var debugWebTitle: String? { webView?.title }
    private var toured = false

    /// `-HQDebugPageShow source | comment | find`: the opened page shows its Source, or Comment with the box on its
    /// first heading or chart, or the find bar, for a picture (a simulator has no finger to tap them).
    private func debugTour() {
        guard !toured, let what = UserDefaults.standard.string(forKey: "HQDebugPageShow") else { return }
        toured = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            switch what {
            case "source": self.setSource(true)
            case "find": self.find()
            case "comment", "comment-on":
                self.setCommenting(true)
                guard what == "comment" else { return }
                let pick = UserDefaults.standard.string(forKey: "HQDebugPagePick") ?? "h1,h2,svg"
                self.webView?.evaluateJavaScript("""
                    (function(){var e=document.querySelector('\(pick)');if(!e)return;var r=e.getBoundingClientRect();
                    e.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:r.left+r.width/2,clientY:r.top+r.height/2}))})()
                    """)
                #if targetEnvironment(macCatalyst)
                // The Mac hosts the comment's box in a window of its own, which the page window's picture doesn't reach.
                if let name = UserDefaults.standard.string(forKey: "HQDebugFileWindow") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let window = (self?.presentedViewController as? PageCommentBox)?.viewIfLoaded?.window else { return }
                        MacShots.shoot(window, to: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "\(name)-box.png"))
                    }
                }
                #endif
            default: break
            }
        }
    }
    #endif

    // MARK: Talk-back

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "hermes", message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let id = body["id"] as? Int else { return }
        // [page-comment] The comment script naming the part that was clicked (never a prompt: nothing is sent yet).
        if let picked = body["comment"] as? [String: Any] { comment(on: picked); return }
        let prompt = (body["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func ack(_ ok: Bool, _ error: String? = nil) {
            let result = ok ? "{ok:true}" : "{ok:false,error:'\(error ?? "undelivered")'}"
            webView?.evaluateJavaScript("window.__hermesAck && window.__hermesAck(\(id), \(result))")
        }
        guard talks else { ack(false, "undelivered"); return }
        guard !prompt.isEmpty else { ack(false, "empty"); return }
        // Rejected, never cut: a sliced payload reaches the bot as garbage while the page thinks it sent.
        guard prompt.count <= Self.maxIntentLength else { ack(false, "too_long"); return }
        guard Date().timeIntervalSince(lastIntent) >= Self.intentGap else { ack(false, "throttled"); return }
        lastIntent = Date()
        if let send = tile?.send {
            // [live-tiles] As the tile: its bot rewrites the file, read again when it's done.
            let sent = send(prompt, self) { [weak self] in
                guard let self, self.waitingForReply else { return }
                self.waitingForReply = false
                self.readAgain(note: "Updated")
            }
            guard sent else { ack(false, "undelivered"); return }
        } else {
            source?.send?(prompt)
        }
        AppLog.trace("chatui", "html page sent a hidden prompt (\(prompt.count) chars)")
        waitingForReply = true
        show("Sent to \(tile?.botName ?? source?.botName ?? "the bot") · the page updates when it answers")
        ack(true)
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        // The page itself (and its own #anchors) loads here; any other address opens outside it.
        if url.isFileURL, url.path == file?.path { decisionHandler(.allow); return }
        if action.navigationType == .linkActivated { LinkOpener.open(url, from: self) }
        decisionHandler(action.targetFrame?.isMainFrame == false && !url.isFileURL ? .allow : .cancel)
    }

    /// The bands above and below the page's window take the page's own background (a grey tile page in a white sheet).
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshBackdropColor(for: webView, finishLoad: true)
    }

    private func refreshBackdropColor(for webView: WKWebView, finishLoad: Bool = false) {
        webView.evaluateJavaScript("""
            (() => { const b = getComputedStyle(document.body).backgroundColor;
              return /rgba\\(.*, 0\\)$|transparent/.test(b) ? getComputedStyle(document.documentElement).backgroundColor : b })()
            """) { [weak self] value, _ in
            guard let self else { return }
            if finishLoad {
                if self.commenting { webView.evaluateJavaScript("window.__hqComment&&window.__hqComment.set(true)") }
                if let at = self.keptScroll {
                    self.keptScroll = nil
                    // Twice: once now, once after the next frame (a page that draws its charts by script grows then).
                    let js = "scrollTo(\(at[0]),\(at[1]));requestAnimationFrame(function(){scrollTo(\(at[0]),\(at[1]))})"
                    webView.evaluateJavaScript(js)
                }
            }
            let colour = (value as? String).flatMap(Self.cssColour)
            // [tiles] The first draw fades in over its own colour, the spinner gone; later ones (a look change, the bot
            // rewrote it) swap in place.
            if finishLoad && !self.painted {
                self.painted = true
                self.skeleton.vanish()
                UIView.animate(withDuration: HQMotion.quick) {   // motion-ok: a fade and a colour, nothing moves
                    webView.alpha = 1
                    if let colour { self.view.backgroundColor = colour }
                }
            }
            #if DEBUG
            if finishLoad { self.debugTour() }
            #endif
            guard let colour else { return }
            self.view.backgroundColor = colour
            // The bar's words and buttons in the ink that reads on the page's colour: white on a light tile in dark mode
            // was all but invisible (2026-11-03).
            self.inkBar(for: colour)
        }
    }

    private func inkBar(for colour: UIColor) {
        var white: CGFloat = 0
        colour.getWhite(&white, alpha: nil)
        let ink: UIUserInterfaceStyle = white > 0.6 ? .light : white < 0.35 ? .dark : .unspecified
        navigationController?.navigationBar.overrideUserInterfaceStyle = ink
        // [tiles] Mac pass round 6: the spinner kept the app's dark-mode grey over a white tile's colour, all but
        // invisible: a slow tile opened to what looked like a blank white sheet for as long as the page took.
        skeleton.over = colour
        pageInk = ink
        sourceView?.overrideUserInterfaceStyle = ink
        #if targetEnvironment(macCatalyst)
        // [macpass-popups r3] The Mac bar is opaque in the look's own colour: in the Desktop Look dark its near-black
        // stood as a band over a slate tile. The bar takes the page's colour instead, its title fonts kept.
        guard let bar = navigationController?.navigationBar else { return }
        let look = (navigationItem.standardAppearance ?? bar.standardAppearance).copy()
        look.backgroundEffect = nil
        look.backgroundColor = colour
        look.shadowColor = .clear
        navigationItem.standardAppearance = look
        navigationItem.scrollEdgeAppearance = look
        navigationItem.compactAppearance = look
        #endif
    }

    /// [tiles] A page that fails to draw still shows what it has, not a spinner forever.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { reveal(webView, error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { reveal(webView, error) }

    private func reveal(_ webView: WKWebView, _ error: any Error) {
        // A load the next one replaced (the theme handed, the page read again) is not a failure.
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled || ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        guard !painted else { return }
        painted = true
        skeleton.vanish()
        webView.alpha = 1
    }

    /// `rgb(…)`/`rgba(…)` as a colour; nil for a clear one (the page paints nothing: the sheet's own stays).
    static func cssColour(_ css: String) -> UIColor? {
        let numbers = css.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).compactMap(Double.init)
        guard numbers.count >= 3 else { return nil }
        let alpha = numbers.count >= 4 ? numbers[3] : 1
        guard alpha > 0.5 else { return nil }
        return UIColor(red: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, alpha: 1)
    }

    // MARK: Prelude

    /// The desktop frame's theme names (`--foreground`, `--muted-foreground`, `--accent`, `--border`, `--card`), the
    /// system font, no margins, a clear background and pictures and drawings no wider than the screen, set first so
    /// the page's own styles win. A drawing of a fixed size wider than the screen (Otto's chart: an 840-wide `<svg>`
    /// with no viewBox, cut off at attempt 6) is scaled down to fit. A page that paints its own background keeps its
    /// controls in its own light or dark (a white page in a dark app drew a black slider track). Its words too: a page that paints a light
    /// background in a dark app (or the other way) and sets no text colour of its own gets the theme's ink for its own
    /// look, not the app's (2026-11-03: a light tile's words were light grey on white in dark mode). Then `window.hermes.send` (posting to the app, or answering that it can't).
    /// [tile-soft] A background that is a `color-mix()` reads back as `color(srgb 0.95 0.95 0.96)`, its parts from 0 to 1,
    /// not 0 to 255: such a pale page was taken for black, and its words went white on it.
    /// [page-defaults] Plain HTML looks at home too (owner 2026-11-21: bots' pages kept the same small faults): fields
    /// and buttons in the page's own type (16 pt, so iOS doesn't zoom into a tapped field) and ink, a checkbox or radio
    /// kept on the line of its words, links and checkboxes in the theme's tint, long words and code wrapped rather than
    /// widening the page. All in :where(), so a page that styles any of it keeps its own. The add-on's page check
    /// (hermes-hq-push skills/html-page/check_page.py, DEFAULTS) draws pages with the same rules: keep the two alike.
    /// Trait collection carrying the active theme generation, light/dark mode, and contrast for off-screen pages.
    static func pageTraits(dark: Bool, highContrast: Bool = false) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = dark ? .dark : .light
            traits.accessibilityContrast = highContrast ? .high : .normal
            traits[ThemeGenerationTrait.self] = ThemeTable.generation
        }
    }

    private static func cssColor(_ dynamic: UIColor, traits: UITraitCollection) -> String {
        let color = dynamic.resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return "rgba(\(Int(r * 255)),\(Int(g * 255)),\(Int(b * 255)),\(String(format: "%.3f", a)))"
    }

    /// The CSS variables and baseline element defaults injected into the page's `<style id="__hq-theme">`.
    static func preludeCSS(_ traits: UITraitCollection) -> String {
        let desktop = ThemeTable.withSet(generation: traits[ThemeGenerationTrait.self]) { $0.state.desktopLook }
        return """
        :root{--foreground:\(cssColor(ChatPalette.label, traits: traits));--muted-foreground:\(cssColor(ChatPalette.label2, traits: traits));\
        --accent:\(cssColor(ChatPalette.tint, traits: traits));--border:\(cssColor(ChatPalette.separator, traits: traits));--card:\(cssColor(ChatPalette.elevated, traits: traits));\
        --hq-radius:\(desktop ? Int(DesktopRows.radius) : 16)px;\
        color-scheme:\(traits.userInterfaceStyle == .dark ? "dark" : "light");color:var(--foreground);accent-color:var(--accent);\
        font-family:-apple-system,system-ui,sans-serif;-webkit-text-size-adjust:100%}\
        :where(html,body){margin:0;padding:0;background:transparent}:where(body){padding:12px 16px;box-sizing:border-box;\
        overflow-wrap:break-word}:where(img,svg,canvas,video){max-width:100%}:where(svg[viewBox]){height:auto}\
        :where(input,select,textarea,button){font:inherit;color:inherit}\
        :where(label:has(>input[type=checkbox],>input[type=radio])){display:inline-flex;align-items:baseline;gap:.4em}\
        :where(a){color:var(--accent)}:where(pre){white-space:pre-wrap}\
        :where(hr){border:0;border-top:1px solid var(--border)}:where(iframe){max-width:100%;border:0}
        """
    }

    /// Deterministic hash identifying the resolved visual theme + mode + contrast for `traits`.
    static func themeKey(_ traits: UITraitCollection) -> String {
        let dark = traits.userInterfaceStyle == .dark
        let input = (dark ? "d|" : "l|") + preludeCSS(traits) + "|" + PageLegibility.groundJS(traits)
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return (dark ? "d-" : "l-") + String(format: "%016llx", hash)
    }

    /// Updates an already-loaded page's theme variables and legibility in place; evaluates to `true` when the page's
    /// scripts or canvases require a reload, `false` when the in-place update is complete, or `'reload'` before prelude runs.
    static func applyThemeScript(_ traits: UITraitCollection) -> String {
        let escaped = preludeCSS(traits)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        let dark = traits.userInterfaceStyle == .dark ? "true" : "false"
        let ground = PageLegibility.groundJS(traits)
        return "typeof window.__hqApplyTheme==='function'?window.__hqApplyTheme(`\(escaped)`,\(dark),\(ground)):'reload'"
    }

    static func prelude(_ traits: UITraitCollection, talks: Bool) -> String {
        // In :where() (no weight): a page's own rules win, even `*{padding:0}` (owner 2026-11-02: a dashboard sized
        // 100vw x 100vh got the 16 pt sides on top and ran wider than its window).
        let style = preludeCSS(traits)
        let escaped = style
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        let send = talks ? """
        var n=0,w={};window.__hermesAck=function(id,r){var f=w[id];delete w[id];if(f)f(r)};\
        window.hermes={send:function(p){return new Promise(function(res){var id=++n;w[id]=res;\
        try{window.webkit.messageHandlers.hermes.postMessage({id:id,prompt:String(p)})}catch(e){delete w[id];res({ok:false,error:'undelivered'})}})}};\
        document.addEventListener('click',function(e){var t=e.target&&e.target.closest&&e.target.closest('[data-hermes-send]');\
        if(t){e.preventDefault();window.hermes.send(t.getAttribute('data-hermes-send'))}},true);
        """ + PageComment.script(accent: cssColor(ChatPalette.tint, traits: traits))
        : "window.hermes={send:function(){return Promise.resolve({ok:false,error:'undelivered'})}};"
        return """
        (function(){var m=document.querySelector('meta[name=viewport]');if(!m){m=document.createElement('meta');m.name='viewport';\
        m.content='width=device-width,initial-scale=1';(document.head||document.documentElement).appendChild(m)}\
        var s=document.createElement('style');s.id='__hq-theme';s.textContent=`\(escaped)`;\
        (document.head||document.documentElement).prepend(s);\(send)\
        function fit(){var vw=document.documentElement.clientWidth;\
        document.querySelectorAll('svg[width][height]:not([viewBox])').forEach(function(g){\
        var w=parseFloat(g.getAttribute('width')),h=parseFloat(g.getAttribute('height'));\
        if(w>0&&h>0&&w>vw-8){g.setAttribute('viewBox','0 0 '+w+' '+h);g.setAttribute('preserveAspectRatio','xMinYMin meet');\
        g.style.width='100%';g.style.height='auto'}})}\
        var dark=\(traits.userInterfaceStyle == .dark ? "true" : "false"),schemeOwned=false;\
        function scheme(){var r=document.documentElement.style;\
        if(schemeOwned){r.colorScheme='';r.removeProperty('--foreground');r.removeProperty('--muted-foreground');schemeOwned=false}\
        var c=getComputedStyle(document.body).backgroundColor,m=c&&c.match(/[\\d.]+/g);\
        if(!m||m.length<3||(m.length>3&&+m[3]<0.5)){c=getComputedStyle(document.documentElement).backgroundColor;m=c&&c.match(/[\\d.]+/g)}\
        if(m&&m.length>=3&&!(m.length>3&&+m[3]<0.5)){var k=/^color\\(/.test(c)?255:1,l=(0.299*m[0]+0.587*m[1]+0.114*m[2])*k/255;\
        var light=l>0.5;r.colorScheme=light?'light':'dark';\
        if(light===dark){r.setProperty('--foreground',light?'#1c1c1e':'#f2f2f7');\
        r.setProperty('--muted-foreground',light?'rgba(60,60,67,0.75)':'rgba(235,235,245,0.7)')}\
        schemeOwned=true}}\
        window.__hqApplyTheme=function(css,isDark,ground){dark=!!isDark;\
        var st=s||document.getElementById('__hq-theme');if(st)st.textContent=css;\
        if(document.body)scheme();\
        if(window.__hqLegible&&window.__hqLegible.setGround)window.__hqLegible.setGround(ground);\
        requestAnimationFrame(function(){if(document.body)scheme();if(window.__hqLegible)window.__hqLegible.run()});\
        if(document.querySelector('canvas'))return true;\
        var re=/prefers-color-scheme|getComputedStyle|--foreground|--card|--accent|--muted-foreground|--border/;\
        for(var i=0;i<document.scripts.length;i++){if(re.test(document.scripts[i].textContent||''))return true}\
        return false};\
        document.addEventListener('DOMContentLoaded',function(){fit();scheme();new MutationObserver(fit).observe(document.body,\
        {subtree:true,childList:true,attributes:true,attributeFilter:['width','height']})});})();
        """ + PageLegibility.script(traits)   // after `scheme`, so it reads the inks that left
    }
}

/// The page's message handler without the web view keeping the page's sheet alive.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Keeps a page where it is: it and its own #anchors load, a tapped link opens in the in-app Safari view.
final class PageLinkGuard: NSObject, WKNavigationDelegate {
    private let file: URL
    private weak var host: UIViewController?

    init(file: URL, host: UIViewController) {
        self.file = file
        self.host = host
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.isFileURL, url.path == file.path { decisionHandler(.allow); return }
        if action.navigationType == .linkActivated, let host { LinkOpener.open(url, from: host) }
        decisionHandler(action.targetFrame?.isMainFrame == false && !url.isFileURL ? .allow : .cancel)
    }
}

#if targetEnvironment(macCatalyst)
/// [tiles] Says when its size changes: laid out to fill a sheet's container, it hears the window being resized.
final class WindowSizeProbe: UIView {
    var changed: ((CGSize) -> Void)?
    private var last = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != last else { return }
        last = bounds.size
        changed?(bounds.size)
    }
}
#endif
