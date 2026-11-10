// [glass-census] DEBUG audit: `-HQDebugGlassCensus YES` walks every window every 2 s and appends each glass / blur /
// edge-effect surface it has not logged before to <tmp>/glass-census.jsonl (one JSON object per line).
#if DEBUG
import ObjectiveC
import UIKit

@MainActor enum GlassCensus {
    private static var seen = Set<String>()
    private static var timer: Timer?
    static var url: URL { FileManager.default.temporaryDirectory.appendingPathComponent("glass-census.jsonl") }

    static func start() {
        guard UserDefaults.standard.bool(forKey: "HQDebugGlassCensus"), timer == nil else { return }
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { sweep() } }
    }

    /// What ThemeChrome's didMoveToWindow hook saw (glass only): the chain at that moment and isOurs then.
    static func noteMove(_ fx: UIVisualEffectView) {
        guard UserDefaults.standard.bool(forKey: "HQDebugGlassCensus"), fx.effect is UIGlassEffect || fx.effect is UIGlassContainerEffect else { return }
        let o: [String: Any] = ["kind": "move", "class": NSStringFromClass(type(of: fx)), "chain": chain(fx), "isOursAtMove": ThemeChrome.isOurs(fx),
                                "id": fx.accessibilityIdentifier ?? "", "owner": owner(fx), "visible": true, "frame": [0, 0, 0, 0], "top": "-"]
        guard let d = try? JSONSerialization.data(withJSONObject: o), let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile(); h.write(d); h.write("\n".data(using: .utf8)!); try? h.close()
    }

    private static func chain(_ view: UIView) -> [String] {
        var out: [String] = []
        var p = view.superview
        while let c = p, out.count < 14 { out.append(NSStringFromClass(type(of: c))); p = c.superview }
        return out
    }
    private static func visible(_ view: UIView) -> Bool {
        var v: UIView? = view
        while let c = v { if c.isHidden || c.alpha < 0.02 { return false }; v = c.superview }
        guard let w = view.window else { return false }
        let r = view.convert(view.bounds, to: w)
        return r.intersects(w.bounds) && r.width > 0.5 && r.height > 0.5
    }
    private static func topController(_ w: UIWindow) -> String {
        var c = w.rootViewController
        while true {
            if let p = c?.presentedViewController { c = p; continue }
            if let n = c as? UINavigationController, let t = n.topViewController { c = t; continue }
            if let t = c as? UITabBarController, let s = t.selectedViewController { c = s; continue }
            break
        }
        return c.map { NSStringFromClass(type(of: $0)) } ?? "-"
    }
    private static func owner(_ view: UIView) -> String {
        var r: UIResponder? = view
        while let n = r { if let vc = n as? UIViewController { return NSStringFromClass(type(of: vc)) }; r = n.next }
        return "-"
    }

    private static func styleName(_ s: UIScrollEdgeEffect.Style) -> String {
        s == .soft ? "soft" : s == .hard ? "hard" : s == .automatic ? "automatic" : String(describing: s)
    }

    private static func sweep() {
        var lines: [String] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for w in ws.windows where !w.isHidden {
                let top = topController(w)
                walk(w, window: w, top: top, into: &lines)
            }
        }
        guard !lines.isEmpty, let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile()
        h.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
        try? h.close()
    }

    private static func record(_ kind: String, _ view: UIView, window: UIWindow, top: String, extra: [String: Any], into lines: inout [String]) {
        let f = view.convert(view.bounds, to: window)
        let cls = NSStringFromClass(type(of: view))
        let ch = chain(view)
        let vis = visible(view)
        let key = "\(kind)|\(cls)|\(ch.prefix(6).joined(separator: ","))|\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))|\(vis)|\(extra["effect"] ?? "")|\(top)"
        guard kind == "edge" || seen.insert(key).inserted else { return }   // edges: every sweep, to see them go
        var o: [String: Any] = ["kind": kind, "class": cls, "chain": ch, "frame": [Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)],
                                "id": view.accessibilityIdentifier ?? "", "visible": vis, "top": top, "owner": owner(view),
                                "window": NSStringFromClass(type(of: window)), "desktop": Theme.isDesktop,
                                "t": Int(Date().timeIntervalSince1970)]
        for (k, v) in extra { o[k] = v }
        if let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) { lines.append(s) }
    }

    private static func walk(_ view: UIView, window: UIWindow, top: String, into lines: inout [String]) {
        if let fx = view as? UIVisualEffectView {
            var kind: String?
            if fx.effect is UIGlassEffect { kind = "glass" }
            else if fx.effect is UIGlassContainerEffect { kind = "glassContainer" }
            else if fx.effect is UIBlurEffect { kind = "blur" }
            else if fx.effect is UIVibrancyEffect { kind = nil }
            else if let e = fx.effect { kind = "effect:" + NSStringFromClass(type(of: e)) }
            if let kind {
                record("vev", fx, window: window, top: top,
                       extra: ["effect": kind, "isOurs": ThemeChrome.isOurs(fx),
                               "bundleMain": Bundle(for: type(of: fx)) == .main, "stashed": objc_getAssociatedObject(fx, ThemeChrome.stashKey) != nil, "hook": ThemeChrome.hookInstalled,
                               "corners": String(describing: fx.cornerConfiguration).prefix(80).description], into: &lines)
            }
        }
        if let b = view as? UIButton, let c = b.configuration {
            let d = String(describing: c)
            if d.localizedCaseInsensitiveContains("glass") {
                record("glassButton", b, window: window, top: top, extra: ["effect": "buttonConfig", "title": c.title ?? (c.image != nil ? "<image>" : "")], into: &lines)
            }
        }
        if let s = view as? UIScrollView {
            let topOn = !s.topEdgeEffect.isHidden, botOn = !s.bottomEdgeEffect.isHidden
            if topOn || botOn {
                record("edge", s, window: window, top: top,
                       extra: ["effect": "edge", "topOn": topOn, "bottomOn": botOn, "edgeOurs": DesktopEdges.isOurs(s), "win": NSStringFromClass(type(of: window)),
                               "topStyle": styleName(s.topEdgeEffect.style), "bottomStyle": styleName(s.bottomEdgeEffect.style)], into: &lines)
            }
        }
        let cls = NSStringFromClass(type(of: view))
        if !(view is UIVisualEffectView), cls.localizedCaseInsensitiveContains("glass") || cls.localizedCaseInsensitiveContains("backdrop") || cls.localizedCaseInsensitiveContains("blur") {
            record("namedView", view, window: window, top: top, extra: ["effect": "name"], into: &lines)
        }
        // Layer-level glass (SwiftUI .glassEffect, private UIKit glass): backdrop layers anywhere under this view's own layer.
        if let subs = view.layer.sublayers {
            for l in subs where !(l.delegate is UIView) {
                let ln = NSStringFromClass(type(of: l))
                if ln.contains("Backdrop") || ln.localizedCaseInsensitiveContains("glass") {
                    record("layer:" + ln, view, window: window, top: top, extra: ["effect": "layer"], into: &lines)
                }
            }
        }
        let ln = NSStringFromClass(type(of: view.layer))
        if ln.contains("Backdrop") || ln.localizedCaseInsensitiveContains("glass") {
            record("viewLayer:" + ln, view, window: window, top: top, extra: ["effect": "layer"], into: &lines)
        }
        for child in view.subviews { walk(child, window: window, top: top, into: &lines) }
    }
}
#endif
