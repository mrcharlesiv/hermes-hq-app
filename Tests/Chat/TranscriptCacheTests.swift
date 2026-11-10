import Foundation
import Testing
@testable import HermesHQNative

@Suite("Transcript cache (spec 03 §7.2.1)")
struct TranscriptCacheTests {
    /// 120 performance-fixture messages followed by the Plaid tail (tool turns with big outputs) as the newest.
    private func plaidMessages() throws -> HydratedPage {
        var rows = try ChatFixtures.json("perf-page-older.json")["messages"]?.array ?? []
        rows += try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []
        rows += try ChatFixtures.json("plaid-page-older.json")["messages"]?.array ?? []
        rows += try ChatFixtures.json("plaid-page-latest-24.json")["messages"]?.array ?? []
        return Hydration.fold(rows, pageSeq: 1)
    }

    @Test func roundTripKeepsNewest40() throws {
        let folded = try plaidMessages()
        #expect(folded.messages.count > 40)
        let cache = makeTempCache()
        cache.save(folded.messages, meta: folded.meta, account: "acct", profile: "default", storedId: "s1")
        cache.flush()
        // A second instance on the same folder reads from disk (no memory hit).
        let disk = TranscriptCache(root: cache.root)
        let entry = try #require(disk.loadEntry(account: "acct", profile: "default", storedId: "s1"))
        #expect(entry.messages.count == 40)
        // A tool row's trailing note ("12 KB output") is not kept in the cache; the fresh page brings it back.
        func plain(_ messages: [ChatMessage]) -> [ChatMessage] {
            messages.map { m in var m = m; m.parts = m.parts.map { if case .tool(var c) = $0 { c.note = nil; return .tool(c) } else { return $0 } }; return m }
        }
        #expect(plain(entry.messages) == plain(Array(folded.messages.suffix(40))))
        // Tool details are kept as their cache copy (heads only; the diff only for the newest turn).
        let newestAssistant = entry.messages.last { $0.role == .assistant }?.id
        var details = 0
        for m in entry.messages {
            var expected = folded.meta[m.id]
            let slim = (folded.meta[m.id]?.tools ?? [:]).mapValues { $0.slimmedForCache(keepDiff: m.id == newestAssistant) }
            expected?.tools = slim
            #expect(entry.meta[m.id] == expected)
            for d in entry.meta[m.id]?.tools.values ?? [:].values {
                details += 1
                #expect(d.isCacheCopy)
                #expect((d.stdout?.utf8.count ?? 0) <= ToolDetail.cacheHeadBytes)
                #expect((d.detail?.utf8.count ?? 0) <= ToolDetail.cacheHeadBytes)
            }
        }
        #expect(details > 0)
        #expect(!entry.partial)
        #expect(disk.load(account: "acct", profile: "other", storedId: "s1") == nil)
        #expect(disk.load(account: "other", profile: "default", storedId: "s1") == nil)
    }

    @Test func coldLoadIsFast() throws {
        let folded = try plaidMessages()
        let cache = makeTempCache()
        cache.save(folded.messages, meta: folded.meta, account: "acct", profile: "default", storedId: "fast")
        cache.flush()
        let bytes = cache.diskBytes
        var timings: [Double] = []
        for _ in 0..<15 {
            let fresh = TranscriptCache(root: cache.root)
            let start = ContinuousClock.now
            let messages = fresh.load(account: "acct", profile: "default", storedId: "fast")
            let elapsed = ContinuousClock.now - start
            #expect(messages?.count == 40)
            timings.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        timings.sort()
        let median = timings[timings.count / 2]
        print("transcript cache: 40 messages, \(bytes) bytes on disk, cold load median \(String(format: "%.3f", median)) ms, max \(String(format: "%.3f", timings.last!)) ms")
        #expect(median < 5.0)
        // Warm (memory) hit.
        let start = ContinuousClock.now
        _ = cache.load(account: "acct", profile: "default", storedId: "fast")
        let warm = ContinuousClock.now - start
        #expect(warm < .milliseconds(1))
    }

    @Test func oversizedEntryStepsDownThenGoesPartial() throws {
        let limits = TranscriptCache.Limits(entryBytes: 8 * 1024)
        let cache = makeTempCache(limits: limits)
        let big = String(repeating: "lorem ipsum ", count: 300)       // ~3.6 KB each
        let messages = (0..<40).map { i in
            ChatMessage(id: "stored-row-\(i + 1)-assistant", role: .assistant, parts: [.text("\(i) " + big)], timestamp: nil, rowId: i + 1)
        }
        let data = try #require(cache.admit(TranscriptEntry(messages: messages, meta: [:], savedAt: Date())))
        let entry = try TranscriptEntry.decode(data)
        #expect(entry.messages.count == 1)            // 40 → 8 → 3 → 1
        #expect(!entry.partial)

        let huge = ChatMessage(id: "stored-row-99-assistant", role: .assistant, parts: [.text(String(repeating: "x", count: 50_000))],
                               timestamp: nil, rowId: 99)
        let partialData = try #require(cache.admit(TranscriptEntry(messages: [huge], meta: [:], savedAt: Date())))
        let partial = try TranscriptEntry.decode(partialData)
        #expect(partial.partial)
        if case .text(let t)? = partial.messages.first?.parts.first {
            #expect(t.hasSuffix(TranscriptCache.partialNote))
            #expect(t.count <= 8000 + TranscriptCache.partialNote.count)
        } else { Issue.record("partial copy lost its text") }

        cache.save([huge], meta: [:], account: "a", profile: "p", storedId: "huge")
        cache.flush()
        let fresh = TranscriptCache(root: cache.root, limits: limits)
        #expect(fresh.load(account: "a", profile: "p", storedId: "huge") == nil)          // partial: offline restore only
        #expect(fresh.loadEntry(account: "a", profile: "p", storedId: "huge", allowPartial: true)?.partial == true)
    }

    @Test func evictsLeastRecentButNeverTheVisibleChat() throws {
        let cache = makeTempCache(limits: TranscriptCache.Limits(maxEntries: 3))
        let m = [ChatMessage(id: "stored-row-1-user", role: .user, parts: [.text("hi")], timestamp: nil, rowId: 1)]
        cache.setVisible(TranscriptCache.key(account: "a", profile: "p", storedId: "s0"))
        for i in 0..<5 {
            cache.save(m, meta: [:], account: "a", profile: "p", storedId: "s\(i)")
            cache.flush()
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(cache.entryCount == 3)
        let fresh = TranscriptCache(root: cache.root)
        #expect(fresh.load(account: "a", profile: "p", storedId: "s0") != nil)     // visible, kept
        #expect(fresh.load(account: "a", profile: "p", storedId: "s1") == nil)     // least recent, evicted
        #expect(fresh.load(account: "a", profile: "p", storedId: "s4") != nil)
    }

    @Test func purgeAndRemove() throws {
        let cache = makeTempCache()
        let m = [ChatMessage(id: "stored-row-1-user", role: .user, parts: [.text("hi")], timestamp: nil, rowId: 1)]
        cache.save(m, meta: [:], account: "a", profile: "p", storedId: "s1")
        cache.save(m, meta: [:], account: "b", profile: "p", storedId: "s1")
        cache.flush()
        cache.remove(account: "b", profile: "p", storedId: "s1")
        cache.purge(account: "a")
        cache.flush()
        let fresh = TranscriptCache(root: cache.root)
        #expect(fresh.load(account: "a", profile: "p", storedId: "s1") == nil)
        #expect(fresh.load(account: "b", profile: "p", storedId: "s1") == nil)
    }

    // [13-7] Sign-out purges the transcripts before the screen changes; the chat still open saves its tail as it
    // closes. That save is dropped until the account is signed in again.
    @Test func aChatClosingAfterSignOutDoesNotWriteItsTailBack() throws {
        let cache = makeTempCache()
        let m = [ChatMessage(id: "stored-row-1-user", role: .user, parts: [.text("hi")], timestamp: nil, rowId: 1)]
        cache.save(m, meta: [:], account: "a", profile: "p", storedId: "s1")
        cache.flush()
        cache.purge(account: "a")
        cache.save(m, meta: [:], account: "a", profile: "p", storedId: "s1")   // the open chat closing
        cache.save(m, meta: [:], account: "b", profile: "p", storedId: "s1")   // another account is untouched
        cache.flush()
        var fresh = TranscriptCache(root: cache.root)
        #expect(fresh.load(account: "a", profile: "p", storedId: "s1") == nil)
        #expect(fresh.load(account: "b", profile: "p", storedId: "s1") != nil)
        cache.reopen(account: "a")                                               // signed in again
        cache.save(m, meta: [:], account: "a", profile: "p", storedId: "s1")
        cache.flush()
        fresh = TranscriptCache(root: cache.root)
        #expect(fresh.load(account: "a", profile: "p", storedId: "s1") != nil)
    }

    // [13-16] The index rebuilt from disk names each file under the cache's folder even when the walk and the folder
    // spell the path differently (a link in it, as iOS's /var and /private/var).
    @Test func rebuiltIndexPathsResolveLinks() throws {
        let fm = FileManager.default
        let real = fm.temporaryDirectory.appending(path: "hq-cache-real-\(UUID().uuidString)", directoryHint: .isDirectory)
        let link = fm.temporaryDirectory.appending(path: "hq-cache-link-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? fm.removeItem(at: link); try? fm.removeItem(at: real) }
        let file = real.appending(path: "acct/p/s1.hqt")
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        #expect(TranscriptCache.relativePath(of: file, under: link) == "acct/p/s1.hqt")
        #expect(TranscriptCache.relativePath(of: link.appending(path: "acct/p/s1.hqt"), under: real) == "acct/p/s1.hqt")
        let elsewhere = fm.temporaryDirectory.appending(path: "elsewhere-\(UUID().uuidString).hqt")
        try Data("x".utf8).write(to: elsewhere)
        defer { try? fm.removeItem(at: elsewhere) }
        #expect(TranscriptCache.relativePath(of: elsewhere, under: real) == nil)
    }

    @Test func pendingAndStreamingRowsAreNotCached() throws {
        let cache = makeTempCache()
        var pending = ChatMessage(id: "local-user-1", role: .user, parts: [.text("sending")], timestamp: nil, rowId: nil)
        pending.isPending = true
        var streaming = ChatMessage(id: "local-assistant-2", role: .assistant, parts: [.text("typing")], timestamp: nil, rowId: nil)
        streaming.isStreaming = true
        let done = ChatMessage(id: "stored-row-1-user", role: .user, parts: [.text("hi")], timestamp: nil, rowId: 1)
        cache.save([done, pending, streaming], meta: [:], account: "a", profile: "p", storedId: "s")
        cache.flush()
        #expect(TranscriptCache(root: cache.root).load(account: "a", profile: "p", storedId: "s")?.map(\.id) == ["stored-row-1-user"])
    }

    // MARK: [perf] savedAt from the header (the warmer's staleness check)

    private func file(_ cache: TranscriptCache, _ account: String, _ profile: String, _ stored: String) -> URL {
        cache.root.appending(path: "\(TranscriptCache.accountKey(account))/\(profile)/\(stored).hqt", directoryHint: .notDirectory)
    }

    @Test func savedAtPeekReadsTheHeaderWithoutDecoding() throws {
        let cache = makeTempCache()
        let m = [ChatMessage(id: "stored-row-1-user", role: .user, parts: [.text("hi")], timestamp: nil, rowId: 1)]
        let when = Date(timeIntervalSince1970: 1_791_000_123.456)
        cache.save(m, meta: [:], account: "a", profile: "p", storedId: "s1", savedAt: when)
        // A save still waiting for its write answers from memory.
        #expect(cache.savedAtPeek(account: "a", profile: "p", storedId: "s1") == when)
        cache.flush()
        let fresh = TranscriptCache(root: cache.root)
        let peeked = try #require(fresh.savedAtPeek(account: "a", profile: "p", storedId: "s1"))
        #expect(abs(peeked.timeIntervalSince(when)) < 1e-6)
        #expect(fresh.memoryCount == 0, "no decode, nothing put in memory")
        #expect(fresh.savedAtPeek(account: "a", profile: "p", storedId: "missing") == nil)
    }

    @Test func savedAtPeekTreatsOldOrShortFilesAsMissingAndReadsPartialOnes() throws {
        var limits = TranscriptCache.Limits()
        limits.entryBytes = 2048
        let cache = makeTempCache(limits: limits)
        let m = [ChatMessage(id: "stored-row-1-user", role: .user, parts: [.text("hi")], timestamp: nil, rowId: 1)]
        cache.save(m, meta: [:], account: "a", profile: "p", storedId: "old")
        cache.save(m, meta: [:], account: "a", profile: "p", storedId: "short")
        let huge = ChatMessage(id: "stored-row-2-assistant", role: .assistant, parts: [.text(String(repeating: "x", count: 20_000))],
                               timestamp: nil, rowId: 2)
        let when = Date(timeIntervalSince1970: 1_791_000_000)
        cache.save([huge], meta: [:], account: "a", profile: "p", storedId: "partial", savedAt: when)
        cache.flush()
        var old = try Data(contentsOf: file(cache, "a", "p", "old"))
        old.replaceSubrange(0..<4, with: Array("HQT2".utf8))
        try old.write(to: file(cache, "a", "p", "old"))
        let short = try Data(contentsOf: file(cache, "a", "p", "short"))
        try short.prefix(12).write(to: file(cache, "a", "p", "short"))
        let fresh = TranscriptCache(root: cache.root, limits: limits)
        #expect(fresh.savedAtPeek(account: "a", profile: "p", storedId: "old") == nil)
        #expect(fresh.savedAtPeek(account: "a", profile: "p", storedId: "short") == nil)
        #expect(fresh.loadEntry(account: "a", profile: "p", storedId: "partial", allowPartial: true)?.partial == true)
        #expect(TranscriptCache(root: cache.root, limits: limits).savedAtPeek(account: "a", profile: "p", storedId: "partial") == when)
    }

    /// The warmer's checks used to push every chat they looked at into the 8-entry memory LRU, evicting the tails the
    /// owner opens. Peeking leaves memory as it was.
    @Test func savedAtPeekLeavesTheMemoryLRUAlone() throws {
        let cache = makeTempCache()
        let m = [ChatMessage(id: "stored-row-1-user", role: .user, parts: [.text("hi")], timestamp: nil, rowId: 1)]
        for i in 0..<28 { cache.save(m, meta: [:], account: "a", profile: "p", storedId: "s\(i)") }
        cache.flush()
        let fresh = TranscriptCache(root: cache.root)
        for i in 0..<8 { _ = fresh.load(account: "a", profile: "p", storedId: "s\(i)") }
        #expect(fresh.memoryCount == 8)
        for i in 8..<28 { #expect(fresh.savedAtPeek(account: "a", profile: "p", storedId: "s\(i)") != nil) }
        #expect(fresh.memoryCount == 8)
        // The first eight are still memory hits: with their files gone they still load.
        for i in 0..<8 { try FileManager.default.removeItem(at: file(fresh, "a", "p", "s\(i)")) }
        for i in 0..<8 { #expect(fresh.load(account: "a", profile: "p", storedId: "s\(i)") != nil) }
    }
}
