import UIKit
import WebKit

// The picture a page card shows in a reply (`PageCardView`): the bot's HTML page drawn off screen with its scripts, then
// photographed. The desktop runs the page live in the reply; a picture keeps a chat scrolling smoothly, and a tap opens
// the live page (`HTMLPageSheet`). One page draws at a time. Pictures are kept in memory per page, chat look and
// generation: a chat's turn ending (`turnEnded`) starts a new generation for its pages, since a bot answers a page's
// button by rewriting the file.

@MainActor final class PageSnapshots: NSObject, WKNavigationDelegate {
    static let shared = PageSnapshots()

    /// Posted when a chat's turn ends; `object` is the chat's `MediaContext` (boxed). Open pages reload, pictures redraw.
    static let turnEnded = Notification.Name("hq.page.turnEnded")

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
    /// How long a page's scripts get after it loads before the picture is taken.
    private static let settle: Duration = .milliseconds(700)

    private let cache = NSCache<NSString, UIImage>()
    private var generations: [MediaContext: Int] = [:]
    private var waiting: [String: [(UIImage?) -> Void]] = [:]
    private var queue: [(key: String, path: String, name: String, context: MediaContext, fresh: Bool, dark: Bool, shape: Shape)] = []
    private var drawing = false
    /// [tiles] Each page's title and job, as its last read said (`TileNames.head`), by account, bot and path.
    private var heads: [String: TileNames.Head] = [:]
    private var loaded: CheckedContinuation<Bool, Never>?

    override private init() {
        super.init()
        cache.countLimit = 24
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

    func cached(path: String, context: MediaContext, dark: Bool, shape: Shape = .phone) -> UIImage? {
        cache.object(forKey: key(path: path, context: context, dark: dark, shape: shape) as NSString)
    }

    /// [tiles] What the page's head said when it was last read for a picture (nil before then).
    func head(path: String, context: MediaContext) -> TileNames.Head? { heads[Self.headKey(path, context)] }

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
        queue.append((k, path, name, context, true, dark, shape))
        drainQueue()
    }

    private func drainQueue() {
        guard !drawing, !queue.isEmpty else { return }
        drawing = true
        let job = queue.removeFirst()
        Task { [weak self] in
            var image: UIImage?
            do {
                let url = try await MediaLoader.shared.file(path: job.path, name: job.name, context: job.context,
                                                            progressKey: "page|" + job.path, fresh: job.fresh)
                self?.heads[Self.headKey(job.path, job.context)] = Self.readHead(url)
                image = await self?.draw(url, dark: job.dark, shape: job.shape)
            } catch {
                AppLog.swallowed("chatui", "page card download", error)
            }
            guard let self else { return }
            if let image { self.cache.setObject(image, forKey: job.key as NSString) }
            for callback in self.waiting.removeValue(forKey: job.key) ?? [] { callback(image) }
            self.drawing = false
            self.drainQueue()
        }
    }

    private func draw(_ url: URL, dark: Bool, shape: Shape) async -> UIImage? {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return nil }
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let web = HTMLPageSheet.makeWebView(traits: traits)
        web.navigationDelegate = self
        web.overrideUserInterfaceStyle = dark ? .dark : .light
        // Off screen but in a window: WebKit only paints a view that is in one.
        // A phone's screen tall: a page sized to the screen ("100vh", a widget centred in it) lays out as it opens.
        // [mac] Zoomed, the page lays out in the tile's size over its zoom and its picture is drawn at the tile's size
        // (`snapshotWidth`). Not `pageZoom`: on the Mac it magnifies without laying the page out again (a tile's
        // page came out wider than its tile), and CSS `zoom` grows "100vh" with the words.
        let zoom = shape.zoom
        web.frame = CGRect(origin: CGPoint(x: -10_000, y: 0),
                           size: CGSize(width: (shape.size.width / zoom).rounded(), height: (shape.size.height / zoom).rounded()))
        web.isUserInteractionEnabled = false
        // No safe-area inset: the window's top inset shifted the page under the snapshot's rectangle.
        web.scrollView.contentInsetAdjustmentBehavior = .never
        window.addSubview(web)
        defer { web.removeFromSuperview() }
        let ok = await withCheckedContinuation { continuation in
            loaded = continuation
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        guard ok else { return nil }
        try? await Task.sleep(for: Self.settle)
        // A tile's shape: a page that fits its window (no scrolling) is pictured whole, edge to edge.
        if shape != .phone {
            // The layout viewport (clientWidth/Height), not innerWidth: a page sized "device-width" lays out at the
            // phone's width (402 on a Pro) and WebKit shrinks it into the 390 pt window. The height is kept to
            // innerHeight too: a page with no <!doctype> (quirks mode) reports its whole height as clientHeight.
            let fits = (try? await web.evaluateJavaScript(
                "(function(){var d=document.documentElement;return d.scrollHeight<=Math.min(d.clientHeight,innerHeight)+1&&d.scrollWidth<=d.clientWidth+1})()")) as? Bool
            if fits == true {
                let config = WKSnapshotConfiguration()
                config.rect = web.bounds
                if zoom != 1 { config.snapshotWidth = NSNumber(value: Double(shape.size.width)) }
                config.afterScreenUpdates = true
                return try? await web.takeSnapshot(configuration: config)
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

    private func finishLoad(_ ok: Bool) {
        loaded?.resume(returning: ok)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoad(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoad(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishLoad(false) }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Only the page itself: nothing it does while being pictured leaves it.
        decisionHandler(action.request.url?.isFileURL == true || action.targetFrame?.isMainFrame == false ? .allow : .cancel)
    }
}

/// A `MediaContext` as a notification's object.
final class ContextBox: NSObject {
    let context: MediaContext
    init(_ context: MediaContext) { self.context = context }
}
