// [plugin-pages] A page plugin's page, opened in Hermes HQ: the plugin's dashboard bundle runs in a web view on HQ's own
// host (scripts/plugin-host: React, the dashboard's plugin SDK, HQ-styled components). Everything the page loads comes
// through the signed-in gateway client:
// - `hqplugin://page/…` is served by `PluginPageSchemeHandler`: the shell, the host's files from the app, and the
//   plugin's own files (`/dashboard-plugins/<name>/…`) and GET routes (`/api/plugins/<name>/…`, for pictures);
// - fetchJSON/authedFetch reach `userContentController(_:didReceive:replyHandler:)`, which sends the request with the
//   account's auth (cookies, or a Nous bearer) and allows only the plugin's own `/api/plugins/<name>/` routes.
// A bundle that can't load, never registers or crashes, and a plugin API the server hasn't mounted yet (a 404 with no
// route: Hermes must restart), each get a native message instead of a blank page.

import SwiftUI
import UIKit
import WebKit

@MainActor @Observable
final class PluginWebPageState {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(title: String, words: String)
        /// The plugin's routes aren't on the server yet: Hermes must restart to finish adding the page.
        case needsRestart
    }

    var phase: Phase = .loading { didSet { if phase != oldValue { changed?(phase) } } }
    var asking = false
    /// The controller hides the message's view once the page is up, so touches reach the web view.
    @ObservationIgnored var changed: ((Phase) -> Void)?
    var askNote: String?
}

final class PluginWebPageController: UIViewController, WKNavigationDelegate, WKScriptMessageHandlerWithReply, WKScriptMessageHandler,
                                     KeyRefreshing {
    static let scheme = "hqplugin"

    let page: PluginDashboardPage
    let profile: String
    let botName: String
    private let client: any GatewayClient
    private weak var services: AppModel?
    let state = PluginWebPageState()
    private var web: WKWebView?
    private var schemes: PluginPageSchemeHandler?
    private var status: UIHostingController<HQScaledRoot<PluginWebPageStatus>>?
    private var loadTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private(set) var bundle: Data?
    private(set) var stylesheet: Data?
    private let opened = ContinuousClock.now
    /// [plugin-pages-more] The bots that have this page too (More › Plugin Pages), for the bar's bot switch; empty when
    /// only this bot has it.
    var otherBots: [(profile: String, name: String)] = []

    init(page: PluginDashboardPage, profile: String, botName: String, client: any GatewayClient, services: AppModel?) {
        self.page = page
        self.profile = profile
        self.botName = botName
        self.client = client
        self.services = services
        super.init(nibName: nil, bundle: nil)
        title = page.label
        navigationItem.largeTitleDisplayMode = .never
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The page for `page`, or nil when the app has no gateway client (signed out).
    static func make(page: PluginDashboardPage, model: CapabilitiesModel) -> PluginWebPageController? {
        guard let client = model.store?.client else { return nil }
        return PluginWebPageController(page: page, profile: model.profile, botName: model.botName, client: client,
                                       services: model.services as? AppModel)
    }

    deinit {
        loadTask?.cancel()
        watchdog?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.groupedPage
        view.accessibilityIdentifier = "plugin-web-page"
        let reload = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), primaryAction: UIAction { [weak self] _ in self?.reload() })
        reload.accessibilityLabel = "Reload"
        reload.accessibilityIdentifier = "plugin-web-page.reload"
        navigationItem.rightBarButtonItem = reload
        // [plugin-pages-more] Whose page this is (each bot's plugin reads its own data), and a switch when several have it.
        if otherBots.count > 1 {
            navigationItem.subtitle = botName
            let bots = UIBarButtonItem(image: UIImage(systemName: "person.crop.circle"), menu: botMenu())
            bots.accessibilityLabel = "Bot"
            bots.accessibilityValue = botName
            bots.accessibilityIdentifier = "plugin-web-page.bot"
            navigationItem.rightBarButtonItems = [reload, bots]
        }

        let host = UIHostingController(rootView: HQScaledRoot(PluginWebPageStatus(state: state, page: page, botName: botName,
                                                                                   retry: { [weak self] in self?.reload() },
                                                                                   restart: { [weak self] in self?.askToRestart() },
                                                                                   canAsk: canAskRestart)))
        host.view.backgroundColor = .clear
        host.sizingOptions = []
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        status = host
        state.changed = { [weak host] phase in host?.view.isHidden = phase == .ready }

        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (self: PluginWebPageController, _) in
            self.restyle()
        }
        load()
    }

    // MARK: Loading

    private func load() {
        loadTask?.cancel()
        watchdog?.cancel()
        state.phase = .loading
        let client = self.client, page = self.page, profile = self.profile
        let started = ContinuousClock.now
        loadTask = Task { [weak self] in
            do {
                let bundle = try await client.pageRest("GET", PluginDashboardPage.assetPath(name: page.name, file: page.entry, profile: profile), query: [], body: nil, timeout: 30)
                var css: Data?
                if let file = page.css { css = try? await client.pageRest("GET", PluginDashboardPage.assetPath(name: page.name, file: file, profile: profile), query: [], body: nil, timeout: 20) }
                guard let self, !Task.isCancelled else { return }
                AppLog.trace("plugin-pages", "\(page.name) bundle \(bundle.count) B\(css.map { ", css \($0.count) B" } ?? "") in \(AppLog.ms(since: started)) ms")
                self.bundle = bundle
                self.stylesheet = css
                self.showWeb()
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                let status = (error as? HTTPError)?.status
                AppLog.note("plugin-pages", "\(page.name) bundle failed after \(AppLog.ms(since: started)) ms: \(status.map { "HTTP \($0)" } ?? "\(type(of: error))")")
                if status == 404 {
                    self.state.phase = .failed(title: "Couldn’t Open \(page.label)",
                                               words: "Hermes didn’t send this page’s files. Check that the plugin is on for \(self.botName) in Plugins. If it was just installed, Hermes may need a restart first.")
                } else {
                    let words = (error as? LocalizedError)?.errorDescription ?? "Hermes didn’t answer."
                    self.state.phase = .failed(title: "Couldn’t Open \(page.label)", words: words)
                }
            }
        }
    }

    private func showWeb() {
        web?.removeFromSuperview()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let handler = PluginPageSchemeHandler(owner: self)
        schemes = handler
        config.setURLSchemeHandler(handler, forURLScheme: Self.scheme)
        let content = config.userContentController
        let proxy = PluginPageWeakHandler(self)
        content.addScriptMessageHandler(proxy, contentWorld: .page, name: "hq")
        content.add(proxy, name: "hqNote")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = HQPalette.groupedPage
        web.scrollView.backgroundColor = HQPalette.groupedPage
        web.scrollView.contentInsetAdjustmentBehavior = .automatic
        web.scrollView.keyboardDismissMode = .interactive
        web.allowsBackForwardNavigationGestures = false
        web.accessibilityIdentifier = "plugin-web-page.web"
        #if DEBUG
        web.isInspectable = true
        #endif
        web.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(web, at: 0)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        self.web = web
        web.load(URLRequest(url: URL(string: "\(Self.scheme)://page\(pageURLPath)")!))
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, self.state.phase == .loading else { return }
            AppLog.note("plugin-pages", "\(self.page.name) never said it was ready")
            self.state.phase = .failed(title: "\(self.page.label) Didn’t Start", words: "Its page took too long to load. Try again.")
        }
    }

    /// [plugin-pages-more] The bots that have this page; picking one shows its page in this one's place.
    private func botMenu() -> UIMenu {
        UIMenu(title: "Show for", children: otherBots.map { bot in
            UIAction(title: bot.name, state: bot.profile == profile ? .on : .off) { [weak self] _ in
                guard let self, bot.profile != self.profile, let navigation = self.navigationController,
                      let next = PluginPagesMore.open(self.page.name, profile: bot.profile) else { return }
                Haptics.play(.light)
                AppLog.trace("plugin-pages", "\(self.page.name) bot \(AppLog.tag(self.profile)) → \(AppLog.tag(bot.profile))")
                var stack = navigation.viewControllers
                guard let index = stack.firstIndex(of: self) else { return }
                stack[index] = next
                navigation.setViewControllers(stack, animated: false)
            }
        })
    }

    private func reload() {
        Haptics.play(.light)
        load()
    }

    /// [keys] Mac polish #22: View › Refresh (⌘R) reloads the page as its Reload button does; it refreshed the list
    /// behind the page, or nothing.
    var keyRefresh: (() -> Void)? { { [weak self] in self?.reload() } }

    /// The page's own path on the host (the tab's path), so a plugin reading `location.pathname` sees what the
    /// dashboard would give it.
    var pageURLPath: String {
        let path = page.tabPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "/\(page.name)"
        return path.hasPrefix("/") ? path : "/" + path
    }

    private func restyle() {
        web?.backgroundColor = HQPalette.groupedPage
        web?.scrollView.backgroundColor = HQPalette.groupedPage
        let css = PluginPageTheme.css(traitCollection)
        guard let data = try? JSONSerialization.data(withJSONObject: [css], options: []), let json = String(data: data, encoding: .utf8) else { return }
        web?.evaluateJavaScript("window.__HQ_HOST__ && window.__HQ_HOST__.theme(\(json)[0])")
    }

    // MARK: The shell

    func shellHTML() -> Data {
        let info: [String: String] = ["name": page.name, "label": page.label, "profile": profile == "default" ? "" : profile]
        let infoJSON = (try? JSONSerialization.data(withJSONObject: info)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let entry = PluginDashboardPage.assetPath(name: page.name, file: page.entry, profile: profile)
        let hostCSS = Self.resource("plugin-host", "css").flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let pluginCSS = page.css.map { "<link rel=\"stylesheet\" href=\"\(PluginDashboardPage.assetPath(name: page.name, file: $0, profile: profile))\">" } ?? ""
        let html = """
        <!doctype html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>\(Self.escape(page.label))</title>
        <style id="hq-vars">\(PluginPageTheme.css(traitCollection))</style>
        <script>window.__HQ_PAGE__ = \(infoJSON);</script>
        <script src="/__hq/tailwind.js"></script>
        <style type="text/tailwindcss">\(hostCSS)</style>
        \(pluginCSS)
        <script src="/__hq/plugin-host.js"></script>
        </head><body><div id="root"></div>
        <script src="\(entry)" data-hermes-profile="\(Self.escape(profile == "default" ? "" : profile))" onerror="window.__HQ_HOST__ && window.webkit.messageHandlers.hqNote.postMessage({kind:'state',state:'script-error',message:'The page’s script didn’t load.'})"></script>
        <script>window.__HQ_HOST__ && window.__HQ_HOST__.bundleRan();</script>
        </body></html>
        """
        return Data(html.utf8)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func resource(_ name: String, _ ext: String) -> Data? {
        Bundle.main.url(forResource: name, withExtension: ext).flatMap { try? Data(contentsOf: $0) }
    }

    // MARK: Requests from the page

    /// fetchJSON/authedFetch: the plugin's own routes only, sent with the account's auth.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], body["kind"] as? String == "fetch", let raw = body["path"] as? String else {
            replyHandler(["status": 400, "body": "{\"detail\":\"Bad request\"}"], nil)
            return
        }
        let method = (body["method"] as? String ?? "GET").uppercased()
        guard PluginPageBridge.methods.contains(method),
              let path = PluginPageBridge.allowedPath(raw, plugin: page.name, profile: profile) else {
            AppLog.note("plugin-pages", "\(page.name) asked for a route outside its own: refused")
            replyHandler(["status": 403, "body": "{\"detail\":\"Hermes HQ lets a plugin page call only its own plugin’s routes.\"}"], nil)
            return
        }
        let text = body["body"] as? String
        let client = self.client, name = page.name
        let started = ContinuousClock.now
        Task { [weak self] in
            do {
                let data = try await client.pageRest(method, path, query: [], body: text.map { Data($0.utf8) }, timeout: 60)
                AppLog.trace("plugin-pages", "\(name) \(method) \(AppLog.tag(path)) 200 \(data.count) B in \(AppLog.ms(since: started)) ms")
                replyHandler(["status": 200, "body": String(decoding: data, as: UTF8.self)], nil)
            } catch let error as HTTPError {
                AppLog.note("plugin-pages", "\(name) \(method) \(AppLog.tag(path)) HTTP \(error.status) in \(AppLog.ms(since: started)) ms")
                if PluginPageBridge.routeMissing(status: error.status, body: error.body) { self?.state.phase = .needsRestart }
                replyHandler(["status": error.status, "body": error.body ?? ""], nil)
            } catch {
                let words = (error as? LocalizedError)?.errorDescription ?? "Hermes HQ couldn’t reach Hermes."
                AppLog.note("plugin-pages", "\(name) \(method) \(AppLog.tag(path)) failed: \(type(of: error))")
                replyHandler(["status": 0, "error": words], nil)
            }
        }
    }

    /// The host's notes: ready, never registered, a script error, a crash.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["kind"] as? String == "state", let what = body["state"] as? String else { return }
        let detail = (body["message"] as? String).map { String($0.prefix(300)) }
        switch what {
        case "ready":
            guard state.phase == .loading else { return }
            watchdog?.cancel()
            AppLog.trace("plugin-pages", "\(page.name) ready in \(AppLog.ms(since: opened)) ms")
            // A breath for the page's first data and its styles, so the spinner gives way to a drawn page.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.state.phase == .loading else { return }
                // The page drew before the bars' insets reached it (the Mac): start at its top, not under the bar.
                if let scroll = self.web?.scrollView { scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false) }
                HQMotion.withAnimation(.easeOut(duration: 0.2)) { self.state.phase = .ready }
                #if DEBUG
                // Shots: `-HQDebugPluginPageClick <button words>` presses that button once the page is drawn (a dialog open).
                if let words = UserDefaults.standard.string(forKey: "HQDebugPluginPageClick"), !words.isEmpty {
                    try? await Task.sleep(for: .milliseconds(1200))
                    let quoted = String(decoding: (try? JSONSerialization.data(withJSONObject: [words])) ?? Data("[\"\"]".utf8), as: UTF8.self)
                    _ = try? await self.web?.evaluateJavaScript("[...document.querySelectorAll('button')].find(b => b.textContent.trim() === \(quoted)[0])?.click()",
                                                                 in: nil, contentWorld: .page)
                }
                #endif
            }
        case "unregistered":
            guard state.phase == .loading else { return }
            AppLog.note("plugin-pages", "\(page.name) bundle ran but never registered")
            state.phase = .failed(title: "\(page.label) Didn’t Start",
                                  words: "Its page loaded but never showed itself. It may need a newer version of Hermes HQ, or of the plugin.")
        case "script-error":
            guard state.phase == .loading else { return }
            AppLog.note("plugin-pages", "\(page.name) script error: \(detail ?? "")")
            state.phase = .failed(title: "\(page.label) Didn’t Start", words: "Its page hit an error while loading" + (detail.map { ": \($0)" } ?? "."))
        case "crashed":
            AppLog.note("plugin-pages", "\(page.name) crashed: \(detail ?? "")")
            state.phase = .failed(title: "\(page.label) Stopped", words: "Its page hit an error" + (detail.map { ": \($0)" } ?? "."))
        default:
            break
        }
    }

    // MARK: Links

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == Self.scheme { decisionHandler(.allow); return }
        if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""), action.navigationType == .linkActivated || action.targetFrame == nil {
            UIApplication.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        AppLog.note("plugin-pages", "\(page.name) web content process ended; reloading")
        load()
    }

    // MARK: Restart

    private var canAskRestart: Bool {
        guard let services else { return false }
        return !CloudGatewayFlow.isCloud(services.account?.baseURL) && (try? MainBotRequest.mainBot(services.bots)) != nil
    }

    private func askToRestart() {
        guard let services, !state.asking else { return }
        do { try services.canAskMainBot() } catch {
            state.askNote = (error as? LocalizedError)?.errorDescription ?? MainBotRequest.couldNotSend
            return
        }
        state.asking = true
        state.askNote = nil
        let text = PluginPageRestart.prompt(label: page.label, plugin: page.name, bot: botName)
        Task { [weak self, weak services] in
            defer { self?.state.asking = false }
            do {
                try await MainBotRequest.queue(text: text, title: PluginPageRestart.title(page: self?.page.label ?? "the page"),
                                               linkReady: { services?.connection == .ready })
            } catch {
                self?.state.askNote = (error as? LocalizedError)?.errorDescription ?? MainBotRequest.couldNotSend
            }
        }
    }
}

/// What the main bot is asked when a page's routes need the web server restarted.
enum PluginPageRestart {
    static func title(page: String) -> String { "Restart Hermes so \(page) opens in \(AppIdentity.current.displayName)." }

    static func prompt(label: String, plugin: String, bot: String) -> String {
        let app = AppIdentity.current.displayName
        return """
        Please restart Hermes so the \(plugin) plugin's page (\(label)) works in \(app). It's installed and on for \(bot), but the server hasn't loaded its routes yet: /api/plugins/\(plugin)/ answers 404. Do it yourself with your terminal tools; ask me only for what you can't do.

        Hermes loads a plugin's web routes only when its web server starts, so restart the server \(app) connects to (hermes dashboard or hermes serve). Find how it runs first (whether a launchd, systemd or other service manages it), then restart it the same way, keeping its arguments and profile. Restarting ends this chat's connection for a moment, so tell me before you do it, and schedule the restart in the background to start about 15 seconds after your reply, so it survives this chat (for example nohup sh -c 'sleep 15; <restart command>' >/dev/null 2>&1 &). It must run exactly once: never schedule it with launchctl submit, a LaunchAgent, cron, a systemd timer or anything else that starts it again, because a restart that repeats keeps Hermes down and locks me out. Don't restart anything else.

        When you're done, tell me in a sentence what you did.
        """
    }
}

/// The message handlers keep their target weakly (the content controller holds its handlers).
private final class PluginPageWeakHandler: NSObject, WKScriptMessageHandlerWithReply, WKScriptMessageHandler {
    weak var target: PluginWebPageController?
    init(_ target: PluginWebPageController) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let target else { replyHandler(nil, "The page has closed."); return }
        target.userContentController(controller, didReceive: message, replyHandler: replyHandler)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

// MARK: - hqplugin://page/…

/// Serves the page: the shell, the host's files, and the plugin's own files and GET routes through the gateway client.
final class PluginPageSchemeHandler: NSObject, WKURLSchemeHandler {
    private weak var owner: PluginWebPageController?
    private var live: Set<ObjectIdentifier> = []

    init(owner: PluginWebPageController) { self.owner = owner }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        live.insert(id)
        guard let owner, let url = task.request.url else { fail(task, 404); return }
        let path = url.path(percentEncoded: true)
        let query = url.query(percentEncoded: true).map { "?" + $0 } ?? ""
        let page = owner.page
        switch path {
        case "/__hq/plugin-host.js": serve(task, PluginWebPageController.resource("plugin-host", "js"), type: "application/javascript")
        case "/__hq/tailwind.js": serve(task, PluginWebPageController.resource("tailwind", "js"), type: "application/javascript")
        case owner.pageURLPath, "/", "/\(page.name)": serve(task, owner.shellHTML(), type: "text/html")
        case PluginDashboardPage.assetPath(name: page.name, file: page.entry, profile: owner.profile): serve(task, owner.bundle, type: "application/javascript")
        default:
            if let file = page.css, path == PluginDashboardPage.assetPath(name: page.name, file: file, profile: owner.profile), let css = owner.stylesheet {
                serve(task, css, type: "text/css")
                return
            }
            let assets = PluginDashboardPage.assetPath(name: page.name, file: "", profile: owner.profile)
            let remote: String?
            if path.hasPrefix(assets), !path.contains("/../") { remote = path + query }
            else if task.request.httpMethod ?? "GET" == "GET" { remote = PluginPageBridge.allowedPath(path + query, plugin: page.name, profile: owner.profile) }
            else { remote = nil }
            guard let remote else { fail(task, 404); return }
            let client = owner.clientForAssets
            Task { [weak self] in
                do {
                    let data = try await client.pageRest("GET", remote, query: [], body: nil, timeout: 30)
                    self?.serve(task, data, type: Self.type(of: path))
                } catch let error as HTTPError {
                    self?.fail(task, error.status)
                } catch {
                    self?.fail(task, 502)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        live.remove(ObjectIdentifier(task))
    }

    private func serve(_ task: any WKURLSchemeTask, _ data: Data?, type: String) {
        guard live.contains(ObjectIdentifier(task)), let url = task.request.url else { return }
        guard let data else { fail(task, 404); return }
        live.remove(ObjectIdentifier(task))
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Content-Length": "\(data.count)", "Cache-Control": "no-store"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: any WKURLSchemeTask, _ status: Int) {
        guard live.contains(ObjectIdentifier(task)), let url = task.request.url else { return }
        live.remove(ObjectIdentifier(task))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
        task.didReceive(response)
        task.didReceive(Data())
        task.didFinish()
    }

    static func type(of path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "js", "mjs": "application/javascript"
        case "css": "text/css"
        case "json", "map": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "ttf": "font/ttf"
        case "html": "text/html"
        default: "application/octet-stream"
        }
    }
}

extension PluginWebPageController {
    var clientForAssets: any GatewayClient { client }
}

// MARK: - The native message over the page

struct PluginWebPageStatus: View {
    @Bindable var state: PluginWebPageState
    let page: PluginDashboardPage
    let botName: String
    let retry: () -> Void
    let restart: () -> Void
    let canAsk: Bool

    var body: some View {
        Group {
            switch state.phase {
            case .ready:
                Color.clear.allowsHitTesting(false)
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Opening \(page.label)…").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.hqGroupedPage)
                .accessibilityIdentifier("plugin-web-page.loading")
            case .failed(let title, let words):
                message(symbol: "exclamationmark.triangle", title: title, words: words) {
                    Button("Try Again", action: retry).hqEmptyActionButtonStyle(glass: true)
                        .accessibilityIdentifier("plugin-web-page.retry")
                }
                .accessibilityIdentifier("plugin-web-page.failed")
            case .needsRestart:
                message(symbol: "arrow.clockwise.circle", title: "Restart Hermes to Finish",
                        words: "\(page.label) is installed, but Hermes loads a plugin’s web routes only when its web server starts. Restart Hermes once and this page will work.") {
                    VStack(spacing: 10) {
                        if canAsk {
                            Button(state.asking ? "Asking…" : "Ask Hermes to Restart", action: restart)
                                .hqEmptyActionButtonStyle(glass: true)
                                .disabled(state.asking)
                                .accessibilityIdentifier("plugin-web-page.ask-restart")
                        }
                        Button("Try Again", action: retry).hqBorderedButtonStyle()
                            .accessibilityIdentifier("plugin-web-page.retry")
                        if let note = state.askNote {
                            Text(note).font(Font.hq(.footnote)).foregroundStyle(.red).multilineTextAlignment(.center)
                        }
                    }
                }
                .accessibilityIdentifier("plugin-web-page.restart")
            }
        }
        .animation(HQMotion.swiftUI(.easeOut(duration: 0.2)), value: state.phase)
    }

    private func message<Actions: View>(symbol: String, title: String, words: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 0) {
            Image(systemName: symbol).font(.system(size: HQFont.scaled(GlassSheetKit.emptySymbolSize))).foregroundStyle(Color.hqLabel2)
                .padding(.bottom, GlassSheetKit.emptySymbolGap)
            Text(title).font(Font.hq(.title3).weight(.semibold)).foregroundStyle(Color.hqLabel).multilineTextAlignment(.center)
                .padding(.bottom, GlassSheetKit.emptyLineGap)
            Text(words).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, GlassSheetKit.emptyButtonGap)
            actions()
        }
        .padding(.horizontal, GlassSheetKit.emptySide)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.hqGroupedPage)
    }
}

extension GatewayClient {
    /// A REST call with its own time limit where the client takes one (the live client); the plain call otherwise.
    nonisolated func pageRest(_ method: String, _ path: String, query: [URLQueryItem], body: Data?, timeout: TimeInterval) async throws -> Data {
        if let live = self as? LiveGatewayClient { return try await live.rest(method, path, query: query, body: body, timeout: timeout) }
        return try await rest(method, path, query: query, body: body)
    }
}
