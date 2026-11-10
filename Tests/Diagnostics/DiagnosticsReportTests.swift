import Foundation
import Testing
@testable import HermesHQNative

/// The pure rows behind Settings › About › Diagnostics and Copy Diagnostics: the cases of the web app's
/// `src/diagnostics-sheet.test.ts` that apply to native (docs/spec/3x-diagnostics.md §2–§4, §6).
@Suite struct DiagnosticsReportTests {
    typealias R = DiagnosticsReport
    private func utc(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        var parts = DateComponents(); parts.year = 2026; parts.month = 9; parts.day = 27; parts.hour = h; parts.minute = m; parts.second = s
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: parts)!
    }
    private func hhmm(_ date: Date) -> String { String(R.iso(date).dropFirst(11).prefix(5)) }

    // MARK: Errors

    @Test func listsRecentErrorsNewestFirstOneBoundedLineEach() {
        let errors = (0..<25).map { (message: "TypeError: failure \($0)\n  at stack", at: Date?.none) }
        let shown = R.recentErrors(errors)
        #expect(shown.count == 20)
        #expect(shown.first == R.ErrorGroup(message: "TypeError: failure 24 at stack", count: 1, at: nil))
        #expect(shown.last?.message == "TypeError: failure 5 at stack")
        #expect(R.recentErrors([("Error: " + String(repeating: "x ", count: 250), nil)])[0].message.utf16.count == 300)
        #expect(R.recentErrors([]).isEmpty)
        #expect(R.recentErrors([("", nil), ("  ", nil)]).isEmpty)
        #expect(R.recentErrors([("Error: " + String(repeating: "x ", count: 100_000), nil)])[0].message.utf16.count <= 300)
    }

    @Test func foldsRepeatsIntoOneRowWithACountAndTheLatestTime() {
        let failed = "Error: Gateway connection failed (code -1001). The request timed out."
        let first = utc(4, 1), last = utc(4, 3)
        let groups = R.recentErrors([(failed, first), ("TypeError: boom", nil), (failed, nil), (failed, nil), (failed, nil), (failed, last)])
        #expect(groups == [R.ErrorGroup(message: failed, count: 5, at: last), R.ErrorGroup(message: "TypeError: boom", count: 1, at: nil)])
        #expect(R.errorMeta(groups[0], time: hhmm) == "×5 · last 04:03")
        #expect(R.errorMeta(groups[1], time: hhmm) == "")
        #expect(R.errorMeta(R.ErrorGroup(message: "x", count: 1, at: last), time: hhmm) == "last 04:03")
        #expect(R.errorMeta(R.ErrorGroup(message: "x", count: 5, at: nil), time: hhmm) == "×5")
    }

    @Test func redactsBeforeGroupingDatingAndBounding() {
        #expect(R.recentErrors([("Error: password=FAKE-first", nil), ("Error: password=FAKE-second", nil), ("Error: password=FAKE-third", nil)])
                == [R.ErrorGroup(message: "Error: password=[redacted]", count: 3, at: nil)])
        let prefix = String(repeating: "x", count: 280) + " password="
        let message = R.recentErrors([(prefix + "FAKE-secret-straddles-the-boundary", nil)])[0].message
        #expect(message == prefix + "[redacted]")
        #expect(message.utf16.count <= 300)
    }

    // MARK: Gateway

    @Test func socketCountsReadInWordsWithTheirRawNames() {
        var counts = SocketStats.Counts()
        counts.live = 1; counts.gateway = 1; counts.peak = 2; counts.opened = 3; counts.reconnects = 2; counts.attempts = 4
        let rows = R.socketRows(counts)
        #expect(rows.map(\.label) == ["Open connections", "Gateway connections", "Most open at once", "Opened since launch",
                                      "Reconnects since launch", "Connection attempts", "Messages too large to receive"])
        #expect(rows.map(\.raw) == ["live", "gateway", "peak", "opened", "reconnects", "attempts", "tooBig"])
        #expect(R.text(sections: [.init(title: "Gateway", rows: rows)], errors: []).contains("  Connection attempts [attempts]: 4"))
    }

    /// [mac] Stress test 2026-10-28 round 6: the Mac's page shows the rows' labels in Title Case.
    @Test func rowLabelsReadInTitleCase() {
        #expect(R.titleCase("Open connections") == "Open Connections")
        #expect(R.titleCase("Most open at once") == "Most Open at Once")
        #expect(R.titleCase("Messages too large to receive") == "Messages Too Large to Receive")
        #expect(R.titleCase("Hangs, last macOS daily report") == "Hangs, Last macOS Daily Report")
        #expect(R.titleCase("Sign-in, total") == "Sign-In, Total")
        #expect(R.titleCase("CPU time") == "CPU Time")
        #expect(R.titleCase("Version") == "Version")
    }

    @Test func socketStatsCountOpensClosesAndReconnects() {
        let stats = SocketStats()
        stats.attempt(); stats.opened(gateway: true)
        stats.attempt(); stats.opened(gateway: false)
        #expect(stats.counts == .init(live: 2, gateway: 1, peak: 2, opened: 2, reconnects: 0, attempts: 2, tooBig: 0))
        stats.closed(gateway: true)
        stats.attempt(); stats.opened(gateway: true)
        stats.closed(gateway: false); stats.tooBig()
        #expect(stats.counts == .init(live: 1, gateway: 1, peak: 2, opened: 3, reconnects: 1, attempts: 3, tooBig: 1))
        stats.closed(gateway: true); stats.closed(gateway: true)
        #expect(stats.counts.live == 0 && stats.counts.gateway == 0, "never below zero")
    }

    private var mixed: [R.Timing] {
        [.init(name: "socket.ticket", offsetMs: 500_200, durationMs: 8004, outcome: "failed", at: utc(9, 8, 20)),
         .init(name: "socket.ticket", offsetMs: 3487, durationMs: 260, outcome: "ok", at: utc(9, 0, 3)),
         .init(name: "socket.ticket", offsetMs: 520_000, durationMs: 250, outcome: "ok", at: utc(9, 8, 40)),
         .init(name: "native.loaded", offsetMs: 0, durationMs: 188, outcome: "ok"),
         .init(name: "socket.handshake", offsetMs: 3747, durationMs: 101, outcome: "ok"),
         .init(name: "auth.resume", offsetMs: 944, durationMs: 278, outcome: "ok"),
         .init(name: "socket.handshake", offsetMs: 520_250, durationMs: 110, outcome: "ok"),
         .init(name: "auth.total", offsetMs: 940, durationMs: 286, outcome: "ok"),
         .init(name: "native.restore", offsetMs: 892, durationMs: 334, outcome: "ok")]
    }

    @Test func startupKeepsTheLaunchRowsWhateverTheBufferOrderWithOnlyTheFirstConnection() {
        let rows = R.startupRows(marks: [.init(name: "launch.ready", atMs: 1371.2)], entries: mixed)
        #expect(rows.map { "\($0.label): \($0.value)" } == ["App ready: 1371 ms", "App launch: 188 ms", "Saved sign-in restore: 334 ms",
                                                            "Sign-in, total: 286 ms", "Saved sign-in check: 278 ms",
                                                            "Connection ticket: 260 ms", "Connection handshake: 101 ms"])
        #expect(rows.map(\.raw) == ["launch.ready", "native native.loaded", "native native.restore", "native auth.total", "native auth.resume",
                                    "native socket.ticket", "native socket.handshake"])
        #expect(R.startupRows(marks: [], entries: []) == [R.Row("Startup", "Not recorded")])
        let odd = R.startupRows(marks: [], entries: [.init(name: "native.loaded", offsetMs: 0, durationMs: 40.2, outcome: "ok"),
                                                     .init(name: "socket.ticket", offsetMs: 5, durationMs: 88, outcome: "cancelled"),
                                                     .init(name: "auth.new-step", offsetMs: 9, durationMs: 3)])
        #expect(odd.map { "\($0.label): \($0.value)" } == ["App launch: 40 ms", "Auth new step: 3 ms", "Connection ticket: 88 ms (cancelled)"])
    }

    @Test func listsLaterReconnectsNewestFirstWithClockTimeAndOutcome() {
        let attempts = R.reconnects(mixed)
        #expect(attempts == [.init(at: utc(9, 8, 40), outcome: "Connected in 360 ms"),
                             .init(at: utc(9, 8, 20), outcome: "Failed: no connection ticket after 8.0 s")])
        let rows = R.reconnectRows(attempts) { String(R.iso($0).dropFirst(11).prefix(8)) }
        #expect(rows == [R.Row("09:08:40", "Connected in 360 ms", "2026-09-27T09:08:40.000Z"),
                         R.Row("09:08:20", "Failed: no connection ticket after 8.0 s", "2026-09-27T09:08:20.000Z")])
        #expect(R.reconnects([mixed[1]]).isEmpty)
        #expect(R.reconnects([]).isEmpty)
        #expect(R.reconnectRows([.init(at: nil, outcome: "Handshake in 5 ms")]) == [R.Row("Time unknown", "Handshake in 5 ms", nil)])
    }

    @Test func aTicketAskedEarlyIsASuccessAndOtherEndingsReadInWords() {
        let entries: [R.Timing] = [
            .init(name: "native.loaded", offsetMs: 0, durationMs: 100, outcome: "ok"),
            .init(name: "socket.ticket", offsetMs: 900, durationMs: 4, outcome: "early"), .init(name: "socket.handshake", offsetMs: 904, durationMs: 40, outcome: "ok"),
            .init(name: "socket.ticket", offsetMs: 60_000, durationMs: 0, outcome: "early"), .init(name: "socket.handshake", offsetMs: 60_000, durationMs: 55, outcome: "ok"),
            .init(name: "socket.ticket", offsetMs: 70_000, durationMs: 30, outcome: "ok"), .init(name: "socket.handshake", offsetMs: 70_030, durationMs: 8000, outcome: "timeout"),
            .init(name: "socket.ticket", offsetMs: 80_000, durationMs: 30, outcome: "ok"),
            .init(name: "socket.ticket", offsetMs: 90_000, durationMs: 1200, outcome: "cancelled"),
        ]
        #expect(R.startupRows(marks: [], entries: entries).map { "\($0.label): \($0.value)" }
                == ["App launch: 100 ms", "Connection ticket: 4 ms (asked early)", "Connection handshake: 40 ms"])
        #expect(R.reconnects(entries).map(\.outcome) == ["Failed: no connection ticket after 1.2 s (cancelled)", "Got a ticket; the connection didn’t open",
                                                          "Failed: handshake timeout after 8.0 s", "Connected in 55 ms (ticket asked early)"])
    }

    @Test func copiesTheReconnectsUnderTheGatewaySection() {
        let list = R.RowList(title: "Recent reconnects", rows: R.reconnectRows(R.reconnects(mixed)) { _ in "x" }, empty: "None since launch")
        let text = R.text(sections: [.init(title: "Gateway", rows: [R.Row("Address", "100.101.102.103:9119")], list: list)], errors: [])
        #expect(text.contains("Gateway\n  Address: 100.101.102.103:9119\n  Recent reconnects:\n    2026-09-27T09:08:40.000Z: Connected in 360 ms\n    2026-09-27T09:08:20.000Z: Failed: no connection ticket after 8.0 s"))
        let empty = R.text(sections: [.init(title: "Gateway", rows: [], list: .init(title: "Recent reconnects", rows: [], empty: "None since launch"))], errors: [])
        #expect(empty.contains("  Recent reconnects:\n    None since launch"))
    }

    @Test func sessionListOnReconnect() {
        #expect(R.sidebarProbeRows(probes: 5, skipped: 4, full: 2) == [R.Row("Session list on reconnect", "4 of 6 unchanged, not re-read · 5 checked", "sidebar-probe")])
        #expect(R.sidebarProbeRows(probes: 0, skipped: 0, full: 0).isEmpty)
        #expect(R.sidebarProbeRows(probes: 0, skipped: 1, full: 0).first?.value == "1 of 1 unchanged, not re-read")
        #expect(R.sidebarProbeRows(probes: 3, skipped: 1, full: 0, top: 2).first?.value == "1 of 3 unchanged, not re-read · 2 top only · 3 checked")
    }

    @Test func returnsToTheApp() {
        let web: [R.Mark] = [
            .init(name: "socket.open", atMs: 900),
            // Back after a long background: the socket closed just before the mark; connected 640 ms after the return.
            .init(name: "socket.close", atMs: 60_000), .init(name: "app.foreground", atMs: 60_004), .init(name: "socket.open", atMs: 60_644),
            // Back within the 20 s grace: nothing closed, nothing opened.
            .init(name: "app.background", atMs: 90_000), .init(name: "app.foreground", atMs: 95_000),
            // The close reported just after the mark, then a slower reconnect.
            .init(name: "app.foreground", atMs: 200_000), .init(name: "socket.close", atMs: 200_010), .init(name: "socket.error", atMs: 200_400),
            .init(name: "socket.open", atMs: 201_200),
            // The latest return has not reconnected yet.
            .init(name: "socket.close", atMs: 299_500), .init(name: "app.foreground", atMs: 300_000),
        ]
        let returns = R.appReturns(web)
        #expect(returns.map(\.outcome) == [.connected, .kept, .connected, .reconnecting])
        #expect(returns.compactMap(\.ms) == [640, 1200])
        #expect(R.returnRows(returns) == [R.Row("Returns to the app", "4 · connected again in 640 ms (median of 2) · 1 kept the connection", "app.foreground"),
                                          R.Row("Last return", "Not connected yet", "app.foreground → socket.open")])
        #expect(R.returnRows(Array(returns.prefix(2))).last?.value == "Connection kept")
        #expect(R.returnRows(Array(returns.prefix(1))) == [R.Row("Returns to the app", "1 · connected again in 640 ms (median of 1)", "app.foreground"),
                                                           R.Row("Last return", "Connected in 640 ms", "app.foreground → socket.open")])
        #expect(R.returnRows([]).isEmpty)
    }

    // MARK: Stability and field metrics

    @Test func stabilityShowsCrashesAlwaysAndTheRestOnlyOnceTheyHappened() {
        #expect(R.stabilityRows([:]) == [R.Row("Crashes reported by iOS", "0", "crashes")])
        let at = utc(4, 3).timeIntervalSince1970 * 1000
        let rows = R.stabilityRows(["crashes": 2, "crashesLastAt": at, "caughtCrashes": 1, "mainHangs": 3, "mainHangLongestSeconds": 2.5,
                                    "cpuExceptions": 1, "alerts.opened": 7, "alerts.noKey": 1, "hangCount": 4, "peakMemoryBytes": 212 * 1_048_576],
                                   time: hhmm)
        #expect(rows.map { "\($0.label) [\($0.raw ?? "")]: \($0.value)" } == [
            "Crashes reported by iOS [crashes]: 2 · last 04:03", "Crashes caught by Hermes HQ [caughtCrashes]: 1",
            "Hermes HQ stopped responding [mainHangs]: 3", "Longest unresponsive stretch [mainHangLongestSeconds]: 2.5 s",
            "CPU limit reports [cpuExceptions]: 1", "Alerts opened [alerts.opened]: 7", "Alerts unread: no key on this phone [alerts.noKey]: 1",
            "Hangs, last iOS daily report [hangCount]: 4", "Peak memory, last iOS daily report [peakMemoryBytes]: 212 MB"])
    }

    @Test func stabilityCountsAreKeptPerBuild() {
        let suite = "diag-stability-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        StabilityCounts.count("crashes", at: at, defaults: defaults, build: "251")
        StabilityCounts.count("crashes", by: 2, at: at, defaults: defaults, build: "251")
        StabilityCounts.count("crashes", by: 0, defaults: defaults, build: "251")
        StabilityCounts.raise("mainHangLongestSeconds", to: 2.5, defaults: defaults, build: "251")
        StabilityCounts.raise("mainHangLongestSeconds", to: 1.0, defaults: defaults, build: "251")
        let values = StabilityCounts.values(defaults: defaults, build: "251")
        #expect(values["crashes"] == 3 && values["crashesLastAt"] == 1_800_000_000_000 && values["mainHangLongestSeconds"] == 2.5)
        #expect(StabilityCounts.values(defaults: defaults, build: "252").isEmpty, "another build's counts read as none")
        StabilityCounts.count("crashes", defaults: defaults, build: "252")
        #expect(StabilityCounts.values(defaults: defaults, build: "252")["crashes"] == 1)
        #expect(StabilityCounts.values(defaults: defaults, build: "251").isEmpty)
    }

    @Test func caughtCrashRecordsAreCountedOnceEach() {
        let suite = "diag-caught-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }
        StabilityCounts.countCaughtCrashes([url("exception-1.txt")], defaults: defaults, build: "9")
        #expect(StabilityCounts.values(defaults: defaults, build: "9")["caughtCrashes"] == nil, "what was there before counting began is only noted")
        StabilityCounts.countCaughtCrashes([url("exception-1.txt"), url("signal-2.txt"), url("signal-3-pending.txt"), url("metrickit-4.json")], defaults: defaults, build: "9")
        #expect(StabilityCounts.values(defaults: defaults, build: "9")["caughtCrashes"] == 1)
        StabilityCounts.countCaughtCrashes([url("exception-1.txt"), url("signal-2.txt")], defaults: defaults, build: "9")
        #expect(StabilityCounts.values(defaults: defaults, build: "9")["caughtCrashes"] == 1)
    }

    @Test func fieldSummaryAndRows() {
        let values: [String: Double] = ["windowSeconds": 86_400, "peakMemoryBytes": 212 * 1_048_576, "suspendedMemoryBytes": 61 * 1_048_576,
                                        "hangCount": 1, "hangSeconds": 0.6, "scrollHitchMsPerSecond": 1.23, "cpuSeconds": 411.6,
                                        "launch.firstDraw.under500ms": 3, "launch.firstDraw.over4000ms": 1, "launch.resume.under500ms": 9,
                                        "exits.background.memoryLimit": 1, "exits.background.taskTimeout": 2, "exits.foreground.normal": 1,
                                        "exits.background.normal": 4, "diag.crashes": 1]
        #expect(R.fieldSummary(values) == "peak 212 MB · 1 hang · 1 forced exit · 1 crash report · hitches 1.2 ms/s")
        #expect(R.fieldSummary(["diag.hangs": 0]) == "diagnostics only")
        #expect(R.fieldSummary(["hangCount": 2, "exits.foreground.watchdog": 2]) == "2 hangs · 2 forced exits")
        let entries = [R.FieldEntry(day: "2026-09-25", build: "250", at: utc(1, 0), values: ["windowSeconds": 86_400, "peakMemoryBytes": 100 * 1_048_576]),
                       R.FieldEntry(day: "2026-09-26", build: "251", at: utc(2, 0), values: values),
                       R.FieldEntry(day: "2026-09-27", build: "251", at: utc(3, 0), values: ["diag.hangs": 1])]
        let section = R.fieldSection(entries, build: "251")
        #expect(section.title == "Field metrics, from iOS")
        #expect(section.rows.map { "\($0.label): \($0.value)" } == [
            "Report day: 2026-09-26", "Peak memory: 212 MB", "Memory while suspended, average: 61 MB", "Hangs: 1 · 0.6 s in all",
            "Scroll hitches: 1.2 ms per second of scrolling", "CPU time: 412 s", "Launches, time to first draw: 3 under 0.5 s · 1 over 4 s",
            "Returns from background, time to resume: 9 under 0.5 s", "Closed by iOS for memory, in background: 1",
            "Background task ran out of time: 2", "Normal exits: 5"])
        #expect(section.list?.rows.map(\.label) == ["2026-09-27 · build 251", "2026-09-26 · build 251", "2026-09-25 · build 250"])
        #expect(section.list?.rows.first?.value == "diagnostics only")
        #expect(R.fieldSection(entries, build: "999").rows.first == R.Row("Report day", "2026-09-26 (build 251)"))
        let none = R.fieldSection([], build: "251")
        #expect(none.rows == [R.Row("Daily summary", "Not received yet")])
        #expect(none.list?.empty == "None yet: iOS sends the first summary about a day after install")
    }

    @Test func fieldHistoryKeepsTheLastSevenOldestFirst() {
        let entries = (1...9).reversed().map { R.FieldEntry(day: "2026-09-0\($0)", build: "1", at: utc(0, $0), values: ["a": Double($0), "bad": .nan]) }
        let kept = R.fieldHistory(entries)
        #expect(kept.map(\.day) == (3...9).map { "2026-09-0\($0)" })
        #expect(kept.allSatisfy { $0.values["bad"] == nil })
    }

    @Test func fieldHistoryOnDiskReplacesADaysSummaryAddsUpDiagnosticCountsAndKeepsSeven() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("diag-field-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        FieldHistory.record(["windowSeconds": 100, "hangCount": 1], day: "2026-09-01", build: "5", at: utc(1, 0), file: file)
        FieldHistory.record(["windowSeconds": 200, "hangCount": 3], day: "2026-09-01", build: "5", at: utc(2, 0), file: file)
        FieldHistory.record(["diag.crashes": 1], day: "2026-09-01", build: "5", at: utc(3, 0), file: file)
        FieldHistory.record(["diag.crashes": 2], day: "2026-09-01", build: "5", at: utc(4, 0), file: file)
        FieldHistory.record([:], day: "2026-09-02", build: "5", file: file)
        var saved = FieldHistory.saved(file: file)
        #expect(saved.count == 1)
        #expect(saved[0].values == ["windowSeconds": 200, "hangCount": 3, "diag.crashes": 3])
        #expect(saved[0].at == utc(4, 0))
        for day in 2...9 { FieldHistory.record(["windowSeconds": Double(day)], day: "2026-09-0\(day)", build: day < 9 ? "5" : "6", at: utc(5, day), file: file) }
        saved = FieldHistory.saved(file: file)
        #expect(saved.map(\.day) == (3...9).map { "2026-09-0\($0)" })
        #expect(FieldHistory.latest(build: "5", file: file)["windowSeconds"] == 8)
        #expect(FieldHistory.latest(build: "7", file: file).isEmpty)
        #expect(FieldHistory.day(Date(timeIntervalSince1970: 1_790_000_000)) == "2026-09-21")
    }

    @Test func launchBucketsAndHangTotals() {
        let buckets = [FieldHistory.Bucket(startMs: 0, endMs: 400, count: 3), .init(startMs: 400, endMs: 800, count: 2), .init(startMs: 900, endMs: 1100, count: 1),
                       .init(startMs: 3000, endMs: 4000, count: 1), .init(startMs: 4000, endMs: 9000, count: 2), .init(startMs: 1500, endMs: 1600, count: 0)]
        #expect(FieldHistory.launchBuckets("launch.firstDraw", buckets) == ["launch.firstDraw.under500ms": 3, "launch.firstDraw.500to1000ms": 2,
                                                                           "launch.firstDraw.1000to2000ms": 1, "launch.firstDraw.2000to4000ms": 1,
                                                                           "launch.firstDraw.over4000ms": 2])
        #expect(FieldHistory.launchBuckets("x", []).isEmpty)
        let hangs = FieldHistory.hangs([.init(startMs: 250, endMs: 500, count: 2), .init(startMs: 1000, endMs: 2000, count: 1)])
        #expect(hangs.count == 3 && abs(hangs.seconds - 2.25) < 0.0001)
    }

    @Test func crashLogKeepsTheLastThreeOfThisBuildAsShortText() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("diag-reports-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let json: [String: Any] = [
            "diagnosticMetaData": ["appBuildVersion": "251", "osVersion": "iPhone OS 27.0", "signal": 11, "exceptionType": 1, "bundleIdentifier": "x.y"],
            "callStackTree": ["callStacks": [
                ["threadAttributed": false, "callStackRootFrames": [["binaryName": "Other", "offsetIntoBinaryTextSegment": 1]]],
                ["threadAttributed": true, "callStackRootFrames": [
                    ["binaryName": "HermesHQNative", "offsetIntoBinaryTextSegment": 4096, "sampleCount": 9,
                     "subFrames": [["binaryName": "UIKitCore", "offsetIntoBinaryTextSegment": 255, "sampleCount": 2],
                                   ["binaryName": "libswiftCore.dylib", "offsetIntoBinaryTextSegment": 16, "sampleCount": 7]]],
                    ["binaryName": "Light", "offsetIntoBinaryTextSegment": 2, "sampleCount": 1]]],
            ]],
        ]
        let entry = CrashLog.summary(kind: "Crash", json: try JSONSerialization.data(withJSONObject: json), at: utc(4, 3))
        #expect(entry.text == "Crash\n  build: 251\n  exception type: 1\n  iOS: iPhone OS 27.0\n  signal: 11\n  Thread (attributed of 2):\n    0 HermesHQNative +0x1000\n    1 libswiftCore.dylib +0x10")
        #expect(!entry.text.contains("x.y"), "only the named fields are kept")
        for index in 0..<5 { CrashLog.keep([.init(kind: "Hang", at: utc(5, index), text: "Hang\n  n: \(index)")], build: "251", file: file) }
        #expect(CrashLog.saved(build: "251", file: file).map(\.text) == ["Hang\n  n: 2", "Hang\n  n: 3", "Hang\n  n: 4"])
        #expect(CrashLog.saved(build: "252", file: file).isEmpty)
        CrashLog.keep([entry], build: "252", file: file)
        #expect(CrashLog.saved(build: "252", file: file) == [entry], "an earlier build's reports go")
        #expect(R.nativeReports(CrashLog.saved(build: "252", file: file) + [.init(kind: "Hang", at: utc(6, 0), text: "Hang")]).map(\.kind) == ["Hang", "Crash"])
        let huge = CrashLog.summary(kind: "Crash", json: try JSONSerialization.data(withJSONObject: ["diagnosticMetaData": ["terminationReason": String(repeating: "r", count: 20_000)]]), at: utc(1, 1))
        #expect(huge.text.utf8.count <= CrashLog.limit + 8 && huge.text.hasSuffix("\n  …"))
    }

    // MARK: Copy Diagnostics

    @Test func copiesAsPlainTextWithEverySectionTheRawNamesAndTheErrors() {
        let at = utc(4, 3)
        let text = R.text(sections: [.init(title: "App", rows: [R.Row("Version", "1.0 (14)")]), .init(title: "Gateway", rows: [R.Row("Most open at once", "2", "peak")])],
                          errors: [.init(message: "TypeError: boom", count: 5, at: at), .init(message: "Error: once", count: 1, at: nil)], now: utc(4, 4))
        #expect(text.hasPrefix("Hermes HQ diagnostics\n2026-09-27T04:04:00.000Z\n\nApp\n  Version: 1.0 (14)\n\nGateway\n  Most open at once [peak]: 2\n\n"))
        #expect(text.hasSuffix("Recent errors (6)\n  TypeError: boom (×5 · last 2026-09-27T04:03:00.000Z)\n  Error: once"))
        #expect(R.text(sections: [], errors: []).hasSuffix("Recent errors (0)\n  None since launch"))
    }

    @Test func copiesWhatEarlierLaunchesKeptAndTheReportsFromIOS() {
        let text = R.text(sections: [], errors: [], earlier: [.init(message: "load: timed out · on open chat", count: 2, at: utc(3, 0))],
                          reports: [.init(kind: "Crash", at: utc(2, 10), text: "Crash\n  build: 251\n  Thread:\n    0 HermesHQNative +0x1000")])
        #expect(text.hasSuffix("Recent errors (0)\n  None since launch\n\nBefore the last launch (2)\n  load: timed out · on open chat (×2 · last 2026-09-27T03:00:00.000Z)\n\niOS report: Crash, 2026-09-27T02:10:00.000Z\n    build: 251\n    Thread:\n      0 HermesHQNative +0x1000"))
    }

    @Test func guardsEveryFieldOfTheCopiedText() {
        let fixture = "FAKE-private-value"
        let output = R.text(sections: [.init(title: "Gateway", rows: [R.Row("Status", "password=\(fixture)")],
                                             list: .init(title: "Reconnects", rows: [R.Row("Time", "Bearer \(fixture)", "token=\(fixture)")], empty: "None"))],
                            errors: [.init(message: "Cookie: session=\(fixture)", count: 1, at: nil)])
        #expect(!output.contains(fixture) && output.contains("[redacted]"))
        #expect(DiagnosticRedactor.redact(output) == output)
    }

    @Test func redactsLineByLineSoAStrayQuoteKeepsTheOtherLines() {
        let errors = ["Error: Unexpected character \" in header value", "TypeError: Load failed", "Error: Gateway HTTP 404", "Error: second stray \" here",
                      "Error: bad session:", "TypeError: x is undefined"].map { R.ErrorGroup(message: $0, count: 1, at: nil) }
        let output = R.text(sections: [.init(title: "Gateway", rows: [R.Row("Update check", "Failed: unexpected \" in body")])], errors: errors)
        for kept in ["TypeError: Load failed", "Error: Gateway HTTP 404", "TypeError: x is undefined", "Recent errors (6)"] { #expect(output.contains(kept)) }
        #expect(output.components(separatedBy: "\n").map(DiagnosticRedactor.redact).joined(separator: "\n") == output)
    }

    // MARK: Kept across launches

    @Test func errorsAreKeptForTheNextLaunchRedactedWithTheirScreen() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("diag-kept-\(UUID().uuidString)/errors.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let first = KeptErrors(file: file, build: "251", run: "run-1")
        first.keepNow(message: "wss://host/api/ws?ticket=FAKE-private-value failed", at: utc(4, 0), route: "open chat (3 messages)?x=1")
        first.keepNow(message: "load: timed out", at: utc(4, 1))
        #expect(first.earlier().isEmpty, "this run's own errors are not earlier ones")
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("FAKE-private-value"), "redacted when stored")

        let second = KeptErrors(file: file, build: "251", run: "run-2")
        #expect(second.earlier().map(\.message) == ["wss://host/api/ws?[redacted] failed · on open chat (3 messages)", "load: timed out"])
        #expect(second.earlier().first?.at == utc(4, 0))
        for index in 0..<25 { second.keepNow(message: "error \(index)", at: utc(5, index)) }
        let third = KeptErrors(file: file, build: "251", run: "run-3")
        #expect(third.earlier().count == 20 && third.earlier().last?.message == "error 24" && third.earlier().first?.message == "error 5")

        let updated = KeptErrors(file: file, build: "252", run: "run-4")
        #expect(updated.earlier().isEmpty, "another build's errors are dropped")
        updated.keepNow(message: String(repeating: "y", count: 2000), at: utc(6, 0), route: String(repeating: "r", count: 300))
        let after = KeptErrors(file: file, build: "252", run: "run-5").earlier()
        #expect(after.count == 1)
        #expect(after[0].message.hasSuffix(" · on " + String(repeating: "r", count: 120)))
    }

    @Test func theTimelineKeepsErrorsMarksReturnsAndRemembersTheScreen() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("diag-timeline-\(UUID().uuidString)/errors.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1000)
        let kept = KeptErrors(file: file, build: "1", run: "a")
        let timings = StartupTimings(processStart: start)
        let timeline = DiagnosticsTimeline(processStart: start, kept: kept, timings: timings)
        timeline.record(category: "app", message: "active", at: start.addingTimeInterval(1))          // the launch's own activation
        timeline.record(category: "screen", message: "open chat (3 messages)")
        for second in 0..<5 { timeline.record(category: "error", message: "roster read: timed out", at: start.addingTimeInterval(Double(10 + second))) }
        timeline.record(category: "app", message: "background", at: start.addingTimeInterval(20))
        timeline.record(category: "app", message: "active (not a return)", at: start.addingTimeInterval(21))
        timeline.record(category: "app", message: "active", at: start.addingTimeInterval(25))
        timeline.record(category: "app", message: "active", at: start.addingTimeInterval(26))
        #expect(timeline.recentErrors() == [.init(message: "roster read: timed out", count: 5, at: start.addingTimeInterval(14))])
        #expect(timings.marks.map(\.name) == ["app.background", "app.foreground"])
        #expect(timings.marks.last?.atMs == 25_000)
        kept.settle()
        let next = DiagnosticsTimeline(processStart: start, kept: KeptErrors(file: file, build: "1", run: "b"))
        #expect(next.recentErrors().isEmpty)
        #expect(next.earlierErrors() == [.init(message: "roster read: timed out · on open chat (3 messages)", count: 5, at: start.addingTimeInterval(14))])
    }

    @Test func startupTimingsKeepTheLaunchWhenAFlakyConnectionFillsTheBuffer() {
        let start = Date(timeIntervalSince1970: 5000)
        let timings = StartupTimings(processStart: start)
        timings.record("native.loaded", from: start, to: start.addingTimeInterval(0.141))
        timings.markOnce("launch.ready", at: start.addingTimeInterval(0.612))
        timings.markOnce("launch.ready", at: start.addingTimeInterval(9))
        timings.record("socket.ticket", from: start.addingTimeInterval(1), to: start.addingTimeInterval(1.26))
        timings.record("socket.handshake", from: start.addingTimeInterval(1.26), to: start.addingTimeInterval(1.361))
        for index in 0..<400 {
            let at = start.addingTimeInterval(Double(100 + index))
            timings.record("socket.ticket", from: at, to: at.addingTimeInterval(0.2), outcome: "timeout")
            timings.mark("socket.error", at: at)
        }
        #expect(timings.entries.count == StartupTimings.entryLimit)
        #expect(timings.marks.count == StartupTimings.markLimit + 1)
        let rows = DiagnosticsReport.startupRows(marks: timings.marks, entries: timings.entries)
        #expect(rows.map { "\($0.label): \($0.value)" } == ["App ready: 612 ms", "App launch: 141 ms", "Connection ticket: 260 ms", "Connection handshake: 101 ms"])
        #expect(DiagnosticsReport.reconnects(timings.entries).first?.outcome == "Failed: no connection ticket after 0.2 s")
        #expect(DiagnosticsReport.reconnects(timings.entries).first?.at == start.addingTimeInterval(499))
    }
}
