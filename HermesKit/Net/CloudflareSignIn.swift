// [cf-access] Sign in with Nous while the gateway is behind Cloudflare Access.
//
// The system sheet (`ASWebAuthenticationSession.additionalHeaderFields`) attaches the service token to its first
// request only. Strict service-token authentication — on by default for Zero Trust organizations created on or after
// 2026-10-05 — does not set a `CF_Authorization` cookie and will not take one in place of the headers. The identity
// provider then redirects the browser to `<gateway>/auth/callback` with neither, and Access answers 401 before Hermes
// can finish the login.
//
// This view sends `CF-Access-Client-Id` and `CF-Access-Client-Secret` on every main-frame request to the gateway's
// own origin, including that callback, and on no other host. Reloading the callback here keeps the PKCE cookie the
// authorize response stored. The loopback redirect is not loaded in the view (an https page does not reliably
// navigate to `http://127.0.0.1`); the app fetches it so `LoopbackRelay` still settles.

import UIKit
import WebKit

/// Where one navigation in the access sign-in view is allowed to go. Pure: the view applies it, the tests lock it.
nonisolated enum CloudflareSignIn {
    enum Step: Equatable, Sendable {
        /// Load the request as it stands.
        case allow
        /// The gateway, missing its service token. Load it again with the headers on.
        case stamp
        /// `http://127.0.0.1/callback` (or `::1`). Fetch it for the relay; do not load it in the view.
        case loopback
        /// Drop it. A subframe of the gateway without the token, or a subframe of the loopback redirect.
        case cancel
    }

    /// A saved token: at least one header has a value. Blank headers take the ordinary system sheet.
    static func needsWebView(_ headers: [String: String]) -> Bool {
        headers.contains { !$0.value.isEmpty }
    }

    /// Both headers are already on `request`, with these exact values (header names are compared case-insensitively).
    static func carries(_ request: URLRequest, headers: [String: String]) -> Bool {
        headers.allSatisfy { request.value(forHTTPHeaderField: $0.key) == $0.value }
    }

    static func sameOrigin(_ url: URL, _ gateway: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              scheme == gateway.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty, host == gateway.host?.lowercased() else { return false }
        return port(of: url) == port(of: gateway)
    }

    /// `GET /callback` on the loopback, which is the relay's redirect and never the gateway's own origin.
    static func isLoopbackCallback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host == "127.0.0.1" || host == "::1" else { return false }
        return url.path == "/callback"
    }

    static func step(url: URL, mainFrame: Bool, carriesToken: Bool, gateway: URL) -> Step {
        if sameOrigin(url, gateway) {
            if carriesToken { return .allow }
            return mainFrame ? .stamp : .cancel
        }
        if isLoopbackCallback(url) { return mainFrame ? .loopback : .cancel }
        return .allow
    }

    static func port(of url: URL) -> Int {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return -1
        }
    }
}

/// The sign-in page used when a Cloudflare Access service token is saved. Presented full screen, with Cancel.
@MainActor final class CloudflareSignInController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let start: URL
    private let gateway: URL
    private let headers: [String: String]
    private let isPrivate: Bool
    private let onCancel: @MainActor () -> Void
    private var web: WKWebView?
    private let progress = UIProgressView(progressViewStyle: .bar)
    private let failed = UILabel()
    private var observers: [NSKeyValueObservation] = []
    private var stampCounts: [String: Int] = [:]
    private var deliveredLoopback = false
    private var ended = false
    /// A headerless gateway navigation was cancelled so it can be loaded again with the token. Its failure is not
    /// the page failing.
    private var replacing = false
    private var current: WKNavigation?
    private let loopback: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    init(start: URL, headers: [String: String], isPrivate: Bool, onCancel: @escaping @MainActor () -> Void) {
        self.start = start
        gateway = start
        self.headers = headers
        self.isPrivate = isPrivate
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The relay caught the loopback redirect. Does not report a cancel.
    func close() {
        guard !ended else { return }
        ended = true
        tearDown()
        navigationController?.dismiss(animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = start.host
        navigationItem.largeTitleDisplayMode = .never
        let cancel = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.cancel() })
        cancel.accessibilityIdentifier = "access-sign-in.cancel"
        navigationItem.leftBarButtonItem = cancel

        let config = WKWebViewConfiguration()
        // A private sheet keeps no logins of its own. This view does not share Safari's cookies: the system sheet
        // does, and it cannot carry the service token past its first request.
        config.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.scrollView.keyboardDismissMode = .interactive
        web.accessibilityIdentifier = "access-sign-in.web"
        #if DEBUG
        web.isInspectable = true
        #endif
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        self.web = web

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.trackTintColor = .clear
        progress.alpha = 0
        view.addSubview(progress)

        failed.font = .preferredFont(forTextStyle: .body)
        failed.adjustsFontForContentSizeCategory = true
        failed.textColor = .secondaryLabel
        failed.textAlignment = .center
        failed.numberOfLines = 0
        failed.text = "This page didn’t load."
        failed.isHidden = true
        failed.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(failed)

        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progress.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            failed.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            failed.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            failed.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
        ])
        observers.append(web.observe(\.estimatedProgress) { [weak self] web, _ in
            Task { @MainActor in self?.showProgress(web.estimatedProgress, loading: web.isLoading) }
        })
        observers.append(web.observe(\.isLoading) { [weak self] web, _ in
            Task { @MainActor in self?.showProgress(web.estimatedProgress, loading: web.isLoading) }
        })
        var first = URLRequest(url: start)
        first.cachePolicy = .reloadIgnoringLocalCacheData
        load(first, addingToken: true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !ended, isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        ended = true
        onCancel()
        tearDown()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard !ended, let url = action.request.url else { return .cancel }
        // A new window is loaded from `createWebViewWith`, which runs this same decision.
        if action.targetFrame == nil { return .cancel }
        let mainFrame = action.targetFrame?.isMainFrame == true
        switch CloudflareSignIn.step(url: url, mainFrame: mainFrame,
                                     carriesToken: CloudflareSignIn.carries(action.request, headers: headers), gateway: gateway) {
        case .allow:
            return .allow
        case .cancel:
            return .cancel
        case .loopback:
            deliver(url)
            return .cancel
        case .stamp:
            let key = "\(url.host ?? "")\(url.path)"
            let count = stampCounts[key, default: 0] + 1
            stampCounts[key] = count
            guard count <= 2 else {
                AppLog.note("auth", "access sign-in gave up restamping \(url.path)")
                return .cancel
            }
            AppLog.trace("auth", "access sign-in sending the token to \(url.host ?? "")\(url.path)")
            replacing = true
            load(action.request, addingToken: true)
            return .cancel
        }
    }

    /// `target=_blank` and `window.open` stay in this view. The token is added only when the destination is the gateway.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !ended, let url = action.request.url else { return nil }
        switch CloudflareSignIn.step(url: url, mainFrame: true,
                                     carriesToken: CloudflareSignIn.carries(action.request, headers: headers), gateway: gateway) {
        case .allow:
            load(action.request, addingToken: false)
        case .stamp:
            load(action.request, addingToken: true)
        case .loopback:
            deliver(url)
        case .cancel:
            break
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        current = navigation
        replacing = false
        failed.isHidden = true
        web?.isHidden = false
        if let host = webView.url?.host { title = host }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        noteFailure(navigation, error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        noteFailure(navigation, error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !ended else { return }
        var again = URLRequest(url: webView.url ?? start)
        again.cachePolicy = .reloadIgnoringLocalCacheData
        load(again, addingToken: CloudflareSignIn.sameOrigin(again.url ?? start, gateway))
    }

    private func load(_ request: URLRequest, addingToken: Bool) {
        guard !ended, web != nil else { return }
        var next = request
        next.cachePolicy = .reloadIgnoringLocalCacheData
        if addingToken {
            guard let url = request.url, CloudflareSignIn.sameOrigin(url, gateway) else { return }
            for (field, value) in headers {
                next.setValue(value, forHTTPHeaderField: field)
            }
        }
        // Outside `decidePolicyFor`: a load started inside that callback is cancelled with the policy.
        Task { @MainActor [weak self] in
            guard let self, !self.ended else { return }
            self.web?.load(next)
        }
    }

    /// One GET, with no cookies and no service token. The relay answers and closes this view.
    private func deliver(_ url: URL) {
        guard !ended, !deliveredLoopback else { return }
        deliveredLoopback = true
        let session = loopback
        Task { _ = try? await session.data(from: url) }
    }

    private func cancel() {
        guard !ended else { return }
        ended = true
        onCancel()
        tearDown()
        navigationController?.dismiss(animated: true)
    }

    private func tearDown() {
        web?.navigationDelegate = nil
        web?.uiDelegate = nil
        loopback.invalidateAndCancel()
    }

    private func noteFailure(_ navigation: WKNavigation?, _ error: any Error) {
        guard !replacing, !isCancellation(error) else { return }
        guard current == nil || navigation === current else { return }
        fail()
    }

    private func fail() {
        guard !ended else { return }
        web?.isHidden = true
        failed.isHidden = false
        progress.alpha = 0
    }

    private func showProgress(_ value: Double, loading: Bool) {
        guard failed.isHidden else { return }
        progress.setProgress(Float(value), animated: loading)
        progress.alpha = loading ? 1 : 0
    }

    private func isCancellation(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return true }
        return error.domain == "WebKitErrorDomain" && error.code == 102
    }
}
