// [diagnostics] One path for giving memory back (the web app's `src/memory-trim.ts`, `src/session-cache-phone.ts`;
// docs/spec/3x-diagnostics.md §12). A memory warning (or the system's own pressure signal) empties what can be rebuilt:
// every decoded transcript that is not on screen and has nothing waiting to be written. Staying in the background
// trims to what a return needs: the warm transcripts held to 4 chats or 4 MB, whichever is smaller, and the chat
// layout caches to their most recent. The chat on show is outside both, and nothing on disk is touched, so a trimmed
// chat opens from disk exactly as a cold open does.
//
// [perf] The background trim waits 20 s and a return before then calls it off: most trips away are shorter than the
// socket's own ~25 s hold, and a trim at once made each quick return rebuild its caches on the main thread.
//
// Each cache registers its own trim and answers how many things it dropped. The chat layout caches register their
// background trim here and keep their memory-warning observer; the media and photo-face caches keep the observers
// they already had and are listed in the report, not rewired.

import Foundation
import Synchronization
import UIKit

nonisolated enum MemoryTrim {
    enum Reason: String, Sendable { case pressure, background }

    /// The background rule: at most this many warm chats, or this much decoded text, whichever is smaller.
    static let backgroundChats = 4
    static let backgroundBytes = 4 << 20

    private struct Registered: Sendable {
        var name: String
        var trim: @Sendable (Reason) -> Int
    }

    private struct State {
        var trims: [Registered] = []
        var runs = 0
        var lastDropped = 0
        /// Bumped by every trip to the background and every return: a scheduled background trim runs only if it is
        /// still the latest.
        var backgroundGeneration = 0
        var backgroundDelay: DispatchTimeInterval = .seconds(20)
        /// When the last pressure trim ran (uptime seconds): the memory warning and the pressure source both report
        /// one event, so the second within `pressureWindow` is the same event.
        var lastPressure: TimeInterval?
    }

    /// [diagnostics] One pressure event, one trim: the Mac logged two `mem.trim` at the same millisecond for each
    /// event (the second dropping 0), one from the memory warning and one from the pressure source.
    static let pressureWindow: TimeInterval = 1

    private static let state = Mutex(State())
    private static let queue = DispatchQueue(label: "ai.hermes.hqnative.memorytrim", qos: .utility)
    private nonisolated(unsafe) static var pressure: DispatchSourceMemoryPressure?

    /// How many trims have run, and what the last one dropped (tests and the DEBUG probe).
    static var runs: Int { state.withLock { $0.runs } }
    static var lastDropped: Int { state.withLock { $0.lastDropped } }
    /// How long the app stays in the background before its trim runs (tests shorten it).
    static var backgroundDelay: DispatchTimeInterval {
        get { state.withLock { $0.backgroundDelay } }
        set { state.withLock { $0.backgroundDelay = newValue } }
    }

    /// A cache's own trim; it answers how many entries it let go. A second registration under a name replaces the first.
    static func register(_ name: String, _ trim: @escaping @Sendable (Reason) -> Int) {
        state.withLock { s in
            s.trims.removeAll { $0.name == name }
            s.trims.append(Registered(name: name, trim: trim))
        }
    }

    /// Observes the memory warning, the system's pressure signal and the app going to the background. Once.
    @MainActor static func install(transcripts: TranscriptCache = .shared) {
        guard pressure == nil else { return }
        register("transcripts") { reason in
            switch reason {
            case .pressure: transcripts.trimMemory()
            case .background: transcripts.trimMemory(keeping: backgroundChats, bytes: backgroundBytes)
            }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in queue.async { pressureSignal() } }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in scheduleBackground() }
        // Calls off a trim still waiting. Nothing orders this ahead of a timer whose time passed while the app was
        // suspended (it fires as the process thaws): `scheduleBackground` skips that one itself.
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in cancelBackground() }
        let source = makePressureSource()
        source.resume()
        pressure = source
    }

    /// Not in `install`: a closure written in a main-actor function is checked for the main actor when it runs, and
    /// this one runs on `queue`, so the first pressure signal stopped the app (build 315 crash, TestFlight).
    private static func makePressureSource() -> DispatchSourceMemoryPressure {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        source.setEventHandler(handler: pressureHandler)
        return source
    }

    /// What the pressure source runs, on `queue`.
    static let pressureHandler: @Sendable () -> Void = { pressureSignal() }

    /// Either pressure trigger, on `queue`: the pressure trim, unless the other trigger already ran it for this event.
    @discardableResult
    static func pressureSignal(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let fresh = state.withLock { s in
            if let last = s.lastPressure, now - last >= 0, now - last < pressureWindow { return false }
            s.lastPressure = now
            return true
        }
        if fresh { runNow(.pressure) }
        return fresh
    }

    /// The background trim, after `backgroundDelay` unless the app returns (or leaves again) first.
    static func scheduleBackground() {
        let (generation, delay) = state.withLock { s in
            s.backgroundGeneration += 1
            return (s.backgroundGeneration, s.backgroundDelay)
        }
        let deadline = DispatchTime.now() + delay
        queue.asyncAfter(deadline: deadline) {
            // Fired well after its time: the app was suspended and is coming back now, the moment the trim must not
            // take. Same clock as the deadline, so a device that slept does not count as late.
            guard DispatchTime.now().uptimeNanoseconds <= deadline.uptimeNanoseconds + 2_000_000_000 else { return }
            guard state.withLock({ $0.backgroundGeneration }) == generation else { return }
            runNow(.background)
        }
    }

    /// The app is coming back: a background trim still waiting does not run.
    static func cancelBackground() { state.withLock { $0.backgroundGeneration += 1 } }

    /// Every registered trim, off the caller's thread. One that drops nothing does not stop the rest.
    static func run(_ reason: Reason) { queue.async { runNow(reason) } }

    @discardableResult
    static func runNow(_ reason: Reason) -> Int {
        let trims = state.withLock { $0.trims }
        let dropped = trims.reduce(0) { $0 + $1.trim(reason) }
        state.withLock { s in
            s.runs += 1
            s.lastDropped = dropped
        }
        AppLog.note("mem", "trim \(reason.rawValue): \(dropped) dropped")
        LogUploader.shared.record("mem.trim", [("why", reason.rawValue), ("chats", dropped),
                                               ("scr", DiagnosticsTimeline.shared.screenName)] + MemoryFootprint.fields())
        return dropped
    }

    /// Waits for trims already asked for (tests).
    static func settle() { queue.sync {} }

    static func resetForTests() {
        state.withLock { s in
            let generation = s.backgroundGeneration + 1    // calls off a trim a test left scheduled
            s = State()
            s.backgroundGeneration = generation
        }
    }
}
