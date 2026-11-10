import Foundation
import Testing
@testable import HermesHQNative

/// Settings › About › Share Logs reads what these write (HermesKit/Diagnostics/DiagnosticLog.swift).
@Suite(.serialized) struct DiagnosticLogTests {
    @Test func noteLandsInTheLogFile() {
        let marker = "diag-" + String((0..<10).map { _ in "abcdefghij".randomElement()! })   // no digits: ids are tagged
        AppLog.note("test", marker)
        #expect(DiagnosticLog.shared.tail().contains("[test] (main) \(marker)"))
    }

    @Test func crashRecordsAreListed() throws {
        let log = DiagnosticLog.shared
        log.writeRecord(prefix: "exception", ext: "txt", Data("one".utf8))
        let first = try #require(log.crashRecords().first)
        #expect(first.lastPathComponent.hasPrefix("exception-"))
        try FileManager.default.removeItem(at: first)
    }

    // [13-8] Several MetricKit payloads in one delivery are written the same second: each keeps its own file.
    @Test func recordsWrittenTheSameSecondKeepTheirOwnFiles() throws {
        let log = DiagnosticLog.shared
        let prefix = "test-record-\(UUID().uuidString.prefix(8))"
        let urls = (1...3).map { log.writeRecord(prefix: prefix, ext: "json", Data("payload \($0)".utf8)) }
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        #expect(Set(urls).count == 3)
        #expect(try urls.map { try String(contentsOf: $0, encoding: .utf8) } == ["payload 1", "payload 2", "payload 3"])
    }

    // [13-20] The crash handler reads the log's tail, which waits for the log's queue: from that queue itself it must
    // not wait (it would hang instead of writing the record).
    @Test func readingTheTailOnTheLogsOwnQueueDoesNotHang() {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = DiagnosticLog.shared.onLogQueue { DiagnosticLog.shared.tail(bytes: 64) }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 3) == .success)
    }

    @Test func crashRecordIsNotedOnceWithItsAge() {
        let now = Date()
        let line = CrashCapture.crashRecordNote(name: "metrickit-1.json", modified: now.addingTimeInterval(-9 * 86_400),
                                                lastNoted: nil, now: now)
        #expect(line == "new crash record: metrickit-1.json (written 9 days ago)")
        #expect(CrashCapture.crashRecordNote(name: "metrickit-1.json", modified: now, lastNoted: "metrickit-1.json", now: now) == nil)
        #expect(CrashCapture.crashRecordNote(name: "signal-2.txt", modified: now.addingTimeInterval(-300),
                                             lastNoted: "metrickit-1.json", now: now)?.hasSuffix("(written 5 min ago)") == true)
    }

    /// The same id gives the same tag here and in scripts/hqn-logs.py (`tag`), so `--chat <id>` finds its lines.
    @Test func tagIsShortStableAndMatchesTheReader() {
        #expect(AppLog.tag("abc") == "#ba7816")
        #expect(AppLog.tag(nil) == "#-")
        #expect(AppLog.tag("") == "#-")
    }

    @Test func pathTagsIdsAndDropsTheQuery() {
        let url = URL(string: "https://gw.example/api/sessions/20251027_101010_ab12cd/messages?limit=50")!
        #expect(AppLog.path(url) == "/api/sessions/\(AppLog.tag("20251027_101010_ab12cd"))/messages?…")
        #expect(AppLog.path(URL(string: "https://gw.example/api/plugins/hermes-hq-push/logs")!) == "/api/plugins/hermes-hq-push/logs")
        #expect(AppLog.path(URL(string: "https://gw.example/api/plugins/hermes-hq-browser/health")!) == "/api/plugins/hermes-hq-browser/health")
    }

    @Test func scrubTagsIdsInGatewayWords() {
        let text = AppLog.scrub("Details: session 20251027_101010_ab12cd opened by cli, retry in 30 s")
        #expect(text == "Details: session \(AppLog.tag("20251027_101010_ab12cd")) opened by cli, retry in 30 s")
        #expect(AppLog.scrub("permission_denied: not the owner") == "permission_denied: not the owner")
    }

    @Test func everyLineTagsRawIdsButKeepsModelNamesAndCounts() {
        #expect(AppLog.tagIds("resume 20251027_101010_ab12cd: 4009") == "resume \(AppLog.tag("20251027_101010_ab12cd")): 4009")
        #expect(AppLog.tagIds("model gpt-4o-2024-08-06, 12345678 B in 250 ms, #3fa9b2") == "model gpt-4o-2024-08-06, 12345678 B in 250 ms, #3fa9b2")
        let uuid = "123e4567-e89b-12d3-a456-426614174000"
        #expect(AppLog.tagIds("upload \(uuid) done") == "upload \(AppLog.tag(uuid)) done")
    }

    @Test func scrubTagsEveryURLHostSoTheGatewayAddressNeverReachesTheLog() {
        // A URLError's description carries the failing URL twice (build 409 log: the gateway's address in 23 lines).
        let error = URLError(.cancelled, userInfo: [
            NSURLErrorFailingURLStringErrorKey: "https://my-mac.tail1234.ts.net:9119/api/profiles/sessions/sidebar?x=1",
            NSURLErrorFailingURLErrorKey: URL(string: "https://My-Mac.tail1234.ts.net:9119/api/sessions/")!,
        ])
        let line = AppLog.scrub(String(describing: error))
        #expect(!line.lowercased().contains("my-mac"))
        #expect(!line.contains("tail1234"))
        #expect(!line.contains("9119"))
        // The words the phone logged (build 409), host swapped: both keys keep their URL, now tagged.
        // (The redactor masks a plain UserInfo block whole; a nested one, as a lost connection's, it let through.)
        let raw = #"failed: Error Domain=NSURLErrorDomain Code=-1005 "The network connection was lost." UserInfo={_kCFStreamErrorCodeKey=53, NSUnderlyingError=0x1 {Error Domain=kCFErrorDomainCFNetwork Code=-1005 "(null)"}, NSErrorFailingURLStringKey=https://my-mac.tail1234.ts.net:9119/api/auth/ws-ticket, NSErrorFailingURLKey=https://my-mac.tail1234.ts.net:9119/api/auth/ws-ticket}"#
        let logged = AppLog.scrub(raw)
        #expect(!logged.contains("my-mac") && !logged.contains("9119"))
        #expect(AppLog.tagHosts(raw).contains("NSErrorFailingURLStringKey=https://\(AppLog.tag("my-mac.tail1234.ts.net"))/api/auth/ws-ticket"))
        #expect(AppLog.tagHosts("ws://[fd7a:115c::1]:8080/x and http://user@10.0.0.5/y")
            == "ws://\(AppLog.tag("[fd7a:115c::1]"))/x and http://\(AppLog.tag("10.0.0.5"))/y")
        #expect(AppLog.tagHosts("no address here, 3 of 4") == "no address here, 3 of 4")
        #expect(AppLog.tagHosts("https://#20f234/api") == "https://#20f234/api")
    }
}
