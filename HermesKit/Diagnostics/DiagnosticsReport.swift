// [diagnostics] What Settings › About › Diagnostics shows and what Copy Diagnostics copies, as pure functions over
// plain values: a port of the web app's `src/diagnostics-sheet.tsx` (docs/spec/3x-diagnostics.md §2–§4, §6). The page
// and the copied text are built from the same sections, so they can never disagree.

import Foundation

nonisolated enum DiagnosticsReport {
    /// A row: what the user reads, its value, and the raw metric name the copied report keeps for debugging.
    struct Row: Sendable, Equatable {
        var label: String
        var value: String
        var raw: String?
        init(_ label: String, _ value: String, _ raw: String? = nil) { self.label = label; self.value = value; self.raw = raw }
    }

    /// A titled run of rows under a section (the Gateway's reconnects, the kept daily reports).
    struct RowList: Sendable, Equatable {
        var title: String
        var rows: [Row]
        var empty: String
    }

    struct Section: Sendable, Equatable {
        var title: String
        var rows: [Row]
        var list: RowList?
        init(title: String, rows: [Row], list: RowList? = nil) { self.title = title; self.rows = rows; self.list = list }
    }

    /// One error message and how often it happened; `at` is its latest time.
    struct ErrorGroup: Sendable, Equatable {
        var message: String
        var count: Int
        var at: Date?
    }

    /// A named startup or connection step (`StartupTimings`): when it began (ms since the process started), how long
    /// it took, how it ended ("ok", "early", "cancelled" or a short failure code), and the clock time it began.
    struct Timing: Sendable, Equatable, Codable {
        var name: String
        var offsetMs: Double
        var durationMs: Double?
        var outcome: String?
        var at: Date?
    }

    /// A point in time by name ("app.foreground", "socket.open"…), ms since the process started.
    struct Mark: Sendable, Equatable {
        var name: String
        var atMs: Double
    }

    /// An iOS report kept as text (crash, hang, CPU, disk writes).
    struct NativeReport: Sendable, Equatable, Codable {
        var kind: String
        var at: Date
        var text: String
    }

    // MARK: Errors

    /// Recent errors, newest first, one bounded line each, repeats folded into one row. `entries` is oldest first.
    static func recentErrors(_ entries: [(message: String, at: Date?)], limit: Int = 20) -> [ErrorGroup] {
        var groups: [ErrorGroup] = []
        var index: [String: Int] = [:]
        for entry in entries.suffix(100).reversed() {
            let message = oneLine(DiagnosticRedactor.redact(entry.message), limit: 300)
            guard !message.isEmpty else { continue }
            if let at = index[message] {
                groups[at].count += 1
            } else {
                index[message] = groups.count
                groups.append(ErrorGroup(message: message, count: 1, at: entry.at))
            }
        }
        return Array(groups.prefix(limit))
    }

    /// Runs of white space become one space, the ends are trimmed, and the line is cut to `limit` UTF-16 units.
    static func oneLine(_ text: String, limit: Int) -> String {
        let joined = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard joined.utf16.count > limit else { return joined }
        return String(decoding: Array(joined.utf16.prefix(limit)), as: UTF16.self)
    }

    /// "×5 · last 4:03 AM": how often, and when last, if either is worth saying.
    static func errorMeta(_ group: ErrorGroup, time: (Date) -> String = clock) -> String {
        [group.count > 1 ? "×\(group.count)" : "", group.at.map { "last \(time($0))" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    static func clockSeconds(_ date: Date) -> String { date.formatted(date: .omitted, time: .standard) }
    static func dateTime(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) }

    static func iso(_ date: Date) -> String {
        // `Date.ISO8601FormatStyle` is a value type, so this is safe from any thread.
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    // MARK: Row titles

    private static let smallWords: Set<String> = ["a", "an", "and", "as", "at", "by", "for", "from", "in", "of", "on", "or",
                                                  "per", "the", "to", "vs", "with"]

    /// [mac] Stress test 2026-10-28 round 6: a row's label in Title Case, as every other Settings row on the Mac reads
    /// ("Open connections" → "Open Connections", "Most open at once" → "Most Open at Once"). Short joining words stay
    /// lower case unless they lead; a word that already has a capital or a digit ("macOS", "CPU") is left as it is, and
    /// each part of a hyphenated word is capitalised ("Sign-in" → "Sign-In"). The copied report keeps its own words.
    static func titleCase(_ label: String) -> String {
        var first = true
        return label.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            defer { if !word.isEmpty { first = false } }
            let text = String(word)
            if text.contains(where: { $0.isUppercase && $0 != text.first } ) || text.contains(where: \.isNumber) { return text }
            let bare = text.trimmingCharacters(in: .punctuationCharacters).lowercased()
            if !first, smallWords.contains(bare) { return text }
            return text.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: "-")
        }.joined(separator: " ")
    }

    // MARK: Gateway

    /// The connection counts in words, in the web app's order (`SOCKET_LABELS`; "Event listeners" is a page-side
    /// count and has no native equivalent).
    static func socketRows(_ stats: SocketStats.Counts) -> [Row] {
        [Row("Open connections", "\(stats.live)", "live"), Row("Gateway connections", "\(stats.gateway)", "gateway"),
         Row("Most open at once", "\(stats.peak)", "peak"), Row("Opened since launch", "\(stats.opened)", "opened"),
         Row("Reconnects since launch", "\(stats.reconnects)", "reconnects"), Row("Connection attempts", "\(stats.attempts)", "attempts"),
         Row("Messages too large to receive", "\(stats.tooBig)", "tooBig")]
    }

    private static let nativeLabels = [
        "native.loaded": "App launch", "native.restore": "Saved sign-in restore", "auth.total": "Sign-in, total",
        "auth.providers": "Sign-in options", "auth.resume": "Saved sign-in check", "auth.login": "Password sign-in",
        "auth.verify": "Sign-in check", "socket.ticket": "Connection ticket", "socket.handshake": "Connection handshake",
        "session": "Session setup",
    ]

    static func nativeLabel(_ name: String) -> String {
        if let label = nativeLabels[name] { return label }
        var text = name.hasPrefix("native.") ? String(name.dropFirst(7)) : name
        text = text.split(whereSeparator: { ".-_".contains($0) }).joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func isLaunch(_ name: String) -> Bool {
        name == "session" || ["native.", "auth.", "launch.", "renderer."].contains { name.hasPrefix($0) }
    }

    private static func succeeded(_ outcome: String?) -> Bool { outcome == nil || outcome == "ok" || outcome == "early" }
    private static func outcomeNote(_ outcome: String?) -> String {
        guard let outcome, outcome != "ok" else { return "" }
        return outcome == "early" ? " (asked early)" : " (\(outcome))"
    }

    private static func byOffset(_ entries: [Timing]) -> [Timing] {
        entries.enumerated().sorted { ($0.element.offsetMs, $0.offset) < ($1.element.offsetMs, $1.offset) }.map(\.element)
    }

    /// The launch's own connection is the first ticket and the handshake that follows it; everything else is later.
    static func splitConnections(_ entries: [Timing]) -> (launch: [Timing], later: [Timing]) {
        let sockets = byOffset(entries).filter { $0.name.hasPrefix("socket.") }
        guard let ticket = sockets.firstIndex(where: { $0.name == "socket.ticket" }) else { return ([], sockets) }
        var first = [ticket]
        if let handshake = sockets.indices.first(where: { $0 > ticket && sockets[$0].name == "socket.handshake" }),
           !sockets[(ticket + 1)..<handshake].contains(where: { $0.name == "socket.ticket" }) {
            first.append(handshake)
        }
        return (first.map { sockets[$0] }, sockets.indices.filter { !first.contains($0) }.map { sockets[$0] })
    }

    /// Startup rows: when the app was worth showing (`launch.ready`), then each named step of this launch.
    static func startupRows(marks: [Mark], entries: [Timing]) -> [Row] {
        var rows: [Row] = []
        if let ready = marks.first(where: { $0.name == "launch.ready" }) {
            rows.append(Row("App ready", "\(Int(ready.atMs.rounded())) ms", "launch.ready"))
        }
        let launch = byOffset(entries).filter { isLaunch($0.name) } + splitConnections(entries).launch
        for entry in launch {
            guard let duration = entry.durationMs else { continue }
            rows.append(Row(nativeLabel(entry.name), "\(Int(duration.rounded())) ms\(outcomeNote(entry.outcome))", "native \(entry.name)"))
        }
        return rows.isEmpty ? [Row("Startup", "Not recorded")] : rows
    }

    /// One reconnect: when it started (nil if the entry has no clock time) and how it went, in words.
    struct Reconnect: Sendable, Equatable {
        var at: Date?
        var outcome: String
    }

    private static func seconds(_ ms: Double?) -> String { String(format: "%.1f s", (ms ?? 0) / 1000) }

    /// Reconnect attempts after the launch, newest first.
    static func reconnects(_ entries: [Timing], limit: Int = 12) -> [Reconnect] {
        let later = splitConnections(entries).later
        var attempts: [Reconnect] = []
        var index = 0
        while index < later.count {
            let entry = later[index]
            let next = index + 1 < later.count ? later[index + 1] : nil
            if entry.name == "socket.ticket" {
                if !succeeded(entry.outcome) {
                    attempts.append(Reconnect(at: entry.at, outcome: "Failed: no connection ticket after \(seconds(entry.durationMs))\(entry.outcome == "cancelled" ? " (cancelled)" : "")"))
                } else if let next, next.name == "socket.handshake" {
                    index += 1
                    let outcome = (next.outcome ?? "ok") == "ok"
                        ? "Connected in \(Int(((entry.durationMs ?? 0) + (next.durationMs ?? 0)).rounded())) ms\(entry.outcome == "early" ? " (ticket asked early)" : "")"
                        : "Failed: handshake \(next.outcome ?? "") after \(seconds(next.durationMs))"
                    attempts.append(Reconnect(at: entry.at, outcome: outcome))
                } else {
                    attempts.append(Reconnect(at: entry.at, outcome: "Got a ticket; the connection didn’t open"))
                }
            } else {
                attempts.append(Reconnect(at: entry.at, outcome: (entry.outcome ?? "ok") == "ok"
                    ? "Handshake in \(Int((entry.durationMs ?? 0).rounded())) ms"
                    : "Failed: handshake \(entry.outcome ?? "") after \(seconds(entry.durationMs))"))
            }
            index += 1
        }
        return Array(attempts.reversed().prefix(limit))
    }

    static func reconnectRows(_ attempts: [Reconnect], time: (Date) -> String = clockSeconds) -> [Row] {
        attempts.map { Row($0.at.map(time) ?? "Time unknown", $0.outcome, $0.at.map(iso)) }
    }

    /// A return to the app and how it went: connected again `ms` after it (the first socket.open before the next
    /// return), the connection kept (back within the 20 s grace: no close, no open), or not connected yet.
    struct AppReturn: Sendable, Equatable {
        enum Outcome: Sendable, Equatable { case connected, kept, reconnecting }
        var atMs: Double
        var outcome: Outcome
        var ms: Double?
    }

    static func appReturns(_ marks: [Mark]) -> [AppReturn] {
        let web = marks.enumerated().sorted { ($0.element.atMs, $0.offset) < ($1.element.atMs, $1.offset) }.map(\.element)
        let returns = web.filter { $0.name == "app.foreground" }
        return returns.enumerated().map { index, mark in
            let until = index + 1 < returns.count ? returns[index + 1].atMs : Double.infinity
            if let open = web.first(where: { $0.name == "socket.open" && $0.atMs >= mark.atMs && $0.atMs < until }) {
                return AppReturn(atMs: mark.atMs, outcome: .connected, ms: open.atMs - mark.atMs)
            }
            let closed = web.contains { ($0.name == "socket.close" || $0.name == "socket.error") && $0.atMs >= mark.atMs - 2000 && $0.atMs < until }
            return AppReturn(atMs: mark.atMs, outcome: closed ? .reconnecting : .kept)
        }
    }

    /// The Gateway rows for the returns: how many, the median reconnect, how many kept their connection, and the last.
    static func returnRows(_ returns: [AppReturn]) -> [Row] {
        guard let last = returns.last else { return [] }
        let connected = returns.compactMap { $0.outcome == .connected ? ($0.ms ?? 0) : nil }.sorted()
        let kept = returns.filter { $0.outcome == .kept }.count
        var summary = ["\(returns.count)"]
        if !connected.isEmpty {
            summary.append("connected again in \(Int(connected[(connected.count - 1) / 2].rounded())) ms (median of \(connected.count))")
        }
        if kept > 0 { summary.append("\(kept) kept the connection") }
        let outcome = switch last.outcome {
        case .connected: "Connected in \(Int((last.ms ?? 0).rounded())) ms"
        case .kept: "Connection kept"
        case .reconnecting: "Not connected yet"
        }
        return [Row("Returns to the app", summary.joined(separator: " · "), "app.foreground"),
                Row("Last return", outcome, "app.foreground → socket.open")]
    }

    /// How the reconnects' session-list refreshes went. Nothing until a reconnect has refreshed the list.
    /// [perf-returns] `top`: refreshes that read the newest rows only (§11.5).
    static func sidebarProbeRows(probes: Int, skipped: Int, full: Int, top: Int = 0) -> [Row] {
        guard skipped + full + top > 0 else { return [] }
        return [Row("Session list on reconnect", "\(skipped) of \(skipped + full + top) unchanged, not re-read"
                    + (top > 0 ? " · \(top) top only" : "") + (probes > 0 ? " · \(probes) checked" : ""), "sidebar-probe")]
    }

    // MARK: Stability

    /// Stability of the installed build: counts with the last time each happened. `values` holds `<name>` counts
    /// and `<name>LastAt` epoch milliseconds, as `StabilityCounts` stores them.
    static func stabilityRows(_ values: [String: Double], time: (Date) -> String = dateTime) -> [Row] {
        func counted(_ key: String, _ label: String) -> Row {
            let count = Int(values[key] ?? 0)
            let last = values["\(key)LastAt"].map { Date(timeIntervalSince1970: $0 / 1000) }
            return Row(label, "\(count)\(count > 0 && last != nil ? " · last \(time(last!))" : "")", key)
        }
        var rows = [counted("crashes", "Crashes reported by \(DeviceWord.system)")]
        // Only once they have happened, so a healthy build's list stays short.
        for (key, label) in [("caughtCrashes", "Crashes caught by Hermes HQ"), ("mainHangs", "Hermes HQ stopped responding")]
        where (values[key] ?? 0) > 0 {
            rows.append(counted(key, label))
        }
        if let longest = values["mainHangLongestSeconds"], longest > 0 {
            rows.append(Row("Longest unresponsive stretch", "\(number(longest)) s", "mainHangLongestSeconds"))
        }
        for (key, label) in [("cpuExceptions", "CPU limit reports"), ("diskWriteExceptions", "Disk write reports")] where (values[key] ?? 0) > 0 {
            rows.append(counted(key, label))
        }
        let alerts = [("opened", "Alerts opened"), ("noFace", "Alerts opened without the bot’s face"),
                      ("locked", "Alerts unread: phone not yet unlocked"), ("noKey", "Alerts unread: no key on this phone"),
                      ("unreadable", "Alerts unread: damaged"), ("expired", "Alerts unread: \(DeviceWord.system)’s time ran out")]
        for (key, label) in alerts where (values["alerts.\(key)"] ?? 0) > 0 { rows.append(counted("alerts.\(key)", label)) }
        if let hangs = values["hangCount"] { rows.append(Row("Hangs, last \(DeviceWord.system) daily report", "\(Int(hangs))", "hangCount")) }
        if let memory = values["peakMemoryBytes"] { rows.append(Row("Peak memory, last \(DeviceWord.system) daily report", megabytes(memory), "peakMemoryBytes")) }
        return rows
    }

    // MARK: Smoothness (FrameMeter)

    private static let momentLabels = [("scroll", "Scrolling"), ("keyboard", "Keyboard"), ("chat.open", "Opening a chat"),
                                       ("push", "Opening a page"), ("pop", "Going back"), ("present", "Sheets"),
                                       ("fold", "Opening a project")]

    /// [diagnostics] This run's moments per kind: how many, the median and 90th-percentile hitch ratio (ms of hitch
    /// per second of motion; under 5 is smooth) and the worst frame.
    static func smoothnessRows(_ totals: [FrameBook.Total]) -> [Row] {
        let rows = momentLabels.compactMap { kind, label -> Row? in
            guard let total = totals.first(where: { $0.kind == kind }), total.moments > 0 else { return nil }
            let median = FrameMath.short(FrameMath.median(total.hitchRatios)), p90 = FrameMath.short(FrameMath.quantile(total.hitchRatios, 0.9))
            return Row(label, "\(total.moments) · \(median) ms/s, 90% under \(p90) · worst \(Int(total.worstMs.rounded())) ms", "frames.\(kind)")
        }
        return rows.isEmpty ? [Row("Measured", "Nothing yet", "frames")] : rows
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }

    // MARK: Field metrics (MetricKit daily summaries)

    /// One kept daily summary: its UTC day, the build it describes, when it arrived and its numbers.
    struct FieldEntry: Sendable, Equatable, Codable {
        var day: String
        var build: String
        var at: Date
        var values: [String: Double]
    }

    /// The kept summaries, oldest first, the last seven.
    static func fieldHistory(_ entries: [FieldEntry]) -> [FieldEntry] {
        let clean = entries.map { entry in
            var copy = entry
            copy.values = entry.values.filter { $0.value.isFinite }
            return copy
        }
        return Array(clean.sorted { $0.day == $1.day ? $0.at < $1.at : $0.day < $1.day }.suffix(7))
    }

    static func megabytes(_ bytes: Double) -> String { "\(Int((bytes / 1_048_576).rounded())) MB" }

    private static let launchBandNames = [("under500ms", "under 0.5 s"), ("500to1000ms", "0.5–1 s"), ("1000to2000ms", "1–2 s"),
                                          ("2000to4000ms", "2–4 s"), ("over4000ms", "over 4 s")]

    private static func launchBands(_ values: [String: Double], _ prefix: String) -> String? {
        let parts = launchBandNames.compactMap { key, label in
            (values["\(prefix).\(key)"] ?? 0) != 0 ? "\(Int(values["\(prefix).\(key)"]!)) \(label)" : nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Exit reasons worth a row, in the words a tester understands; zero counts are left out.
    static let exits = [
        ("exits.foreground.memoryLimit", "Closed by \(DeviceWord.system) for memory, in use"), ("exits.background.memoryLimit", "Closed by \(DeviceWord.system) for memory, in background"),
        ("exits.background.memoryPressure", "Closed by \(DeviceWord.system) under memory pressure"),
        ("exits.foreground.watchdog", "Closed by \(DeviceWord.system) for not responding (watchdog)"), ("exits.background.watchdog", "Closed by \(DeviceWord.system) for not responding, in background"),
        ("exits.foreground.abnormal", "Abnormal exits, in use"), ("exits.background.abnormal", "Abnormal exits, in background"),
        ("exits.foreground.badAccess", "Crashes (bad memory access), in use"), ("exits.background.badAccess", "Crashes (bad memory access), in background"),
        ("exits.foreground.illegalInstruction", "Crashes (illegal instruction), in use"), ("exits.background.illegalInstruction", "Crashes (illegal instruction), in background"),
        ("exits.background.taskTimeout", "Background task ran out of time"), ("exits.background.lockedFile", "Suspended with a locked file"),
    ]

    /// One kept day in a line: what a tester would want to know first.
    static func fieldSummary(_ values: [String: Double]) -> String {
        var parts: [String] = []
        if let peak = values["peakMemoryBytes"] { parts.append("peak \(megabytes(peak))") }
        if let hangs = values["hangCount"] { parts.append("\(Int(hangs)) hang\(hangs == 1 ? "" : "s")") }
        let forced = Int(exits.reduce(0) { $0 + (values[$1.0] ?? 0) } - (values["exits.background.taskTimeout"] ?? 0) - (values["exits.background.lockedFile"] ?? 0))
        if forced != 0 { parts.append("\(forced) forced exit\(forced == 1 ? "" : "s")") }
        if let crashes = values["diag.crashes"], crashes != 0 { parts.append("\(Int(crashes)) crash report\(crashes == 1 ? "" : "s")") }
        if let hitches = values["scrollHitchMsPerSecond"] { parts.append("hitches \(String(format: "%.1f", hitches)) ms/s") }
        return parts.isEmpty ? "diagnostics only" : parts.joined(separator: " · ")
    }

    /// The latest daily iOS summary for the installed build (or the newest kept one), with each kept day under it.
    static func fieldSection(_ entries: [FieldEntry], build: String?) -> Section {
        let summaries = entries.filter { $0.values["windowSeconds"] != nil }
        let latest = summaries.last { build == nil || $0.build == build } ?? summaries.last
        let list = RowList(title: "Kept daily reports",
                           rows: entries.reversed().map { Row("\($0.day) · build \($0.build)", fieldSummary($0.values), "\($0.day) build \($0.build)") },
                           empty: "None yet: \(DeviceWord.system) sends the first summary about a day after install")
        guard let latest else { return Section(title: "Field metrics, from \(DeviceWord.system)", rows: [Row("Daily summary", "Not received yet")], list: list) }
        let values = latest.values
        var rows = [Row("Report day", "\(latest.day)\(build != nil && latest.build != build ? " (build \(latest.build))" : "")")]
        if let v = values["peakMemoryBytes"] { rows.append(Row("Peak memory", megabytes(v), "peakMemoryBytes")) }
        if let v = values["suspendedMemoryBytes"] { rows.append(Row("Memory while suspended, average", megabytes(v), "suspendedMemoryBytes")) }
        if let v = values["hangCount"] {
            let total = values["hangSeconds"] ?? 0
            rows.append(Row("Hangs", "\(Int(v))\(total != 0 ? " · \(String(format: "%.1f", total)) s in all" : "")", "hangCount"))
        }
        if let v = values["scrollHitchMsPerSecond"] { rows.append(Row("Scroll hitches", "\(String(format: "%.1f", v)) ms per second of scrolling", "scrollHitchMsPerSecond")) }
        if let v = values["cpuSeconds"] { rows.append(Row("CPU time", "\(Int(v.rounded())) s", "cpuSeconds")) }
        if let bands = launchBands(values, "launch.firstDraw") { rows.append(Row("Launches, time to first draw", bands, "launch.firstDraw")) }
        if let bands = launchBands(values, "launch.extended") { rows.append(Row("Launches, until usable", bands, "launch.extended")) }
        if let bands = launchBands(values, "launch.resume") { rows.append(Row("Returns from background, time to resume", bands, "launch.resume")) }
        for (key, label) in exits where (values[key] ?? 0) != 0 { rows.append(Row(label, "\(Int(values[key]!))", key)) }
        if values["exits.foreground.normal"] != nil || values["exits.background.normal"] != nil {
            rows.append(Row("Normal exits", "\(Int((values["exits.foreground.normal"] ?? 0) + (values["exits.background.normal"] ?? 0)))", "exits.normal"))
        }
        return Section(title: "Field metrics, from \(DeviceWord.system)", rows: rows, list: list)
    }

    /// iOS's reports for this build, newest first, the last three.
    static func nativeReports(_ reports: [NativeReport]) -> [NativeReport] { Array(reports.suffix(3).reversed()) }

    // MARK: Copy Diagnostics

    /// Plain text for a bug report: friendly labels with the raw metric names beside them, and full error times.
    /// Redacted line by line: a stray quote or a trailing key in one error must not swallow the lines after it.
    static func text(sections: [Section], errors: [ErrorGroup], earlier: [ErrorGroup] = [], reports: [NativeReport] = [], now: Date = Date()) -> String {
        var lines = ["Hermes HQ diagnostics", iso(now), ""]
        for section in sections {
            lines.append(section.title)
            for row in section.rows {
                lines.append("  \(row.label)\(row.raw != nil && row.raw != row.label ? " [\(row.raw!)]" : ""): \(row.value)")
            }
            if let list = section.list {
                lines.append("  \(list.title):")
                lines += list.rows.isEmpty ? ["    \(list.empty)"] : list.rows.map { "    \($0.raw ?? $0.label): \($0.value)" }
            }
            lines.append("")
        }
        func line(_ group: ErrorGroup) -> String {
            let meta = errorMeta(group, time: iso)
            return "  \(group.message)\(meta.isEmpty ? "" : " (\(meta))")"
        }
        lines.append("Recent errors (\(errors.reduce(0) { $0 + $1.count }))")
        lines += errors.isEmpty ? ["  None since launch"] : errors.map(line)
        if !earlier.isEmpty {
            lines += ["", "Before the last launch (\(earlier.reduce(0) { $0 + $1.count }))"]
            lines += earlier.map(line)
        }
        for report in reports {
            lines += ["", "\(DeviceWord.system) report: \(report.kind), \(iso(report.at))"]
            lines += report.text.components(separatedBy: "\n").dropFirst().map { "  \($0)" }
        }
        return lines.map(DiagnosticRedactor.redact).joined(separator: "\n")
    }
}
