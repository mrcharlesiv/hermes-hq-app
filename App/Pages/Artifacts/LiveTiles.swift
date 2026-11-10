import SwiftUI
import UIKit
import WebKit

// [live-tiles] Tester 2026-11-05 on Tiles: "Next step is making it more interactive like home screen widgets. Refreshing
// data automatically, invoking JavaScript actions directly from the widget", as the desktop's `::preview` widgets do
// (`V:components/assistant-ui/inline-preview-directive.tsx`: a live frame, `window.hermes.send(prompt)` and
// `data-hermes-send="prompt"` buttons that message the bot with no bubble).
//
// A tile was a picture of its page (PageSnapshots), so nothing on it could be pressed and it changed only when redrawn.
// Now a page that has something to press or asks to be read again runs live in its Grid tile (`TileNames.Head.live`):
//   • its scripts run (a clock ticks, a chart animates, tabs switch);
//   • its buttons (`data-hermes-send`, `hermes.send`) go to the tile's bot as a hidden turn (`TileMaker.act`), the Tiles
//     page shows "Updating <tile>…" and the tile reads its file again when the bot is done;
//   • `<meta name="hq-tile-refresh" content="300">` reads its file again that often while the Tiles page shows (30 s at
//     the least), and `hermes.refresh()` does it at once;
//   • a tap on nothing pressable opens the tile, as before; holding still gives its menu.
// Every other tile stays a picture (most tiles are read-only charts, and a web view each would cost memory and scrolling).
// At most `limit` run at once, the oldest shown giving way. Edit Tiles shows pictures: the wiggle, drag and resize stay.

@MainActor
final class LiveTiles: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// Live web views at once (each is a web content process' worth of memory).
    static let limit = 8

    private struct Live {
        let web: WKWebView
        var file: URL
        /// The theme the page was drawn with (a change of look draws it again).
        var dark: Bool
        var readAt = Date()
        var lastIntent = Date.distantPast
        var shownAt = Date()
        /// The page's buttons by their words, as last drawn (VoiceOver presses them from the tile's actions).
        var buttons: [String] = []
    }

    private var tiles: [String: Live] = [:]
    private var reading: Set<String> = []
    private var watch: Task<Void, Never>?
    private weak var host: UIViewController?

    /// Opens the tile (a tap on nothing pressable).
    var open: ((String) -> Void)?
    /// A button's prompt for the tile's bot (pin id, prompt): false when it can't be sent.
    var send: ((String, String) -> Bool)?
    /// The pin, by id (its path, bot and refresh are read from it each time).
    var pin: ((String) -> ArtifactPin?)?
    /// Where the pin's page lives (account, bot, chat).
    var context: ((ArtifactPin) -> MediaContext)?
    /// The cell is drawn again (the live view is ready, or gone).
    var onChange: ((String) -> Void)?
    /// The pins whose tiles are on screen now. Only a tile off screen gives way to a new one: with more live tiles on
    /// screen than `limit`, giving way to each other redrew one another's cells, which asked for their views again (a
    /// reload loop, every tile blinking). The rest stay pictures.
    var onScreen: (() -> Set<String>)?

    init(host: UIViewController) {
        self.host = host
        super.init()
    }

    // MARK: Which tiles run live

    /// Whether the pin's tile runs live: a page whose head says so (read when its picture was drawn).
    func isLive(_ pin: ArtifactPin) -> Bool {
        guard pin.isPage, let path = pin.gatewayPath, let context = context?(pin) else { return false }
        return PageSnapshots.shared.head(path: path, context: context)?.live == true
    }

    /// Its live view is up (it takes the tile's taps then).
    func isRunning(_ id: String) -> Bool { tiles[id] != nil }

    /// The live web view for a tile (made and loaded the first time), or nil while its page is read.
    func view(for pin: ArtifactPin, dark: Bool) -> WKWebView? {
        guard isLive(pin) else { return nil }
        if var live = tiles[pin.id] {
            live.shownAt = Date()
            if live.dark != dark { live.dark = dark; handTheme(live.web, dark: dark); live.web.loadFileURL(live.file, allowingReadAccessTo: live.file.deletingLastPathComponent()) }
            tiles[pin.id] = live
            return live.web
        }
        guard hasRoom() else { return nil }
        read(pin, fresh: false)
        return nil
    }

    /// Room for one more live view: under the limit, or one off screen to give way.
    private func hasRoom() -> Bool { tiles.count < Self.limit || leastRecent() != nil }

    /// The live tile shown longest ago, among those off screen and not drawn in the last 2 s (a cell UIKit readied
    /// ahead counts as off screen: two of them must not take turns).
    private func leastRecent() -> String? {
        let shown = onScreen?() ?? []
        let now = Date()
        return tiles.filter { !shown.contains($0.key) && now.timeIntervalSince($0.value.shownAt) >= 2 }
            .min(by: { $0.value.shownAt < $1.value.shownAt })?.key
    }

    /// Reads the page's file (again) and loads it in its web view, making one when there is none.
    private func read(_ pin: ArtifactPin, fresh: Bool) {
        guard let path = pin.gatewayPath, let context = context?(pin), reading.insert(pin.id).inserted else { return }
        Task { [weak self] in
            let url = try? await MediaLoader.shared.file(path: path, name: pin.label, context: context,
                                                         progressKey: "live-tile|" + path, fresh: fresh)
            guard let self else { return }
            self.reading.remove(pin.id)
            guard let url else { AppLog.note("pages", "live tile not read"); return }
            if var live = self.tiles[pin.id] {
                live.file = url
                live.readAt = Date()
                self.tiles[pin.id] = live
                live.web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
                return
            }
            self.make(pin.id, file: url)
        }
    }

    private func make(_ id: String, file: URL) {
        // The oldest shown off screen gives way past the limit; with every live tile on screen this one stays a picture.
        while tiles.count >= Self.limit {
            guard let oldest = leastRecent() else { return }
            drop(oldest)
        }
        let dark = host?.traitCollection.userInterfaceStyle == .dark
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(LiveTileHandler(self), name: "hermes")
        config.userContentController.add(LiveTileHandler(self), name: "hermesTile")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false            // the Tiles page scrolls, not the tile
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsLinkPreview = false
        web.alpha = 0                                     // the picture shows until the page has drawn
        web.navigationDelegate = self
        web.accessibilityIdentifier = "live-tile"
        handTheme(web, dark: dark)
        tiles[id] = Live(web: web, file: file, dark: dark)
        web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        AppLog.trace("pages", "live tile started (\(tiles.count) live)")
        onChange?(id)
    }

    private func handTheme(_ web: WKWebView, dark: Bool) {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let content = web.configuration.userContentController
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(source: HTMLPageSheet.prelude(traits, talks: true), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: Self.tileScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    private func drop(_ id: String) {
        guard let live = tiles.removeValue(forKey: id) else { return }
        live.web.removeFromSuperview()
        live.web.configuration.userContentController.removeAllScriptMessageHandlers()
        onChange?(id)
    }

    /// The tile's file read again and drawn (its bot answered a button, its job ran, the person pulled to refresh).
    func reload(_ id: String) {
        guard tiles[id] != nil, let pin = pin?(id) else { return }
        read(pin, fresh: true)
    }

    // MARK: While the Tiles page shows

    /// The Tiles page shows: pages that ask for it are read again on their schedule. Hidden: every live view goes.
    func watch(_ on: Bool) {
        watch?.cancel()
        watch = nil
        guard on else {
            for id in Array(tiles.keys) { drop(id) }
            return
        }
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                self?.refreshDue()
            }
        }
    }

    private func refreshDue(now: Date = Date()) {
        for (id, live) in tiles {
            guard let pin = pin?(id), let path = pin.gatewayPath, let context = context?(pin),
                  let every = PageSnapshots.shared.head(path: path, context: context)?.refreshSeconds,
                  now.timeIntervalSince(live.readAt) >= TimeInterval(every) else { continue }
            read(pin, fresh: true)
        }
    }

    // MARK: The page talks

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let web = message.webView,
              let id = tiles.first(where: { $0.value.web === web })?.key else { return }
        let body = message.body as? [String: Any] ?? [:]
        if message.name == "hermesTile" {
            if body["open"] as? Bool == true { open?(id) }
            if body["refresh"] as? Bool == true { reload(id) }
            return
        }
        guard message.name == "hermes", let intent = body["id"] as? Int else { return }
        let prompt = (body["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ack: (Bool, String?) -> Void = { ok, error in
            let result = ok ? "{ok:true}" : "{ok:false,error:'\(error ?? "undelivered")'}"
            web.evaluateJavaScript("window.__hermesAck && window.__hermesAck(\(intent), \(result))")
        }
        guard !prompt.isEmpty else { ack(false, "empty"); return }
        // Rejected, never cut, as the opened page does (HTMLPageSheet): a sentence at human speed.
        guard prompt.count <= HTMLPageSheet.maxIntentLength else { ack(false, "too_long"); return }
        guard let live = tiles[id] else { ack(false, "undelivered"); return }
        // One a second: a second tap sooner waits out the second (one at most; any more are refused with a buzz).
        let wait = 1 - Date().timeIntervalSince(live.lastIntent)
        guard wait > 0 else { deliver(id, prompt, ack: ack); return }
        guard !waiting.contains(id) else { PagesHaptics.error(); ack(false, "throttled"); return }
        waiting.insert(id)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self else { return }
            self.waiting.remove(id)
            guard self.tiles[id]?.web === web else { ack(false, "undelivered"); return }
            self.deliver(id, prompt, ack: ack)
        }
    }

    /// Tiles with a button's prompt waiting out the one-a-second limit.
    private var waiting: Set<String> = []

    /// The prompt goes to the tile's bot (`send` says why when it can't, with an error buzz).
    private func deliver(_ id: String, _ prompt: String, ack: (Bool, String?) -> Void) {
        tiles[id]?.lastIntent = Date()
        guard send?(id, prompt) == true else { ack(false, "undelivered"); return }
        Haptics.play(.light)
        ack(true, nil)
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        let file = tiles.first(where: { $0.value.web === webView })?.value.file
        if url.isFileURL, url.path == file?.path { decisionHandler(.allow); return }
        if action.navigationType == .linkActivated, let host { LinkOpener.open(url, from: host) }
        decisionHandler(action.targetFrame?.isMainFrame == false && !url.isFileURL ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        readButtons(webView)
        guard webView.alpha < 1 else { return }
        UIView.animate(withDuration: HQMotion.reduced ? 0 : 0.2) { webView.alpha = 1 }
    }

    // MARK: VoiceOver

    /// The tile is one element for VoiceOver (its name, its menu's actions): the page's buttons are actions on it too.
    func buttons(_ id: String) -> [String] { tiles[id]?.buttons ?? [] }

    /// Presses the page's button with these words, as a tap on it would.
    func press(_ id: String, button words: String) {
        guard let web = tiles[id]?.web else { return }
        web.callAsyncJavaScript(Self.pressScript, arguments: ["words": words], in: nil, in: .page) { _ in }
    }

    private func readButtons(_ web: WKWebView) {
        web.evaluateJavaScript(Self.buttonsScript) { [weak self, weak web] value, _ in
            guard let self, let web, let id = self.tiles.first(where: { $0.value.web === web })?.key else { return }
            let words = value as? [String] ?? []
            guard self.tiles[id]?.buttons != words else { return }
            self.tiles[id]?.buttons = words
            self.onChange?(id)
        }
    }

    private static let buttonSelector = "[data-hermes-send],button,[role=button],input[type=button],input[type=submit]"
    private static let buttonWords = #"function w(e){return (e.getAttribute('aria-label')||e.innerText||e.value||e.title||'').trim().replace(/\s+/g,' ').slice(0,60)}"#
    /// The page's buttons' words (twelve at most, each once).
    static let buttonsScript = "(function(){" + buttonWords + "var l=document.querySelectorAll('" + buttonSelector + "'),o=[];"
        + "for(var i=0;i<l.length&&o.length<12;i++){var t=w(l[i]);if(t&&o.indexOf(t)<0)o.push(t)}return o})()"
    /// The first button with `words` clicked (a function body: `callAsyncJavaScript` hands it `words`).
    static let pressScript = buttonWords + "var l=document.querySelectorAll('" + buttonSelector + "');"
        + "for(var i=0;i<l.length;i++){if(w(l[i])===words){l[i].click();return true}}return false;"

    /// The web content process went away (memory): the tile shows its picture until it's read again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let id = tiles.first(where: { $0.value.web === webView })?.key else { return }
        AppLog.note("pages", "live tile's page process ended")
        drop(id)
    }

    // MARK: The tile's own script

    /// After the theme prelude: no text selection or callout (a hold is the tile's menu), a tap on nothing pressable
    /// opens the tile, and `hermes.refresh()`. Pressable: links, form controls, `data-hermes-send`, `[onclick]`,
    /// `[role=button]`, `[data-hq-tap]`, or anything the page styles with a pointer cursor.
    static let tileScript = """
    (function(){var s=document.createElement('style');\
    s.textContent=':where(html,body){-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;overflow:hidden}';\
    (document.head||document.documentElement).appendChild(s);\
    function post(m){try{window.webkit.messageHandlers.hermesTile.postMessage(m)}catch(e){}}\
    window.hermes=window.hermes||{};window.hermes.refresh=function(){post({refresh:true})};\
    function pressable(t){for(var e=t;e&&e.nodeType===1;e=e.parentElement){\
    if(e.matches('a[href],button,input,select,textarea,label,summary,details,[data-hermes-send],[onclick],[role=button],[data-hq-tap]'))return true;\
    if(getComputedStyle(e).cursor==='pointer')return true}return false}\
    document.addEventListener('click',function(e){if(e.defaultPrevented||pressable(e.target))return;post({open:true})},false);})();
    """
}

/// The tiles' message handler without the web views keeping LiveTiles alive.
private final class LiveTileHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// A live tile's web view in its Grid cell (the view moves to whichever cell shows the tile now).
struct LiveTileHost: UIViewRepresentable {
    let web: WKWebView

    func makeUIView(context: Context) -> LiveTileBox {
        let box = LiveTileBox()
        box.backgroundColor = .clear
        box.clipsToBounds = true
        return box
    }

    func updateUIView(_ box: LiveTileBox, context: Context) {
        box.setNeedsLayout()
        guard web.superview !== box else { return }
        web.removeFromSuperview()
        box.addSubview(web)
    }
}

/// [mac] The live tile's box: its page lays out in the box's size over the app's scale and is drawn grown by it, as
/// its picture is (`PageSnapshots.Shape.frame`'s zoom), so its words are the size of the app's own. At 1 (a phone at
/// 100 %) the page fills the box as before.
final class LiveTileBox: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        let zoom = max(1, HQFont.scale)
        for web in subviews {
            web.transform = .identity
            web.frame = CGRect(x: 0, y: 0, width: (bounds.width / zoom).rounded(), height: (bounds.height / zoom).rounded())
            web.transform = zoom == 1 ? .identity : CGAffineTransform(scaleX: zoom, y: zoom)
            web.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }
}
