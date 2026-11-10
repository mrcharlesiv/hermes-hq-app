// [diagnostics] Named startup and connection timings, and named marks, for Settings › About › Diagnostics (the web
// shell's `HermesNative.measured` / `recordTiming` and the page's own trace): "App launch 141 ms", "Connection ticket
// 260 ms", every reconnect's ticket and handshake, and the returns to the app. In memory, this run only, bounded, and
// safe from any thread. Times are milliseconds since the process started (the kernel's own record).

import Foundation
import Synchronization

nonisolated final class StartupTimings: Sendable {
    static let shared = StartupTimings()

    typealias Timing = DiagnosticsReport.Timing
    typealias Mark = DiagnosticsReport.Mark

    private struct State {
        var entries: [Timing] = []
        /// Marks of the launch itself, kept apart so a flaky connection's marks never push them out.
        var launchMarks: [Mark] = []
        var marks: [Mark] = []
    }

    private let state = Mutex(State())
    let processStart: Date

    static let entryLimit = 256
    static let markLimit = 256

    init(processStart: Date = DiagnosticsTimeline.processStartDate()) { self.processStart = processStart }

    func offsetMs(_ date: Date = Date()) -> Double { date.timeIntervalSince(processStart) * 1000 }

    /// A step that began at `start` and has just ended.
    func record(_ name: String, from start: Date, to end: Date = Date(), outcome: String = "ok") {
        record(Timing(name: name, offsetMs: offsetMs(start), durationMs: end.timeIntervalSince(start) * 1000, outcome: outcome, at: start))
    }

    func record(_ entry: Timing) {
        state.withLock { s in
            s.entries.append(entry)
            guard s.entries.count > Self.entryLimit else { return }
            // The launch's own steps stay; the oldest reconnect entry goes.
            if let index = s.entries.firstIndex(where: { $0.name.hasPrefix("socket.") && $0.offsetMs > (s.entries.first { $0.name == "socket.handshake" }?.offsetMs ?? 0) }) {
                s.entries.remove(at: index)
            } else {
                s.entries.removeFirst()
            }
        }
    }

    /// Recorded once per launch, however often it is asked for ("launch.ready", "native.loaded").
    func markOnce(_ name: String, at date: Date = Date()) {
        let atMs = offsetMs(date)
        state.withLock { s in
            guard !s.launchMarks.contains(where: { $0.name == name }) else { return }
            s.launchMarks.append(Mark(name: name, atMs: atMs))
        }
    }

    /// "app.foreground", "socket.open", "socket.close", "socket.error": the last 256.
    func mark(_ name: String, at date: Date = Date()) {
        let atMs = offsetMs(date)
        state.withLock { s in
            s.marks.append(Mark(name: name, atMs: atMs))
            if s.marks.count > Self.markLimit { s.marks.removeFirst(s.marks.count - Self.markLimit) }
        }
    }

    var entries: [Timing] { state.withLock { $0.entries } }
    var marks: [Mark] { state.withLock { $0.launchMarks + $0.marks } }

    func resetForTests() { state.withLock { $0 = State() } }
}
