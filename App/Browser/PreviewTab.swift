// [preview-tab] Collaborative In-App Browser: the shared browser pane beside a chat (docked in MacInspector on Mac,
// pop-outable into its own Mac window, or a half/full sheet on iPhone and iPad).
//
// Both you and Hermes share the same live page and persistent sign-in session (`WKWebsiteDataStore(forIdentifier:)`):
// - You can open it yourself at any time (toolbar globe button, ⌥⌘B, or ⋯ › In-App Browser), browse with multiple tabs
//   and an editable address bar, sign into sites, and click "Ask <bot>" to bring the page straight into chat.
// - Hermes controls the same open tab through its existing desktop protocol:
//   * `preview.open {url, label}` opens or navigates the tab (when that chat is on screen).
//   * `preview.close {url}` closes a tab or the browser pane.
//   * `preview.read {start, count}` reads visible page text in Hermes Desktop's windowed JSON shape.
//   * `preview.act {action, ref, selector, text, ...}` drives and annotates the page (`drive_preview` /
//     `annotate_preview`) with live visual highlight cues so you watch Hermes work alongside you.
// - When a bot also runs its own Chromium via Watch Browser (`hermes-hq-browser`), a quick button lets you jump straight
//   into that live Chromium stream.

import SwiftUI
import UIKit
import WebKit

@MainActor final class PreviewTabCenter {
    static let maxChars = 24_000

    private let client: any GatewayClient
    private let accountId: String
    /// [preview-vault] Memory-only pinned document bindings & RPC helper for 1Password / Hermes Vault autofill.
    let vaultBindings = PreviewVaultBindings()
    private let vaultService: PreviewVaultService
    /// True when the gateway runs on this same computer (so `localhost` targets from `preview.open` are reachable on Mac).
    var isLocalGateway = false
    /// Optional bridge to open the bot's live Chromium stream (`Watch Browser`) from the in-app browser toolbar.
    var openWatchBrowser: ((_ screen: ChatViewController) -> Void)?
    /// Optional check for whether this bot currently has an active Chromium session in Watch Browser.
    var hasLiveWatchBrowser: ((_ screen: ChatViewController) -> Bool)?
    /// Optional bridge to open Settings › Passwords (1Password setup).
    var openPasswordsSettings: ((_ presenter: UIViewController) -> Void)?

    private var eventsTask: Task<Void, Never>?
    private var screens: [WeakScreen] = []
    /// The browser controller belonging to each chat screen.
    private var tabs: [ObjectIdentifier: PreviewTabController] = [:]

    private struct WeakScreen { weak var screen: ChatViewController? }

    init(client: any GatewayClient, accountId: String) {
        self.client = client
        self.accountId = accountId
        self.vaultService = PreviewVaultService(client: client)
        let events = client.events(matching: ["preview.open", "preview.close"])
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.receive(event)
            }
        }
    }

    func shutdown() {
        eventsTask?.cancel()
        eventsTask = nil
        for tab in tabs.values { tab.close() }
        tabs = [:]
        screens = []
    }

    /// Each chat screen as it opens (`installBrowser(on:)`).
    func register(_ screen: ChatViewController) {
        screens = screens.filter { $0.screen != nil && $0.screen !== screen } + [WeakScreen(screen: screen)]
        pruneDeadTabs()
    }

    private func pruneDeadTabs() {
        let alive = Set(screens.compactMap { $0.screen.map(ObjectIdentifier.init) })
        tabs = tabs.filter { alive.contains($0.key) }
    }

    // MARK: User-initiated open / toggle

    /// Open or toggle the collaborative in-app browser for `screen`.
    /// On Mac, docks it right beside the chat in `MacInspector`; on iPhone/iPad (or narrow Mac windows), presents a sheet.
    func toggleBrowser(for screen: ChatViewController, initialURL: URL? = nil) {
        register(screen)
        let key = ObjectIdentifier(screen)
        if let existing = tabs[key], existing.isVisibleAnywhere {
            if let initialURL {
                existing.openOrFocus(url: initialURL, label: "")
            } else {
                existing.close()
            }
            return
        }
        presentBrowser(url: initialURL, label: "", on: screen)
    }

    /// Ensure the in-app browser is open for `screen` and showing `url` (if provided).
    func openBrowser(url: URL? = nil, label: String = "", on screen: ChatViewController) {
        register(screen)
        presentBrowser(url: url, label: label, on: screen)
    }

    /// Whether `screen` currently has its in-app browser visible (docked, popped out, or presented).
    func isOpen(for screen: ChatViewController) -> Bool {
        tabs[ObjectIdentifier(screen)]?.isVisibleAnywhere == true
    }

    // MARK: Events

    func receive(_ event: GatewayEvent) {
        // A reconnect's catch-up is old news: the page was for then.
        guard !event.replayed else { return }
        switch event.type {
        case "preview.open":
            guard let target = event.payload["url"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else { return }
            let label = event.payload["label"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let screen = screenShowing(event.sessionId) else {
                AppLog.trace("preview", "open for \(AppLog.tag(event.sessionId)): chat not on screen, left")
                return
            }
            let allowLoopback = DeviceWord.isMac && isLocalGateway
            open(PreviewTarget(target, allowLoopback: allowLoopback), label: label, on: screen)
        case "preview.close":
            let url = event.payload["url"]?.string ?? ""
            for screen in screens.compactMap(\.screen) where Self.covers(screen, event.sessionId) {
                guard let tab = tabs[ObjectIdentifier(screen)] else { continue }
                if url.isEmpty {
                    tab.close()
                } else {
                    tab.closeMatching(url)
                }
            }
        default: break
        }
    }

    /// The chat screen of `session` that is on screen (in a window, not hidden under another page of its stack).
    private func screenShowing(_ session: String) -> ChatViewController? {
        screens.compactMap(\.screen).first { screen in
            guard Self.covers(screen, session), let window = screen.viewIfLoaded?.window, !window.isHidden else { return false }
            if let nav = screen.navigationController, nav.topViewController !== screen { return false }
            return true
        }
    }

    private static func covers(_ screen: ChatViewController, _ session: String) -> Bool {
        guard !session.isEmpty, let live = screen.session as? LiveChatSession else { return false }
        return live.runtimeSessionId == session || live.storedSessionId == session
    }

    private func open(_ target: PreviewTarget, label: String, on screen: ChatViewController) {
        switch target {
        case .file(let path):
            let name = label.isEmpty ? (path as NSString).lastPathComponent : label
            let live = screen.session as? LiveChatSession
            let context = MediaContext(accountId: accountId, profile: screen.session.profile, storedSessionId: live?.storedSessionId)
            AppLog.trace("preview", "open file for \(AppLog.tag(live?.runtimeSessionId ?? ""))")
            FilePreviewPresenter.shared.open(path: path, name: name, context: context, from: FailureAlert.topmost(screen) ?? screen, row: nil)
        case .page(let url):
            AppLog.trace("preview", "open page for \(AppLog.tag((screen.session as? LiveChatSession)?.runtimeSessionId ?? "")) host=\(url.host ?? "-")")
            presentBrowser(url: url, label: label, on: screen)
        case .unreachable(let address):
            LinkOpener.notice(PreviewTarget.unreachableNotice(address, bot: botName(screen)), from: screen)
        }
    }

    private func presentBrowser(url: URL?, label: String, on screen: ChatViewController) {
        let key = ObjectIdentifier(screen)
        let browser: PreviewTabController
        if let existing = tabs[key] {
            browser = existing
            if let url { browser.openOrFocus(url: url, label: label) }
        } else {
            browser = PreviewTabController(initialURL: url, label: label, botName: botName(screen),
                                           allowLoopback: DeviceWord.isMac)
            wireCallbacks(browser, for: screen)
            tabs[key] = browser
        }

        if browser.isVisibleAnywhere {
            #if targetEnvironment(macCatalyst)
            _ = ViewerWindow.bringForward(browser)
            #endif
            return
        }

        #if targetEnvironment(macCatalyst)
        if let inspector = MacInspector.beside(screen) {
            browser.presentationMode = .docked
            inspector.showBrowser(browser, title: browser.headerTitle, popOut: { [weak self, weak browser, weak inspector, weak screen] in
                guard let self, let browser, let screen else { return }
                inspector?.closeBrowser()
                self.popOut(browser, for: screen)
            }, onClosed: { [weak screen] in
                screen?.refreshInAppBrowserButton()
            })
            if inspector.isVisible {
                browser.onHeaderTitleChange = { [weak inspector] title in inspector?.renameBrowser(title) }
                browser.onPopOutRequested = { [weak self, weak browser, weak inspector, weak screen] in
                    guard let self, let browser, let screen else { return }
                    inspector?.closeBrowser()
                    self.popOut(browser, for: screen)
                }
                browser.onDismissRequested = { [weak inspector] in inspector?.closeBrowser() }
                screen.refreshInAppBrowserButton()
                return
            }
            inspector.closeBrowser()
        }
        #endif

        browser.presentationMode = .sheet
        browser.onHeaderTitleChange = nil
        browser.onPopOutRequested = nil
        browser.onDismissRequested = nil
        browser.presentSheet(from: screen)
        screen.refreshInAppBrowserButton()
    }

    #if targetEnvironment(macCatalyst)
    private func popOut(_ browser: PreviewTabController, for screen: ChatViewController) {
        browser.presentationMode = .window
        browser.onHeaderTitleChange = nil
        browser.onPopOutRequested = nil
        browser.onDismissRequested = { [weak browser] in
            guard let browser else { return }
            _ = ViewerWindow.close(browser)
        }
        let opened = ViewerWindow.open(browser, title: "\(botName(screen))’s In-App Browser") { [weak browser, weak screen] in
            guard let browser, let screen else { return }
            browser.presentationMode = .sheet
            browser.presentSheet(from: screen)
            screen.refreshInAppBrowserButton()
        }
        if !opened {
            browser.presentationMode = .sheet
            browser.presentSheet(from: screen)
        }
        screen.refreshInAppBrowserButton()
    }
    #endif

    private func wireCallbacks(_ browser: PreviewTabController, for screen: ChatViewController) {
        browser.onVisibilityChange = { [weak screen] in
            screen?.refreshInAppBrowserButton()
        }
        browser.onAskBot = { [weak screen] url, title in
            guard let screen else { return }
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = cleanTitle.isEmpty
                ? "Look at \(url.absoluteString) in the preview pane: "
                : "Look at \"\(cleanTitle)\" (\(url.absoluteString)) in the preview pane: "
            let current = screen.composer.text
            screen.composer.text = current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? prefix
                : "\(current)\n\(prefix)"
            screen.focusComposer()
        }
        browser.onSendScreenshot = { [weak screen] image, url, title in
            guard let screen else { return }
            screen.attachments?.attachSnapshot(image)
            if screen.composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
                screen.composer.text = label.isEmpty
                    ? "Here’s a screenshot of \(url.absoluteString): "
                    : "Here’s a screenshot of \"\(label)\" (\(url.absoluteString)): "
            }
            screen.focusComposer()
        }
        browser.onOpenWatchBrowser = { [weak self, weak screen] in
            guard let self, let screen else { return }
            self.openWatchBrowser?(screen)
        }
        browser.watchBrowserLiveCheck = { [weak self, weak screen] in
            guard let self, let screen else { return false }
            return self.hasLiveWatchBrowser?(screen) ?? false
        }
        let profile = screen.session.profile
        browser.vaultService = vaultService
        browser.vaultBindings = vaultBindings
        browser.vaultProfile = profile
        browser.onOpenPasswordsSettings = { [weak self, weak browser] in
            guard let self, let browser else { return }
            self.openPasswordsSettings?(browser)
        }
    }

    private func botName(_ screen: ChatViewController) -> String {
        (screen.session as? LiveChatSession)?.botName ?? screen.session.title
    }

    private func activeBrowser(for session: String) -> PreviewTabController? {
        screens.compactMap(\.screen)
            .filter { Self.covers($0, session) }
            .compactMap { tabs[ObjectIdentifier($0)] }
            .first(where: { $0.isVisibleAnywhere })
    }

    // MARK: Reading & Acting (`preview.read`, `preview.act`)

    /// `preview.read` for `session`: the active page as JSON, or nil when no browser of that chat is open here.
    func read(session: String, params: JSONValue) async -> String? {
        guard let browser = activeBrowser(for: session), browser.hasLoadedPage else { return nil }
        let page = await browser.readPage()
        return Self.answer(page, start: params["start"]?.int, count: params["count"]?.int)
    }

    /// `preview.act` (`drive_preview` / `annotate_preview` / `vault`) for `session`: runs the action against the open tab,
    /// or returns nil when no browser of that chat is open here (so another desktop window can answer).
    func act(session: String, params: JSONValue) async -> String? {
        // [preview-vault] Vault fills (`vault.preview.fill` user fills arrive session-less; agent fills carry session).
        if (params["action"]?.string ?? "").lowercased() == "vault" {
            let browser = session.isEmpty ? nil : activeBrowser(for: session)
            return await vaultBindings.handleAct(
                sessionId: session,
                params: params,
                activeDocument: browser?.activeVaultDocument,
                onActivity: { [weak browser] text in browser?.showVaultNotice(text) }
            )
        }
        guard let browser = activeBrowser(for: session) else { return nil }
        return await browser.performAct(params)
    }

    /// Desktop's read answer for one page, windowed (HA preview-reader.ts `windowText`).
    static func answer(_ page: PreviewTabController.Page, start: Int?, count: Int?) -> String {
        let text = Array(page.text)
        let total = text.count
        let from = max(0, min(start ?? 0, total))
        let want = min(max(1, count ?? maxChars), maxChars)
        let to = max(from, min(from + want, total))
        let object: [String: Any] = ["kind": "url", "url": page.url, "title": page.title, "text": String(text[from..<to]),
                                     "start": from, "end": to, "total_chars": total]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// What a `preview.open` names, as this device can show it.
enum PreviewTarget: Equatable {
    case page(URL)
    case file(String)
    /// A page on the bot's own computer (localhost), which this device can't reach.
    case unreachable(String)

    init(_ raw: String) {
        self.init(raw, allowLoopback: false)
    }

    init(_ raw: String, allowLoopback: Bool) {
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "`").union(.whitespacesAndNewlines))
        if value.hasPrefix("/") || value.hasPrefix("~") {
            self = .file(value)
            return
        }
        if value.lowercased().hasPrefix("file://"), let url = URL(string: value) {
            self = .file(url.path)
            return
        }
        // A bare domain, as the tool's own normalizer takes it ("www.cnn.com" → https).
        var text = value
        if !text.contains("://") {
            text = (Self.isLoopback(text) ? "http://" : "https://") + text
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            self = .unreachable(value)
            return
        }
        self = (!allowLoopback && Self.isLoopback(host)) ? .unreachable(value) : .page(url)
    }

    static func isLoopback(_ text: String) -> Bool {
        let host = text.lowercased().split(separator: "/").first.map(String.init) ?? ""
        let bare = host.hasPrefix("[") ? host : (host.split(separator: ":").first.map(String.init) ?? host)
        return ["localhost", "127.0.0.1", "0.0.0.0", "[::1]", "::1"].contains(bare) || bare.hasPrefix("[::1]")
            || bare.hasSuffix(".localhost")
    }

    static func unreachableNotice(_ address: String, bot: String) -> String {
        "\(bot) opened \(address), a page on its own computer. It can’t be shown on this \(DeviceWord.name)."
    }
}

// MARK: - Collaborative Multi-Tab Browser Controller

final class PreviewTabController: UIViewController, WKNavigationDelegate, WKUIDelegate, UITextFieldDelegate, MacWindowPage {
    struct Page { var url: String; var title: String; var text: String }
    enum PresentationMode { case sheet, docked, window }

    /// One browser tab with its own live `WKWebView` sharing the persistent sign-in store.
    final class BrowserTab: PreviewVaultDocument {
        let id = UUID()
        var url: URL?
        var label: String
        let webView: WKWebView
        var observers: [NSKeyValueObservation] = []
        /// Incremented on every committed navigation/reload so pinned vault bindings never fill a different page.
        var documentGeneration: Int = 0
        /// Most recent provisional/navigation load failure for this tab, if any.
        var loadError: String?

        init(url: URL?, label: String, webView: WKWebView) {
            self.url = url
            self.label = label
            self.webView = webView
        }

        var currentURL: URL? { webView.url ?? url }

        var isLiveForVault: Bool { webView.window != nil && currentURL != nil }

        /// Evaluate a backend vault expression safely in `WKWebView`: awaits Promises, converts `undefined` to `nil`
        /// (preventing `WKError.javaScriptResultTypeIsUnsupported`), and JSON-normalizes object results.
        func evaluateVaultExpression(_ expression: String) async throws -> Any? {
            try await Self.evaluateVaultExpression(expression, in: webView)
        }

        static func evaluateVaultExpression(_ expression: String, in webView: WKWebView) async throws -> Any? {
            let body = """
            const __r = await (async () => (
            \(expression)
            ))();
            if (__r === undefined || __r === null) return null;
            if (typeof __r === 'string' || typeof __r === 'number' || typeof __r === 'boolean') return __r;
            return JSON.parse(JSON.stringify(__r));
            """
            let value = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .defaultClient)
            return value is NSNull ? nil : value
        }

        var displayTitle: String {
            let webTitle = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !webTitle.isEmpty { return webTitle }
            if !label.isEmpty { return label }
            if let host = currentURL?.host, !host.isEmpty {
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
            return "New Tab"
        }
    }

    /// One store for every bot's tab (Desktop's `persist:hermes-preview`): sign-ins on these pages are kept.
    private static let storeID = UUID(uuidString: "6E1F3A52-8C2D-4B7E-9A41-2D5C0B7F4E19")!
    private static let maxTabs = 8
    private static var chromeLine: UIColor {
        #if targetEnvironment(macCatalyst)
        HQPalette.paneLine
        #else
        HQPalette.separator
        #endif
    }

    private let botName: String
    private let allowLoopback: Bool
    private let initialURL: URL?
    private let initialLabel: String

    var presentationMode: PresentationMode = .sheet {
        didSet { if isViewLoaded { updateChromeForPresentation() } }
    }
    var onHeaderTitleChange: ((String) -> Void)?
    var onPopOutRequested: (() -> Void)?
    var onDismissRequested: (() -> Void)?
    var onVisibilityChange: (() -> Void)?
    var onAskBot: ((URL, String) -> Void)?
    var onSendScreenshot: ((UIImage, URL, String) -> Void)?
    var onOpenWatchBrowser: (() -> Void)?
    var watchBrowserLiveCheck: (() -> Bool)?
    /// [preview-vault] 1Password & Hermes Vault autofill wiring.
    var vaultService: PreviewVaultService?
    var vaultBindings: PreviewVaultBindings?
    var vaultProfile: String?
    var onOpenPasswordsSettings: (() -> Void)?

    private var tabs: [BrowserTab] = []
    private var selectedIndex: Int = 0
    private var activeTab: BrowserTab? { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil }
    private var activeWeb: WKWebView? { activeTab?.webView }
    var activeVaultDocument: (any PreviewVaultDocument)? { activeTab }

    var hasLoadedPage: Bool { activeTab?.currentURL != nil }

    var isVisibleAnywhere: Bool {
        if presentingViewController != nil { return true }
        if isViewLoaded, view.window != nil { return true }
        #if targetEnvironment(macCatalyst)
        if ViewerWindow.owns(self) { return true }
        #endif
        return false
    }

    var headerTitle: String {
        guard let tab = activeTab, tab.currentURL != nil else { return "In-App Browser" }
        return tab.displayTitle
    }

    // MARK: Chrome UI
    private let tabStripScroll = UIScrollView()
    private let tabStripStack = UIStackView()
    private let tabStripDivider = UIView()
    private var tabStripHeight: NSLayoutConstraint!

    private let navBar = UIView()
    private let navStack = UIStackView()
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let reloadButton = UIButton(type: .system)
    private let addressField = BrowserAddressField()
    private let vaultButton = UIButton(type: .system)
    private let askBotButton = UIButton(type: .system)
    private let watchChromeButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let navDivider = UIView()

    private let agentBanner = UIView()
    private let agentDot = UIView()
    private let agentLabel = UILabel()
    private let agentClearButton = UIButton(type: .system)
    private var agentBannerHeight: NSLayoutConstraint!
    private var agentBannerTimer: Timer?
    private var hasPinnedMarks = false

    private let progress = UIProgressView(progressViewStyle: .bar)
    private let webContainer = UIView()
    private let startPage = UIView()
    private let errorPage = UIView()
    private let errorTitle = UILabel()
    private let errorBody = UILabel()
    private var editingAddress = false
    private var themeObserver: NSObjectProtocol?

    init(initialURL: URL?, label: String, botName: String, allowLoopback: Bool) {
        self.initialURL = initialURL
        self.initialLabel = label
        self.botName = botName
        self.allowLoopback = allowLoopback
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        agentBannerTimer?.invalidate()
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    // MARK: Presentation

    func presentSheet(from screen: UIViewController) {
        let nav = UINavigationController(rootViewController: self)
        nav.view.accessibilityIdentifier = "preview-tab"
        if let sheet = nav.sheetPresentationController, !DeviceWord.isMac {
            sheet.detents = [.medium(), .large()]   // solid-ok: live WKWebView browser sheet stays opaque so web pages remain readable at half height
            sheet.selectedDetentIdentifier = traitCollection.horizontalSizeClass == .compact ? .medium : .large
            sheet.largestUndimmedDetentIdentifier = .medium
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        (FailureAlert.topmost(screen) ?? screen).present(nav, animated: true)
    }

    func close() {
        agentBannerTimer?.invalidate()
        if let onDismissRequested {
            onDismissRequested()
            onVisibilityChange?()
            return
        }
        if presentingViewController != nil {
            dismiss(animated: true) { [weak self] in self?.onVisibilityChange?() }
        }
    }

    func windowClosed() {
        agentBannerTimer?.invalidate()
        onDismissRequested = nil
        onPopOutRequested = nil
        onHeaderTitleChange = nil
        presentationMode = .sheet
        onVisibilityChange?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onVisibilityChange?()
    }

    // MARK: Browser Keyboard Shortcuts

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "Focus Address Bar", action: #selector(focusAddressBarCommand), input: "l", modifierFlags: .command),
            UIKeyCommand(title: "Reload Page", action: #selector(reloadPageCommand), input: "r", modifierFlags: .command),
            UIKeyCommand(title: "New Browser Tab", action: #selector(newTabCommand), input: "t", modifierFlags: .command),
            UIKeyCommand(title: "Back", action: #selector(goBackCommand), input: "[", modifierFlags: .command),
            UIKeyCommand(title: "Forward", action: #selector(goForwardCommand), input: "]", modifierFlags: .command),
        ]
    }

    @objc private func focusAddressBarCommand() { addressField.becomeFirstResponder() }
    @objc private func reloadPageCommand() { activeWeb?.reload() }
    @objc private func newTabCommand() {
        addTab(url: nil, select: true)
        addressField.becomeFirstResponder()
    }
    @objc private func goBackCommand() { activeWeb?.goBack() }
    @objc private func goForwardCommand() { activeWeb?.goForward() }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if editingAddress, presses.contains(where: { $0.key?.keyCode == .keyboardEscape }) {
            editingAddress = false
            addressField.resignFirstResponder()
            syncChrome()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    // MARK: Tab Management

    func openOrFocus(url: URL, label: String) {
        loadViewIfNeeded()
        if let idx = tabs.firstIndex(where: { tab in
            tab.currentURL.map { Self.same($0, url) } == true
        }) {
            selectTab(at: idx)
            if !label.isEmpty { tabs[idx].label = label }
            tabs[idx].webView.load(URLRequest(url: url))
            rebuildTabStrip()
            syncChrome()
            return
        }
        // Reuse an empty "New Tab" if it is currently selected.
        if let current = activeTab, current.currentURL == nil {
            current.url = url
            current.label = label
            current.webView.load(URLRequest(url: url))
            rebuildTabStrip()
            syncChrome()
            return
        }
        addTab(url: url, label: label, select: true)
    }

    func closeMatching(_ address: String) {
        guard case .page(let target) = PreviewTarget(address, allowLoopback: allowLoopback) else { return }
        if let idx = tabs.firstIndex(where: { tab in tab.currentURL.map { Self.same($0, target) } == true }) {
            closeTab(at: idx)
        }
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        a.host?.lowercased() == b.host?.lowercased()
            && a.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            == b.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeID)
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.accessibilityIdentifier = "preview-tab.web"
        #if DEBUG
        web.isInspectable = true
        #endif
        web.translatesAutoresizingMaskIntoConstraints = false
        return web
    }

    @discardableResult
    private func addTab(url: URL?, label: String = "", select: Bool = true) -> BrowserTab {
        if tabs.count >= Self.maxTabs {
            // Evict the oldest inactive tab to keep memory bounded.
            if let dropIndex = tabs.indices.first(where: { $0 != selectedIndex }) {
                removeTabView(at: dropIndex)
            }
        }
        let web = makeWebView()
        let tab = BrowserTab(url: url, label: label, webView: web)
        attachObservers(to: tab)
        tabs.append(tab)
        webContainer.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: webContainer.topAnchor),
            web.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
        ])
        if let url { web.load(URLRequest(url: url)) }
        if select { selectTab(at: tabs.count - 1) } else { web.isHidden = true }
        rebuildTabStrip()
        syncChrome()
        return tab
    }

    private func attachObservers(to tab: BrowserTab) {
        let web = tab.webView
        tab.observers = [
            web.observe(\.estimatedProgress) { [weak self, weak tab] web, _ in
                Task { @MainActor in
                    guard let self, tab === self.activeTab else { return }
                    self.showProgress(web.estimatedProgress, loading: web.isLoading)
                }
            },
            web.observe(\.isLoading) { [weak self, weak tab] web, _ in
                Task { @MainActor in
                    guard let self, tab === self.activeTab else { return }
                    self.showProgress(web.estimatedProgress, loading: web.isLoading)
                    self.syncChrome()
                }
            },
            web.observe(\.title) { [weak self, weak tab] _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.rebuildTabStrip()
                    if tab === self.activeTab { self.syncChrome() }
                }
            },
            web.observe(\.url) { [weak self, weak tab] _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.rebuildTabStrip()
                    if tab === self.activeTab { self.syncChrome() }
                }
            },
            web.observe(\.canGoBack) { [weak self, weak tab] _, _ in
                Task { @MainActor in if tab === self?.activeTab { self?.syncChrome() } }
            },
            web.observe(\.canGoForward) { [weak self, weak tab] _, _ in
                Task { @MainActor in if tab === self?.activeTab { self?.syncChrome() } }
            },
        ]
    }

    private func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
        for (i, tab) in tabs.enumerated() {
            tab.webView.isHidden = (i != index) || (tab.currentURL == nil)
        }
        rebuildTabStrip()
        syncChrome()
    }

    private func removeTabView(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let removed = tabs.remove(at: index)
        removed.observers.removeAll()
        removed.webView.stopLoading()
        removed.webView.removeFromSuperview()
        if selectedIndex >= tabs.count { selectedIndex = max(0, tabs.count - 1) }
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        removeTabView(at: index)
        if tabs.isEmpty {
            close()
            return
        }
        selectTab(at: min(selectedIndex, tabs.count - 1))
    }

    // MARK: Lifecycle & Layout

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.page
        view.accessibilityIdentifier = "preview-tab.root"
        navigationItem.largeTitleDisplayMode = .never

        buildTabStrip()
        buildNavBar()
        buildAgentBanner()
        buildWebArea()
        buildStartPage()
        buildErrorPage()

        NSLayoutConstraint.activate([
            tabStripScroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tabStripScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabStripScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabStripHeight,
            tabStripDivider.topAnchor.constraint(equalTo: tabStripScroll.bottomAnchor),
            tabStripDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabStripDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabStripDivider.heightAnchor.constraint(equalToConstant: HQShape.hairline),

            navBar.topAnchor.constraint(equalTo: tabStripDivider.bottomAnchor),
            navBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            navBar.heightAnchor.constraint(equalToConstant: 44),
            navDivider.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            navDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            navDivider.heightAnchor.constraint(equalToConstant: HQShape.hairline),

            agentBanner.topAnchor.constraint(equalTo: navDivider.bottomAnchor),
            agentBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            agentBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            agentBannerHeight,

            webContainer.topAnchor.constraint(equalTo: agentBanner.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            progress.topAnchor.constraint(equalTo: navDivider.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            startPage.topAnchor.constraint(equalTo: webContainer.topAnchor),
            startPage.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            startPage.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            startPage.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),

            errorPage.topAnchor.constraint(equalTo: webContainer.topAnchor),
            errorPage.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            errorPage.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            errorPage.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])

        updateChromeForPresentation()
        addTab(url: initialURL, label: initialLabel, select: true)

        themeObserver = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
        applyTheme()
    }

    private func buildTabStrip() {
        tabStripScroll.translatesAutoresizingMaskIntoConstraints = false
        tabStripScroll.showsHorizontalScrollIndicator = false
        tabStripScroll.alwaysBounceHorizontal = false
        tabStripScroll.backgroundColor = HQPalette.groupedPage

        tabStripStack.axis = .horizontal
        tabStripStack.alignment = .center
        tabStripStack.spacing = 6
        tabStripStack.translatesAutoresizingMaskIntoConstraints = false
        tabStripScroll.addSubview(tabStripStack)
        NSLayoutConstraint.activate([
            tabStripStack.topAnchor.constraint(equalTo: tabStripScroll.contentLayoutGuide.topAnchor, constant: 4),
            tabStripStack.bottomAnchor.constraint(equalTo: tabStripScroll.contentLayoutGuide.bottomAnchor, constant: -4),
            tabStripStack.leadingAnchor.constraint(equalTo: tabStripScroll.contentLayoutGuide.leadingAnchor, constant: 8),
            tabStripStack.trailingAnchor.constraint(equalTo: tabStripScroll.contentLayoutGuide.trailingAnchor, constant: -8),
            tabStripStack.heightAnchor.constraint(equalTo: tabStripScroll.frameLayoutGuide.heightAnchor, constant: -8),
        ])
        tabStripHeight = tabStripScroll.heightAnchor.constraint(equalToConstant: 34)
        tabStripDivider.translatesAutoresizingMaskIntoConstraints = false
        tabStripDivider.backgroundColor = Self.chromeLine
        view.addSubview(tabStripScroll)
        view.addSubview(tabStripDivider)
    }

    private func buildNavBar() {
        navBar.translatesAutoresizingMaskIntoConstraints = false
        navBar.backgroundColor = HQPalette.groupedPage
        navDivider.translatesAutoresizingMaskIntoConstraints = false
        navDivider.backgroundColor = Self.chromeLine

        configureToolbarButton(backButton, symbol: "chevron.backward", label: "Back", id: "preview-tab.back") { [weak self] in
            self?.activeWeb?.goBack()
        }
        configureToolbarButton(forwardButton, symbol: "chevron.forward", label: "Forward", id: "preview-tab.forward") { [weak self] in
            self?.activeWeb?.goForward()
        }
        configureToolbarButton(reloadButton, symbol: "arrow.clockwise", label: "Reload", id: "preview-tab.reload") { [weak self] in
            guard let web = self?.activeWeb else { return }
            if web.isLoading { web.stopLoading() } else { web.reload() }
        }

        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.delegate = self
        addressField.backgroundColor = .tertiarySystemFill
        addressField.layer.cornerRadius = 8
        addressField.layer.cornerCurve = .continuous
        addressField.font = HQFont.preferred(.footnote)
        addressField.adjustsFontForContentSizeCategory = true
        addressField.textAlignment = .left
        addressField.keyboardType = .URL
        addressField.returnKeyType = .go
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.spellCheckingType = .no
        addressField.clearButtonMode = .whileEditing
        addressField.placeholder = "Enter URL or search…"
        addressField.accessibilityLabel = "Address"
        addressField.accessibilityIdentifier = "preview-tab.address"
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        vaultButton.translatesAutoresizingMaskIntoConstraints = false
        var vaultConfig = UIButton.Configuration.plain()
        vaultConfig.image = UIImage(systemName: "key.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        vaultConfig.baseForegroundColor = HQPalette.label2
        vaultConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        vaultButton.configuration = vaultConfig
        vaultButton.showsMenuAsPrimaryAction = true
        vaultButton.accessibilityLabel = "Saved Logins (1Password & Vault)"
        vaultButton.accessibilityIdentifier = "preview-tab.vault"
        vaultButton.toolTip = "Fill saved login (1Password & Vault)"
        vaultButton.setContentHuggingPriority(.required, for: .horizontal)
        vaultButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        vaultButton.menu = buildVaultMenu()

        configureToolbarButton(askBotButton, symbol: "sparkles", label: "Ask \(botName) about this page", id: "preview-tab.ask") { [weak self] in
            self?.askBotTapped()
        }
        configureToolbarButton(watchChromeButton, symbol: "desktopcomputer", label: "Watch \(botName)’s Chromium", id: "preview-tab.watch-chrome") { [weak self] in
            self?.onOpenWatchBrowser?()
        }

        moreButton.translatesAutoresizingMaskIntoConstraints = false
        var moreConfig = UIButton.Configuration.plain()
        moreConfig.image = UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        moreConfig.baseForegroundColor = HQPalette.label2
        moreConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        moreButton.configuration = moreConfig
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.accessibilityLabel = "Browser Actions"
        moreButton.accessibilityIdentifier = "preview-tab.more"
        moreButton.menu = buildMoreMenu()

        navStack.axis = .horizontal
        navStack.alignment = .center
        navStack.spacing = 4
        navStack.translatesAutoresizingMaskIntoConstraints = false
        for item in [backButton, forwardButton, reloadButton, addressField, vaultButton, askBotButton, watchChromeButton, moreButton] as [UIView] {
            navStack.addArrangedSubview(item)
        }
        navBar.addSubview(navStack)
        NSLayoutConstraint.activate([
            navStack.leadingAnchor.constraint(equalTo: navBar.leadingAnchor, constant: 8),
            navStack.trailingAnchor.constraint(equalTo: navBar.trailingAnchor, constant: -8),
            navStack.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            addressField.heightAnchor.constraint(equalToConstant: 30),
        ])
        view.addSubview(navBar)
        view.addSubview(navDivider)
    }

    private func configureToolbarButton(_ button: UIButton, symbol: String, label: String, id: String, action: @escaping () -> Void) {
        button.translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        config.baseForegroundColor = HQPalette.label2
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        button.configuration = config
        button.accessibilityLabel = label
        button.accessibilityIdentifier = id
        button.toolTip = label
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
    }

    private func buildAgentBanner() {
        agentBanner.translatesAutoresizingMaskIntoConstraints = false
        agentBanner.clipsToBounds = true
        agentBanner.backgroundColor = UIColor(red: 0.925, green: 0.0, blue: 0.549, alpha: 0.10)
        agentBannerHeight = agentBanner.heightAnchor.constraint(equalToConstant: 0)

        agentDot.translatesAutoresizingMaskIntoConstraints = false
        agentDot.backgroundColor = UIColor(red: 0.925, green: 0.0, blue: 0.549, alpha: 1.0)
        agentDot.layer.cornerRadius = 4

        agentLabel.translatesAutoresizingMaskIntoConstraints = false
        agentLabel.font = HQFont.preferred(.caption1).pagesWeight(.semibold)
        agentLabel.textColor = HQPalette.label
        agentLabel.lineBreakMode = .byTruncatingTail
        agentLabel.accessibilityIdentifier = "preview-tab.agent-status"

        var clearConfig = UIButton.Configuration.plain()
        clearConfig.title = "Clear Marks"
        clearConfig.baseForegroundColor = UIColor(red: 0.925, green: 0.0, blue: 0.549, alpha: 1.0)
        clearConfig.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
        clearConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var out = attrs
            out.font = HQFont.preferred(.caption1).pagesWeight(.semibold)
            return out
        }
        agentClearButton.configuration = clearConfig
        agentClearButton.translatesAutoresizingMaskIntoConstraints = false
        agentClearButton.isHidden = true
        agentClearButton.addAction(UIAction { [weak self] _ in
            Task { await self?.clearAnnotations() }
        }, for: .primaryActionTriggered)

        agentBanner.addSubview(agentDot)
        agentBanner.addSubview(agentLabel)
        agentBanner.addSubview(agentClearButton)
        NSLayoutConstraint.activate([
            agentDot.leadingAnchor.constraint(equalTo: agentBanner.leadingAnchor, constant: 12),
            agentDot.centerYAnchor.constraint(equalTo: agentBanner.centerYAnchor),
            agentDot.widthAnchor.constraint(equalToConstant: 8),
            agentDot.heightAnchor.constraint(equalToConstant: 8),
            agentLabel.leadingAnchor.constraint(equalTo: agentDot.trailingAnchor, constant: 8),
            agentLabel.centerYAnchor.constraint(equalTo: agentBanner.centerYAnchor),
            agentLabel.trailingAnchor.constraint(lessThanOrEqualTo: agentClearButton.leadingAnchor, constant: -8),
            agentClearButton.trailingAnchor.constraint(equalTo: agentBanner.trailingAnchor, constant: -8),
            agentClearButton.centerYAnchor.constraint(equalTo: agentBanner.centerYAnchor),
        ])
        view.addSubview(agentBanner)
    }

    private func buildWebArea() {
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.backgroundColor = HQPalette.page
        view.addSubview(webContainer)

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.trackTintColor = .clear
        progress.alpha = 0
        view.addSubview(progress)
    }

    private func buildStartPage() {
        startPage.translatesAutoresizingMaskIntoConstraints = false
        startPage.backgroundColor = HQPalette.page
        webContainer.addSubview(startPage)

        let icon = UIImageView(image: UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .light)))
        icon.tintColor = HQPalette.label2

        let heading = UILabel()
        heading.text = "Shared In-App Browser"
        heading.font = HQFont.preferred(.title3).pagesWeight(.semibold)
        heading.textColor = HQPalette.label
        heading.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = "Browse right beside your chat. Your sign-ins stay saved, and \(botName) can read, click, type, and highlight elements on this page with you."
        subtitle.font = HQFont.preferred(.subheadline)
        subtitle.textColor = HQPalette.label2
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0

        let pills = UIStackView()
        pills.axis = .horizontal
        pills.spacing = 8
        pills.alignment = .center
        pills.distribution = .fillProportionally

        let quickLinks: [(String, String)] = allowLoopback
            ? [("localhost:3000", "http://localhost:3000"), ("GitHub", "https://github.com"), ("Docs", "https://developer.apple.com")]
            : [("GitHub", "https://github.com"), ("Hacker News", "https://news.ycombinator.com"), ("Wikipedia", "https://en.wikipedia.org")]

        for (title, urlStr) in quickLinks {
            var cfg = UIButton.Configuration.tinted()
            cfg.title = title
            cfg.cornerStyle = .capsule
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var out = attrs
                out.font = HQFont.preferred(.footnote).pagesWeight(.medium)
                return out
            }
            let btn = UIButton(configuration: cfg, primaryAction: UIAction { [weak self] _ in
                guard let url = URL(string: urlStr) else { return }
                self?.navigateActiveTab(to: url)
            })
            pills.addArrangedSubview(btn)
        }

        let stack = UIStackView(arrangedSubviews: [icon, heading, subtitle, pills])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.setCustomSpacing(16, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        startPage.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: startPage.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: startPage.centerYAnchor, constant: -24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: startPage.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: startPage.trailingAnchor, constant: -28),
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    private func buildErrorPage() {
        errorPage.translatesAutoresizingMaskIntoConstraints = false
        errorPage.backgroundColor = HQPalette.page
        errorPage.isHidden = true
        webContainer.addSubview(errorPage)

        let icon = UIImageView(image: UIImage(systemName: "wifi.exclamationmark",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .light)))
        icon.tintColor = HQPalette.label2

        errorTitle.font = HQFont.preferred(.headline)
        errorTitle.textColor = HQPalette.label
        errorTitle.textAlignment = .center
        errorTitle.numberOfLines = 0

        errorBody.font = HQFont.preferred(.subheadline)
        errorBody.textColor = HQPalette.label2
        errorBody.textAlignment = .center
        errorBody.numberOfLines = 0

        var retryCfg = UIButton.Configuration.tinted()
        retryCfg.title = "Try Again"
        retryCfg.cornerStyle = .capsule
        let retryBtn = UIButton(configuration: retryCfg, primaryAction: UIAction { [weak self] _ in
            guard let self, let tab = self.activeTab else { return }
            tab.loadError = nil
            if let url = tab.currentURL { tab.webView.load(URLRequest(url: url)) } else { tab.webView.reload() }
            self.syncChrome()
        })

        let stack = UIStackView(arrangedSubviews: [icon, errorTitle, errorBody, retryBtn])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.setCustomSpacing(16, after: errorBody)
        stack.translatesAutoresizingMaskIntoConstraints = false
        errorPage.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: errorPage.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: errorPage.centerYAnchor, constant: -24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: errorPage.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: errorPage.trailingAnchor, constant: -28),
            errorBody.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])
    }

    private func captureScreenshotForChat() {
        guard let tab = activeTab, let url = tab.currentURL, let send = onSendScreenshot else { return }
        let web = tab.webView
        let cfg = WKSnapshotConfiguration()
        cfg.rect = web.bounds
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let image = try await web.takeSnapshot(configuration: cfg)
                Haptics.play(.success)
                send(image, url, tab.displayTitle)
                self.showAgentActivity("Screenshot attached to chat")
            } catch {
                Haptics.play(.error)
                self.showAgentActivity("Couldn’t capture screenshot")
            }
        }
    }

    private func buildMoreMenu() -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { completion([]); return }
                var items: [UIMenuElement] = [
                    UIAction(title: "New Tab", image: UIImage(systemName: "plus")) { [weak self] _ in
                        self?.addTab(url: nil, select: true)
                        self?.addressField.becomeFirstResponder()
                    },
                ]
                if let url = self.activeTab?.currentURL {
                    if self.onSendScreenshot != nil {
                        items.append(UIAction(title: "Send Screenshot to Chat", image: UIImage(systemName: "camera.viewfinder")) { [weak self] _ in
                            self?.captureScreenshotForChat()
                        })
                    }
                    items.append(UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
                        UIPasteboard.general.url = url
                        Haptics.play(.success)
                    })
                    items.append(UIAction(title: LinkOpener.outsideTitle, image: UIImage(systemName: "safari")) { _ in
                        LinkOpener.openOutside(url)
                    })
                }
                if self.hasPinnedMarks {
                    items.append(UIAction(title: "Clear Highlights", image: UIImage(systemName: "eraser")) { [weak self] _ in
                        Task { await self?.clearAnnotations() }
                    })
                }
                if self.presentationMode == .docked, let popOut = self.onPopOutRequested {
                    items.append(UIAction(title: "Open in Separate Window", image: UIImage(systemName: "arrow.up.right.square")) { _ in
                        popOut()
                    })
                }
                if let watch = self.onOpenWatchBrowser {
                    items.append(UIMenu(title: "", options: .displayInline, children: [
                        UIAction(title: "Watch \(self.botName)’s Chromium", image: UIImage(systemName: "desktopcomputer")) { _ in
                            watch()
                        },
                    ]))
                }
                completion(items)
            },
        ])
    }

    private func updateChromeForPresentation() {
        switch presentationMode {
        case .docked:
            navigationItem.leftBarButtonItems = nil
            navigationItem.rightBarButtonItems = nil
            navigationItem.title = nil
            navigationItem.subtitle = nil
        case .sheet, .window:
            let closeBtn = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.close() })
            closeBtn.accessibilityIdentifier = "preview-tab.close"
            navigationItem.leftBarButtonItems = [closeBtn]
            navigationItem.rightBarButtonItems = nil
            navigationItem.title = headerTitle
            navigationItem.subtitle = activeTab?.currentURL.map(Self.site)
        }
    }

    private func applyTheme() {
        view.backgroundColor = HQPalette.page
        tabStripScroll.backgroundColor = HQPalette.groupedPage
        navBar.backgroundColor = HQPalette.groupedPage
        tabStripDivider.backgroundColor = Self.chromeLine
        navDivider.backgroundColor = Self.chromeLine
        webContainer.backgroundColor = HQPalette.page
        startPage.backgroundColor = HQPalette.page
        errorPage.backgroundColor = HQPalette.page
        rebuildTabStrip()
    }

    // MARK: Tab Strip Rendering

    private func rebuildTabStrip() {
        for sub in tabStripStack.arrangedSubviews {
            tabStripStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        for (idx, tab) in tabs.enumerated() {
            let active = idx == selectedIndex
            let pill = UIView()
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.layer.cornerRadius = 7
            pill.layer.cornerCurve = .continuous
            pill.backgroundColor = active ? HQPalette.card : .clear
            pill.layer.borderWidth = active ? HQShape.hairline : 0
            pill.layer.borderColor = Self.chromeLine.cgColor

            let titleBtn = UIButton(type: .system)
            var cfg = UIButton.Configuration.plain()
            cfg.title = tab.displayTitle
            cfg.baseForegroundColor = active ? HQPalette.label : HQPalette.label2
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 2)
            cfg.titleLineBreakMode = .byTruncatingTail
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var out = attrs
                out.font = HQFont.preferred(.caption1).pagesWeight(active ? .semibold : .regular)
                return out
            }
            titleBtn.configuration = cfg
            titleBtn.translatesAutoresizingMaskIntoConstraints = false
            titleBtn.addAction(UIAction { [weak self] _ in self?.selectTab(at: idx) }, for: .primaryActionTriggered)

            let closeBtn = UIButton(type: .system)
            var xCfg = UIButton.Configuration.plain()
            xCfg.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
            xCfg.baseForegroundColor = HQPalette.label2
            xCfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 3, bottom: 4, trailing: 6)
            closeBtn.configuration = xCfg
            closeBtn.translatesAutoresizingMaskIntoConstraints = false
            closeBtn.accessibilityLabel = "Close \(tab.displayTitle)"
            closeBtn.addAction(UIAction { [weak self] _ in self?.closeTab(at: idx) }, for: .primaryActionTriggered)

            pill.addSubview(titleBtn)
            pill.addSubview(closeBtn)
            NSLayoutConstraint.activate([
                pill.widthAnchor.constraint(lessThanOrEqualToConstant: 170),
                pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
                titleBtn.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
                titleBtn.topAnchor.constraint(equalTo: pill.topAnchor),
                titleBtn.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
                closeBtn.leadingAnchor.constraint(equalTo: titleBtn.trailingAnchor),
                closeBtn.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
                closeBtn.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            ])
            tabStripStack.addArrangedSubview(pill)
        }

        let plusBtn = UIButton(type: .system)
        var pCfg = UIButton.Configuration.plain()
        pCfg.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        pCfg.baseForegroundColor = HQPalette.label2
        pCfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        plusBtn.configuration = pCfg
        plusBtn.accessibilityLabel = "New Tab"
        plusBtn.accessibilityIdentifier = "preview-tab.new-tab"
        plusBtn.toolTip = "New Tab"
        plusBtn.addAction(UIAction { [weak self] _ in
            self?.addTab(url: nil, select: true)
            self?.addressField.becomeFirstResponder()
        }, for: .primaryActionTriggered)
        tabStripStack.addArrangedSubview(plusBtn)
    }

    private func syncChrome() {
        guard isViewLoaded else { return }
        let tab = activeTab
        let url = tab?.currentURL
        let loading = tab?.webView.isLoading ?? false

        let loadError = tab?.loadError
        startPage.isHidden = url != nil
        errorPage.isHidden = loadError == nil
        if let loadError {
            errorTitle.text = url.map { "Couldn’t Open \(Self.site($0))" } ?? "Couldn’t Load Page"
            errorBody.text = loadError
        }
        for (i, t) in tabs.enumerated() {
            t.webView.isHidden = (i != selectedIndex) || (t.currentURL == nil) || (t.loadError != nil)
        }

        backButton.isEnabled = tab?.webView.canGoBack ?? false
        forwardButton.isEnabled = tab?.webView.canGoForward ?? false
        let reloadSymbol = loading ? "xmark" : "arrow.clockwise"
        reloadButton.configuration?.image = UIImage(systemName: reloadSymbol,
                                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        reloadButton.isEnabled = url != nil

        askBotButton.isEnabled = url != nil
        askBotButton.configuration?.baseForegroundColor = url != nil ? ChatPalette.tint : HQPalette.label2

        let hasOrigin = url.flatMap(PreviewVaultOrigin.origin(of:)) != nil
        let hasVault = vaultService != nil || onOpenPasswordsSettings != nil
        vaultButton.isHidden = !hasVault
        vaultButton.isEnabled = hasOrigin
        vaultButton.configuration?.baseForegroundColor = hasOrigin ? HQPalette.label : HQPalette.label2

        watchChromeButton.isHidden = onOpenWatchBrowser == nil
        let liveChrome = watchBrowserLiveCheck?() ?? false
        watchChromeButton.configuration?.baseForegroundColor = liveChrome ? .systemGreen : HQPalette.label2
        watchChromeButton.toolTip = liveChrome ? "\(botName)’s Chromium is live — click to watch" : "Watch \(botName)’s Chromium"

        if !editingAddress {
            if let url {
                let parsed = BrowserAddress(url.absoluteString)
                addressField.text = parsed.host.isEmpty ? url.absoluteString : parsed.host
                addressField.showsLock = parsed.secure
            } else {
                addressField.text = ""
                addressField.showsLock = false
            }
        }

        let titleText = headerTitle
        onHeaderTitleChange?(titleText)
        if presentationMode != .docked {
            navigationItem.title = titleText
            navigationItem.subtitle = url.map(Self.site)
        }
    }

    static func site(_ url: URL) -> String {
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func showProgress(_ value: Double, loading: Bool) {
        progress.setProgress(Float(value), animated: loading)
        HQMotion.animate(loading ? 0 : 0.25, changes: { self.progress.alpha = loading ? 1 : 0 })
    }

    private func navigateActiveTab(to url: URL) {
        guard let tab = activeTab else { addTab(url: url, select: true); return }
        tab.url = url
        tab.label = ""
        tab.webView.load(URLRequest(url: url))
        rebuildTabStrip()
        syncChrome()
    }

    private func askBotTapped() {
        guard let tab = activeTab, let url = tab.currentURL else { return }
        Haptics.play(.selection)
        onAskBot?(url, tab.displayTitle)
    }

    // MARK: Live Agent Activity Banner

    private func showAgentActivity(_ text: String, sticky: Bool = false) {
        agentBannerTimer?.invalidate()
        agentBannerTimer = nil
        agentLabel.text = text
        agentClearButton.isHidden = !hasPinnedMarks
        agentBannerHeight.constant = 28
        HQMotion.animate(0.18, changes: { self.view.layoutIfNeeded() })
        guard !sticky && !hasPinnedMarks else { return }
        agentBannerTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.hasPinnedMarks else { return }
                self.agentBannerHeight.constant = 0
                HQMotion.animate(0.2, changes: { self.view.layoutIfNeeded() })
            }
        }
    }

    private func clearAnnotations() async {
        _ = await performAct(.object(["action": .string("unpin")]))
    }

    func showVaultNotice(_ text: String) {
        showAgentActivity(text)
    }

    // MARK: 1Password & Vault Autofill (`preview-tab.vault`)

    private func buildVaultMenu() -> UIMenu {
        UIMenu(title: "Saved Logins", children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { completion([]); return }
                guard let tab = self.activeTab, let url = tab.currentURL,
                      let origin = PreviewVaultOrigin.origin(of: url) else {
                    completion([UIAction(title: "Open an http(s) site to fill logins", attributes: .disabled) { _ in }])
                    return
                }
                guard let vaultService = self.vaultService else {
                    var items: [UIMenuElement] = [
                        UIAction(title: "No saved logins on this site", attributes: .disabled) { _ in },
                    ]
                    if let openSettings = self.onOpenPasswordsSettings {
                        items.append(UIAction(title: "1Password & Passwords Settings…", image: UIImage(systemName: "person.badge.key")) { _ in
                            openSettings()
                        })
                    }
                    completion(items)
                    return
                }
                Task { @MainActor [weak self, weak tab] in
                    guard let self, let tab else { completion([]); return }
                    let state = await vaultService.load(origin: origin, profile: self.vaultProfile)
                    completion(self.vaultMenuElements(for: state, tab: tab))
                }
            },
        ])
    }

    private func vaultMenuElements(for state: PreviewVaultMenuState, tab: BrowserTab) -> [UIMenuElement] {
        var sections: [UIMenuElement] = []

        if let error = state.loadError {
            sections.append(UIAction(title: error, image: UIImage(systemName: "exclamationmark.triangle"), attributes: .disabled) { _ in })
        } else if !state.logins.isEmpty {
            let loginActions = state.logins.map { login in
                let detail = [login.identifier, login.backendDisplayName]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                return UIAction(title: login.label, subtitle: detail.isEmpty ? nil : detail,
                                image: UIImage(systemName: "key.fill")) { [weak self, weak tab] _ in
                    guard let self, let tab else { return }
                    Task { await self.fillSavedLogin(login, in: tab) }
                }
            }
            sections.append(UIMenu(title: "Fill for \(PreviewTabController.site(URL(string: state.origin) ?? URL(string: "https://example.com")!))",
                                   options: .displayInline, children: loginActions))
        } else {
            sections.append(UIAction(title: "No saved logins for this site", attributes: .disabled) { _ in })
        }

        if !state.lockedSources.isEmpty {
            let unlockActions = state.lockedSources.map { source in
                UIAction(title: "Unlock \(source.name)…", image: UIImage(systemName: "lock.open")) { [weak self] _ in
                    self?.promptUnlock(source: source)
                }
            }
            sections.append(UIMenu(title: "", options: .displayInline, children: unlockActions))
        }

        var manageActions: [UIMenuElement] = []
        if state.onePasswordConnected {
            manageActions.append(UIAction(title: "Move Login from 1Password Private…",
                                          image: UIImage(systemName: "tray.and.arrow.up")) { [weak self] _ in
                self?.presentOnePasswordMove(origin: state.origin)
            })
        }
        if let openSettings = onOpenPasswordsSettings {
            let title = state.onePasswordConnected ? "1Password & Passwords Settings…" : "Connect 1Password…"
            manageActions.append(UIAction(title: title, image: UIImage(systemName: "person.badge.key")) { _ in
                openSettings()
            })
        }
        if !manageActions.isEmpty {
            sections.append(UIMenu(title: "", options: .displayInline, children: manageActions))
        }
        return sections
    }

    private func fillSavedLogin(_ login: PreviewVaultLogin, in tab: BrowserTab) async {
        guard let vaultService, let vaultBindings else { return }
        showAgentActivity("Filling \(login.label) from \(login.backendDisplayName)…")
        let result = await vaultService.fill(login: login, document: tab, bindings: vaultBindings, profile: vaultProfile)
        if result.success {
            Haptics.play(.success)
            showAgentActivity("Filled \(login.label) from \(login.backendDisplayName)")
        } else {
            Haptics.play(.error)
            showAgentActivity(result.error ?? "Couldn’t fill \(login.label)")
        }
    }

    private func promptUnlock(source: VaultSource) {
        let alert = UIAlertController(title: "Unlock \(source.name)",
                                      message: "Enter your \(source.name) master password to fill saved logins.",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.placeholder = "Master password"
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Unlock", style: .default) { [weak self, weak alert] _ in
            let password = alert?.textFields?.first?.text ?? ""
            alert?.textFields?.first?.text = ""
            guard let self, !password.isEmpty, let vaultService = self.vaultService else { return }
            Task { @MainActor in
                self.showAgentActivity("Unlocking \(source.name)…")
                let outcome = await vaultService.unlock(source: source, password: password, profile: self.vaultProfile)
                if outcome.ok {
                    Haptics.play(.success)
                    self.showAgentActivity("\(source.name) unlocked — tap the key icon to fill")
                } else {
                    Haptics.play(.error)
                    self.showAgentActivity(outcome.error ?? "Couldn’t unlock \(source.name)")
                }
            }
        })
        (FailureAlert.topmost(self) ?? self).present(alert, animated: true)
    }

    private func presentOnePasswordMove(origin: String) {
        let model = OnePasswordMoveModel(origin: origin)
        var holder: UIViewController?
        let view = OnePasswordMoveView(
            model: model,
            done: { [weak self] in
                holder?.dismiss(animated: true)
                self?.showAgentActivity("Moved login from 1Password — tap the key icon to fill")
            },
            typeInstead: {
                holder?.dismiss(animated: true)
            }
        )
        let host = UIHostingController(rootView: HQScaledRoot(view))
        host.title = "Move from 1Password"
        let nav = UINavigationController(rootViewController: host)
        host.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak nav] _ in
            nav?.dismiss(animated: true)
        })
        holder = nav
        SheetStyle.apply(nav, from: self)
        (FailureAlert.topmost(self) ?? self).present(nav, animated: true)
    }

    // MARK: Address Bar (`UITextFieldDelegate`)

    func textFieldDidBeginEditing(_ textField: UITextField) {
        editingAddress = true
        addressField.showsLock = false
        addressField.text = activeTab?.currentURL?.absoluteString ?? ""
        DispatchQueue.main.async { textField.selectAll(nil) }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        editingAddress = false
        syncChrome()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let raw = textField.text ?? ""
        editingAddress = false
        textField.resignFirstResponder()
        if let url = PreviewActEngine.normalizeAddress(raw, allowLoopback: allowLoopback) {
            navigateActiveTab(to: url)
        } else {
            syncChrome()
        }
        return true
    }

    // MARK: Agent Reading & Driving (`preview.read` / `preview.act`)

    /// The page as the bot reads it: its address, title and visible text.
    func readPage() async -> Page {
        guard let web = activeWeb, let fallbackURL = activeTab?.currentURL else {
            return Page(url: "", title: "", text: "")
        }
        showAgentActivity("\(botName) is reading this page…")
        // Trigger subtle visual read sweep without blocking the read.
        _ = try? await web.callAsyncJavaScript(
            PreviewActEngine.actScript,
            arguments: ["payload": ["action": "read_cue"]],
            in: nil,
            contentWorld: .defaultClient
        )
        let fallback = Page(url: fallbackURL.absoluteString, title: web.title ?? "", text: "")
        guard let value = try? await web.callAsyncJavaScript(
            "return {url: location.href, title: document.title || '', text: document.body ? document.body.innerText : ''}",
            arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any] else { return fallback }
        return Page(url: value["url"] as? String ?? fallback.url, title: value["title"] as? String ?? fallback.title,
                    text: value["text"] as? String ?? "")
    }

    /// Execute one `preview.act` request (`drive_preview` / `annotate_preview`) on the active page.
    func performAct(_ params: JSONValue) async -> String {
        guard let web = activeWeb, activeTab?.currentURL != nil else {
            return PreviewActEngine.errorJSON("No live page is open in the in-app browser — open one with desktop_preview first.")
        }
        let action = (params["action"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let targetHint = params["ref"]?.string ?? params["selector"]?.string

        showAgentActivity(PreviewActEngine.statusSummary(action: action, target: targetHint, botName: botName),
                          sticky: action == "pin" || action == "hold")

        // Navigation verbs are owned by the WKWebView directly.
        if action == "back" || action == "forward" || action == "reload" {
            switch action {
            case "back":
                if !web.canGoBack {
                    return PreviewActEngine.errorJSON("Can’t go back: already at the first page.",
                                                      url: web.url?.absoluteString ?? "", title: web.title ?? "")
                }
                web.goBack()
            case "forward":
                if !web.canGoForward {
                    return PreviewActEngine.errorJSON("Can’t go forward: already at the latest page.",
                                                      url: web.url?.absoluteString ?? "", title: web.title ?? "")
                }
                web.goForward()
            case "reload":
                web.reload()
            default: break
            }
            try? await Task.sleep(for: .milliseconds(350))
            return PreviewActEngine.encode([
                "success": true,
                "acted": action == "reload" ? "reloaded the page" : "navigated \(action)",
                "url": web.url?.absoluteString ?? "",
                "title": web.title ?? "",
            ])
        }

        if action == "pin" || action == "hold" {
            hasPinnedMarks = true
            agentClearButton.isHidden = false
        } else if action == "unpin", params["ref"]?.string == nil, params["selector"]?.string == nil {
            hasPinnedMarks = false
            agentClearButton.isHidden = true
        }

        let payload = Self.foundationDict(params)
        do {
            let result = try await web.callAsyncJavaScript(
                PreviewActEngine.actScript,
                arguments: ["payload": payload],
                in: nil,
                contentWorld: .defaultClient
            )
            if let text = result as? String { return text }
            return PreviewActEngine.errorJSON("The page returned an unexpected response.",
                                              url: web.url?.absoluteString ?? "", title: web.title ?? "")
        } catch {
            // A click/submit that starts a navigation tears down the JS context mid-settle.
            if action == "click" || action == "type" || action == "press" {
                return PreviewActEngine.encode([
                    "success": true,
                    "acted": "acted and the page started navigating",
                    "note": "The page stopped answering right after — it is probably navigating. Call elements to see where you landed.",
                    "url": web.url?.absoluteString ?? "",
                    "title": web.title ?? "",
                ])
            }
            return PreviewActEngine.errorJSON("Browser script failed: \(error.localizedDescription)",
                                              url: web.url?.absoluteString ?? "", title: web.title ?? "")
        }
    }

    private static func foundationDict(_ value: JSONValue) -> [String: Any] {
        guard let data = try? value.encoded(),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    // MARK: WKNavigationDelegate & WKUIDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let tab = tabs.first(where: { $0.webView === webView }) {
            tab.loadError = nil
        }
        if webView === activeWeb { syncChrome() }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let tab = tabs.first(where: { $0.webView === webView }) {
            tab.documentGeneration += 1
            tab.loadError = nil
        }
        if webView === activeWeb {
            hasPinnedMarks = false
            agentClearButton.isHidden = true
            syncChrome()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        recordLoadError(error, for: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        recordLoadError(error, for: webView)
    }

    private func recordLoadError(_ error: Error, for webView: WKWebView) {
        let ns = error as NSError
        // Ignore normal cancellations (e.g. fast redirects or policy-handled external links).
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        if let tab = tabs.first(where: { $0.webView === webView }) {
            tab.loadError = error.localizedDescription
        }
        if webView === activeWeb { syncChrome() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let target = action.request.url, let scheme = target.scheme?.lowercased() else { return .cancel }
        if ["http", "https", "about", "blob", "data"].contains(scheme) { return .allow }
        _ = await UIApplication.shared.open(target)
        return .cancel
    }

    /// `target=_blank` and `window.open` open in a new tab inside this browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url {
            addTab(url: url, select: true)
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    #if DEBUG
    var debugActiveWebView: WKWebView? { activeWeb }

    func debugOpenDemoTab(html: String, baseURL: URL, label: String, select: Bool = true) {
        loadViewIfNeeded()
        let tab: BrowserTab
        if let current = activeTab, current.currentURL == nil, select {
            tab = current
            tab.url = baseURL
            tab.label = label
        } else {
            tab = addTab(url: nil, label: label, select: select)
            tab.url = baseURL
        }
        tab.webView.loadHTMLString(html, baseURL: baseURL)
        if select { selectTab(at: tabs.firstIndex(where: { $0 === tab }) ?? selectedIndex) }
        rebuildTabStrip()
        syncChrome()
    }
    #endif
}
