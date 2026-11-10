// The performance log's sending rules (lifecycle #43, #45): a hold after the link comes back, forced kicks that ignore
// it, a batch the plugin refuses for good let go, a batch that keeps failing let go after 8 tries, and requests capped
// by bytes as well as lines.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@Suite(.serialized) struct LogUploaderTests {
    nonisolated final class Sink: Sendable {
        let raw = Mutex<[Data]>([])
        let failWith = Mutex<Int?>(nil)
        var count: Int { raw.withLock { $0.count } }
        var bodies: [[String: Any]] { raw.withLock { $0 }.map { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] ?? [:] } }
        var sender: @Sendable (Data) async throws -> Void {
            { [self] body in
                raw.withLock { $0.append(body) }
                if let status = failWith.withLock({ $0 }) { throw HTTPError(status: status, body: nil) }
            }
        }
    }

    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("logup-\(UUID().uuidString)", isDirectory: true)
    private var outbox: URL { directory.appendingPathComponent("outbox.jsonl") }
    private var sending: URL { directory.appendingPathComponent("sending.jsonl") }

    private func uploader(_ sink: Sink) throws -> LogUploader {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: LogUploader.enabledKey)   // the default; a test run may have left it off
        let uploader = LogUploader(directory: directory)
        uploader.setSender(sink.sender)   // nothing waits yet: no send
        uploader.settle()
        return uploader
    }

    private func line(_ uploader: LogUploader, _ text: String = "hello") {
        uploader.record("test", [("m", text)])
        uploader.settle()
    }

    private func kick(_ uploader: LogUploader, force: Bool = false) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            uploader.kick("test", force: force) { done.resume() }
        }
        uploader.settle()   // the upload's own bookkeeping
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func aHoldKeepsTheLinesUntilItEndsAndAForcedKickIgnoresIt() async throws {
        let sink = Sink()
        let uploader = try uploader(sink)
        line(uploader)
        uploader.hold(until: Date().addingTimeInterval(60))
        await kick(uploader)
        #expect(sink.count == 0)
        #expect(exists(outbox), "the lines wait in the outbox")
        await kick(uploader, force: true)
        #expect(sink.count == 1)
        line(uploader)
        uploader.hold(until: Date().addingTimeInterval(-1))
        await kick(uploader)
        #expect(sink.count == 2)
        #expect(!exists(outbox) && !exists(sending))
    }

    @Test func aBatchRefusedForGoodIsLetGoAndTheNextSaysLost() async throws {
        let sink = Sink()
        let uploader = try uploader(sink)
        line(uploader)
        sink.failWith.withLock { $0 = 413 }
        await kick(uploader)
        #expect(uploader.lastStatus == 413)
        #expect(!exists(sending), "a refused batch is not sent again")
        sink.failWith.withLock { $0 = nil }
        line(uploader, "next")
        await kick(uploader)
        #expect(sink.count == 2)
        #expect(sink.bodies.last?["lost"] as? Bool == true)
    }

    @Test func aPassingFailureKeepsTheBatchAndBacksOff() async throws {
        let sink = Sink()
        let uploader = try uploader(sink)
        line(uploader)
        sink.failWith.withLock { $0 = 503 }
        await kick(uploader)
        #expect(exists(sending))
        await kick(uploader)
        #expect(sink.count == 1, "the back-off holds the next try")
    }

    @Test func aBatchThatKeepsFailingIsLetGoAfterEightTries() async throws {
        let sink = Sink()
        let uploader = try uploader(sink)
        line(uploader)
        sink.failWith.withLock { $0 = 401 }
        for attempt in 1...LogUploader.maxBatchFailures {
            uploader.clearBackOff()
            await kick(uploader)
            #expect(sink.count == attempt)
            #expect(exists(sending) == (attempt < LogUploader.maxBatchFailures))
        }
    }

    // [13-10] A send that fails partway: the chunks that arrived are not sent again.
    @Test func aBatchThatFailsPartwayResendsOnlyWhatDidNotArrive() async throws {
        let sink = Sink()
        let uploader = try uploader(sink)
        let calls = Mutex(0)
        uploader.setSender { body in
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 2 { throw HTTPError(status: 503, body: nil) }    // the second chunk fails
            sink.raw.withLock { $0.append(body) }
        }
        uploader.settle()                                            // its own kick finds nothing waiting
        let text = String(repeating: "x", count: 1_000)
        try Data((0..<300).map { "\($0) " + text + "\n" }.joined().utf8).write(to: outbox)
        await kick(uploader)
        #expect(sink.count == 1 && exists(sending))
        uploader.clearBackOff()
        await kick(uploader)
        let sent = sink.bodies.flatMap { ($0["lines"] as? [String]) ?? [] }
        #expect(sent.count == 300, "every line once: \(sent.count)")
        #expect(Set(sent).count == 300)
        #expect(!exists(sending))
    }

    // [13-9] Lines logged while signed in to one gateway wait for that gateway; the next account's sends don't carry them.
    @Test func linesLoggedForOneGatewayAreNotSentToAnother() async throws {
        let a = Sink(), b = Sink()
        let uploader = try uploader(a)
        uploader.setSender(a.sender, account: "http://a|me")
        uploader.settle()
        uploader.hold(until: Date().addingTimeInterval(60))     // nothing goes by itself
        line(uploader, "for a")
        uploader.setSender(b.sender, account: "http://b|me")
        uploader.settle()
        line(uploader, "for b")
        await kick(uploader, force: true)
        let toB = b.bodies.flatMap { ($0["lines"] as? [String]) ?? [] }
        #expect(toB.count == 1 && toB.first?.contains("for b") == true, "\(toB)")
        uploader.setSender(a.sender, account: "http://a|me")    // back on gateway A
        uploader.settle()
        await kick(uploader, force: true)
        let toA = a.bodies.flatMap { ($0["lines"] as? [String]) ?? [] }
        #expect(toA.count == 1 && toA.first?.contains("for a") == true, "\(toA)")
    }

    @Test func aRequestEndsAtTheByteCap() async throws {
        let sink = Sink()
        let uploader = try uploader(sink)
        let text = String(repeating: "x", count: 1_000)
        try Data((0..<300).map { _ in text + "\n" }.joined().utf8).write(to: outbox)
        await kick(uploader)
        let sizes = sink.bodies.map { ($0["lines"] as? [String])?.count ?? 0 }
        #expect(sizes == [262, 38])
        #expect(!exists(sending))
    }
}
