// The last 30 audio events and the Voice Diagnostics report (docs/spec/3x-talk.md §9.4), after the web app's
// `src/voice-events.ts` and `src/voice-report.ts`. Never the words that were said, never a gateway address, never a
// token: callers pass short facts only.

import Foundation

nonisolated struct VoiceEvent: Equatable, Sendable {
    var at: Date
    var text: String
}

@MainActor
enum VoiceEvents {
    static let limit = 30
    static let changed = Notification.Name("hq.voice.events.changed")
    private(set) static var all: [VoiceEvent] = []
    /// A count of every note ever taken (the probe reads the order of the newest ones).
    private(set) static var total = 0

    static func note(_ text: String, at: Date = Date()) {
        all.append(VoiceEvent(at: at, text: VoiceReport.scrub(text)))
        if all.count > limit { all.removeFirst(all.count - limit) }
        total += 1
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// From any thread (the audio queue).
    nonisolated static func noteLater(_ text: String) {
        let at = Date()
        Task { @MainActor in note(text, at: at) }
    }

    static func clear() {
        all = []
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Newest first, as the page lists them.
    static var newestFirst: [VoiceEvent] { all.reversed() }
}

/// The plain-text report behind Copy report. Pure, so its exact shape is unit-tested.
nonisolated enum VoiceReport {
    struct Row: Equatable, Sendable {
        var name: String
        var value: String
    }

    static func time(_ date: Date, zone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Addresses and long secrets never reach the log, whatever a caller passed. `limit`: the most characters kept (the
    /// log's 160; Copy Details keeps more).
    static func scrub(_ text: String, limit: Int = 160) -> String {
        var value = text.replacingOccurrences(of: "\\b(?:https?|wss?)://\\S+", with: "(address)", options: [.regularExpression, .caseInsensitive])
        // A query string or credential that came without its address (a provider's error quoting part of a URL).
        value = value.replacingOccurrences(of: "\\b(bearer|basic)\\s+[A-Za-z0-9._~+/=\\-]+", with: "$1 (hidden)", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: "\\b([A-Za-z_]*(?:token|key|ticket|secret|password|auth|signature|sig)[A-Za-z_]*)=[^\\s&'\"]+",
                                           with: "$1=(hidden)", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: "\\bsk-[A-Za-z0-9_\\-]{8,}", with: "(hidden)", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\b[A-Za-z0-9_\\-]{32,}\\b", with: "(hidden)", options: .regularExpression)
        return value.count > limit ? String(value.prefix(max(0, limit - 1))) + "…" : value
    }

    static func line(_ event: VoiceEvent, zone: TimeZone = .current) -> String { "\(time(event.at, zone: zone))  \(event.text)" }

    static func text(appName: String, version: String, build: String, device: String, system: String, now: Date, rows: [Row],
                     test: String?, events: [VoiceEvent], zone: TimeZone = .current) -> String {
        var lines = ["\(appName) voice diagnostics", "Time: \(stamp(now))", "App: \(appName) \(version) (\(build)) · \(device) · \(system)"]
        lines += rows.map { "\($0.name): \($0.value)" }
        if let test, !test.isEmpty { lines.append("Test: \(test)") }
        lines.append("Recent audio events:")
        if events.isEmpty {
            lines.append("  None yet.")
        } else {
            lines += events.map { "  \(time($0.at, zone: zone)) \($0.text)" }
        }
        return lines.joined(separator: "\n")
    }

    static func holds(_ count: Int) -> String {
        count <= 0 ? "no" : count == 1 ? "yes (1 hold)" : "yes (\(count) holds)"
    }

    static func size(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) bytes" : bytes < 1024 * 1024 ? "\(Int((Double(bytes) / 1024).rounded())) KB"
            : String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}
