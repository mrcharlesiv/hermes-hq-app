import UIKit
import os

/// Timing marks for the chat (signposts + console lines in DEBUG). `pushStart` is set by whoever pushes the chat.
enum ChatPerf {
    static let log = OSLog(subsystem: "com.charlesmcdowell.hermeshq.native", category: "chat")
    static var pushStart: CFTimeInterval?

    static func mark(_ name: String) {
        #if DEBUG
        let t = pushStart.map { String(format: " +%.1f ms", (CACurrentMediaTime() - $0) * 1000) } ?? ""
        print("[ChatPerf] \(name)\(t)\(name.contains(".done") ? String(format: " footprint %.0f MB", footprintMB()) : "")")
        #endif
        os_signpost(.event, log: log, name: "chat", "%{public}s", name)
    }

    /// The process's physical memory footprint (what jetsam counts).
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// The first layout pass with cells: report the next display refresh as the first frame with content.
    static func firstContentLaidOut() {
        let laidOut = CACurrentMediaTime()
        mark("chat.firstLayoutWithCells")
        let probe = FirstFrameProbe(laidOut: laidOut)
        probe.start()
    }

    private final class FirstFrameProbe: NSObject {
        let laidOut: CFTimeInterval
        var link: CADisplayLink?
        var keepAlive: FirstFrameProbe?
        init(laidOut: CFTimeInterval) { self.laidOut = laidOut }

        func start() {
            keepAlive = self
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc func tick(_ link: CADisplayLink) {
            link.invalidate()
            self.link = nil
            let now = CACurrentMediaTime()
            if let start = ChatPerf.pushStart {
                let total = (now - start) * 1000
                print(String(format: "[ChatPerf] FIRST FRAME WITH CONTENT: %.1f ms after push start (layout done at %.1f ms)",
                             total, (laidOut - start) * 1000))
            }
            keepAlive = nil
        }
    }
}

#if DEBUG
/// Debug auto-scroll: drives the table from the newest end to the oldest at a steady speed and back, and reports
/// dropped frames from CADisplayLink deltas (and the hitch time ratio, ms of hitch per s of scrolling).
final class ChatScrollProbe: NSObject {
    private weak var chat: ChatViewController?
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var direction: CGFloat = 1
    private let speed: CGFloat
    private var frames = 0
    private var dropped = 0
    private var hitchTime: CFTimeInterval = 0
    private var maxDelta: CFTimeInterval = 0
    private var started: CFTimeInterval = 0
    private var waitingSince: CFTimeInterval?
    private var passes = 0
    private var keepAlive: ChatScrollProbe?
    private var rowsSeen = 0

    private let legSeconds: CFTimeInterval
    private var legStart: CFTimeInterval = 0
    private var distance: CGFloat = 0

    /// Scrolls toward older rows for `legSeconds` (or to the oldest end), then back to the newest end.
    init(chat: ChatViewController, speed: CGFloat = 3000, legSeconds: CFTimeInterval = 12) {
        self.chat = chat
        self.speed = speed
        self.legSeconds = legSeconds
    }

    func start() {
        keepAlive = self
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        started = CACurrentMediaTime()
        legStart = started
        // Like a finger: leaving the newest end stops following.
        chat?.debugScroll(by: 0)
        print("[ChatProbe] start, maximumFramesPerSecond=\(chat?.view.window?.windowScene?.screen.maximumFramesPerSecond ?? 0)")
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let chat else { link.invalidate(); keepAlive = nil; return }
        let table = chat.tableView
        let expected = link.targetTimestamp - link.timestamp
        if last > 0 {
            let dt = link.timestamp - last
            frames += 1
            maxDelta = max(maxDelta, dt)
            if dt > expected * 1.5 {
                dropped += Int((dt / expected).rounded()) - 1
                hitchTime += dt - expected
            }
        }
        let dt = last > 0 ? min(link.timestamp - last, 0.1) : expected
        last = link.timestamp
        let minY = -table.contentInset.top
        let maxY = max(minY, table.contentSize.height + table.contentInset.bottom - table.bounds.height)
        var y = table.contentOffset.y + direction * speed * CGFloat(dt)
        distance += speed * CGFloat(dt)
        if direction > 0 && link.timestamp - legStart > legSeconds {
            rowsSeen = max(rowsSeen, chat.debugCounts.shown)
            direction = -1
            passes += 1
        } else if direction > 0 && y >= maxY {
            y = maxY
            let counts = chat.debugCounts
            if counts.canGrowOlder {
                // Wait for older rows (paging or background layout); give up after 5 s.
                if waitingSince == nil { waitingSince = link.timestamp }
                if link.timestamp - waitingSince! < 5 { table.contentOffset.y = y; return }
            }
            waitingSince = nil
            rowsSeen = max(rowsSeen, counts.shown)
            direction = -1
            passes += 1
        } else if direction < 0 && y <= minY {
            y = minY
            passes += 1
            finish()
            return
        } else {
            waitingSince = nil
        }
        table.contentOffset.y = y
        // Main-thread cost of this frame: layout (cells dequeued and configured) plus the commit, which runs the
        // text drawing of newly shown blocks.
        let t0 = CACurrentMediaTime()
        table.layoutIfNeeded()
        CATransaction.flush()
        workTimes.append(CACurrentMediaTime() - t0)
    }

    private var workTimes: [CFTimeInterval] = []

    private func finish() {
        link?.invalidate()
        link = nil
        let duration = CACurrentMediaTime() - started
        let counts = chat?.debugCounts
        print(String(format: "[ChatProbe] done: speed %.0f pt/s, %.1f s, %.0f pt scrolled, %d frames, %d dropped (%.2f%%), hitch ratio %.1f ms/s, worst frame %.1f ms, rows %d/%d",
                     speed, duration, distance, frames, dropped, frames > 0 ? Double(dropped) * 100 / Double(frames + dropped) : 0,
                     hitchTime * 1000 / max(duration, 0.001), maxDelta * 1000, counts?.shown ?? 0, counts?.built ?? 0))
        let sorted = workTimes.sorted()
        if !sorted.isEmpty {
            let avg = sorted.reduce(0, +) / Double(sorted.count)
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
            print(String(format: "[ChatProbe] main-thread work per frame: avg %.2f ms, p95 %.2f ms, p99 %.2f ms, max %.2f ms (budget 8.3 ms at 120 Hz)",
                         avg * 1000, p95 * 1000, p99 * 1000, sorted.last! * 1000))
        }
        print("[ChatProbe] TextKit pool on main: \(TextKitPool.mainThreadHits) hits, \(TextKitPool.mainThreadMisses) misses")
        // Back at the end like a finger that let go: following again, and the table trims back to a few screens.
        chat?.scrollToBottom(animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak chat] in
            print("[ChatProbe] after settling at the end: table rows \(chat?.debugCounts.shown ?? 0)")
        }
        keepAlive = nil
    }
}
#endif
