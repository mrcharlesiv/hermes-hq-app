// DEBUG only. `-HQStarMapProbe YES`: once the Map has framed its graph, a scripted 5 s pan and zoom runs and the time
// between frames is recorded (docs/spec/3x-morepages.md §17 acceptance 3: no frame over 25 ms after the first
// second), as `ChatScrollProbe` does for the chat. The result is printed (`[StarMapProbe] …`), noted in the
// diagnostic log and readable by the UI tests as the value of the element `starmap.probe`.
// `-HQStarMapDebug YES`: an element `starmap.debug` whose value is JSON (zoom, star counts, where a few stars are on
// screen), so a UI test can tap a real star.

#if DEBUG
import SwiftUI
import UIKit

@MainActor @Observable
final class StarMapProbeResult {
    static let shared = StarMapProbeResult()
    var text: String?
}

@MainActor
final class StarMapProbe: NSObject {
    static var isRunning = false
    static var lastDrawn = 0
    private static var current: StarMapProbe?
    private static var ran = false

    static var wanted: Bool { UserDefaults.standard.bool(forKey: "HQStarMapProbe") }

    static func noteDrawn(stars: Int) { lastDrawn = stars }
    static func noteDraw(seconds: CFTimeInterval) { current?.draws.append(seconds) }

    /// Once per launch, a second after the Map framed its graph (the fly-in is over by then).
    static func startIfWanted(_ stage: StarMapStage) {
        guard wanted, !ran, !stage.layout.stars.isEmpty else { return }
        ran = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            let probe = StarMapProbe(stage: stage)
            current = probe
            probe.start()
        }
    }

    private let stage: StarMapStage
    private let whole: StarMapCamera
    private let near: StarMapCamera
    private var link: CADisplayLink?
    private var started: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var intervals: [CFTimeInterval] = []
    fileprivate var draws: [CFTimeInterval] = []
    private var drawsAtSecond = 0
    private var mostDrawn = 0
    static let seconds: CFTimeInterval = 5

    private init(stage: StarMapStage) {
        self.stage = stage
        whole = stage.whole()
        let cluster = stage.layout.clusters.first
        near = StarMapCamera(scale: min(StarMapCamera.maxZoom, max(2.2, whole.scale * 4)), center: cluster?.center ?? whole.center)
    }

    private func start() {
        Self.isRunning = true
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))   // motion-ok: a DEBUG measurement, never shown to a user
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// The script: 0–1.5 s a circle at the whole-map zoom, 1.5–3 s zooming in to the largest cluster (star names
    /// come on), 3–4 s a circle there, 4–5 s back out.
    private func camera(at time: CFTimeInterval) -> StarMapCamera {
        func smooth(_ x: CGFloat) -> CGFloat { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
        func between(_ a: StarMapCamera, _ b: StarMapCamera, _ x: CGFloat) -> StarMapCamera {
            let t = smooth(x)
            return StarMapCamera(scale: a.scale * pow(b.scale / a.scale, t),
                                 center: CGPoint(x: a.center.x + (b.center.x - a.center.x) * t, y: a.center.y + (b.center.y - a.center.y) * t))
        }
        func circle(_ base: StarMapCamera, _ x: CGFloat, radius: CGFloat) -> StarMapCamera {
            let grow = sin(.pi * min(1, max(0, x)))
            let angle = 2 * CGFloat.pi * x
            return StarMapCamera(scale: base.scale, center: CGPoint(x: base.center.x + cos(angle) * radius * grow / base.scale,
                                                                     y: base.center.y + sin(angle) * radius * grow / base.scale))
        }
        let t = CGFloat(time)
        if t < 1.5 { return circle(whole, t / 1.5, radius: 90) }
        if t < 3 { return between(whole, near, (t - 1.5) / 1.5) }
        if t < 4 { return circle(near, t - 3, radius: 140) }
        return between(near, whole, t - 4)
    }

    @objc private func tick(_ link: CADisplayLink) {
        if started == 0 { started = link.timestamp; last = link.timestamp; return }
        let elapsed = link.timestamp - started
        // "After the first second": the first second's frames are not counted.
        if elapsed > 1 {
            if intervals.isEmpty { drawsAtSecond = draws.count }
            intervals.append(link.timestamp - last)
        }
        last = link.timestamp
        mostDrawn = max(mostDrawn, Self.lastDrawn)
        guard elapsed < Self.seconds else { return finish() }
        stage.camera = camera(at: elapsed)
    }

    private func finish() {
        link?.invalidate()
        link = nil
        Self.isRunning = false
        Self.current = nil
        stage.camera = whole
        let counted = Array(draws.dropFirst(drawsAtSecond))
        func ms(_ value: CFTimeInterval) -> String { String(format: "%.1f", value * 1000) }
        func stats(_ values: [CFTimeInterval]) -> (mean: CFTimeInterval, p95: CFTimeInterval, max: CFTimeInterval) {
            guard !values.isEmpty else { return (0, 0, 0) }
            let sorted = values.sorted()
            return (values.reduce(0, +) / Double(values.count), sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], sorted.last ?? 0)
        }
        let frames = stats(intervals), drawing = stats(counted)
        let over = intervals.filter { $0 > 0.025 }.count
        let text = "nodes=\(stage.layout.stars.count) edges=\(stage.layout.edges.count) frames=\(intervals.count) "
            + "frame_ms mean=\(ms(frames.mean)) p95=\(ms(frames.p95)) max=\(ms(frames.max)) over25=\(over) "
            + "draw_ms mean=\(ms(drawing.mean)) p95=\(ms(drawing.p95)) max=\(ms(drawing.max)) draws=\(counted.count) most_stars_drawn=\(mostDrawn)"
        print("[StarMapProbe] \(text)")
        AppLog.note("starmap", "probe \(text)")
        StarMapProbeResult.shared.text = text
    }
}

/// The elements the UI tests read.
struct StarMapDebugElements: View {
    let stage: StarMapStage
    static let enabled = UserDefaults.standard.bool(forKey: "HQStarMapDebug")

    var body: some View {
        if Self.enabled {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Star Map Debug")
                .accessibilityValue(json)
                .accessibilityIdentifier("starmap.debug")
                .allowsHitTesting(false)
        }
        if let result = StarMapProbeResult.shared.text {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Star Map Probe")
                .accessibilityValue(result)
                .accessibilityIdentifier("starmap.probe")
                .allowsHitTesting(false)
                .offset(x: 2)
        }
    }

    /// {"scale","stars","clusters","edges","flown","points":[{"id","x","y"}]}: `points` are each cluster's most used
    /// star when it is on screen clear of the bars, in the canvas's own coordinates.
    private var json: String {
        let layout = stage.layout, camera = stage.camera, size = stage.size
        var points: [[String: Any]] = []
        for cluster in layout.clusters where cluster.count > 0 && points.count < 8 {
            let star = layout.stars[cluster.first]
            let point = camera.screen(star.point, in: size)
            guard point.x > 30, point.x < size.width - 30, point.y > 30, point.y < size.height - stage.bottomInset - 30 else { continue }
            points.append(["id": star.id, "x": Double(point.x.rounded()), "y": Double(point.y.rounded())])
        }
        let object: [String: Any] = ["scale": Double((camera.scale * 1000).rounded() / 1000), "stars": layout.stars.count,
                                     "clusters": layout.clusters.count, "edges": layout.edges.count,
                                     "flown": stage.appear >= 1, "points": points]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
