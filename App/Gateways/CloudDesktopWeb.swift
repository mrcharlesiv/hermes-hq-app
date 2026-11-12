// [cloud-desktop] A Hermes Cloud agent's own Hermes Desktop, inside the app. Since Hermes 0.23 ("Desktop in a browser
// tab"), a gateway can serve the whole Desktop workspace as a web page (the Webapp); Hermes Cloud agents serve it at
// their own address (`https://<name>.agents.nousresearch.com/`), behind Sign in with Nous.
//
// The app's own Nous sign-in can't be handed to that page: upstream binds every browser login to a secret the gateway
// keeps (hermes_cli/webapp_sign_in.py), and its handoff tickets work only on a loopback Webapp. So the page signs in
// with Nous once, in this view, and keeps that login in a web data store of its own per agent (30 days, as in a
// browser). The page's own links to other sites open in the in-app Safari view; sign-in pages stay here.

import CryptoKit
import UIKit
import WebKit

enum CloudDesktopWeb {
    static let title = "Hermes Desktop"
    static let menuTitle = "Open Hermes Desktop"
    static let rowDetail = "This agent’s full Desktop: chats, files, jobs and settings. Sign in with Nous once."
    static let failedTitle = "Couldn’t Open Hermes Desktop"
    static let failedBody = "The agent didn’t answer. Check that it’s running, then try again."
    static let tooOldBody = "This agent’s Hermes is too old for Desktop in a browser. Update it on its page, then try again."
    static let signOutTitle = "Sign Out of Hermes Desktop"

    /// The Webapp's address on a gateway Nous hosts (its root); nil for any other gateway (a self-hosted Webapp has its
    /// own port, off by default, which the app can't know).
    static func address(_ gateway: URL?) -> URL? {
        guard let gateway, CloudGatewayFlow.isCloud(gateway), let host = gateway.host else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = "/"
        return parts.url
    }

    /// Hosts the page may move to inside this view: the agent itself and Nous (its sign-in). Anything else the page's
    /// own links lead to opens in Safari; a sign-in page's links stay here (a Nous login may pass through its
    /// identity provider).
    static func staysInside(_ url: URL, agentHost: String, from source: URL?) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" || scheme == "blob" || scheme == "data" { return true }
        guard scheme == "https" || scheme == "http", let host = url.host?.lowercased() else { return false }
        if host == agentHost || host == "nousresearch.com" || host.hasSuffix(".nousresearch.com") { return true }
        // A link the agent's own page offers leaves for Safari; one on a sign-in page (Portal, its identity provider) stays.
        return source?.host?.lowercased() != agentHost
    }

    /// Opens it over `presenter`, full screen with its own Done.
    static func present(gateway: URL, name: String, from presenter: UIViewController?) {
        guard let url = address(gateway), let host = FailureAlert.topmost(presenter) else { return }
        let page = CloudDesktopWebController(url: url, agentName: name)
        let nav = UINavigationController(rootViewController: page)
        nav.modalPresentationStyle = .fullScreen
        page.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak nav] _ in
            nav?.dismiss(animated: true)
        })
        page.navigationItem.leftBarButtonItem?.accessibilityIdentifier = "cloud-desktop.done"
        host.present(nav, animated: true)
    }

    /// A store per agent, so each one's login is its own and survives the app closing.
    static func store(for host: String) -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: storeID(host))
    }

    static func storeID(_ host: String) -> UUID {
        // A stable UUID from the host: the first 16 bytes of its SHA-256, shaped as a name-based (v5) UUID.
        var bytes = Array(SHA256.hash(data: Data("hq-cloud-desktop:\(host.lowercased())".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

final class CloudDesktopWebController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    let url: URL
    let agentName: String
    private var agentHost: String { url.host?.lowercased() ?? "" }
    private var web: WKWebView!
    private let progress = UIProgressView(progressViewStyle: .bar)
    private let message = UIStackView()
    private let messageTitle = UILabel()
    private let messageBody = UILabel()
    private var observers: [NSKeyValueObservation] = []

    init(url: URL, agentName: String) {
        self.url = url
        self.agentName = agentName
        super.init(nibName: nil, bundle: nil)
        title = agentName.isEmpty ? CloudDesktopWeb.title : agentName
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.groupedPage
        navigationItem.largeTitleDisplayMode = .never
        let config = WKWebViewConfiguration()
        config.websiteDataStore = CloudDesktopWeb.store(for: agentHost)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.scrollView.keyboardDismissMode = .interactive
        web.isOpaque = false
        web.backgroundColor = HQPalette.groupedPage
        web.accessibilityIdentifier = "cloud-desktop.web"
        #if DEBUG
        web.isInspectable = true
        #endif
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        self.web = web

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.trackTintColor = .clear
        view.addSubview(progress)

        messageTitle.font = DeviceWord.isMac ? MacType.emptyTitle : HQFont.preferred(.headline)
        messageTitle.textAlignment = .center
        messageTitle.numberOfLines = 0
        messageBody.font = DeviceWord.isMac ? MacType.emptyBody : HQFont.preferred(.subheadline)
        messageBody.textColor = HQPalette.label2
        messageBody.textAlignment = .center
        messageBody.numberOfLines = 0
        var again = UIButton.Configuration.hqPush()
        again.title = "Try Again"
        let button = UIButton(configuration: again, primaryAction: UIAction { [weak self] _ in self?.load() })
        button.accessibilityIdentifier = "cloud-desktop.retry"
        message.axis = .vertical
        message.spacing = 10
        message.alignment = .center
        [messageTitle, messageBody, button].forEach(message.addArrangedSubview)
        message.setCustomSpacing(18, after: messageBody)
        message.translatesAutoresizingMaskIntoConstraints = false
        message.isHidden = true
        view.addSubview(message)

        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progress.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            message.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor, constant: 16),
            message.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor, constant: -16),
        ])

        observers.append(web.observe(\.estimatedProgress) { [weak self] web, _ in
            Task { @MainActor in self?.showProgress(web.estimatedProgress, loading: web.isLoading) }
        })
        observers.append(web.observe(\.isLoading) { [weak self] web, _ in
            Task { @MainActor in self?.showProgress(web.estimatedProgress, loading: web.isLoading) }
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: moreMenu())
        navigationItem.rightBarButtonItem?.accessibilityLabel = "More"
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "cloud-desktop.more"
        load()
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Reload", action: #selector(reload), input: "r", modifierFlags: .command)]
    }

    private func moreMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Reload", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.reload() },
            UIAction(title: LinkOpener.outsideTitle, image: UIImage(systemName: "safari")) { [weak self] _ in
                guard let self else { return }
                LinkOpener.openOutside(self.web.url.flatMap { $0.host?.lowercased() == self.agentHost ? $0 : nil } ?? self.url)
            },
            UIAction(title: CloudDesktopWeb.signOutTitle, image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                     attributes: .destructive) { [weak self] _ in self?.signOut() },
        ])
    }

    private func load() {
        message.isHidden = true
        web.isHidden = false
        web.load(URLRequest(url: url))
    }

    @objc private func reload() {
        if web.url == nil || !message.isHidden { load() } else { web.reload() }
    }

    /// Forgets this agent's Nous login in the app (the gateway's own record of it ends when it expires).
    private func signOut() {
        let store = web.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            self?.load()
        }
    }

    private func showProgress(_ value: Double, loading: Bool) {
        progress.setProgress(Float(value), animated: loading)
        HQMotion.animate(loading ? 0 : 0.25, changes: { self.progress.alpha = loading ? 1 : 0 })
    }

    private func fail(_ body: String) {
        messageTitle.text = CloudDesktopWeb.failedTitle
        messageBody.text = body
        message.isHidden = false
        web.isHidden = true
        AppLog.note("cloud-desktop", "page failed: \(body == CloudDesktopWeb.tooOldBody ? "no webapp" : "unreachable")")
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let target = action.request.url else { return .cancel }
        // Subframes load as the page asks.
        guard action.targetFrame?.isMainFrame ?? true else { return .allow }
        if CloudDesktopWeb.staysInside(target, agentHost: agentHost, from: action.sourceFrame.request.url) { return .allow }
        openOutside(target)
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // The agent answering 404 at its root: its Hermes predates the Webapp.
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode == 404,
           http.url?.host?.lowercased() == agentHost, http.url?.path == "/" {
            fail(CloudDesktopWeb.tooOldBody)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    private func failed(_ error: any Error) {
        let error = error as NSError
        // A navigation this view cancelled (sent to Safari) or replaced is not a failure.
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return }   // frame load interrupted
        fail(error.localizedDescription.isEmpty ? CloudDesktopWeb.failedBody : "\(CloudDesktopWeb.failedBody)\n\n\(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: WKUIDelegate

    /// `target=_blank` and `window.open`: the agent's own pages load here; anything else opens in Safari.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let target = action.request.url else { return nil }
        if target.host?.lowercased() == agentHost {
            webView.load(action.request)
        } else {
            openOutside(target)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage text: String, initiatedByFrame frame: WKFrameInfo) async {
        _ = await ask(text, cancel: false)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage text: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await ask(text, cancel: true)
    }

    private func ask(_ text: String, cancel: Bool) async -> Bool {
        await withCheckedContinuation { done in
            let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
            if cancel { alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done.resume(returning: false) }) }
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done.resume(returning: true) })
            guard let host = FailureAlert.topmost(self) else { done.resume(returning: false); return }
            host.present(alert, animated: true)
        }
    }

    private func openOutside(_ target: URL) {
        let scheme = target.scheme?.lowercased()
        if scheme == "https" || scheme == "http" {
            LinkOpener.open(target, from: self)
        } else {
            UIApplication.shared.open(target)
        }
    }
}
