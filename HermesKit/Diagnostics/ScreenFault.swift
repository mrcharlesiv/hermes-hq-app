// [diagnostics] Reports of a screen that fell back instead of showing its content (docs/spec/3x-diagnostics.md §7;
// the web app's renderer-crash-report.ts, whose error boundaries native does not have). One line,
// "Screen problem in <screen>: <message> · at <A › B>", bounded and redacted; the same problem within five seconds is
// one entry. It lands in Recent errors (so it folds, is kept for the next launch and is copied) and in the
// performance log as `page.crash`, the kind the log reader on the computer already counts. Never throws.

import Foundation
import Synchronization

nonisolated enum ScreenFault {
    static let repeatWindow: TimeInterval = 5
    static let maxPath = 6

    /// "A › B › C" from type names, outermost last, at most six; anything that is not a plain name is left out.
    static func path(_ names: [String], limit: Int = maxPath) -> String {
        names.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: #"^[A-Za-z_$][A-Za-z0-9_$.]*$"#, options: .regularExpression) != nil }
            .prefix(limit).joined(separator: " › ")
    }

    static func entry(screen: String?, message: String?, path names: [String] = []) -> String {
        let trimmed = (screen ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let screen = trimmed.isEmpty ? "unlabeled" : String(trimmed.prefix(60))
        let collapsed = (message ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let message = collapsed.isEmpty ? "Unknown error" : String(collapsed.prefix(400))
        let path = path(names)
        return DiagnosticRedactor.redact("Screen problem in \(screen): \(message)" + (path.isEmpty ? "" : " · at \(path)"))
    }

    /// The entry without its "Screen problem in X: " start: what two reports of one failure share.
    static func key(_ entry: String) -> String {
        entry.replacingOccurrences(of: #"^Screen problem in [^:]*: "#, with: "", options: .regularExpression)
    }

    /// The five-second fold, on its own so tests can drive the clock.
    final class Recent: Sendable {
        private let seen = Mutex<[String: Date]>([:])
        var count: Int { seen.withLock { $0.count } }

        /// True when this entry is new (not seen within the window).
        func admit(_ entry: String, now: Date = Date()) -> Bool {
            let key = ScreenFault.key(entry)
            return seen.withLock { seen in
                if let last = seen[key], now.timeIntervalSince(last) < ScreenFault.repeatWindow { return false }
                seen[key] = now
                if seen.count > 50 { seen = seen.filter { now.timeIntervalSince($0.value) < ScreenFault.repeatWindow } }
                return true
            }
        }
    }

    private static let recent = Recent()

    /// Records the problem; false when the same one was recorded within five seconds.
    @discardableResult
    static func report(screen: String, message: String, path: [String] = [], now: Date = Date()) -> Bool {
        let entry = entry(screen: screen, message: message, path: path)
        guard recent.admit(entry, now: now) else { return false }
        AppLog.note("error", entry)
        LogUploader.shared.record("page.crash", [("what", entry)], at: now)
        return true
    }
}
