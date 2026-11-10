// [perf] DEBUG audit: `-HQDebugAnimationWatch YES` walks every window's layers every 3 s and appends each layer that is
// animating to <tmp>/animation-watch.jsonl (one JSON object per sweep): its view's class, accessibility identifier,
// view chain and animation keys. For a UI test that keeps logging "App animations complete notification not
// received": the layer that shows up in sweep after sweep is the one that never stops.
#if DEBUG
import UIKit

@MainActor enum AnimationWatch {
    private static var timer: Timer?
    private static var sweeps = 0
    static var url: URL { FileManager.default.temporaryDirectory.appendingPathComponent("animation-watch.jsonl") }

    static func start() {
        guard UserDefaults.standard.bool(forKey: "HQDebugAnimationWatch"), timer == nil else { return }
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in MainActor.assumeIsolated { sweep() } }
    }

    private static func sweep() {
        sweeps += 1
        var found: [[String: Any]] = []
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { visit(window.layer, window: NSStringFromClass(type(of: window)), into: &found) }
        }
        let line: [String: Any] = ["sweep": sweeps, "at": Date().timeIntervalSince1970, "animating": found]
        guard let data = try? JSONSerialization.data(withJSONObject: line), let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.write(Data("\n".utf8))
        try? handle.close()
    }

    private static func visit(_ layer: CALayer, window: String, into found: inout [[String: Any]]) {
        if let keys = layer.animationKeys(), !keys.isEmpty {
            let view = layer.delegate as? UIView
            var chain: [String] = []
            var up = view?.superview
            while let next = up, chain.count < 8 { chain.append(NSStringFromClass(type(of: next))); up = next.superview }
            let durations = keys.compactMap { layer.animation(forKey: $0) }.map { "\($0.duration)×\($0.repeatCount)" }
            found.append(["window": window, "layer": NSStringFromClass(type(of: layer)),
                          "view": view.map { NSStringFromClass(type(of: $0)) } ?? "-",
                          "id": view?.accessibilityIdentifier ?? "", "chain": chain, "keys": keys, "timing": durations])
        }
        for sub in layer.sublayers ?? [] { visit(sub, window: window, into: &found) }
    }
}
#endif
