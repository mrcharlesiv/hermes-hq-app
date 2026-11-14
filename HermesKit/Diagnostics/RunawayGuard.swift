// [diagnostics] Tester 2026-11-14 (kwojt, Mac 970): a click on Sessions sent the main thread into a layout loop that
// never ended, and every turn of it kept memory the loop never gave back. Ninety minutes later the app held 111 GB,
// macOS paused it and asked to quit apps ("Your system has run out of application memory"), and the only record was
// one 2-second hang line with the eight innermost frames. On the Mac nothing stops a runaway app before the whole
// computer suffers (an iPhone's memory limit ends it in seconds).
//
// The Mac's guard: a background timer asks the main thread to answer once a second. When it has not answered for 30 s
// and the app's memory has grown 1.5 GB since it stopped answering, the app is in a loop it will not leave: the whole
// main-thread stack goes into the log (where it was stuck, outer frames too, which the hang line cuts off), then the
// main thread is stopped with SIGABRT, so the crash handler writes its backtrace and macOS makes a crash report. Only
// memory that keeps growing stops it: a stall that holds its memory steady (a long read, a debugger's pause) is left
// alone, as is a process held back as a whole (sleep, App Nap).

import Darwin
import Foundation
import Synchronization

nonisolated enum RunawayJudge {
    static let interval: TimeInterval = 1
    /// How long the main thread has been silent before its memory is judged.
    static let stuck: TimeInterval = 30
    /// How much the footprint grew since the main thread stopped answering.
    static let growthMB = 1536
    /// A turn of the timer this late means the whole process was held back (sleep, App Nap): the wait so far is no
    /// measure of the main thread, and the question starts again.
    static let late: TimeInterval = 5

    /// Whether to stop the app: silent `waited` seconds, the footprint gone from `fromMB` to `nowMB` meanwhile.
    static func stops(waited: TimeInterval, fromMB: Int, nowMB: Int) -> Bool {
        waited >= stuck && nowMB - fromMB >= growthMB
    }
}

nonisolated final class RunawayGuard: Sendable {
    private struct State {
        var timer: DispatchSourceTimer?
        var askedAt: Date?
        var fromMB = 0
        var lastTick: Date?
        var fired = false
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "hq.runaway-guard", qos: .utility)
    private let footprintMB: @Sendable () -> Int?
    private let stop: @Sendable (_ waited: TimeInterval, _ fromMB: Int, _ nowMB: Int) -> Void

    static let shared = RunawayGuard(footprintMB: { MemoryFootprint.sample()?.mb }, stop: RunawayGuard.stopApp)

    init(footprintMB: @escaping @Sendable () -> Int?, stop: @escaping @Sendable (TimeInterval, Int, Int) -> Void) {
        self.footprintMB = footprintMB
        self.stop = stop
    }

    /// Whether it stopped the app (tests).
    var fired: Bool { state.withLock { $0.fired } }

    /// Once, on the main thread, at launch. The Mac only: elsewhere the system's memory limit ends a runaway app.
    @MainActor static func install() {
        #if targetEnvironment(macCatalyst)
        MainStack.install()
        mainThread = pthread_self()
        shared.start()
        #endif
    }

    func start() {
        state.withLock { s in
            guard s.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + RunawayJudge.interval, repeating: RunawayJudge.interval, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.tick() }
            s.timer = timer
            timer.resume()
        }
    }

    /// One turn of the timer (also what the tests drive): ask when nothing is asked, else judge the wait.
    func tick(now: Date = Date(), ask: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil) {
        let mb = footprintMB()
        var verdict: (waited: TimeInterval, from: Int, now: Int)?
        let asking: Bool = state.withLock { s in
            defer { s.lastTick = now }
            guard !s.fired else { return false }
            if let last = s.lastTick, now.timeIntervalSince(last) >= RunawayJudge.late { s.askedAt = nil }
            guard let askedAt = s.askedAt else {
                s.askedAt = now
                s.fromMB = mb ?? 0
                return true
            }
            let waited = now.timeIntervalSince(askedAt)
            if let mb, mb > 0, s.fromMB > 0, RunawayJudge.stops(waited: waited, fromMB: s.fromMB, nowMB: mb) {
                s.fired = true
                s.timer?.cancel()
                verdict = (waited, s.fromMB, mb)
            }
            return false
        }
        if let verdict { stop(verdict.waited, verdict.from, verdict.now); return }
        guard asking else { return }
        let answer: @Sendable () -> Void = { [weak self] in self?.answered(asked: now) }
        if let ask { ask(answer) } else { DispatchQueue.main.async(execute: answer) }
    }

    func answered(asked: Date) {
        state.withLock { s in if s.askedAt == asked { s.askedAt = nil } }
    }

    // MARK: Stopping

    nonisolated(unsafe) private static var mainThread: pthread_t?

    /// The whole stack to the log, then SIGABRT on the main thread: the crash handler (`CrashCapture`) writes that
    /// thread's backtrace and the system its crash report. Not under a debugger, whose pause is no runaway.
    static let stopApp: @Sendable (TimeInterval, Int, Int) -> Void = { waited, fromMB, nowMB in
        guard !beingDebugged() else { return }
        let frames = MainStack.sample(limit: 512).map(MainStack.frames) ?? []
        let stack = frames.isEmpty ? "(could not be read)" : MainStack.summary(frames, count: frames.count)
        DiagnosticLog.shared.note("hang", "main thread stuck for \(Int(waited)) s while the app's memory grew from \(fromMB) MB "
                                  + "to \(nowMB) MB: stopping the app before it uses up the Mac's memory. "
                                  + "Stuck in (\(frames.count) frames): \(stack)", code: true)
        StabilityCounts.count("mainHangs")
        DiagnosticLog.shared.flush()
        if let main = mainThread { pthread_kill(main, SIGABRT) }
        sleep(5)   // the main thread's handler ends the process; this thread waits for it
        abort()
    }

    private static func beingDebugged() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return info.kp_proc.p_flag & P_TRACED != 0
    }
}
