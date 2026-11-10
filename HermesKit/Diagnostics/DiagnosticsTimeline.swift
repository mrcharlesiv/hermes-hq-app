// What Settings › About › Diagnostics shows of this run (`src/diagnostics-sheet.tsx`): recent errors (repeats folded,
// newest first) and, through `StartupTimings`, the returns to the app. Fed by `DiagnosticLog.note` (categories "error",
// "screen", "app"), kept in memory for this run, bounded. Errors are redacted when stored (`DiagnosticRedactor`), kept
// on disk for the next launch (`KeptErrors`), and redacted again when shown and when copied.

import Foundation
import Synchronization

nonisolated final class DiagnosticsTimeline: Sendable {
    static let shared = DiagnosticsTimeline(kept: .shared, timings: .shared)

    typealias ErrorGroup = DiagnosticsReport.ErrorGroup

    private struct State {
        var errors: [(message: String, at: Date?)] = []
        /// The newest screen the log named: where an error happened ("· on <screen>").
        var screen: String?
        var wasInBackground = false
    }

    private let state = Mutex(State())
    private let kept: KeptErrors?
    private let timings: StartupTimings?
    /// When this process started (the kernel's own record), for startup timings.
    let processStart: Date

    /// `shared` writes errors through to disk and marks returns; any other instance is a test's own and touches neither.
    init(processStart: Date = DiagnosticsTimeline.processStartDate(), kept: KeptErrors? = nil, timings: StartupTimings? = nil) {
        self.processStart = processStart
        self.kept = kept
        self.timings = timings
    }

    // MARK: Recording (from DiagnosticLog.note)

    func record(category: String, message: String, at date: Date = Date()) {
        switch category {
        case "error":
            let safe = DiagnosticRedactor.redact(message)
            let screen = state.withLock { s in
                s.errors.append((safe, date))
                if s.errors.count > 100 { s.errors.removeFirst(s.errors.count - 100) }
                return s.screen
            }
            kept?.keep(message: safe, at: date, route: screen)
        case "screen":
            state.withLock { $0.screen = String(message.prefix(120)) }
        case "app":
            // A return is an activation that follows the background; the launch's own activation is not one.
            if message == "background" {
                state.withLock { $0.wasInBackground = true }
                timings?.mark("app.background", at: date)
            } else if message == "active" {
                let returned = state.withLock { s in
                    defer { s.wasInBackground = false }
                    return s.wasInBackground
                }
                if returned { timings?.mark("app.foreground", at: date) }
            }
        default:
            break
        }
    }

    // MARK: Reading

    /// The newest screen's fixed name for the performance log ("open chat", "tab 0"): letters before any detail.
    var screenName: String { Self.fixedName(state.withLock { $0.screen } ?? "") }

    /// "show SettingsPageController<DiagnosticsView> (depth 3)" → "show DiagnosticsView": letters before any detail,
    /// and a generic screen named by what it holds (build 293: the wrapper's name pushed the page past 40 characters).
    static func fixedName(_ screen: String) -> String {
        var name = Substring(screen)
        if let open = name.firstIndex(of: "<"), let close = name.lastIndex(of: ">"), open < close {
            let prefix = name[..<open]
            let start = prefix.lastIndex(of: " ").map { prefix.index(after: $0) } ?? prefix.startIndex
            var inner = name[name.index(after: open)..<close]
            if let nested = inner.firstIndex(where: { "<,".contains($0) }) { inner = inner[..<nested] }
            if let dot = inner.lastIndex(of: ".") { inner = inner[inner.index(after: dot)...] }
            name = Substring(String(name[..<start]) + inner.trimmingCharacters(in: .whitespaces) + String(name[name.index(after: close)...]))
        }
        let cut = name.firstIndex { "(:".contains($0) } ?? name.endIndex
        return String(name[..<cut].trimmingCharacters(in: .whitespaces).prefix(40))
    }

    /// Recent errors, newest first, one bounded line each, repeats folded.
    func recentErrors(limit: Int = 20) -> [ErrorGroup] {
        DiagnosticsReport.recentErrors(state.withLock { $0.errors }, limit: limit)
    }

    /// What earlier launches of this build kept, folded the same way.
    func earlierErrors(limit: Int = 20) -> [ErrorGroup] {
        guard let kept else { return [] }
        return DiagnosticsReport.recentErrors(kept.earlier(), limit: limit)
    }

    // MARK: Process start

    static func processStartDate() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
}
