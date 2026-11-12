// [preview-tab] A bot's Browser tab: the page a bot shows you with Hermes's `desktop_preview` tool (Hermes 0.23; Hermes
// Desktop's preview pane, HA:tools/preview_tool.py). Hermes offers that tool to every chat whose app says it is the
// desktop, which this app does, so bots here have had it with nothing answering. Now:
// - `preview.open {url, label}` opens the page over the chat it belongs to, when that chat is on screen (as Desktop:
//   a chat you aren't looking at never pulls a page up). A file path on the bot's computer opens in the file viewer;
//   a page on the bot's own computer (localhost) says it can't be reached from here.
// - `preview.close {url}` closes it ('' closes any).
// - the `preview.read` request answers with the page's title, address and visible text in Desktop's shape
//   (HA:apps/desktop/src/app/chat/right-rail/preview-reader.ts), paged by start/count, 24,000 characters at most.
// The tab is a sheet that rests at half height over the chat on the iPhone, so the chat stays in view.

import UIKit
import WebKit

@MainActor final class PreviewTabCenter {
    static let maxChars = 24_000

    private let client: any GatewayClient
    private let accountId: String
    private var eventsTask: Task<Void, Never>?
    private var screens: [WeakScreen] = []
    /// The open tab of each chat screen.
    private var tabs: [ObjectIdentifier: WeakTab] = [:]

    private struct WeakScreen { weak var screen: ChatViewController? }
    private struct WeakTab { weak var tab: PreviewTabController? }

    init(client: any GatewayClient, accountId: String) {
        self.client = client
        self.accountId = accountId
        let events = client.events()
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
        for case let tab? in tabs.values.map(\.tab) { tab.dismiss(animated: false) }
        tabs = [:]
        screens = []
    }

    /// Each chat screen as it opens (`installBrowser(on:)`).
    func register(_ screen: ChatViewController) {
        screens = screens.filter { $0.screen != nil && $0.screen !== screen } + [WeakScreen(screen: screen)]
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
            open(PreviewTarget(target), label: label, on: screen)
        case "preview.close":
            let url = event.payload["url"]?.string ?? ""
            for screen in screens.compactMap(\.screen) where Self.covers(screen, event.sessionId) {
                guard let tab = tabs[ObjectIdentifier(screen)]?.tab else { continue }
                if url.isEmpty || tab.matches(url) { tab.close() }
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
            if let tab = tabs[ObjectIdentifier(screen)]?.tab, tab.presentingViewController != nil {
                tab.show(url, label: label)
                return
            }
            let tab = PreviewTabController(url: url, label: label, botName: botName(screen))
            tabs[ObjectIdentifier(screen)] = WeakTab(tab: tab)
            tab.present(from: screen)
        case .unreachable(let address):
            LinkOpener.notice(PreviewTarget.unreachableNotice(address, bot: botName(screen)), from: screen)
        }
    }

    private func botName(_ screen: ChatViewController) -> String {
        (screen.session as? LiveChatSession)?.botName ?? screen.session.title
    }

    // MARK: Reading

    /// `preview.read` for `session`: the page as JSON, or nil when no tab of that chat is open here.
    func read(session: String, params: JSONValue) async -> String? {
        guard let tab = screens.compactMap(\.screen).filter({ Self.covers($0, session) })
            .compactMap({ tabs[ObjectIdentifier($0)]?.tab }).first(where: { $0.presentingViewController != nil }) else { return nil }
        let page = await tab.readPage()
        return Self.answer(page, start: params["start"]?.int, count: params["count"]?.int)
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
        self = Self.isLoopback(host) ? .unreachable(value) : .page(url)
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

/// One bot's Browser tab: a page in a sheet, with its address, back and forward, Safari and Close.
final class PreviewTabController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    struct Page { var url: String; var title: String; var text: String }

    private(set) var url: URL
    private var label: String
    private let botName: String
    private var web: WKWebView!
    private let progress = UIProgressView(progressViewStyle: .bar)
    private var observers: [NSKeyValueObservation] = []
    private var backItem: UIBarButtonItem!
    private var forwardItem: UIBarButtonItem!

    /// One store for every bot's tab (Desktop's `persist:hermes-preview`): sign-ins on these pages are kept.
    private static let storeID = UUID(uuidString: "6E1F3A52-8C2D-4B7E-9A41-2D5C0B7F4E19")!

    init(url: URL, label: String, botName: String) {
        self.url = url
        self.label = label
        self.botName = botName
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func present(from screen: UIViewController) {
        let nav = UINavigationController(rootViewController: self)
        nav.view.accessibilityIdentifier = "preview-tab"
        if let sheet = nav.sheetPresentationController, !DeviceWord.isMac {
            // Half height over the chat, which stays in view and in reach; up to full height for reading.
            sheet.detents = [.medium(), .large()]   // solid-ok: a web page fills the sheet edge to edge, no glass shows
            sheet.selectedDetentIdentifier = traitCollection.horizontalSizeClass == .compact ? .medium : .large
            sheet.largestUndimmedDetentIdentifier = .medium
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        (FailureAlert.topmost(screen) ?? screen).present(nav, animated: true)
    }

    func matches(_ address: String) -> Bool {
        guard case .page(let other) = PreviewTarget(address) else { return false }
        return Self.same(other, url) || web.flatMap { $0.url.map { Self.same(other, $0) } } == true
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        a.host?.lowercased() == b.host?.lowercased() && a.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            == b.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Another open from the same chat: the tab moves to it.
    func show(_ url: URL, label: String) {
        self.url = url
        self.label = label
        updateTitle()
        web.load(URLRequest(url: url))
    }

    func close() {
        dismiss(animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.groupedPage
        navigationItem.largeTitleDisplayMode = .never
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
        view.addSubview(web)
        self.web = web
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.trackTintColor = .clear
        view.addSubview(progress)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progress.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.close() })
        close.accessibilityIdentifier = "preview-tab.close"
        backItem = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), primaryAction: UIAction { [weak self] _ in self?.web.goBack() })
        backItem.accessibilityLabel = "Back"
        forwardItem = UIBarButtonItem(image: UIImage(systemName: "chevron.forward"), primaryAction: UIAction { [weak self] _ in self?.web.goForward() })
        forwardItem.accessibilityLabel = "Forward"
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [
            UIAction(title: "Reload", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.web.reload() },
            UIAction(title: LinkOpener.outsideTitle, image: UIImage(systemName: "safari")) { [weak self] _ in
                guard let self else { return }
                LinkOpener.openOutside(self.web.url ?? self.url)   // [links-browser]
            },
            UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { [weak self] _ in
                guard let self else { return }
                UIPasteboard.general.url = self.web.url ?? self.url
                Haptics.play(.success)
            },
        ]))
        more.accessibilityLabel = "More"
        more.accessibilityIdentifier = "preview-tab.more"
        navigationItem.leftBarButtonItems = [close]
        navigationItem.rightBarButtonItems = [more, forwardItem, backItem]

        observers.append(web.observe(\.estimatedProgress) { [weak self] web, _ in
            Task { @MainActor in self?.showProgress(web.estimatedProgress, loading: web.isLoading) }
        })
        observers.append(web.observe(\.isLoading) { [weak self] web, _ in
            Task { @MainActor in self?.showProgress(web.estimatedProgress, loading: web.isLoading) }
        })
        observers.append(web.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.updateTitle() } })
        observers.append(web.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.updateTitle() } })
        observers.append(web.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.updateButtons() } })
        observers.append(web.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor in self?.updateButtons() } })
        updateTitle()
        updateButtons()
        web.load(URLRequest(url: url))
    }

    /// The label the bot gave, else the page's title; the site under it.
    private func updateTitle() {
        guard isViewLoaded else { return }
        let pageTitle = web.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        navigationItem.title = !label.isEmpty ? label : (pageTitle.isEmpty ? botName : pageTitle)
        navigationItem.subtitle = Self.site(web.url ?? url)
    }

    static func site(_ url: URL) -> String {
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func updateButtons() {
        backItem.isEnabled = web.canGoBack
        forwardItem.isEnabled = web.canGoForward
    }

    private func showProgress(_ value: Double, loading: Bool) {
        progress.setProgress(Float(value), animated: loading)
        HQMotion.animate(loading ? 0 : 0.25, changes: { self.progress.alpha = loading ? 1 : 0 })
    }

    /// The page as the bot reads it: its address, title and visible text.
    func readPage() async -> Page {
        let fallback = Page(url: (web.url ?? url).absoluteString, title: web.title ?? "", text: "")
        guard let value = try? await web.callAsyncJavaScript(
            "return {url: location.href, title: document.title || '', text: document.body ? document.body.innerText : ''}",
            arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any] else { return fallback }
        return Page(url: value["url"] as? String ?? fallback.url, title: value["title"] as? String ?? fallback.title,
                    text: value["text"] as? String ?? "")
    }

    // MARK: Web

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let target = action.request.url, let scheme = target.scheme?.lowercased() else { return .cancel }
        if ["http", "https", "about", "blob", "data"].contains(scheme) { return .allow }
        _ = await UIApplication.shared.open(target)   // mail, phone, an app's own link
        return .cancel
    }

    /// `target=_blank` and `window.open` stay in the tab.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}
