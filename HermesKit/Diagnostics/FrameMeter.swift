// [diagnostics] Smoothness in the performance log (build 293): dropped frames during the moments the owner feels — a
// scroll (drag and coast), the keyboard moving, a chat opening, a page push or pop, a sheet coming up. A display link
// runs only while such a moment lasts (paused otherwise, so an idle app pays nothing); each frame only adds to a
// tally, and a finished moment is folded into a per-(moment, screen) bucket. The log gets:
//   frames {kd, scr, n, dur, hit, wf, mf, hz, b, rs}   a bucket: moments, total ms, hitch ms, worst frame ms, missed
//                                                      frames, top refresh rate, bad moments, each moment's hitch ratio
//   frames.bad {kd, scr, dur, wf, hr, mf, fr, hz}      one moment with a frame over 100 ms (at most one per 5 s)
// A bucket is sent once it holds 20 moments or is 5 minutes old (checked as moments end) and when the app leaves the
// screen. Hitch ratio = ms of hitch per second of motion, Apple's metric (under 5 good, over 10 bad). Frame times come
// from the display link's own timestamps, so a late main thread shows; a slow render-server commit does not. Only
// fixed screen names; no text.

import Foundation
import QuartzCore
import UIKit

nonisolated enum FrameMath {
    /// Frames a moment saw. `add` takes one frame: the time since the previous one and the interval that was expected.
    struct Tally: Sendable, Equatable {
        var frames = 0
        var expected = 0
        var durationMs: Double = 0
        var hitchMs: Double = 0
        var worstMs: Double = 0
        var topHz = 0

        mutating func add(deltaMs: Double, intervalMs: Double) {
            guard deltaMs > 0, intervalMs > 0 else { return }
            frames += 1
            expected += max(1, Int((deltaMs / intervalMs).rounded()))
            durationMs += deltaMs
            worstMs = max(worstMs, deltaMs)
            topHz = max(topHz, Int((1000 / intervalMs).rounded()))
            // Lateness under half a frame is timer jitter, not a hitch.
            if deltaMs - intervalMs > intervalMs / 2 { hitchMs += deltaMs - intervalMs }
        }

        /// ms of hitch per second of motion.
        var hitchRatio: Double { durationMs > 0 ? hitchMs / (durationMs / 1000) : 0 }
        var missed: Int { max(0, expected - frames) }
    }

    /// A moment worth keeping: a few frames at least (a tap that moved a pixel is not a scroll).
    static func counts(_ tally: Tally) -> Bool { tally.frames >= 3 && tally.durationMs >= 40 }

    /// A moment with one frame this long is sent on its own.
    static let badFrameMs: Double = 100

    static func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    /// One decimal as the log writes it ("66.9", never JSON's "66.900000000000006").
    static func decimal1(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(mantissa: UInt64(abs((value * 10).rounded())), exponent: -1, isNegative: value < 0)
    }

    /// "3.2", "12", "0": one decimal under 100, whole above, at most 999.
    static func short(_ value: Double) -> String {
        let v = min(999, max(0, value))
        if v >= 100 { return String(Int(v.rounded())) }
        let r = round1(v)
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    static func median(_ values: [Double]) -> Double { quantile(values, 0.5) }

    /// Nearest-rank quantile (0 for none).
    static func quantile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((q * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }
}

/// The moments, bucketed and turned into log records. Pure; `FrameMeter` owns one.
nonisolated struct FrameBook {
    struct Record { var kind: String; var fields: [(String, Any)] }

    struct Bucket: Sendable, Equatable {
        var started: Date
        var moments = 0
        var durationMs: Double = 0
        var hitchMs: Double = 0
        var worstMs: Double = 0
        var missed = 0
        var topHz = 0
        var bad = 0
        var ratios: [Double] = []

        mutating func add(_ tally: FrameMath.Tally) {
            moments += 1
            durationMs += tally.durationMs
            hitchMs += tally.hitchMs
            worstMs = max(worstMs, tally.worstMs)
            missed += tally.missed
            topHz = max(topHz, tally.topHz)
            if tally.worstMs > FrameMath.badFrameMs { bad += 1 }
            ratios.append(tally.hitchRatio)
        }
        var hitchRatio: Double { durationMs > 0 ? hitchMs / (durationMs / 1000) : 0 }
    }

    /// This run's totals per moment kind, for Settings › Diagnostics.
    struct Total: Sendable, Equatable {
        var kind: String
        var moments = 0
        var hitchRatios: [Double] = []
        var worstMs: Double = 0
        var bad = 0
    }

    static let perBucket = 20
    static let bucketAge: TimeInterval = 300
    static let badGap: TimeInterval = 5

    private(set) var buckets: [String: Bucket] = [:]
    private var order: [String] = []
    private(set) var totals: [String: Total] = [:]
    private var lastBad = Date.distantPast
    private(set) var badSkipped = 0

    private static func key(_ kind: String, _ screen: String) -> String { kind + "\u{1}" + screen }

    /// A finished moment. Answers the records due now: its own when it was bad, and any bucket that is full or old.
    mutating func add(kind: String, screen: String, tally: FrameMath.Tally, now: Date) -> [Record] {
        guard FrameMath.counts(tally) else { return [] }
        var out: [Record] = []
        let key = Self.key(kind, screen)
        if buckets[key] == nil { buckets[key] = Bucket(started: now); order.append(key) }
        buckets[key]!.add(tally)
        var total = totals[kind] ?? Total(kind: kind)
        total.moments += 1
        total.worstMs = max(total.worstMs, tally.worstMs)
        if total.hitchRatios.count >= 500 { total.hitchRatios.removeFirst(total.hitchRatios.count - 499) }
        total.hitchRatios.append(tally.hitchRatio)
        if tally.worstMs > FrameMath.badFrameMs {
            total.bad += 1
            if now.timeIntervalSince(lastBad) >= Self.badGap {
                lastBad = now
                out.append(Record(kind: "frames.bad", fields: [
                    ("kd", kind), ("scr", screen), ("dur", Int(tally.durationMs.rounded())), ("wf", Int(tally.worstMs.rounded())),
                    ("hr", FrameMath.decimal1(tally.hitchRatio)), ("mf", tally.missed), ("fr", tally.frames), ("hz", tally.topHz)]))
            } else {
                badSkipped += 1
            }
        }
        totals[kind] = total
        out += flush(now: now, all: false)
        return out
    }

    /// Buckets due (20 moments or 5 minutes old), or every bucket when the app leaves the screen.
    mutating func flush(now: Date, all: Bool) -> [Record] {
        var out: [Record] = []
        for key in order {
            guard let bucket = buckets[key], bucket.moments > 0 else { continue }
            guard all || bucket.moments >= Self.perBucket || now.timeIntervalSince(bucket.started) >= Self.bucketAge else { continue }
            let parts = key.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            out.append(Record(kind: "frames", fields: [
                ("kd", parts[0]), ("scr", parts.count > 1 ? parts[1] : ""), ("n", bucket.moments),
                ("dur", Int(bucket.durationMs.rounded())), ("hit", FrameMath.decimal1(bucket.hitchMs)),
                ("wf", Int(bucket.worstMs.rounded())), ("mf", bucket.missed), ("hz", bucket.topHz), ("b", bucket.bad),
                ("rs", bucket.ratios.map(FrameMath.short).joined(separator: ","))]))
            buckets[key] = nil
        }
        order.removeAll { buckets[$0] == nil }
        return out
    }
}

/// The display link and the moments it measures. Main thread only.
final class FrameMeter {
    static let shared = FrameMeter()

    enum Kind: String, CaseIterable {
        case scroll, keyboard, push, pop
        case chatOpen = "chat.open"
        case present
        /// [project-unfold] A group on Sessions opening or closing.
        case fold
    }

    private struct Active {
        var id: Int
        var kind: Kind
        var screen: String
        var tally = FrameMath.Tally()
        var began: CFTimeInterval
        var endAt: CFTimeInterval?
        var atMost: TimeInterval
        var keepGoing: (() -> Bool)?
    }

    private var link: CADisplayLink?
    private var active: [Active] = []
    private var nextId = 0
    private var lastTimestamp: CFTimeInterval?
    private var lastInterval: CFTimeInterval = 0
    private(set) var book = FrameBook()
    /// The scroll views under the finger, innermost first, until one starts dragging.
    private var touchedScrollViews: [WeakScrollView] = []
    private struct WeakScrollView { weak var view: UIScrollView? }
    /// Where records go (tests swap it).
    var record: (FrameBook.Record) -> Void = {
        LogUploader.shared.record($0.kind, $0.kind == "frames.bad" ? $0.fields + MemoryFootprint.fields() : $0.fields)
    }

    var isMeasuring: Bool { !active.isEmpty }

    static func install() {
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillHideNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0
                MainActor.assumeIsolated { shared.keyboard(duration: duration) }
            }
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { shared.leave() }
        }
    }

    // MARK: Moments

    /// Starts measuring; `keepGoing` is asked every frame (false ends the moment), `atMost` caps it.
    @discardableResult
    func begin(_ kind: Kind, atMost: TimeInterval = 5, keepGoing: (() -> Bool)? = nil) -> Int? {
        guard LogUploader.isEnabled, UIApplication.shared.applicationState != .background else { return nil }
        nextId += 1
        active.append(Active(id: nextId, kind: kind, screen: DiagnosticsTimeline.shared.screenName, began: CACurrentMediaTime(),
                             atMost: atMost, keepGoing: keepGoing))
        startLink()
        return nextId
    }

    /// Ends a moment `tail` seconds from now (the frames that settle after an animation count too).
    func end(_ id: Int?, after tail: TimeInterval = 0) {
        guard let id, let index = active.firstIndex(where: { $0.id == id }) else { return }
        let at = CACurrentMediaTime() + tail
        active[index].endAt = min(active[index].endAt ?? at, at)
    }

    private func keyboard(duration: Double) {
        guard duration > 0, !active.contains(where: { $0.kind == .keyboard }) else { return }
        let id = begin(.keyboard, atMost: duration + 1)
        end(id, after: duration + 0.1)
    }

    /// [diagnostics] A push or pop in a navigation stack (PushedPageTitles): measured until its transition ends.
    func navigation(_ navigationController: UINavigationController, to viewController: UIViewController, animated: Bool, chat: Bool) {
        guard animated, let coordinator = navigationController.transitionCoordinator else { return }
        let from = coordinator.viewController(forKey: .from)
        let push = from.map { navigationController.viewControllers.contains($0) } ?? true
        let id = begin(chat && push ? .chatOpen : push ? .push : .pop, atMost: 10)
        // A chat's first layout (rows, keyboard guide) lands just after the slide.
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.end(id, after: chat && push ? 0.3 : 0.05) }
    }

    /// [diagnostics] Something was added to the window (a presentation's container): a sheet, alert or cover coming up.
    func windowGainedSubview(_ window: UIWindow) {
        guard LogUploader.isEnabled else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, var top = window?.rootViewController else { return }
            while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
            guard top.isBeingPresented, let coordinator = top.transitionCoordinator else { return }
            let id = self.begin(.present, atMost: 5)
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.end(id, after: 0.05) }
        }
    }

    /// [diagnostics] The window's touches (MeteredWindow.sendEvent): a scroll is measured from its first dragged move
    /// until it has stopped coasting. Costs a pointer walk per touch-down and a flag read per move.
    func touches(_ event: UIEvent) {
        guard event.type == .touches, let touches = event.allTouches, touches.count == 1, let touch = touches.first else { return }
        switch touch.phase {
        case .began:
            touchedScrollViews = []
            var view = touch.view
            while let current = view {
                if let scroll = current as? UIScrollView, scroll.isScrollEnabled { touchedScrollViews.append(WeakScrollView(view: scroll)) }
                view = current.superview
            }
        case .moved:
            guard !touchedScrollViews.isEmpty, !active.contains(where: { $0.kind == .scroll }) else { return }
            guard let scroll = touchedScrollViews.lazy.compactMap(\.view).first(where: \.isDragging) else { return }
            touchedScrollViews = []
            begin(.scroll, atMost: 30) { [weak scroll] in scroll.map { $0.isDragging || $0.isDecelerating } ?? false }
        default:
            break
        }
    }

    #if targetEnvironment(macCatalyst)
    /// When `wheel` last looked for a moving scroll view (it looks at most every 0.2 s while none is found).
    private var lastWheelLook: CFTimeInterval = 0

    /// [mac-audit #28] Owner 2026-11-02: the Mac's trackpad and mouse-wheel scrolls send no touches, so `touches` never
    /// saw them and the Mac recorded no scroll smoothness at all. A scroll event (`.scroll`) starts the same scroll
    /// moment once the scroll view it moved is dragging; the event carries no view, so the window's visible scroll
    /// views are walked, after the event has been handled, at most every 0.2 s and never while a scroll is measured.
    func wheel(_ event: UIEvent, in window: UIWindow) {
        guard event.type == .scroll, LogUploader.isEnabled, !active.contains(where: { $0.kind == .scroll }) else { return }
        let now = CACurrentMediaTime()
        guard now - lastWheelLook >= 0.2 else { return }
        lastWheelLook = now
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, !self.active.contains(where: { $0.kind == .scroll }),
                  let scroll = Self.movingScrollView(in: window) else { return }
            self.begin(.scroll, atMost: 30) { [weak scroll] in scroll.map { $0.isDragging || $0.isDecelerating } ?? false }
        }
    }

    /// The first visible scroll view under `view` that is being dragged or coasting.
    private static func movingScrollView(in view: UIView) -> UIScrollView? {
        if view.isHidden || view.alpha < 0.01 { return nil }
        if let scroll = view as? UIScrollView, scroll.isScrollEnabled, scroll.isDragging || scroll.isDecelerating { return scroll }
        for sub in view.subviews { if let found = movingScrollView(in: sub) { return found } }
        return nil
    }
    #endif

    // MARK: Display link

    private func startLink() {
        if link == nil {
            let link = CADisplayLink(target: FrameMeterTarget(self), selector: #selector(FrameMeterTarget.tick(_:)))
            // ProMotion: the link asks for the screen's top rate, as scrolling and UIKit's animations already run.
            let top = Float(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.maximumFramesPerSecond }.max() ?? 60)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, top), maximum: top, preferred: top)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        if link?.isPaused == true || lastTimestamp == nil {
            link?.isPaused = false
            lastTimestamp = nil
        }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        if let last = lastTimestamp {
            let delta = (link.timestamp - last) * 1000, interval = lastInterval * 1000
            for index in active.indices { active[index].tally.add(deltaMs: delta, intervalMs: interval) }
        }
        lastTimestamp = link.timestamp
        lastInterval = link.targetTimestamp - link.timestamp
        let now = CACurrentMediaTime()
        var done: [Active] = []
        active.removeAll { moment in
            let over = (moment.endAt.map { now >= $0 } ?? false) || now - moment.began >= moment.atMost
                || (moment.endAt == nil && moment.keepGoing.map { !$0() } ?? false)
            if over { done.append(moment) }
            return over
        }
        if active.isEmpty {
            link.isPaused = true
            lastTimestamp = nil
        }
        guard !done.isEmpty else { return }
        let date = Date()
        for moment in done {
            for out in book.add(kind: moment.kind.rawValue, screen: moment.screen, tally: moment.tally, now: date) { record(out) }
        }
        if let last = done.last { MemoryFootprint.observe(screen: last.screen, now: date) }   // [diagnostics] where a peak was
    }

    /// The app leaves the screen: what was being measured ends, every bucket is sent.
    func leave() {
        active.removeAll()
        link?.isPaused = true
        lastTimestamp = nil
        for out in book.flush(now: Date(), all: true) { record(out) }
    }
}

/// The display link holds its target strongly; this keeps the meter out of that cycle.
private final class FrameMeterTarget: NSObject {
    weak var meter: FrameMeter?
    init(_ meter: FrameMeter) { self.meter = meter }
    @objc func tick(_ link: CADisplayLink) { meter?.tick(link) }
}

/// [diagnostics] The app's window: hands touches and added presentation containers to `FrameMeter`, presentations
/// coming and going to `PresentationTrail`, and [mac] clicks to `MacTrail`.
class MeteredWindow: UIWindow {
    override func sendEvent(_ event: UIEvent) {
        FrameMeter.shared.touches(event)
        #if targetEnvironment(macCatalyst)
        MacTrail.event(event)
        FrameMeter.shared.wheel(event, in: self)
        #endif
        super.sendEvent(event)
    }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        FrameMeter.shared.windowGainedSubview(self)
        PresentationTrail.windowChanged(self)
    }

    override func willRemoveSubview(_ subview: UIView) {
        super.willRemoveSubview(subview)
        PresentationTrail.windowChanged(self)
    }
}
