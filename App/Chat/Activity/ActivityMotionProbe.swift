import UIKit

#if DEBUG
/// The UI tests' per-frame motion sampler (`-HQDebugMotionProbe YES`; docs/spec/1x-activity.md §16 checks 18 and 22).
/// Screenshots can't show a jump or a bounce, so while the chat shows, every display frame reads each visible row's
/// on-screen rectangle from its presentation layer (what is really drawn, transforms and animated offsets included) and
/// keeps, since the last reset: how far any row moved from where it first stood (`still`), how much any row's height
/// changed (`height`), the biggest one-frame step (`step`), and for the watched rows (a fold's reply) their largest
/// move, step and direction reversals. It resets whenever the transcript is dragged or decelerating, and when a fold
/// starts. The numbers are the `accessibilityLabel` (JSON) of a 1 pt element "debug.motion" in the chat's view.
final class ActivityMotionProbe: NSObject {
    private unowned let controller: ChatActivityController
    private var link: CADisplayLink?
    private let output = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))

    private struct Track {
        var base: CGFloat
        var baseHeight: CGFloat
        var last: CGFloat
        var maxDy: CGFloat = 0
        var maxDh: CGFloat = 0
        var maxStep: CGFloat = 0
        var direction: CGFloat = 0
        var reversals = 0
        /// Frames in which it moved (a slide spreads over many; a jump is one).
        var moves = 0
    }

    private var tracks: [String: Track] = [:]
    private var watch: Set<String> = []
    private var mode = "still"
    /// A fold's sample ends when its slide does: what moves the rows later (a chip leaving) is not the fold's.
    private var settled = false
    private var frames = 0
    private var gapBase: CGFloat?
    private var gapRow: String?
    private var gapMax: CGFloat = 0
    private var lastText = ""
    /// `-HQDebugMotionTrace YES`: every row's move printed per frame (for working out a failed check).
    private let trace = UserDefaults.standard.bool(forKey: "HQDebugMotionTrace")

    init(controller: ChatActivityController) {
        self.controller = controller
        super.init()
        output.isAccessibilityElement = true
        output.accessibilityIdentifier = "debug.motion"
        output.isUserInteractionEnabled = false
        output.backgroundColor = .clear
    }

    func start() {
        guard link == nil else { return }
        let view = controller.chat.view!
        if output.superview == nil { view.addSubview(output) }
        reset(mode: "still")
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    func note(_ text: @autoclosure () -> String) {
        guard trace else { return }
        // Every line carries its time (verify round 3: notes from the chat screen line up with the frames).
        let line = String(format: "[Motion] %.3f ", CACurrentMediaTime()) + text()
        print(line)
        // Also into the app's tmp folder (a UI test's app has no console): motion-trace.log.
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "motion-trace.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data((line + "\n").utf8)); try? handle.close()
        } else {
            try? Data((line + "\n").utf8).write(to: url)
        }
    }

    /// The fold's slide finished (or nothing slid): its numbers stay as they are until the next reset.
    func foldEnded() {
        guard mode == "fold", !settled else { return }
        note("fold ends")
        settled = true
        publish()
    }

    /// A fold begins: measure from here, watching the reply's own rows (not its steps).
    func foldStarted(messageId: String) {
        if trace { print("[Motion] fold starts \(messageId)") }
        reset(mode: "fold")
        let chat = controller.chat
        for case let cell as ChatBaseCell in chat.tableView.visibleCells {
            guard let row = chat.activityRow(id: cell.rowId), row.messageId == messageId, !row.isStepBlock else { continue }
            watch.insert(cell.rowId)
        }
    }

    private func reset(mode: String) {
        self.mode = mode
        settled = false
        tracks = [:]
        watch = []
        frames = 0
        gapBase = nil
        gapMax = 0
    }

    private func rect(_ view: UIView) -> CGRect? {
        guard let window = view.window, let layer = view.layer.presentation() else { return nil }
        let target = window.layer.presentation() ?? window.layer
        return layer.convert(layer.bounds, to: target)
    }

    private var lastTick: CFTimeInterval = 0

    @objc private func tick() {
        let chat = controller.chat
        let table = chat.tableView
        guard chat.view.window != nil else { return }
        let now = CACurrentMediaTime()
        // A main-thread hitch shows in the trace as a gap between frames.
        if trace, lastTick > 0, now - lastTick > 0.05 { note(String(format: "stall %.0f ms", (now - lastTick) * 1000)) }
        lastTick = now
        if settled { return }
        if mode == "still" && (table.isTracking || table.isDragging || table.isDecelerating) {
            reset(mode: "still")
            publish()
            return
        }
        frames += 1
        var newest: (row: Int, id: String, maxY: CGFloat)?
        for ip in table.indexPathsForVisibleRows ?? [] {
            guard let cell = table.cellForRow(at: ip) as? ChatBaseCell, let r = rect(cell) else { continue }
            let y = (r.minY * 100).rounded() / 100, h = r.height
            if newest == nil || ip.row < newest!.row { newest = (ip.row, cell.rowId, r.maxY) }
            guard var t = tracks[cell.rowId] else {
                tracks[cell.rowId] = Track(base: y, baseHeight: h, last: y)
                continue
            }
            t.maxDy = max(t.maxDy, abs(y - t.base))
            t.maxDh = max(t.maxDh, abs(h - t.baseHeight))
            let step = y - t.last
            t.maxStep = max(t.maxStep, abs(step))
            if abs(step) > 0.3 {
                t.moves += 1
                let sign: CGFloat = step > 0 ? 1 : -1
                if t.direction != 0 && sign != t.direction { t.reversals += 1 }
                t.direction = sign
            }
            if trace && abs(step) > 0.3 {
                note(String(format: "%@ %@ y=%.2f step=%.2f h=%.2f", mode, cell.rowId, y, step, h))
            }
            t.last = y
            tracks[cell.rowId] = t
        }
        // The newest row's distance above the dock's top (the shelf's, else the queue card's or the composer's).
        // A new newest row (a reply arriving) starts a new baseline.
        if let newest {
            if newest.id != gapRow { gapRow = newest.id; gapBase = nil }
            let shelf = controller.shelf
            let shelfHeight = shelf.layer.presentation()?.bounds.height ?? shelf.bounds.height
            let dockTop = shelfHeight > 0.5 ? rect(shelf)?.minY : rect(chat.composer)?.minY
            if let dockTop {
                let gap = dockTop - newest.maxY
                if let base = gapBase { gapMax = max(gapMax, abs(gap - base)) } else { gapBase = gap }
            }
        }
        publish()
    }

    private func publish() {
        let all = tracks.values
        let watched = tracks.filter { watch.contains($0.key) }.values
        func fmt(_ v: CGFloat) -> String { String(format: "%.2f", v) }
        let text = "{\"mode\":\"\(mode)\",\"settled\":\(settled ? 1 : 0),\"frames\":\(frames),\"rows\":\(tracks.count),"
            + "\"still\":\(fmt(all.map(\.maxDy).max() ?? 0)),\"height\":\(fmt(all.map(\.maxDh).max() ?? 0)),"
            + "\"step\":\(fmt(all.map(\.maxStep).max() ?? 0)),\"gap\":\(fmt(gapMax)),"
            + "\"watched\":\(watched.count),\"watchDy\":\(fmt(watched.map(\.maxDy).max() ?? 0)),"
            + "\"watchStep\":\(fmt(watched.map(\.maxStep).max() ?? 0)),\"watchReversals\":\(watched.map(\.reversals).max() ?? 0),"
            + "\"watchMoves\":\(watched.map(\.moves).max() ?? 0)}"
        guard text != lastText else { return }
        lastText = text
        output.accessibilityLabel = text
    }
}

#endif
