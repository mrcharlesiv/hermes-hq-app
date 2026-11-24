import CryptoKit
import UIKit
import WebKit

// The picture a page card shows in a reply (`PageCardView`): the bot's HTML page drawn off screen with its scripts, then
// photographed. The desktop runs the page live in the reply; a picture keeps a chat scrolling smoothly, and a tap opens
// the live page (`HTMLPageSheet`). One page draws at a time. Pictures are kept in memory per page, chat look and
// generation: a chat's turn ending (`turnEnded`) starts a new generation for its pages, since a bot answers a page's
// button by rewriting the file.
// [tiles-v2] Content-hash gating skips WebKit re-renders when the downloaded HTML bytes haven't changed, warm off-screen
// WKWebViews are reused per color scheme instead of spawning a fresh WebContent process per snapshot, and pages can
// signal early completion via `window.hermes.ready()` or `<html data-hq-ready>` instead of waiting the full 700 ms.

@MainActor final class PageSnapshots: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = PageSnapshots()

    /// Posted when a chat's turn ends; `object` is the chat's `MediaContext` (boxed). Open pages reload, pictures redraw.
    static let turnEnded = Notification.Name("hq.page.turnEnded")
    /// Posted when a page's title is read for the first time or has changed (`head`).
    static let headLearnt = Notification.Name("hq.page.headLearnt")

    /// The width a page is drawn at: a phone's column, so a page laid out for a phone pictures as it will open.
    static let drawWidth: CGFloat = 390
    /// The most of a page pictured (in page points): a little more than the card shows at its widest.
    static let pictureHeight: CGFloat = 300
    /// The height a page is drawn at (a phone's screen).
    static let drawHeight: CGFloat = 844
    /// The window a page is drawn in. A chat's card draws it a phone's screen tall; a pinned page's tile draws it the
    /// tile's shape, so a page made to fill its window (a widget in "100vw"/"100vh") lays out as the tile and pictures
    /// whole (owner 2026-11-02: a pinned dashboard.html drew phone-tall, its top third shrunk into a square tile).
    enum Shape: Hashable, Sendable {
        case phone
        /// A tile's or card's picture, this many times as wide as it is high (kept to a twentieth, so near shapes share
        /// a picture).
        case box(aspect: Double)
        /// A Grid tile's own size in points: the page lays out at the size it shows, as a Home Screen widget does, so
        /// "14px" reads as 14 pt in the tile (owner 2026-11-03: a Small tile drawn 390 wide showed its words at 45%).
        /// Kept to 5 pt, so near sizes share a picture. `zoom` (percent): the page drawn at the app's own scale (UI Scale ×
        /// the Mac's 115–130 %), so its "14px" grows as the app's text does (owner 2026-11-10, the Mac's Tiles: "our
        /// proportions are different", only Large tiles were easy to see).
        case frame(width: Int, height: Int, zoom: Int = 100)

        static func tile(width: CGFloat, height: CGFloat) -> Shape {
            guard width > 0, height > 0 else { return .box(aspect: 1) }
            return .box(aspect: max(0.4, min(3, (Double(width / height) * 20).rounded() / 20)))
        }

        static func frame(width: CGFloat, height: CGFloat, zoom: CGFloat = 1) -> Shape {
            func step(_ v: CGFloat) -> Int { Int((max(60, min(1600, v)) / 5).rounded()) * 5 }
            guard width > 0, height > 0 else { return .box(aspect: 1) }
            return .frame(width: step(width), height: step(height), zoom: Int((max(0.5, min(3, zoom)) * 20).rounded()) * 5)
        }

        /// The page's zoom in this shape (1 but in a zoomed Grid tile).
        var zoom: CGFloat {
            if case .frame(_, _, let zoom) = self { CGFloat(zoom) / 100 } else { 1 }
        }

        var size: CGSize {
            switch self {
            case .phone: CGSize(width: drawWidth, height: drawHeight)
            case .box(let aspect): CGSize(width: drawWidth, height: (drawWidth / aspect).rounded())
            case .frame(let width, let height, _): CGSize(width: width, height: height)
            }
        }

        var key: String {
            switch self {
            case .phone: "phone"
            case .box(let aspect): String(format: "box%.2f", aspect)
            case .frame(let width, let height, let zoom): "frame\(width)x\(height)" + (zoom == 100 ? "" : "z\(zoom)")
            }
        }
    }
    /// Ceiling for how long a page's scripts get after it loads before the picture is taken (unless `hermes.ready()` fires sooner).
    private static let settle: Duration = .milliseconds(700)
    /// Short paint grace after a page signals `hermes.ready()` / `data-hq-ready`.
    private static let readyMargin: Duration = .milliseconds(60)

    private let cache = NSCache<NSString, UIImage>()
    /// [tiles-v2] Rendered pictures keyed by `<sha256>|<d|l>|<shape.key>` so unchanged HTML bytes skip WebKit.
    private let contentCache = NSCache<NSString, UIImage>()
    /// [tiles-v2] Last SHA-256 hash observed for each page (`headKey`).
    private var fileHashes: [String: String] = [:]
    /// [tiles-v2] Reusable warm off-screen WKWebViews per color scheme (`true` = dark, `false` = light).
    private var warmWebs: [Bool: WKWebView] = [:]
    private var generations: [MediaContext: Int] = [:]
    private var waiting: [String: [(UIImage?) -> Void]] = [:]
    /// Pages read and waiting to be drawn (one draws at a time; reading is not in line: see `picture`).
    private var queue: [(key: String, contentKey: String?, url: URL, dark: Bool, shape: Shape)] = []
    private var drawing = false
    /// [tiles] Each page's title and job, as its last read said (`TileNames.head`), by account, bot and path.
    private var heads: [String: TileNames.Head] = [:]
    /// [tiles] Pages whose last read said the file is gone (`MediaLoadError.notFound`), by account, bot and path: a tile
    /// over one wears the failed mark instead of a grey chart that looked like one still drawing (Mac pass 2026-11-14).
    private var gone: Set<String> = []
    private var loaded: CheckedContinuation<Bool, Never>?
    private var readySignal: CheckedContinuation<Void, Never>?
    private var pageSignaledReady = false
    /// Pictures begun this run: a load's time limit only ends the draw it was set for.
    private var drawCount = 0
    /// How long a page gets to load before it is pictured as not drawable.
    private static let loadLimit: Duration = .seconds(15)

    override private init() {
        super.init()
        cache.countLimit = 32
        contentCache.countLimit = 48
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropWarmWebs() }
        }
    }

    private func dropWarmWebs() {
        guard !drawing else { return }
        for web in warmWebs.values {
            web.removeFromSuperview()
            web.configuration.userContentController.removeAllScriptMessageHandlers()
        }
        warmWebs.removeAll()
    }

    /// [tiles-v2] SHA-256 digest of a local file's bytes (pure, used for content-hash snapshot gating).
    nonisolated static func contentHash(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return contentHash(data)
    }

    nonisolated static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// [tiles-v2] Last SHA-256 content hash seen for `path` in `context`.
    func lastHash(path: String, context: MediaContext) -> String? {
        fileHashes[Self.headKey(path, context)]
    }

    /// A chat's turn ended: its pages may have changed.
    static func noteTurnEnded(_ context: MediaContext) {
        shared.generations[context, default: 0] += 1
        NotificationCenter.default.post(name: turnEnded, object: ContextBox(context))
    }

    func key(path: String, context: MediaContext, dark: Bool, shape: Shape = .phone) -> String {
        "\(context.accountId)|\(context.profile)|\(path)|\(generations[context] ?? 0)|\(dark ? "d" : "l")"
            + (shape == .phone ? "" : "|" + shape.key)
    }

    /// The chat's page generation this run (0 until a turn of it ends).
    func generation(_ context: MediaContext) -> Int { generations[context] ?? 0 }

    /// [tile-widgets] A new generation for `context` alone, told to nobody: the Home Screen widgets' own context
    /// (`TileWidgetWriter`) reads its pages again without redrawing the chats' cards or the Tiles page.
    func freshen(_ context: MediaContext) { generations[context, default: 0] += 1 }

    /// [tile-widgets] A page is drawing or waiting to: the widgets' pictures wait their turn behind the screen's.
    var isBusy: Bool { drawing || !queue.isEmpty }

    func cached(path: String, context: MediaContext, dark: Bool, shape: Shape = .phone) -> UIImage? {
        cache.object(forKey: key(path: path, context: context, dark: dark, shape: shape) as NSString)
    }

    /// [tiles] What the page's head said when it was last read for a picture (nil before then).
    func head(path: String, context: MediaContext) -> TileNames.Head? { heads[Self.headKey(path, context)] }

    /// [tiles] The page's last read said it isn't on the gateway any more.
    func isGone(path: String, context: MediaContext) -> Bool { gone.contains(Self.headKey(path, context)) }

    private static func headKey(_ path: String, _ context: MediaContext) -> String { "\(context.accountId)|\(context.profile)|\(path)" }

    private static func readHead(_ url: URL) -> TileNames.Head {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return TileNames.Head() }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64_000)) ?? Data()
        return TileNames.head(String(decoding: data, as: UTF8.self))
    }

    /// The page's picture (nil when it can't be read or drawn). Calls back on the main actor.
    func picture(path: String, name: String, context: MediaContext, dark: Bool, shape: Shape = .phone,
                 done: @escaping (UIImage?) -> Void) {
        let k = key(path: path, context: context, dark: dark, shape: shape)
        if let hit = cache.object(forKey: k as NSString) { done(hit); return }
        if waiting[k] != nil { waiting[k]?.append(done); return }
        waiting[k] = [done]
        // Read again each time it's drawn: the bot may have rewritten it (a kept copy if the read fails).
        // [tiles] Mac pass round 6: reading the page used to be in the one-at-a-time line with drawing it, so one tile
        // whose computer never answered (a 30 s timeout) held back every tile pinned after it, and a chat's page cards
        // with them: three plain tiles still spinning half a minute in. Pages are read side by side now (one read per
        // page: the loader joins a second ask), and only drawing waits its turn.
        Task { [weak self] in
            let hk = Self.headKey(path, context)
            let url = await Self.read(path: path, name: name, context: context, headKey: hk, into: self)
            guard let self else { return }
            guard let url else {
                for callback in self.waiting.removeValue(forKey: k) ?? [] { callback(nil) }
                return
            }
            // [tiles-v2] Content-hash gating: if the exact HTML bytes were already rendered at this look + shape,
            // return immediately without touching WebKit.
            let hash = Self.contentHash(of: url)
            if let hash { self.fileHashes[hk] = hash }
            let contentKey = hash.map { "\($0)|\(dark ? "d" : "l")|\(shape.key)" }
            if let contentKey, let hit = self.contentCache.object(forKey: contentKey as NSString) {
                self.cache.setObject(hit, forKey: k as NSString)
                for callback in self.waiting.removeValue(forKey: k) ?? [] { callback(hit) }
                return
            }
            self.queue.append((k, contentKey, url, dark, shape))
            self.drainQueue()
        }
    }

    /// The page's file from the bot's computer, or this Mac's last copy when the read fails for any reason but the
    /// file being gone (nil then, or when there is no copy).
    private static func read(path: String, name: String, context: MediaContext, headKey: String,
                             into snapshots: PageSnapshots?) async -> URL? {
        var url: URL?
        do {
            // [tiles] The loader's own fall-back to the kept copy hid a page deleted on the gateway (Mac pass
            // 2026-11-14: the tile kept drawing the old copy, with no mark): gone is said; any other failure
            // still draws the kept copy.
            url = try await MediaLoader.shared.file(path: path, name: name, context: context,
                                                    progressKey: "page|" + path, fresh: true, keptOnFailure: false)
            snapshots?.gone.remove(headKey)
        } catch {
            if error as? MediaLoadError == .notFound {
                snapshots?.gone.insert(headKey)
            } else if !(error is CancellationError) {
                let store = MediaLoader.shared.store(for: context.accountId)
                url = store.cachedFile(MediaStore.gatewayKey(accountId: context.accountId, profile: context.profile,
                                                             path: path), name: name)
            }
            AppLog.swallowed("chatui", "page card download\(url != nil ? ", the kept copy drawn" : "")", error)
        }
        if let url, let snapshots {
            let head = readHead(url)
            let learnt = snapshots.heads[headKey]?.title != head.title
            snapshots.heads[headKey] = head
            // [page-fold] A folded card of the page isn't pictured, so it hears of the title here.
            if learnt { NotificationCenter.default.post(name: headLearnt, object: nil) }
        }
        return url
    }

    private func drainQueue() {
        guard !drawing, !queue.isEmpty else { return }
        drawing = true
        let job = queue.removeFirst()
        Task { [weak self] in
            let image = await self?.draw(job.url, dark: job.dark, shape: job.shape)
            guard let self else { return }
            if let image {
                self.cache.setObject(image, forKey: job.key as NSString)
                if let contentKey = job.contentKey { self.contentCache.setObject(image, forKey: contentKey as NSString) }
            }
            for callback in self.waiting.removeValue(forKey: job.key) ?? [] { callback(image) }
            self.drawing = false
            self.drainQueue()
        }
    }

    /// [tiles-v2] Reusable off-screen WKWebView per color scheme, with `window.hermes.ready()` support.
    private func warmWebView(dark: Bool) -> WKWebView {
        if let existing = warmWebs[dark] { return existing }
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let web = HTMLPageSheet.makeWebView(traits: traits)
        web.configuration.userContentController.add(PageSnapshotReadyHandler(self), name: "hermesSnapReady")
        web.configuration.userContentController.addUserScript(WKUserScript(
            source: Self.readyScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web.navigationDelegate = self
        web.overrideUserInterfaceStyle = dark ? .dark : .light
        web.isUserInteractionEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        warmWebs[dark] = web
        return web
    }

    private static let readyScript = """
    (function(){window.hermes=window.hermes||{};\
    window.hermes.ready=function(){try{window.webkit.messageHandlers.hermesSnapReady.postMessage(true)}catch(e){}};})();
    """

    private func draw(_ url: URL, dark: Bool, shape: Shape) async -> UIImage? {
        // [tile-widgets] In the background a scene may have no key window: its first window still paints a web view.
        guard let window = UIApplication.shared.connectedScenes.compactMap({ scene -> UIWindow? in
            guard let scene = scene as? UIWindowScene else { return nil }
            return scene.keyWindow ?? scene.windows.first
        }).first else { return nil }
        let web = warmWebView(dark: dark)
        // Off screen but in a window: WebKit only paints a view that is in one.
        // A phone's screen tall: a page sized to the screen ("100vh", a widget centred in it) lays out as it opens.
        // [mac] Zoomed, the page lays out in the tile's size over its zoom and its picture is drawn at the tile's size
        // (`snapshotWidth`). Not `pageZoom`: on the Mac it magnifies without laying the page out again (a tile's
        // page came out wider than its tile), and CSS `zoom` grows "100vh" with the words.
        let zoom = shape.zoom
        web.frame = CGRect(origin: CGPoint(x: -10_000, y: 0),
                           size: CGSize(width: (shape.size.width / zoom).rounded(), height: (shape.size.height / zoom).rounded()))
        if web.superview !== window { window.addSubview(web) }
        defer {
            // Keep the warm web view attached only while drawing so an idle window has no off-screen web views.
            web.removeFromSuperview()
        }
        drawCount += 1
        let thisDraw = drawCount
        pageSignaledReady = false
        readySignal = nil
        let ok = await withCheckedContinuation { continuation in
            loaded = continuation
            web.loadPageFile(url)
            // [tiles] A page that never finishes loading (a picture or script from a server that never answers) is
            // given up on, so the line of pictures behind it keeps moving.
            Task { [weak self] in
                try? await Task.sleep(for: Self.loadLimit)
                guard let self, self.drawCount == thisDraw else { return }
                self.finishLoad(false)
            }
        }
        guard ok else { return nil }
        await waitForSettle(web: web, drawId: thisDraw)
        // A tile's shape: a page that fits its window (no scrolling) is pictured whole, edge to edge.
        if shape != .phone {
            // The layout viewport (clientWidth/Height), not innerWidth: a page sized "device-width" lays out at the
            // phone's width (402 on a Pro) and WebKit shrinks it into the 390 pt window. The height is kept to
            // innerHeight too: a page with no <!doctype> (quirks mode) reports its whole height as clientHeight.
            let fitsScript = "(function(){var d=document.documentElement;return d.scrollHeight<=Math.min(d.clientHeight,innerHeight)+1&&d.scrollWidth<=d.clientWidth+1})()"
            let fits = (try? await web.evaluateJavaScript(fitsScript)) as? Bool
            if fits == true {
                let config = WKSnapshotConfiguration()
                config.rect = web.bounds
                if zoom != 1 { config.snapshotWidth = NSNumber(value: Double(shape.size.width)) }
                config.afterScreenUpdates = true
                return try? await web.takeSnapshot(configuration: config)
            }
            // [mac] Mac pass 2026-11-14: in the Desktop Look (UI Scale over 1) a Small page tile's page didn't fit the
            // tile's size over its zoom, so it fell to the phone's width below and its words came out half size, where
            // the same tile in the iOS look (zoom 1) read at full size. A page that fits the tile's own size is pictured
            // at that size before falling back.
            if zoom != 1 {
                web.frame.size = shape.size
                try? await Task.sleep(for: .milliseconds(150))
                if (try? await web.evaluateJavaScript(fitsScript)) as? Bool == true {
                    let config = WKSnapshotConfiguration()
                    config.rect = web.bounds
                    config.afterScreenUpdates = true
                    return try? await web.takeSnapshot(configuration: config)
                }
            }
            // A page not made for its tile (it scrolls at the tile's own size) lays out as it did before: a phone's
            // width, in the tile's shape, with the part worth showing found below.
            if case .frame(let width, let height, _) = shape {
                web.frame.size = Shape.box(aspect: Double(width) / Double(height)).size
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        // The card shows the page's first chart (its first big drawing or table) whole, when it has one: the page's
        // title is already the card's name, and the top of a page is mostly its heading. Otherwise where the page's
        // content is: whole when it is about as tall as it is wide (a widget, a tile), else its top.
        // Owner 2026-11-02: a pinned dashboard.html (one square tile centred in "100vh", no chart) pictured the empty
        // page above the tile, a blank dark card.
        let probe = """
        (function(){var d=document.documentElement,h=Math.ceil(d.scrollHeight),w=d.clientWidth,y=window.scrollY;\
        var els=document.querySelectorAll('svg,canvas,img,table');for(var i=0;i<els.length;i++){var r=els[i].getBoundingClientRect();\
        if(r.width>=160&&r.height>=100)return [w,Math.max(0,r.left-8),Math.max(0,r.top+y-8),Math.min(w,r.width+16),r.height+16]}\
        var bg=[getComputedStyle(d).backgroundColor,getComputedStyle(document.body).backgroundColor];\
        var L=1e9,T=1e9,R=-1,B=-1,all=document.body.querySelectorAll('*');\
        for(var j=0;j<all.length;j++){var e=all[j],s=getComputedStyle(e);if(s.visibility==='hidden'||+s.opacity===0)continue;\
        var q=e.getBoundingClientRect();if(q.width<1||q.height<1)continue;\
        var text=false;for(var c=e.firstChild;c;c=c.nextSibling)if(c.nodeType===3&&c.nodeValue.trim()){text=true;break}\
        var fill=s.backgroundImage!=='none'||(!/rgba\\(.*, 0\\)$|transparent/.test(s.backgroundColor)&&bg.indexOf(s.backgroundColor)<0);\
        if(!text&&!fill&&!/^(IMG|SVG|CANVAS|VIDEO|INPUT|BUTTON|SELECT|TEXTAREA)$/i.test(e.tagName))continue;\
        if(fill&&!text&&q.width>=w-1&&q.height>=d.clientHeight-1)continue;\
        L=Math.min(L,q.left);T=Math.min(T,q.top+y);R=Math.max(R,q.right);B=Math.max(B,q.bottom+y)}\
        if(R<0)return [w,0,0,w,Math.min(h,260)];\
        L=Math.max(0,L-8);T=Math.max(0,T-8);R=Math.min(w,R+8);B=Math.min(h,B+8);\
        return [w,L,T,R-L,(B-T)<=(R-L)*1.25?B-T:Math.min(B-T,260)]})()
        """
        let found = (try? await web.evaluateJavaScript(probe)) as? [Double] ?? []
        guard found.count == 5, found[0] > 0 else { return nil }
        // Page pixels to the view's points: the Mac lays a page out at its own zoom, so they differ there.
        let k = web.bounds.width / found[0]
        var rect = CGRect(x: found[1] * k, y: found[2] * k, width: found[3] * k, height: min(found[4], Self.pictureHeight * 2) * k)
        rect.size.width = min(rect.width, web.bounds.width - rect.minX)
        if rect.maxY > web.frame.height {
            web.frame.size.height = rect.maxY + 20   // WebKit paints only what the view covers
            try? await Task.sleep(for: .milliseconds(150))
        }
        let config = WKSnapshotConfiguration()
        config.rect = rect
        config.afterScreenUpdates = true
        return try? await web.takeSnapshot(configuration: config)
    }

    /// [tiles-v2] Waits up to `settle` (700 ms), returning early if the page calls `window.hermes.ready()` or sets
    /// `data-hq-ready` on `<html>` / `<body>`.
    private func waitForSettle(web: WKWebView, drawId: Int) async {
        if pageSignaledReady {
            try? await Task.sleep(for: Self.readyMargin)
            return
        }
        let attrReady = (try? await web.evaluateJavaScript(
            "Boolean(document.documentElement?.hasAttribute('data-hq-ready') || document.body?.hasAttribute('data-hq-ready'))"
        )) as? Bool
        if attrReady == true || pageSignaledReady {
            try? await Task.sleep(for: Self.readyMargin)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            readySignal = continuation
            Task { [weak self] in
                try? await Task.sleep(for: Self.settle)
                guard let self, self.drawCount == drawId else { return }
                self.finishReady()
            }
        }
        if pageSignaledReady { try? await Task.sleep(for: Self.readyMargin) }
    }

    private func finishReady() {
        readySignal?.resume()
        readySignal = nil
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "hermesSnapReady" else { return }
        pageSignaledReady = true
        finishReady()
    }

    private func finishLoad(_ ok: Bool) {
        loaded?.resume(returning: ok)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoad(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoad(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishLoad(false) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        for (dark, kept) in warmWebs where kept === webView { warmWebs.removeValue(forKey: dark) }
        finishLoad(false)
        finishReady()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Only the page itself: nothing it does while being pictured leaves it.
        decisionHandler(action.request.url?.isFileURL == true || action.targetFrame?.isMainFrame == false ? .allow : .cancel)
    }
}

private final class PageSnapshotReadyHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// A `MediaContext` as a notification's object.
final class ContextBox: NSObject {
    let context: MediaContext
    init(_ context: MediaContext) { self.context = context }
}

// MARK: - [utf8-pages] Loading a page's file

extension WKWebView {
    /// Loads a page's local file, reading it as UTF-8 when it says nothing of its encoding. WebKit reads a local file
    /// that declares no charset as Latin-1, so a bot's "·" or "—" showed as "Â·" / "â€”" in tiles and opened pages.
    /// Every page file the app shows (tile pictures, live tiles, the opened page, an HTML preview) loads here.
    func loadPageFile(_ file: URL) {
        let folder = file.deletingLastPathComponent()
        if let data = PageEncoding.utf8Undeclared(file) {
            // The file's own address stays its base: its pictures and scripts beside it load, and the page's link guard
            // still sees the page itself.
            load(data, mimeType: "text/html", characterEncodingName: "UTF-8", baseURL: file)
            return
        }
        loadFileURL(file, allowingReadAccessTo: folder)
    }
}

enum PageEncoding {
    /// An HTML file's bytes when they are valid UTF-8, hold some non-ASCII and declare no encoding (no BOM, no
    /// "charset" in the first 1024 bytes, as the HTML prescan reads); nil when WebKit's own reading is right.
    nonisolated static func utf8Undeclared(_ file: URL) -> Data? {
        guard ["html", "htm", "xhtml"].contains(file.pathExtension.lowercased()),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return needsUTF8(data) ? data : nil
    }

    nonisolated static func needsUTF8(_ data: Data) -> Bool {
        guard data.contains(where: { $0 >= 0x80 }) else { return false }                  // ASCII reads the same either way
        if data.starts(with: [0xEF, 0xBB, 0xBF]) || data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE]) { return false }
        let head = String(decoding: data.prefix(1024), as: UTF8.self).lowercased()
        if head.contains("charset") || head.contains("encoding=") { return false }   // <meta charset>, http-equiv, <?xml encoding?>
        return String(data: data, encoding: .utf8) != nil
    }
}
