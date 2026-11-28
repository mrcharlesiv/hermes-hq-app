// Stress regression suite for Domain 2: Chat, Rendering, Math, Markdown, Mermaid, Cache, Voice, Audio, Media & Attachments.

import AVFAudio
import Foundation
import Synchronization
import Testing
import UIKit
@testable import HermesHQNative

// MARK: - Private test stand-ins

private nonisolated final class StressAsyncRestClient: GatewayClient, Sendable {
    typealias AsyncRestResponder = @Sendable (_ path: String, _ query: [URLQueryItem]) async throws -> Data
    typealias CallResponder = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue

    private struct State: Sendable {
        var rest: AsyncRestResponder
        var call: CallResponder
        var events: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]
        var states: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
        var ready: JSONValue? = ["heartbeat": true, "change_events": true, "replay_epoch": "stress-epoch"]
    }

    let account: GatewayAccount
    private let state: Mutex<State>

    init(
        rest: @escaping AsyncRestResponder,
        call: @escaping CallResponder = { method, _ in
            switch method {
            case "session.resume", "session.activate": return ["session_id": "rt-stress-1", "running": false]
            case "session.interrupt": return ["status": "interrupted"]
            case "session.active_list": return ["sessions": []]
            case "session.events.since": return ["events": [], "latest_seq": 0, "truncated": false, "epoch": "stress-epoch"]
            default: return [:]
            }
        }
    ) {
        account = GatewayAccount(id: "http://example.com:9717|tester-\(UUID().uuidString)",
                                 baseURL: URL(string: "http://example.com:9717")!,
                                 kind: .password, username: "tester", label: "stress")
        state = Mutex(State(rest: rest, call: call))
    }

    func onRest(_ responder: @escaping AsyncRestResponder) { state.withLock { $0.rest = responder } }

    func rest(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        let responder = state.withLock { $0.rest }
        return try await responder(path, query)
    }

    func call(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        let responder = state.withLock { $0.call }
        return try await responder(method, params)
    }

    func events() -> AsyncStream<GatewayEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            state.withLock { $0.events[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.events.removeValue(forKey: id) } }
        }
    }

    func connectionStates() -> AsyncStream<ConnectionState> {
        let id = UUID()
        return AsyncStream { continuation in
            state.withLock { $0.states[id] = continuation }
            continuation.yield(.ready)
            continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.states.removeValue(forKey: id) } }
        }
    }

    var latestReady: JSONValue? { state.withLock { $0.ready } }
    func appDidBecomeActive() {}
    func appDidEnterBackground() {}
    func shutdown() {}
}

private nonisolated final class StressWordsListener: LiveWordsListening, Sendable {
    private let phrase: String
    private let cancelled = Mutex(false)

    init(_ phrase: String) { self.phrase = phrase }
    var wasCancelled: Bool { cancelled.withLock { $0 } }

    func feed(_ samples: UnsafeBufferPointer<Int16>) {}
    func finish() async -> String { cancelled.withLock { $0 } ? "" : phrase }
    func cancel() { cancelled.withLock { $0 = true } }
}

private nonisolated final class StressParakeetHearing: ParakeetHearing, Sendable {
    func words(_ samples: [Float]) async -> String? { "hello" }
}

/// Simulates an uninterruptible native call (e.g. Core ML compilation) that ignores cooperative Task cancellation.
private nonisolated final class StressUncancellableGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let list = waiters
        waiters = []
        lock.unlock()
        list.forEach { $0.resume() }
    }
}

@MainActor
private final class StressSlowCloseTransport: LiveVoiceTransport {
    var onEvent: ((LiveServerEvent) -> Void)?
    var onDropped: ((String) -> Void)?
    var onMicLevel: ((Double) -> Void)?
    var onSpeaking: ((Bool) -> Void)?
    var speakerLevel = 0.0

    let closeGate = Latch()
    private(set) var started = false
    private(set) var closeEntered = false
    private(set) var closed = false

    func start(history: JSONValue, exchange: @escaping @MainActor (String) async throws -> String) async throws {
        _ = try await exchange("v=0\r\n")
        started = true
        onEvent?(.started(sessionId: "sess_stress"))
    }

    func send(_ event: String) {}
    func setMuted(_ muted: Bool) {}

    func close() async {
        closeEntered = true
        try? await closeGate.wait()
        closed = true
    }
}

@MainActor
private final class StressStalledSpeechOutput: SpeechOutput {
    private(set) var scheduledBytes = 0
    private(set) var stops = 0
    var pending: TimeInterval = 5.0
    var level: Double { 0 }

    func begin(sampleRate: Double, channels: Int, host: TalkPlaybackHost?) async throws {}
    func schedule(_ pcm: Data) { scheduledBytes += pcm.count }
    func playClip(_ clip: SpeechClip) async throws {}
    func stop() { stops += 1 }
}

@MainActor
private final class StressPhoneRenderer: PhoneSpeechRendering {
    func chooseVoice(for text: String) -> String { "StressVoice" }

    func render(_ sentence: String) -> AsyncThrowingStream<PhonePCM, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(PhonePCM(data: Data(repeating: 0, count: 4_800), sampleRate: 24_000, channels: 1))
            continuation.finish()
        }
    }

    func cancel() {}
}

// MARK: - Pure Math, Markdown, Reasoning, Mermaid & Coding regressions

@Suite("Chat, math, markdown, mermaid & coding stress regressions")
struct ChatRenderAndCodingStressRegressionTests {
    private let style = ChatStyleCache.shared.style(for: .large)

    // C1: Negative math token indices must never trap.
    @Test func negativeMathTokensDoNotTrap() {
        #expect(MathText.blockToken("\u{E002}-1\u{E001}") == nil)
        #expect(MathText.blockToken("\u{E002}-999999\u{E001}") == nil)
        #expect(MathText.blockToken("\u{E002}0\u{E001}") == 0)
        #expect(MathText.pieces("\u{E000}-1\u{E001}") == [.text("\u{E000}-1\u{E001}")])
        #expect(MathText.pieces("\u{E002}-1\u{E001}") == [.text("\u{E002}-1\u{E001}")])

        let sample = [MathText.Span.Taken(source: "x", block: false, ownParagraph: false, written: "$x$")]
        let restored = MathText.restore("\u{E000}-1\u{E001} and \u{E002}-2\u{E001}", sample)
        #expect(restored == "\u{E000}-1\u{E001} and \u{E002}-2\u{E001}")

        let rendered = MarkdownRenderer.render("\u{E002}-1\u{E001}\n\nPrefix \u{E000}-1\u{E001} and $x = 1$", style: style)
        #expect(!rendered.blocks.isEmpty)
    }

    // C10: Deeply nested / raw private-use limit openers must not overflow a 512 KB GCD thread stack.
    @Test func mathStyleCapsRecursionOnGCDThreadAndStripsRawPUA() async {
        let pathological = String(repeating: "\u{E003}", count: 1_995) + "x"
        let baseFont = UIFont.systemFont(ofSize: 17)
        let renderedText: String = await withCheckedContinuation { continuation in
            DispatchQueue(label: "stress.mathstyle.smallstack").async {
                let attr = MathStyle.attributed(pathological, base: baseFont, color: .label, copy: nil)
                continuation.resume(returning: attr.string)
            }
        }
        #expect(renderedText == "x")
        #expect(!renderedText.contains(MathText.limitBelowOpen))
        #expect(!renderedText.contains(MathText.limitAboveOpen))
        #expect(!renderedText.contains(MathText.limitClose))

        // Untrusted PUA limit delimiters inside raw TeX are stripped before MathStyle sees them.
        #expect(MathText.readable(pathological) == "x")

        // Legitimate nested limits close cleanly at their matching limitClose.
        let nested = MathText.readable("\\sum_{\\sum_{i=1}^{n}}^{m}")
        #expect(nested != nil)
        if let nested {
            let styled = MathStyle.attributed(nested, base: baseFont, color: .label, copy: nil)
            #expect(styled.string.contains("∑"))
            #expect(styled.string.contains("m"))
            #expect(!styled.string.contains(MathText.limitBelowOpen))
            #expect(!styled.string.contains(MathText.limitClose))
        }
    }

    // H4: Unclosed math delimiters must scan in O(N).
    @Test func mathTextSpansIsLinearOnRepeatedUnclosedOpeners() {
        let input = String(repeating: "\\(", count: 30_000)
        let start = ContinuousClock.now
        let spans = MathText.spans(in: input)
        let elapsed = ContinuousClock.now - start
        #expect(spans.isEmpty)
        #expect(elapsed < .milliseconds(50), "30k unclosed \\( took \(elapsed)")

        let envInput = String(repeating: "\\begin{", count: 15_000)
        let envStart = ContinuousClock.now
        let envSpans = MathText.spans(in: envInput)
        let envElapsed = ContinuousClock.now - envStart
        #expect(envSpans.isEmpty)
        #expect(envElapsed < .milliseconds(50), "15k unclosed \\begin{ took \(envElapsed)")
    }

    // H5: Repeated unclosed reasoning tags must not suffer O(N^2) scans or allocation churn.
    @Test func reasoningTagsStripIsLinearOn20kUnclosedTags() {
        _ = ReasoningTags.strip("<think>warm</think>ok")
        let input = "hello " + String(repeating: "<think>", count: 20_000)
        let start = ContinuousClock.now
        let stripped = ReasoningTags.strip(input, streaming: false)
        let elapsed = ContinuousClock.now - start
        #expect(stripped == input)
        #expect(elapsed < .milliseconds(50), "20k unclosed <think> took \(elapsed)")

        // Oversized replies still hide leading reasoning blocks cleanly without running full Markdown parsing.
        let huge = "<think>secret</think>\n" + String(repeating: "word ", count: 42_000)
        let rendered = MarkdownRenderer.render(huge, style: style)
        #expect(!rendered.plainText.contains("secret"))
        #expect(rendered.blocks.count == 1)
    }

    // M6: Inline formulas must never split UTF-16 surrogate pairs or combining marks with U+2060.
    @Test func inlineFormulaPreservesSurrogatePairsAndCombiningMarks() throws {
        // Use a raw combining overline (x + U+0305) alongside an emoji surrogate pair so both pass directly through
        // `MarkdownRenderer.inlineFormula` (unlike `\bar{x}` which SwiftMath renders as an attachment).
        let rendered = MarkdownRenderer.render("Emoji: $😀 = 1$ and combining: $x\u{0305} = 1$", style: style)
        let prose = try #require(rendered.blocks.compactMap { block -> NSAttributedString? in
            if case .text(let attr) = block { return attr }
            return nil
        }.first)
        let text = prose.string
        #expect(text.contains("😀"))
        #expect(!text.contains("\u{FFFD}"))
        // Verify every UTF-16 code unit sequence is structurally valid (no lone surrogates).
        var strictDecoder = Unicode.UTF16()
        var strictIter = text.utf16.makeIterator()
        var strictErrors = 0
        decoding: while true {
            switch strictDecoder.decode(&strictIter) {
            case .scalarValue: continue
            case .emptyInput: break decoding
            case .error: strictErrors += 1
            }
        }
        #expect(strictErrors == 0, "inline formula split a surrogate pair (\(strictErrors))")
        #expect(text.contains("x\u{0305}"))
        #expect(!text.contains("x\u{2060}\u{0305}"))
    }

    // M5: Cartesian fan-out in MermaidParser must bail out immediately past maxEdges.
    @Test func mermaidParserBailsFastOnCartesianFanOut() {
        _ = MermaidParser.parse("flowchart TD\nA-->B")
        let left = (1...30).map { "A\($0)" }.joined(separator: " & ")
        let right = (1...30).map { "B\($0)" }.joined(separator: " & ")
        let fanout = "flowchart TD\n\(left) --> \(right)"
        let start = ContinuousClock.now
        let parsed = MermaidParser.parse(fanout)
        let elapsed = ContinuousClock.now - start
        #expect(parsed == nil)
        #expect(elapsed < .milliseconds(5), "Cartesian fanout took \(elapsed)")
    }

    // M7: BinaryReader.int() must use an unsigned logical right shift so high-bit values round-trip.
    @Test func binaryReaderIntRoundTripsFull64BitSignedRange() throws {
        let values: [Int] = [
            0, 1, -1, 42, -42,
            Int(Int32.max), Int(Int32.min),
            (1 << 62) - 1, 1 << 62,
            -(1 << 62), -(1 << 62) - 1,
            Int.max, Int.min,
        ]
        var writer = BinaryWriter()
        for value in values { writer.int(value) }
        var reader = BinaryReader(writer.data)
        for expected in values {
            let decoded = try reader.int()
            #expect(decoded == expected)
        }
        #expect(reader.isAtEnd)
    }

    // H2: Extreme / non-finite dates and timeouts must never trap on Double -> Int conversion.
    @Test func localDayAndApprovalExpiryHandleExtremeAndNonFiniteValues() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let normal = LocalDay.number(Date(timeIntervalSince1970: 86_400 * 10), zone: utc)
        #expect(normal == 10)
        _ = LocalDay.number(Date(timeIntervalSince1970: 1e25), zone: utc)
        _ = LocalDay.number(Date(timeIntervalSince1970: -1e25), zone: utc)
        _ = LocalDay.number(Date(timeIntervalSince1970: .nan), zone: utc)
        _ = LocalDay.number(Date(timeIntervalSince1970: .infinity), zone: utc)
        _ = LocalDay.number(Date(timeIntervalSince1970: -.infinity), zone: utc)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ApprovalExpiry.label(seenAt: now, timeout: 1e25, now: now).hasPrefix("Expires within "))
        #expect(ApprovalExpiry.label(seenAt: now, timeout: .infinity, now: now).hasPrefix("Expires within "))
        #expect(ApprovalExpiry.label(seenAt: now, timeout: -.infinity, now: now) == ApprovalExpiry.expired)
        #expect(ApprovalExpiry.label(seenAt: now, timeout: .nan, now: now) == ApprovalExpiry.expired)
    }

    // M8: TranscriptMerge.graft must not duplicate a leading rowId == nil tool-only message.
    @Test func transcriptMergeGraftDoesNotDuplicateLeadingToolOnlyMessage() {
        let older = ChatMessage(id: "stored-row-1-user", role: .user, parts: [.text("earlier")], timestamp: nil, rowId: 1)
        let toolOnly = ChatMessage(
            id: "stored-tool-2",
            role: .assistant,
            parts: [.tool(ToolCall(id: "call-1", name: "read_file", title: "Read file", argsText: nil, summary: "ok", state: .done, durationSeconds: nil))],
            timestamp: nil,
            rowId: nil
        )
        let anchor = ChatMessage(id: "stored-row-3-user", role: .user, parts: [.text("next")], timestamp: nil, rowId: 3)
        let reply = ChatMessage(id: "stored-row-4-assistant", role: .assistant, parts: [.text("done")], timestamp: nil, rowId: 4)

        let graft = TranscriptMerge.graft(
            fresh: [toolOnly, anchor, reply],
            freshMeta: [:],
            onto: [older, toolOnly, anchor],
            previousMeta: [:],
            aliases: [:],
            replaceAll: false
        )
        #expect(graft.messages.map(\.id) == ["stored-row-1-user", "stored-tool-2", "stored-row-3-user", "stored-row-4-assistant"])
    }

    // M21: Bounded off-main source reading & streaming fingerprint.
    @Test func htmlPageSheetBoundedSourcePrefixAndFingerprint() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hq-html-stress-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appending(path: "page.html")
        // "<html>" (6 bytes) + 4-byte emoji repeated -> limit 15 lands inside the 3rd emoji.
        let html = "<html>" + String(repeating: "😀", count: 500) + "</html>"
        try Data(html.utf8).write(to: file)

        let prefix = HTMLPageSheet.readSourcePrefix(from: file, limit: 15)
        #expect(prefix.truncated)
        #expect(prefix.text == "<html>😀😀")
        #expect(!prefix.text.contains("\u{FFFD}"))

        let fp1 = try #require(HTMLPageSheet.fileFingerprint(file))
        let fp2 = try #require(HTMLPageSheet.fileFingerprint(file))
        #expect(fp1 == fp2)

        try Data((html + " ").utf8).write(to: file)
        let fp3 = try #require(HTMLPageSheet.fileFingerprint(file))
        #expect(fp3 != fp1)
    }
}

// MARK: - Cache & Disk Persistence regressions

@Suite("TranscriptCache & MemoDisk stress regressions", .serialized)
struct CacheAndDiskStressRegressionTests {
    // H16: Cold flush must never wipe index.json; renameProfile must re-key pending, visible, memory and index.
    @Test func transcriptCacheColdFlushPreservesIndexAndRenameReKeysPending() throws {
        let cache1 = makeTempCache()
        defer { try? FileManager.default.removeItem(at: cache1.root) }
        let msg = [ChatMessage(id: "stored-row-1-user", role: .user, parts: [.text("hello")], timestamp: nil, rowId: 1)]
        cache1.save(msg, meta: [:], account: "acct-1", profile: "ivy", storedId: "s1")
        cache1.save(msg, meta: [:], account: "acct-1", profile: "ivy", storedId: "s2")
        cache1.flush()
        #expect(cache1.entryCount == 2)

        let indexURL = cache1.root.appending(path: "index.json")
        let beforeData = try Data(contentsOf: indexURL)
        let beforeMap = try JSONDecoder().decode([String: JSONValue].self, from: beforeData)
        #expect(beforeMap.count == 2)

        // Fresh cold cache instance: calling flush() before any load/write must NOT overwrite index.json with {}.
        let cold = TranscriptCache(root: cache1.root)
        cold.flush()
        let afterData = try Data(contentsOf: indexURL)
        let afterMap = try JSONDecoder().decode([String: JSONValue].self, from: afterData)
        #expect(afterMap.count == 2)
        #expect(cold.entryCount == 2)
        #expect(cold.diskBytes > 0)

        // renameProfile with an unflushed pending write + visible key re-keys both in-memory and on disk.
        let slowLimits = TranscriptCache.Limits(writeDelay: .seconds(60))
        let pendingCache = makeTempCache(limits: slowLimits)
        defer { try? FileManager.default.removeItem(at: pendingCache.root) }
        pendingCache.setVisible(TranscriptCache.key(account: "acct-2", profile: "ivy", storedId: "s9"))
        pendingCache.save(msg, meta: [:], account: "acct-2", profile: "ivy", storedId: "s9")
        pendingCache.renameProfile(account: "acct-2", from: "ivy", to: "wren")

        #expect(pendingCache.load(account: "acct-2", profile: "wren", storedId: "s9") == msg)
        #expect(pendingCache.load(account: "acct-2", profile: "ivy", storedId: "s9") == nil)
        pendingCache.flush()

        let reopened = TranscriptCache(root: pendingCache.root)
        #expect(reopened.load(account: "acct-2", profile: "wren", storedId: "s9") == msg)
        #expect(reopened.load(account: "acct-2", profile: "ivy", storedId: "s9") == nil)
        #expect(reopened.entryCount == 1)
    }

    // M22: MemoDisk.read must observe prior async MemoDisk.write without racing.
    private nonisolated struct MemoDiskPayload: Codable, Equatable, Sendable { var seq: Int; var label: String }

    @Test func memoDiskWriteThenReadIsConsistent() {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hq-memodisk-\(UUID().uuidString)", directoryHint: .isDirectory)
        let file = dir.appending(path: "state.json")
        defer {
            MemoDisk.flush()
            try? FileManager.default.removeItem(at: dir)
        }
        for step in 1...40 {
            let expected = MemoDiskPayload(seq: step, label: "take-\(step)")
            MemoDisk.write(expected, to: file)
            let readBack = MemoDisk.read(MemoDiskPayload.self, from: file)
            #expect(readBack == expected)
        }
    }
}

// MARK: - LiveChatSession Sync, Stop & Steer regressions

@Suite("LiveChatSession sync, stop & steer stress regressions", .serialized)
@MainActor
struct LiveChatSessionStressRegressionTests {
    // H17: Resetting history via non-kept refreshTail cancels in-flight olderTask and drops stale prepends.
    @Test func olderTaskCancelledAndDroppedWhenHistoryResets() async throws {
        let olderGate = Latch()
        let olderStarted = Latch()
        let stored = "20261127_120000_aabbcc99"

        let pageData: @Sendable ([JSONValue], Int, Bool) -> Data = { rows, offset, hasMore in
            encodeJSON([
                "session_id": .string(stored),
                "profile": "default",
                "messages": .array(rows),
                "pagination": [
                    "limit": 24,
                    "offset": .number(Double(offset)),
                    "order": "latest",
                    "returned": .number(Double(rows.count)),
                    "has_more": .bool(hasMore),
                ],
            ])
        }

        let initialRows: [JSONValue] = [
            ["id": 100, "role": "user", "content": "old question"],
            ["id": 101, "role": "assistant", "content": "old answer"],
        ]
        let staleOlderRows: [JSONValue] = [
            ["id": 10, "role": "user", "content": "ancient question"],
            ["id": 11, "role": "assistant", "content": "ancient answer"],
            ["id": 100, "role": "user", "content": "old question"],
        ]
        let rewrittenRows: [JSONValue] = [
            ["id": 50, "role": "user", "content": "compacted question"],
            ["id": 51, "role": "assistant", "content": "compacted answer"],
        ]

        let phase = Mutex(0)
        let client = StressAsyncRestClient { _, query in
            let offset = Int(query.first { $0.name == "offset" }?.value ?? "0") ?? 0
            if offset > 0 {
                olderStarted.open()
                try await olderGate.wait()
                return pageData(staleOlderRows, offset, false)
            }
            let currentPhase = phase.withLock { $0 }
            if currentPhase == 0 {
                return pageData(initialRows, 0, true)
            }
            return pageData(rewrittenRows, 0, false)
        }

        let cache = makeTempCache()
        defer { try? FileManager.default.removeItem(at: cache.root) }
        let session = LiveChatSession(client: client, account: client.account, profile: "default", storedSessionId: stored,
                                      title: "Ivy", head: nil, cache: cache, resolveSessionId: nil, lastActive: nil, frameMode: .manual)
        session.start()
        #expect(await waitUntil { session.openSettled })
        // Background older read starts automatically because nextOffset < fullPageRows and hasOlder == true.
        try await olderStarted.wait()
        #expect(session.isLoadingOlder)

        // Replace transcript via non-overlapping refreshTail (simulating compaction rewrite).
        phase.withLock { $0 = 1 }
        await session.refreshTail(force: true)
        #expect(!session.isLoadingOlder)
        #expect(session.olderTask == nil)
        #expect(session.messages.map(\.plainText) == ["compacted question", "compacted answer"])

        // Let the stale older-page response finish: it must NOT prepend ancient rows.
        olderGate.open()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(session.messages.map(\.plainText) == ["compacted question", "compacted answer"])
        session.stopObserving()
    }

    // M20 (part 1): Cancelled waitForStopTerminal timeout must not wake the next stop waiter.
    @Test func cancelledWaitForStopTerminalTimeoutDoesNotWakeNextWaiter() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())

        s.turn.stopTerminalPending = true
        let firstDone = Task { await s.waitForStopTerminal(.milliseconds(80)) }
        await Task.yield()
        s.stopTerminalReached()
        #expect(await firstDone.value == true)

        // Immediately start a second wait with a long timeout; the first waiter's cancelled 80 ms timer must NOT fire it.
        s.turn.stopTerminalPending = true
        let secondFinished = Mutex(false)
        let secondWait = Task { @MainActor in
            let reached = await s.waitForStopTerminal(.seconds(5))
            secondFinished.withLock { $0 = true }
            return reached
        }
        try? await Task.sleep(for: .milliseconds(160))
        #expect(!secondFinished.withLock { $0 }, "stale cancelled timeout woke the next stop waiter early")

        s.stopTerminalReached()
        #expect(await secondWait.value == true)
        s.stopObserving()
    }

    // M20 (part 2): A second steer queued behind an in-flight steer must respect stopEpoch and skip session.redirect.
    @Test func steerTypedQueuedBehindPriorSteerRespectsStopEpoch() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())

        let redirectGate = Latch()
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.redirect":
                try await redirectGate.wait()
                return ["status": "rejected"]
            case "session.interrupt": return ["status": "interrupted"]
            default: return [:]
            }
        }

        s.send("initial prompt")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Working"])])

        s.send("first steer")
        #expect(await waitUntil { h.client.calls("session.redirect").count == 1 })
        s.send("second steer")

        // Stop bumps stopEpoch before second steer reaches finishSteer.
        s.stop()
        redirectGate.open()

        #expect(await waitUntil { s.queuedMessages.count == 2 })
        #expect(h.client.calls("session.redirect").count == 1, "second steer must not send session.redirect after Stop")
        #expect(s.isQueueParked)
        #expect(s.queuedMessages.map(\.text) == ["first steer", "second steer"])
        s.stopObserving()
    }

    // H1: Reconnect replay cursor check must not overflow when lastSeq == Int.max.
    @Test func reconnectReplayCheckDoesNotOverflowAtIntMax() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())

        s.lastSeq = Int.max
        let rid = try #require(s.runtimeSessionId)
        s.parked = [GatewayEvent(type: "message.delta", sessionId: rid, seq: Int.max, payload: ["text": ""])]
        await s.reconnect(reason: "gateway.ready")
        #expect(s.lastSeq == Int.max)
        s.stopObserving()
    }
}

// MARK: - Voice, Audio, Parakeet, Media & Attachments regressions

@Suite("Voice, audio, media & attachments stress regressions", .serialized)
@MainActor
struct VoiceAndMediaStressRegressionTests {
    // C8: Concurrent GrokLiveAudio play/flush/revive vs stop/restart must never crash or throw NSException.
    nonisolated private static func exerciseGrokLiveAudioConcurrently(_ audio: GrokLiveAudio, chunk: Data) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for i in 0..<80 {
                    _ = audio.play(chunk)
                    if i % 7 == 0 { audio.flush() }
                    if i % 11 == 0 { _ = audio.revive() }
                    _ = audio.isRunning
                    _ = audio.inputDescription
                }
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for _ in 0..<12 {
                    let kept = audio.stop(keeping: true)
                    _ = try? audio.startSpeakerOnly()
                    audio.requeue(kept)
                    Thread.sleep(forTimeInterval: 0.002)
                }
                audio.stop()
                group.leave()
            }
            group.notify(queue: .global()) { done.resume() }
        }
    }

    @Test func grokLiveAudioConcurrentPlayFlushReviveAndStopDoesNotCrash() async throws {
        let audio = GrokLiveAudio()
        try audio.startSpeakerOnly()
        defer { audio.stop() }

        var pcm = Data()
        for index in 0..<480 {
            let sample = Int16(400 * sin(Double(index) * 2 * .pi * 440 / 24_000))
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        await Self.exerciseGrokLiveAudioConcurrently(audio, chunk: pcm)
        #expect(!audio.isRunning)
    }

    // H18 (part 1): releaseAbandoned with a stale grant never tears down a newer session.
    @Test func audioSessionCoordinatorReleaseAbandonedIgnoresStaleGrant() async throws {
        let coordinator = AudioSessionCoordinator.shared
        let priorSimulated = coordinator.simulatedOwners
        coordinator.simulatedOwners = [.memoRecording, .conversation]
        defer {
            coordinator.release(.conversation)
            coordinator.release(.memoRecording)
            coordinator.simulatedOwners = priorSimulated
        }

        let oldGrant = try await coordinator.acquire(.memoRecording)
        let newGrant = try await coordinator.acquire(.conversation, mode: .voiceChat)
        #expect(newGrant > oldGrant)
        #expect(coordinator.owner == .conversation)

        // Abandoned memo take releases with its stale grant: must leave the live conversation untouched.
        coordinator.releaseAbandoned(.memoRecording, grant: oldGrant)
        #expect(coordinator.owner == .conversation)
        #expect(coordinator.grant == newGrant)

        // Matching grant releases cleanly.
        coordinator.releaseAbandoned(.conversation, grant: newGrant)
        #expect(coordinator.owner == nil)
    }

    // H18 (part 2): TalkController.fallBack chains transport.close() onto shuttingDown so endForAnotherMicrophone awaits it.
    @Test func talkControllerFallBackChainsTransportCloseOntoShuttingDown() async {
        let priorEngine = TalkController.chosenEngine
        TalkController.chosenEngine = nil
        defer { TalkController.chosenEngine = priorEngine }

        let controller = TalkController()
        let transport = StressSlowCloseTransport()
        let chat = FakeTalkChat()
        controller.holdsLeases = false
        controller.isOnScreen = { true }
        controller.makeLiveTransport = { transport }
        controller.makeCapture = { _ in LiveInertCapture() }
        controller.loadConfig = { _ in
            var config = TalkConfig()
            config.chatMode = .gptLive
            config.sttEnabled = true
            return config
        }
        controller.loadLiveStatus = { _ in LiveVoiceStatus(mode: .gptLive, available: true) }
        controller.exchangeLive = { _, _, _ in "v=0\r\n" }

        controller.start(in: chat, name: "Ivy")
        #expect(await waitUntil { transport.started })

        // Drop triggers fallBack -> transport.close() blocks on closeGate.
        transport.onDropped?("connection_lost")
        #expect(await waitUntil { transport.closeEntered })

        let ended = Mutex(false)
        let endTask = Task { @MainActor in
            await controller.endForAnotherMicrophone()
            ended.withLock { $0 = true }
        }
        try? await Task.sleep(for: .milliseconds(60))
        #expect(!ended.withLock { $0 }, "endForAnotherMicrophone returned before fallback transport.close() completed")

        transport.closeGate.open()
        await endTask.value
        #expect(transport.closed)
        await controller.resetForTests()
    }

    // H20: Switching ParakeetWords off during load does not wedge .loading, and rapid off/on serializes loads.
    @Test func parakeetWordsOffToggleDoesNotWedgeAndSerializesLoads() async {
        defer {
            ParakeetWords.resetForTests()
            UserDefaults.standard.removeObject(forKey: ParakeetWords.settingKey)
        }
        ParakeetWords.resetForTests()

        let gate1 = StressUncancellableGate()
        let entered1 = Latch()
        let gate2 = StressUncancellableGate()
        let entered2 = Latch()
        let activeCount = Mutex(0)
        let maxConcurrent = Mutex(0)
        let loadCalls = Mutex(0)

        ParakeetWords.debugModelsExist = { true }
        ParakeetWords.debugLoader = {
            let call = loadCalls.withLock { n -> Int in n += 1; return n }
            let nowActive = activeCount.withLock { n -> Int in n += 1; return n }
            maxConcurrent.withLock { $0 = max($0, nowActive) }
            defer { activeCount.withLock { $0 -= 1 } }
            if call == 1 {
                entered1.open()
                await gate1.wait()
                throw NSError(domain: "StressParakeet", code: 42)
            }
            if call == 2 {
                entered2.open()
                await gate2.wait()
            }
            return StressParakeetHearing()
        }

        ParakeetWords.setOn(true)
        #expect(await waitUntil { ParakeetWords.readiness == .loading })
        try? await entered1.wait()

        // Turn off while load #1 is in flight: readiness goes .unknown, and when load #1 fails it must stay .unknown.
        ParakeetWords.setOn(false)
        #expect(ParakeetWords.readiness == .unknown)
        gate1.open()
        try? await Task.sleep(for: .milliseconds(60))
        #expect(ParakeetWords.readiness == .unknown)

        // Rapid off -> on while load #2 is STILL blocked: load #3 must serialize behind load #2 (maxConcurrent == 1).
        ParakeetWords.setOn(true)
        try? await entered2.wait()
        ParakeetWords.setOn(false)
        ParakeetWords.setOn(true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(loadCalls.withLock { $0 } == 2, "load #3 must wait for load #2 to finish before starting")
        gate2.open()
        #expect(await waitUntil { ParakeetWords.readiness == .ready })
        #expect(loadCalls.withLock { $0 } == 3)
        #expect(maxConcurrent.withLock { $0 } == 1)
    }

    // H21: MediaLoader.purge cancels fileFlights, clears seeded keys, and rethrows CancellationError.
    @Test func mediaLoaderPurgeCancelsFileFlightsClearsSeededAndRethrowsCancellation() async {
        let client = FakeTransferClient()
        let accountId = client.account.id
        _ = AttachmentCenter.center(for: client.account, client: client)
        defer { AttachmentCenter.signedOut(accountId: accountId) }

        let downloadStarted = Latch()
        client.onDownload { _, _, _, _ in
            downloadStarted.open()
            try await Task.sleep(for: .seconds(30))
        }

        let context = MediaContext(accountId: accountId, profile: "ivy", storedSessionId: "s1")
        let seededKey = MediaStore.gatewayKey(accountId: accountId, profile: "ivy", path: "photos/a.png")
        MediaLoader.shared.markSeeded(seededKey)
        #expect(MediaLoader.shared.debugIsSeeded(seededKey))

        let task = Task<URL, Error> {
            try await MediaLoader.shared.file(path: "docs/report.pdf", name: "report.pdf", context: context, progressKey: "p-stress")
        }
        try? await downloadStarted.wait()
        #expect(await waitUntil { MediaLoader.shared.debugFileFlights == 1 })

        MediaLoader.shared.purge(accountId: accountId)
        #expect(MediaLoader.shared.debugFileFlights == 0)
        #expect(!MediaLoader.shared.debugIsSeeded(seededKey))

        do {
            _ = try await task.value
            Issue.record("expected CancellationError after purge")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    // M17: MemoController preserves Live Words when a native interruption saves the take as a draft.
    @Test func memoControllerPreservesLiveWordsOnNativeStoppedDraft() async throws {
        let accountId = "memo-words-\(UUID().uuidString)"
        VoiceTestStores.activate(accountId)
        defer { MemoAccountStores.shared.deactivate(purge: true) }

        let file = try VoiceTestStores.recording(accountId, seconds: 3)
        let capture = FakeCapture(file: file)
        let listener = StressWordsListener("buy fresh apples")
        let controller = MemoController(capture: capture)
        controller.tapsMicrophone = false
        controller.makeWords = { _ in listener }

        let target = MemoTarget(scope: "\(accountId)|ivy|s1", host: nil, session: nil, botName: "Ivy",
                                accountKey: MemoPaths.accountKey(accountId))
        controller.memoDown(target, width: 402)
        #expect(await waitUntil { controller.state.phase == .holding })

        capture.nativeStop(.interrupted)
        #expect(await waitUntil { MemoAccountStores.shared.drafts?.draft(for: target.scope) != nil })
        let saved = try #require(MemoAccountStores.shared.drafts?.draft(for: target.scope))
        #expect(!listener.wasCancelled)
        #expect(saved.words == "buy fresh apples")
    }

    // M18: TalkSpeaker.runPhone breaks cleanly when output.pending stalls; ReadAloudCenter stops on interruption/route loss.
    @Test func talkSpeakerRunPhoneBreaksOnStalledPendingAndReadAloudStopsOnInterruption() async {
        let coordinator = AudioSessionCoordinator.shared
        let priorSimulated = coordinator.simulatedOwners
        coordinator.simulatedOwners.insert(.speech)
        defer {
            coordinator.release(.speech)
            coordinator.simulatedOwners = priorSimulated
        }

        let stalledOutput = StressStalledSpeechOutput()
        let speaker = TalkSpeaker(output: stalledOutput)
        speaker.choice = { .phone }
        speaker.phonePendingStallLimit = 0.15
        speaker.makePhoneRenderer = { StressPhoneRenderer() }

        let client = FakeGatewayClient()
        let session = speaker.open(messageId: "m-stall", profile: "ivy", client: client, owner: .readAloud, host: nil)
        session.append("First sentence. Second sentence.")
        session.finish()

        let start = ContinuousClock.now
        let outcome = await session.outcome
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(2), "stalled runPhone hung for \(elapsed)")
        if case .failed = outcome {
            // Expected clean break.
        } else {
            Issue.record("expected .failed on stalled output, got \(outcome)")
        }

        // ReadAloudCenter stops on AVAudioSession interruption and headphone disconnect.
        let center = ReadAloudCenter()
        let fakeSpeaker = FakeSpeaker()
        center.speaker = fakeSpeaker
        center.holdsLeases = false
        center.conversationLive = { false }
        let chat = FakeTalkChat()

        center.toggle(messageId: "m1", markdown: "Read this aloud.", in: chat)
        fakeSpeaker.begin()
        #expect(center.state == .speaking("m1"))
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        #expect(await waitUntil { center.state == .idle })

        center.toggle(messageId: "m2", markdown: "Read this too.", in: chat)
        fakeSpeaker.begin()
        #expect(center.state == .speaking("m2"))
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        )
        #expect(await waitUntil { center.state == .idle })
    }

    // L6: AttachmentCenter.returnToDraft keeps active .uploading state and resets stale .uploading.
    @Test func attachmentCenterReturnToDraftPreservesActiveUploading() async throws {
        let client = FakeTransferClient()
        let center = AttachmentCenter(account: client.account, client: client)
        center.debugSetConnectionReady(true)
        let gate = Latch()
        defer { gate.open(); AttachmentCenter.signedOut(accountId: client.account.id) }
        client.onUpload { upload, _ in
            try await gate.wait()
            return Data("{\"path\":\"\(FakeTransferClient.destination(upload.body))\"}".utf8)
        }

        let id = UUID().uuidString
        _ = try center.staging.write(Data("abc".utf8), id: id, name: "photo.jpg")
        let active = DraftAttachment(id: id, kind: .image, name: "photo.jpg", localFile: "\(id)/photo.jpg",
                                     byteSize: 3, pixelWidth: 10, pixelHeight: 10, typeIdentifier: "public.jpeg", upload: .waiting)
        center.add(active, scope: "s-draft", profile: "default")
        #expect(await waitUntil { if case .uploading? = center.items[id]?.upload { return true }; return false })

        let taken = center.takeForSend("s-draft")
        // Also return a stale item whose upload claims .uploading even though it is not `current`.
        let staleId = UUID().uuidString
        _ = try center.staging.write(Data("xyz".utf8), id: staleId, name: "notes.txt")
        let stale = DraftAttachment(id: staleId, kind: .file, name: "notes.txt", localFile: "\(staleId)/notes.txt",
                                    byteSize: 3, pixelWidth: nil, pixelHeight: nil, typeIdentifier: "public.plain-text",
                                    upload: .uploading(sent: 1, total: 3))

        center.returnToDraft("s-draft", profile: "default", text: nil, attachments: taken.attachments + [stale], setTextIfEmpty: false)
        if case .uploading? = center.items[id]?.upload {
            // Expected: active upload state preserved.
        } else {
            Issue.record("active upload was unexpectedly reset to \(String(describing: center.items[id]?.upload))")
        }
        if case .waiting? = center.items[staleId]?.upload {
            // Expected: non-current stale uploading reset to waiting.
        } else {
            Issue.record("stale uploading item was not reset to .waiting: \(String(describing: center.items[staleId]?.upload))")
        }
        gate.open()
    }

    // L7: Temporary directories created by MediaSource, MediaActions.namedCopy, and AttachmentDrop are cleaned up.
    @Test func mediaActionsAndAttachmentDropCleanUpTempDirectories() async throws {
        let fm = FileManager.default
        let tempURL = try MediaSource.temporaryFile(Data([0xFF, 0xD8, 0xFF]), name: "shot", ext: "jpg")
        let viewerDir = tempURL.deletingLastPathComponent()
        #expect(fm.fileExists(atPath: viewerDir.path))
        MediaActions.removeViewerTempIfOwned(tempURL)
        #expect(!fm.fileExists(atPath: viewerDir.path))

        let shareBefore = Set(((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("HQNShare-") })
        let missing = fm.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).jpg")
        #expect(MediaActions.namedCopy(missing, name: "shot.jpg") == nil)
        let shareAfter = Set(((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("HQNShare-") })
        #expect(shareAfter == shareBefore)

        let dropBefore = Set(((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("HQNDrop-") })
        do {
            _ = try await AttachmentDrop.copyOut(NSItemProvider())
            Issue.record("expected empty NSItemProvider to throw")
        } catch {
            // Expected.
        }
        let dropAfter = Set(((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("HQNDrop-") })
        #expect(dropAfter == dropBefore)
    }
}
