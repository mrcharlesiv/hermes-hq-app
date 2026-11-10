// [diagnostics] [mac] What the system said about the app: the errors and faults the frameworks wrote to this process's
// unified log (UIKit and AppKit warnings, WebKit, the network stack, Sparkle…), which the app's own lines never saw.
// They are read back from the process's own log store every 5 minutes while the app is on screen and once as it
// leaves, and written as `system` log lines ("com.apple.UIKit/Presentation error: …"). The app's own subsystem is
// skipped (those lines are in app.log already). Each message goes through AppLog.scrub; one message repeated within
// a read (numbers and tags aside: "Connection 3: …" and "Connection 4: …" are one) is one line with its count, and the network
// stack's echoes of a failure already said are left out; a read keeps at most `perRead` lines. Off while sending logs
// is off.

import Foundation
import OSLog

nonisolated final class SystemLog: @unchecked Sendable {
    static let shared = SystemLog()
    static let interval: TimeInterval = 300
    static let perRead = 40
    static let maxMessage = 360

    private let queue = DispatchQueue(label: "hq.system-log", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// The read starts here: the process's start, then where the last read ended.
    private var since: Date = StartupTimings.shared.processStart
    private var reading = false

    /// The window is on screen: read now and every `interval`.
    func start() {
        queue.async { [self] in
            guard timer == nil, LogUploader.isEnabled else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: Self.interval, leeway: .seconds(30))
            timer.setEventHandler { [weak self] in self?.read() }
            self.timer = timer
            timer.resume()
        }
    }

    /// The app leaves the screen: one last read, then nothing until it is back.
    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            read()
        }
    }

    private func read() {
        guard LogUploader.isEnabled, !reading else { return }
        reading = true
        defer { reading = false }
        let began = ContinuousClock.now
        let until = Date()
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let predicate = NSPredicate(format: "(messageType == error OR messageType == fault) AND NOT (subsystem BEGINSWITH %@)", "ai.hermes.hqnative")
            let entries = try store.getEntries(at: store.position(date: since), matching: predicate)
            let logs = entries.lazy.compactMap { $0 as? OSLogEntryLog }.filter { $0.date >= self.since && $0.date < until }
            let lines = Self.lines(logs.map { Entry(subsystem: $0.subsystem, category: $0.category, fault: $0.level == .fault, message: $0.composedMessage) })
            for line in lines { AppLog.note("system", line) }
            AppLog.trace("system", "read the system log: \(lines.count) line(s) in \(AppLog.ms(since: began)) ms")
        } catch {
            AppLog.swallowed("system", "reading the system log", error)
        }
        since = until
    }

    struct Entry: Equatable {
        var subsystem: String
        var category: String
        var fault: Bool
        var message: String
    }

    /// What the frameworks repeat about every refused or closed connection after saying it once, and the
    /// accessibility bundles a Mac app never has: nothing in them a fix needs (seen on the Mac, 2026-10-29).
    static let noise = ["on unconnected nw_connection", "already failing, returning", "nw_path_necp_check_for_updates",
                        "cannot add handler to 0 from 0"]

    /// One line per distinct message (numbers and AppLog tags aside), in the order first seen, worded as it first came, with "(×N)"
    /// when it came more than once; at most `perRead`, then a line saying how many more there were.
    static func lines(_ entries: [Entry]) -> [String] {
        var order: [(key: String, line: String)] = []
        var counts: [String: Int] = [:]
        for entry in entries where entry.category != "AXLoading" && !noise.contains(where: entry.message.contains) {
            let source = entry.subsystem.isEmpty ? "(no subsystem)" : entry.subsystem + (entry.category.isEmpty ? "" : "/" + entry.category)
            let text = AppLog.scrub(entry.message).replacingOccurrences(of: "\n", with: " ⏎ ")
            let line = "\(source) \(entry.fault ? "fault" : "error"): \(text.count > maxMessage ? String(text.prefix(maxMessage)) + "…" : text)"
            let key = line.replacingOccurrences(of: #"#[0-9a-f]{6}\b|\d+"#, with: "#", options: .regularExpression)   // numbers, AppLog tags
            if counts[key] == nil { order.append((key, line)) }
            counts[key, default: 0] += 1
        }
        var out = order.prefix(perRead).map { counts[$0.key, default: 1] > 1 ? "\($0.line) (×\(counts[$0.key, default: 1]))" : $0.line }
        if order.count > perRead { out.append("\(order.count - perRead) more different system errors in this read") }
        return out
    }
}
