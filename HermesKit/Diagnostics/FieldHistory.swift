// [diagnostics] MetricKit's daily summaries and iOS's own reports, kept on disk (the web shell's `DispatchFieldHistory`
// and `DispatchCrashLog`, `ios/App/App/AppDelegate.swift`). iOS hands a daily summary to whichever process is running,
// usually one that is gone before Diagnostics is opened, so each summary is kept: one entry per day and build, the
// newest seven. The last three reports for the installed build (crash, hang, CPU limit, disk writes) are kept as short
// text: what happened, then the stack iOS attributes it to. Numbers and frame offsets only; nothing leaves the phone
// unless Copy Diagnostics is used.

import Foundation

nonisolated enum FieldHistory {
    static let kept = 7
    typealias Entry = DiagnosticsReport.FieldEntry

    struct Bucket: Sendable, Equatable {
        var startMs: Double
        var endMs: Double
        var count: Int
    }

    private struct Saved: Codable { var entries: [Entry] }

    static var file: URL { directory.appendingPathComponent("field-metrics.json") }
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private static let lock = NSLock()

    /// A payload's day as `yyyy-MM-dd`, UTC (its own key, whatever the phone's calendar or zone).
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// A day's entry for `build` takes `values`: a repeated daily summary replaces its figures, while `diag.` counts
    /// (several diagnostic payloads can arrive in one day) add up. The newest `kept` entries stay, by day then arrival.
    static func record(_ values: [String: Double], day: String, build: String, at: Date = Date(), file: URL = FieldHistory.file) {
        guard !values.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var saved = read(file)
        if let index = saved.entries.firstIndex(where: { $0.day == day && $0.build == build }) {
            var entry = saved.entries.remove(at: index)
            entry.at = at
            for (key, value) in values { entry.values[key] = key.hasPrefix("diag.") ? (entry.values[key] ?? 0) + value : value }
            saved.entries.append(entry)
        } else {
            saved.entries.append(Entry(day: day, build: build, at: at, values: values))
        }
        saved.entries.sort { $0.day == $1.day ? $0.at < $1.at : $0.day < $1.day }
        saved.entries = Array(saved.entries.suffix(kept))
        write(saved, to: file)
    }

    /// Every kept entry, oldest first.
    static func saved(file: URL = FieldHistory.file) -> [Entry] { read(file).entries }

    /// The newest daily summary for `build` (not a diagnostics-only day), for Stability's hang and memory rows.
    static func latest(build: String, file: URL = FieldHistory.file) -> [String: Double] {
        read(file).entries.last { $0.build == build && $0.values["windowSeconds"] != nil }?.values ?? [:]
    }

    private static func read(_ file: URL) -> Saved {
        guard let data = try? Data(contentsOf: file) else { return Saved(entries: []) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode(Saved.self, from: data)) ?? Saved(entries: [])
    }

    private static func write(_ saved: Saved, to file: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(saved).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// A launch histogram as five coarse counts (`prefix.under500ms` … `prefix.over4000ms`), each MetricKit bucket
    /// counted where its midpoint falls. Empty buckets add nothing, so a day without launches has no launch keys.
    static let launchBands: [(key: String, belowMs: Double)] = [("under500ms", 500), ("500to1000ms", 1000), ("1000to2000ms", 2000),
                                                                ("2000to4000ms", 4000), ("over4000ms", .infinity)]

    static func launchBuckets(_ prefix: String, _ buckets: [Bucket]) -> [String: Double] {
        var values: [String: Double] = [:]
        for bucket in buckets where bucket.count > 0 {
            let midpoint = (bucket.startMs + bucket.endMs) / 2
            let band = launchBands.first { midpoint < $0.belowMs } ?? launchBands[launchBands.count - 1]
            values["\(prefix).\(band.key)", default: 0] += Double(bucket.count)
        }
        return values
    }

    /// Hang count and total seconds from a hang-time histogram (each bucket at its midpoint).
    static func hangs(_ buckets: [Bucket]) -> (count: Double, seconds: Double) {
        (Double(buckets.reduce(0) { $0 + $1.count }), buckets.reduce(0) { $0 + Double($1.count) * ($1.startMs + $1.endMs) / 2000 })
    }

    #if DEBUG
    /// `-HQDebugFieldFixture week`: seven made-up days and three reports, so the page's sections can be seen on a
    /// simulator (MetricKit delivers nothing there).
    static func seedFixture(build: String, now: Date = Date()) {
        for back in (0..<7).reversed() {
            let date = now.addingTimeInterval(-Double(back + 1) * 86_400)
            var values: [String: Double] = ["windowSeconds": 86_400, "peakMemoryBytes": Double(200 + back * 3) * 1_048_576,
                                           "suspendedMemoryBytes": 61 * 1_048_576, "hangCount": Double(back % 3), "hangSeconds": Double(back % 3) * 0.6,
                                           "scrollHitchMsPerSecond": 1.2 + Double(back) / 10, "cpuSeconds": 412,
                                           "launch.firstDraw.under500ms": 3, "launch.firstDraw.500to1000ms": 1, "launch.resume.under500ms": 9,
                                           "exits.foreground.normal": 1, "exits.background.normal": 4]
            if back == 2 { values["exits.background.memoryLimit"] = 1 }
            record(values, day: day(date), build: build, at: date)
        }
        let frames = (0..<4).map { "    \($0) HermesHQNative +0x\(String(0x1a2b0 + $0 * 0x40, radix: 16))" }.joined(separator: "\n")
        CrashLog.replace([
            CrashLog.Entry(kind: "Crash", at: now.addingTimeInterval(-90_000), text: "Crash\n  build: \(build)\n  exception type: 1\n  signal: 11\n  Thread:\n\(frames)"),
            CrashLog.Entry(kind: "Hang", at: now.addingTimeInterval(-50_000), text: "Hang\n  build: \(build)\n  hang: 2.4 sec\n  Thread:\n\(frames)"),
            CrashLog.Entry(kind: "CPU limit", at: now.addingTimeInterval(-4_000), text: "CPU limit\n  build: \(build)\n  CPU time: 91 sec\n  Thread:\n\(frames)"),
        ], build: build)
    }
    #endif
}

/// The last three reports iOS gave the installed build, as short text.
nonisolated enum CrashLog {
    static let kept = 3, frames = 40, limit = 8 * 1024
    typealias Entry = DiagnosticsReport.NativeReport

    private struct Saved: Codable {
        var build: String
        var entries: [Entry]
    }

    static var file: URL { FieldHistory.directory.appendingPathComponent("reports.json") }
    private static let lock = NSLock()

    /// One report as text: its kind and metadata, then the attributed thread's frames (the heaviest path of a hang's
    /// sampled tree), at most `frames` of them and `limit` bytes in all.
    static func summary(kind: String, json: Data, at: Date) -> Entry {
        let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        let meta = object["diagnosticMetaData"] as? [String: Any] ?? [:]
        var lines = [kind]
        let about = ["appBuildVersion": "build", "osVersion": DeviceWord.system, "deviceType": "device", "exceptionType": "exception type",
                     "exceptionCode": "exception code", "signal": "signal", "terminationReason": "termination", "hangDuration": "hang",
                     "totalCPUTime": "CPU time", "totalSampledTime": "sampled", "writesCaused": "writes"]
        for key in about.keys.sorted() { if let value = meta[key] { lines.append("  \(about[key]!): \(value)") } }
        let tree = object["callStackTree"] as? [String: Any] ?? [:]
        let stacks = tree["callStacks"] as? [[String: Any]] ?? []
        if let stack = stacks.first(where: { $0["threadAttributed"] as? Bool == true }) ?? stacks.first {
            lines.append(stacks.count > 1 ? "  Thread (attributed of \(stacks.count)):" : "  Thread:")
            var level = stack["callStackRootFrames"] as? [[String: Any]] ?? []
            var index = 0
            while index < frames, let frame = level.max(by: { ($0["sampleCount"] as? Int ?? 0) < ($1["sampleCount"] as? Int ?? 0) }) {
                let offset = (frame["offsetIntoBinaryTextSegment"] as? NSNumber)?.int64Value ?? 0
                lines.append("    \(index) \(frame["binaryName"] as? String ?? "?") +0x\(String(offset, radix: 16))")
                level = frame["subFrames"] as? [[String: Any]] ?? []
                index += 1
            }
        }
        var text = lines.joined(separator: "\n")
        if text.utf8.count > limit { text = String(decoding: text.utf8.prefix(limit), as: UTF8.self) + "\n  …" }
        return Entry(kind: kind, at: at, text: text)
    }

    /// The newest `kept` of this build's reports: an earlier build's go.
    static func keep(_ entries: [Entry], build: String, file: URL = CrashLog.file) {
        guard !entries.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var saved = read(file).flatMap { $0.build == build ? $0 : nil } ?? Saved(build: build, entries: [])
        saved.entries = Array((saved.entries + entries).suffix(kept))
        write(saved, to: file)
    }

    static func replace(_ entries: [Entry], build: String, file: URL = CrashLog.file) {
        lock.lock(); defer { lock.unlock() }
        write(Saved(build: build, entries: Array(entries.suffix(kept))), to: file)
    }

    /// This build's kept reports, newest last.
    static func saved(build: String, file: URL = CrashLog.file) -> [Entry] {
        guard let saved = read(file), saved.build == build else { return [] }
        return saved.entries
    }

    private static func read(_ file: URL) -> Saved? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(Saved.self, from: data)
    }

    private static func write(_ saved: Saved, to file: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(saved).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
