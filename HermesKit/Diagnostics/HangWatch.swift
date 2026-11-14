// [diagnostics] The stall source of the performance log (docs/spec/3x-diagnostics.md §8.4 `main.hang`; the web
// shell's HangMeter): while the app is on screen a background timer asks the main thread to answer every 0.1 s. An
// answer more than 0.25 s late is a stall that long ("main.hang {ms, screen}"); a question still unanswered after 2 s
// is reported once while it lasts ("ongoing") and counted under Stability › "Hermes HQ stopped responding". Nothing
// runs while the app is in the background or the performance log is off; no text is recorded, only the screen's
// fixed name and the main-thread spans and facts of MainTrail (fixed names, counts). A stall still going 0.35 s
// in, and again at 1.5 s, has the main thread's stack sampled (MainStack.swift): `main.hang.frame` events with it.

import Foundation
import Synchronization
import UIKit

nonisolated enum HangJudge {
    static let interval: TimeInterval = 0.1
    static let stall: TimeInterval = 0.25
    static let hang: TimeInterval = 2

    /// When a stall still going has the main thread's stack sampled: first this far in, then at `secondSample`.
    static let firstSample: TimeInterval = 0.35
    static let secondSample: TimeInterval = 1.5

    struct Report: Equatable, Sendable {
        var ms: Int
        var ongoing: Bool
        /// The main thread's return addresses at each sample taken during this stall (innermost first).
        var stacks: [[UInt]] = []
    }

    /// A sample is due: none yet past the first mark, or one past the second.
    static func sampleDue(_ waited: TimeInterval, taken: Int) -> Bool {
        taken == 0 ? waited >= firstSample : taken == 1 && waited >= secondSample
    }

    /// The answer to a question asked `waited` seconds ago arrived: a stall when it was late. One already reported as
    /// ongoing still reports its full length (the event that says how long it lasted).
    static func answered(after waited: TimeInterval) -> Report? {
        waited >= stall ? Report(ms: Int((waited * 1000).rounded()), ongoing: false) : nil
    }

    /// A question is still unanswered after `waited` seconds: reported once, when it passes two seconds.
    static func waiting(_ waited: TimeInterval, reported: Bool) -> Report? {
        !reported && waited >= hang ? Report(ms: Int((waited * 1000).rounded()), ongoing: true) : nil
    }
}

nonisolated final class HangWatch: Sendable {

    private struct State {
        var timer: DispatchSourceTimer?
        var askedAt: Date?
        var reported = false
        var stalls = 0
        var hangs = 0
        /// The timer's own last turn. A turn that comes late means the whole process was held back (App Nap, a
        /// hidden Mac window's timer throttling), not the main thread: the question then is no measure of a stall.
        var lastTick: Date?
        var throttled = 0
        /// Stacks sampled while the current question waits; they go with the next report about it.
        var stacks: [[UInt]] = []
        var sampled = 0
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "hq.hang-watch", qos: .utility)
    private let record: @Sendable (HangJudge.Report) -> Void
    private let sample: @Sendable () -> [UInt]?

    static let shared = HangWatch(record: HangWatch.log, sample: { MainStack.sample() })

    /// `sample` reads the main thread's stack (MainStack.sample in the app; none by default, so tests never stop it).
    init(record: @escaping @Sendable (HangJudge.Report) -> Void = HangWatch.log, sample: @escaping @Sendable () -> [UInt]? = { nil }) {
        self.record = record
        self.sample = sample
    }

    var stalls: Int { state.withLock { $0.stalls } }
    var hangs: Int { state.withLock { $0.hangs } }
    var isRunning: Bool { state.withLock { $0.timer != nil } }
    /// Questions dropped because the timer itself came late (tests).
    var throttled: Int { state.withLock { $0.throttled } }

    /// [mac] The window is fully covered or on another Space: the system throttles a hidden app's timers and main
    /// queue, so its late answers are no stalls (the Mac's idle 1.3 and 1.6 s "nothing traced" on Bots).
    @MainActor private static var hidden = false

    /// Starts with the app on screen and stops when it leaves (a suspended app answers late by design).
    @MainActor static func install() {
        MainStack.install()
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if !hidden { shared.start() } }
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in shared.stop() }
        #if targetEnvironment(macCatalyst)
        // AppKit's own notification (NSApplicationDidChangeOcclusionStateNotification); its object is NSApp, whose
        // occlusionState has the visible bit (NSApplicationOcclusionStateVisible = 1 << 1).
        center.addObserver(forName: Notification.Name("NSApplicationDidChangeOcclusionStateNotification"), object: nil, queue: .main) { note in
            let state = (note.object as? NSObject)?.value(forKey: "occlusionState") as? UInt ?? 2
            MainActor.assumeIsolated {
                if hidden != (state & 2 == 0) { AppLog.trace("mac", state & 2 == 0 ? "window hidden (covered, minimized or on another Space)" : "window visible") }
                hidden = state & 2 == 0
                if hidden { shared.stop() } else if UIApplication.shared.applicationState == .active { shared.start() }
            }
        }
        #endif
        if UIApplication.shared.applicationState == .active { shared.start() }
    }

    func start() {
        guard LogUploader.isEnabled else { return }
        state.withLock { s in
            guard s.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + HangJudge.interval, repeating: HangJudge.interval, leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.tick() }
            s.timer = timer
            s.askedAt = nil
            s.reported = false
            s.lastTick = nil
            s.stacks = []
            timer.resume()
        }
    }

    func stop() {
        state.withLock { s in
            s.timer?.cancel()
            s.timer = nil
            s.askedAt = nil
            s.reported = false
            s.lastTick = nil
        }
    }

    /// The timer is behind when its last turn was longer ago than a stall: every turn is 0.1 s apart while the
    /// process runs freely, even with the main thread stuck.
    private static func behind(_ s: State, at now: Date) -> Bool {
        guard let last = s.lastTick else { return false }
        return now.timeIntervalSince(last) >= HangJudge.stall
    }

    /// One turn of the timer (also what the tests drive): ask when nothing is asked, else judge the wait.
    func tick(now: Date = Date(), ask: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil) {
        var sampleFor: Date?
        let report: HangJudge.Report? = state.withLock { s in
            defer { s.lastTick = now }
            if s.askedAt != nil, Self.behind(s, at: now) {
                // The timer itself was held back: what is outstanding measures the throttling, not the main thread.
                s.askedAt = nil
                s.reported = false
                s.throttled += 1
            }
            if let askedAt = s.askedAt {
                let waited = now.timeIntervalSince(askedAt)
                if HangJudge.sampleDue(waited, taken: s.sampled) { sampleFor = askedAt }
                guard var report = HangJudge.waiting(waited, reported: s.reported) else { return nil }
                s.reported = true
                s.hangs += 1
                report.stacks = s.stacks
                s.stacks = []
                return report
            }
            s.askedAt = now
            s.stacks = []
            s.sampled = 0
            return nil
        }
        // Outside the lock: the main thread may be waiting for it in `answered`.
        if let asked = sampleFor {
            let stack = sample()
            state.withLock { s in
                guard s.askedAt == asked else { return }
                s.sampled += 1
                if let stack, stack != s.stacks.last { s.stacks.append(stack) }
            }
        }
        if let report { record(report); return }
        guard state.withLock({ $0.askedAt == now }) else { return }
        let answer: @Sendable () -> Void = { [weak self] in self?.answered(asked: now) }
        if let ask { ask(answer) } else { DispatchQueue.main.async(execute: answer) }
    }

    func answered(asked: Date, now: Date = Date()) {
        let report: HangJudge.Report? = state.withLock { s in
            guard s.askedAt == asked else { return nil }
            s.askedAt = nil
            s.reported = false
            let stacks = s.stacks
            s.stacks = []
            if Self.behind(s, at: now) { s.throttled += 1; return nil }
            guard var report = HangJudge.answered(after: now.timeIntervalSince(asked)) else { return nil }
            s.stalls += 1
            report.stacks = stacks
            return report
        }
        if let report { record(report) }
    }

    static let log: @Sendable (HangJudge.Report) -> Void = { report in
        let screen = DiagnosticsTimeline.shared.screenName
        // [diagnostics] build 292: what the main thread was doing (MainTrail): the spans that overlapped the stall (an
        // ongoing one's still open) and the facts the app keeps current (rows on screen, a catch-up running).
        let to = MainTrail.now()
        // The footprint first: a long `did` splits into parts that can use up the event's 16 fields.
        var fields: [(String, Any)] = [("ms", report.ms), ("screen", screen), ("ongoing", report.ongoing)] + MemoryFootprint.fields()
        let did = MainTrail.during(from: to - Double(report.ms) / 1000, to: to)
        fields.append(("did", did.isEmpty ? "nothing traced" : did))
        let facts = MainTrail.facts()
        // A sampled stall carries its record id and build (for the frames' dSYM) ahead of `did`, which may split.
        let stacks = report.stacks.map(MainStack.frames)
        let rec = String(format: "%06x", UInt32.random(in: 0...0xFF_FFFF))
        if !stacks.isEmpty { fields.insert(contentsOf: [("rec", rec), ("bld", StabilityCounts.build)], at: 3) }
        if !facts.isEmpty { fields.append(("ctx", facts)) }
        LogUploader.shared.record("main.hang", fields)
        for (n, frames) in stacks.enumerated() {
            for (i, frame) in frames.enumerated() {
                LogUploader.shared.record("main.hang.frame", [("rec", rec), ("n", n + 1), ("i", i), ("b", frame.binary),
                                                              ("o", frame.offset), ("s", frame.symbol ?? "")])
            }
        }
        if let first = stacks.first {
            AppLog.traceCode("hang", "main thread \(report.ongoing ? "stuck for" : "stalled") \(report.ms) ms in \(MainStack.summary(first))")
        }
        if report.ongoing {
            StabilityCounts.count("mainHangs")
            Signposts.stability.info("main thread unanswered for \(report.ms, privacy: .public) ms")
        } else if report.ms >= Int(HangJudge.hang * 1000) {
            StabilityCounts.raise("mainHangLongestSeconds", to: Double(report.ms) / 1000)
        }
    }
}
