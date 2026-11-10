// A-U5 (stores), A-U6 (memo row layout) and A-U7 (waveform) from docs/spec/1x-voice.md §9.

import AVFAudio
import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@Suite("Memo stores (A-U5)", .serialized)
@MainActor
struct MemoStoreTests {
    private func key() -> String {
        _ = VoiceTestStores.base
        return MemoPaths.accountKey("store-test-\(UUID().uuidString)")
    }

    @Test func shapesKeepTheNewest64AndLinkLocalToGateway() {
        let key = key()
        let shapes = MemoShapeStore(accountKey: key)
        let peaks = Array(repeating: 0.5, count: 48)
        for i in 0..<70 { shapes.remember("/p/\(i).m4a", peaks: peaks, seconds: Double(i + 1)) }
        #expect(shapes.count == 64)
        #expect(shapes.shape(for: "/p/69.m4a") != nil)
        shapes.remember("/local/voice-memo.m4a", peaks: peaks, seconds: 3)
        shapes.link("/local/voice-memo.m4a", to: "/gateway/voice-memo-2.m4a")
        #expect(shapes.shape(for: "/gateway/voice-memo-2.m4a")?.seconds == 3)
        // Persisted: a new store for the account reads them back.
        MemoDisk.flush()
        #expect(MemoShapeStore(accountKey: key).shape(for: "/gateway/voice-memo-2.m4a")?.peaks == peaks)
        // Wrong shapes are refused.
        shapes.remember("/bad.m4a", peaks: [0.1], seconds: 1)
        #expect(shapes.shape(for: "/bad.m4a") == nil)
    }

    @Test func draftsRoundTripNewestFirstAndNeverLoseARecording() throws {
        let accountId = "draft-test-\(UUID().uuidString)"
        let key = MemoPaths.accountKey(accountId)
        let drafts = MemoDraftStore(accountKey: key)
        let first = try VoiceTestStores.recording(accountId)
        let second = try VoiceTestStores.recording(accountId, seconds: 3)
        drafts.set(first, for: "acct|ivy|s1")
        MemoDisk.flush()
        #expect(MemoDraftStore(accountKey: key).draft(for: "acct|ivy|s1") == first, "survives relaunch")
        // A memo handed back goes in front; the earlier draft waits behind it, its recording kept.
        drafts.set(second, for: "acct|ivy|s1")
        #expect(drafts.draft(for: "acct|ivy|s1") == second)
        #expect(FileManager.default.fileExists(atPath: first.path))
        // Taking it to send leaves the file; the earlier draft shows next.
        #expect(drafts.take("acct|ivy|s1") == second)
        #expect(drafts.draft(for: "acct|ivy|s1") == first)
        #expect(FileManager.default.fileExists(atPath: second.path))
        // Remove: the shown draft goes, with its recording.
        drafts.set(nil, for: "acct|ivy|s1")
        #expect(drafts.draft(for: "acct|ivy|s1") == nil)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        // Queued memos handed back when their chat was left: oldest first, with their words.
        let third = try VoiceTestStores.recording(accountId, seconds: 4)
        drafts.set(second, for: "acct|ivy|s2")
        drafts.restore([MemoDraft(memo: third, text: "and the eggs"), MemoDraft(memo: second, text: "")], for: "acct|ivy|s2")
        #expect(drafts.draft(for: "acct|ivy|s2") == third)
        #expect(drafts.text(for: "acct|ivy|s2") == "and the eggs")
        drafts.clearText(for: "acct|ivy|s2")
        #expect(drafts.text(for: "acct|ivy|s2") == nil)
        #expect(drafts.take("acct|ivy|s2") == third)
        #expect(drafts.take("acct|ivy|s2") == second, "the same recording isn't listed twice")
        #expect(drafts.draft(for: "acct|ivy|s2") == nil)
        // A bot chat opened before its id was known finds its draft once it knows it.
        drafts.set(second, for: "acct|default|")
        #expect(drafts.draft(for: "acct|default|20261010_1") == second)
        #expect(drafts.all["acct|default|"] == nil)
        // A draft whose file is gone is dropped on load.
        try FileManager.default.removeItem(atPath: second.path)
        MemoDisk.flush()
        #expect(MemoDraftStore(accountKey: key).draft(for: "acct|default|20261010_1") == nil)
    }

    /// iOS can move the app's container on an update: a draft saved under the old path is found under today's.
    @Test func draftsFollowAMovedContainer() throws {
        let accountId = "rebase-\(UUID().uuidString)"
        let key = MemoPaths.accountKey(accountId)
        let memo = try VoiceTestStores.recording(accountId)
        var moved = memo
        moved.path = "/var/mobile/Containers/Data/Application/OLD-UUID/Library/Application Support/memos/"
            + memo.path.components(separatedBy: "/memos/").last!
        let file = MemoPaths.memos(key).appending(path: "drafts.json")
        MemoPaths.ensure(file.deletingLastPathComponent())
        try JSONEncoder().encode(["acct|ivy|s1": [MemoDraft(memo: moved)]]).write(to: file)
        #expect(MemoDraftStore(accountKey: key).draft(for: "acct|ivy|s1")?.path == memo.path)
        // A drafts file written before drafts were lists still reads.
        try JSONEncoder().encode(["acct|ivy|s1": memo]).write(to: file)
        #expect(MemoDraftStore(accountKey: key).draft(for: "acct|ivy|s1") == memo)
    }

    /// memos/ and memos/<key>/ are kept out of backups on every sign-in; recordings no draft refers to go once a day
    /// old (a crash or a kill mid-send).
    @Test func signInExcludesBackupsAndSweepsOrphans() async throws {
        let accountId = "sweep-\(UUID().uuidString)"
        let key = MemoPaths.accountKey(accountId)
        let kept = try VoiceTestStores.recording(accountId)
        let orphan = try VoiceTestStores.recording(accountId)
        let fresh = try VoiceTestStores.recording(accountId)
        let old = Date(timeIntervalSinceNow: -2 * 86_400)
        for memo in [kept, orphan] {
            let folder = URL(fileURLWithPath: memo.path).deletingLastPathComponent()
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: memo.path)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
        }
        let drafts = MemoDraftStore(accountKey: key)
        drafts.set(kept, for: "acct|ivy|s1")
        MemoDisk.flush()
        MemoAccountStores.shared.deactivate(purge: false)
        MemoAccountStores.shared.activate(accountId: accountId)
        await MemoAccountStores.shared.sweepTask?.value
        #expect(FileManager.default.fileExists(atPath: kept.path), "a draft's recording stays")
        #expect(FileManager.default.fileExists(atPath: fresh.path), "a recording under a day old stays")
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: orphan.path).deletingLastPathComponent().path),
                "an old recording nothing refers to goes")
        for folder in [MemoPaths.memosRoot, MemoPaths.memos(key)] {
            #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true, "\(folder.lastPathComponent)")
        }
    }

    @Test func playbackCacheIsLRUAndPurges() throws {
        let key = key()
        let cache = MemoPlaybackCache(accountKey: key, maxFiles: 3, maxBytes: 1 << 20)
        MemoPaths.ensure(cache.folder)
        for i in 0..<5 {
            let url = cache.cacheURL(for: "/g/voice-memo-\(i).m4a")
            try Data(repeating: UInt8(i), count: 10).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(i - 10))], ofItemAtPath: url.path)
        }
        // Touch the oldest: it becomes the newest.
        #expect(cache.local(for: "/g/voice-memo-0.m4a") != nil)
        cache.evict()
        #expect(cache.fileCount == 3)
        #expect(cache.local(for: "/g/voice-memo-0.m4a") != nil)
        #expect(cache.local(for: "/g/voice-memo-1.m4a") == nil)
        #expect(cache.local(for: "/g/voice-memo-4.m4a") != nil)
        // Adopt: the recording moves in under its gateway path.
        let recording = try VoiceTestStores.recording("cache-\(key)")
        cache.adopt(URL(fileURLWithPath: recording.path), as: "/g/voice-memo-9.wav")
        #expect(cache.local(for: "/g/voice-memo-9.wav") != nil)
        #expect(!FileManager.default.fileExists(atPath: recording.path))
        cache.purge()
        #expect(cache.fileCount == 0)
    }

    @Test func speedCyclesAndPersists() {
        let saved = UserDefaults.standard.object(forKey: MemoPlayer.speedKey)
        defer { UserDefaults.standard.set(saved, forKey: MemoPlayer.speedKey) }
        UserDefaults.standard.removeObject(forKey: MemoPlayer.speedKey)
        let player = MemoPlayer.shared
        #expect(player.speed == 1)
        player.cycleSpeed(); #expect(player.speed == 1.5)
        #expect(UserDefaults.standard.double(forKey: MemoPlayer.speedKey) == 1.5)
        player.cycleSpeed(); #expect(player.speed == 2)
        player.cycleSpeed(); #expect(player.speed == 1)
        UserDefaults.standard.set(3.0, forKey: MemoPlayer.speedKey)
        #expect(player.speed == 1, "an unknown stored speed reads as 1×")
        #expect(MemoBubbleView.speedLabel(1.5) == "1.5×" && MemoBubbleView.speedLabel(2) == "2×")
    }

    @Test func signOutPurgesTheAccountsMemos() throws {
        let accountId = "purge-\(UUID().uuidString)"
        let recording = try VoiceTestStores.recording(accountId)
        let cache = MemoPlaybackCache(accountKey: MemoPaths.accountKey(accountId))
        MemoPaths.ensure(cache.folder)
        try Data([1]).write(to: cache.cacheURL(for: "/g/v.m4a"))
        MemoPaths.purge(accountId: accountId)
        #expect(!FileManager.default.fileExists(atPath: recording.path))
        #expect(cache.fileCount == 0)
    }
}

@Suite("Memo row layout (A-U6)")
@MainActor
struct MemoLayoutTests {
    private func rows(_ text: String, open: Bool = false, pending: Bool = false) -> [ChatRow] {
        var message = ChatMessage(id: "stored-row-7-user", role: .user, parts: [.text(text)], timestamp: Date(), rowId: 7)
        message.isPending = pending
        let input = ChatRowBuilder.Input(messages: [message], isRunning: false, botName: "Ivy",
                                         expanded: open ? ["stored-row-7-user|b0"] : [], scope: "t|ivy|s")
        return ChatRowBuilder.build(input).filter(\.isBubble)
    }

    private let long = "MEDIA:\"/g/voice-memo.m4a\"\n\nVoice memo transcript: " + String(repeating: "Pick up the milk and the bread on the way home. ", count: 8)
    private let short = "MEDIA:\"/g/voice-memo.m4a\"\n\nVoice memo transcript: Pick up milk."

    /// The measured height is what a drawn cell shows: every visible part of the memo sits inside the bubble above its
    /// bottom padding, and the bubble has no blank band below its last part beyond the time's own line.
    @Test func heightMatchesWhatIsDrawn() throws {
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            let style = ChatStyle.make(category: category)
            for (text, open) in [(short, false), (long, false), (long, true), ("MEDIA:\"/g/voice-memo.m4a\"", false)] {
                let label = "\(category.rawValue) \(open) \(text.prefix(40))"
                let row = try #require(rows(text, open: open).first)
                let layout = TextLayout.make(row, width: 402, style: style)
                guard case .bubble(let b) = layout.content, let memo = b.memo else { Issue.record("not a memo bubble"); continue }
                #expect(memo.playFrame.height == 44 && memo.waveFrame.height == MemoBubbleLayout.waveHeight)
                #expect(memo.cardFrame.contains(memo.waveFrame) && memo.cardFrame.contains(memo.lengthFrame), "the player sits on its card \(label)")
                #expect(memo.wordsFrame.minY >= memo.cardFrame.maxY, "the words start under the card \(label)")
                let cell = ChatBubbleCell(style: .default, reuseIdentifier: nil)
                cell.frame = CGRect(x: 0, y: 0, width: 402, height: layout.height)
                cell.configure(row, layout: layout)
                cell.layoutIfNeeded()
                let view = try #require(MemoViewTests.memoView(in: cell), "the cell draws the memo")
                let bubble = try #require(view.superview)
                #expect(abs(bubble.frame.height - b.frame.height) < 0.5, "the cell's bubble takes the measured height \(label)")
                #expect(abs(cell.convert(bubble.bounds, from: bubble).maxY - layout.height) < 0.5, "the row ends with the bubble \(label)")
                #expect(view.frame == bubble.bounds)
                let drawn = MemoViewTests.drawnFrames(view)
                let bottom = try #require(drawn.map(\.maxY).max())
                #expect(bottom <= view.bounds.height - ChatMetrics.bubblePadV + 0.5, "drawn inside the padding \(label)")
                #expect(drawn.allSatisfy { $0.minX >= -0.5 && $0.maxX <= view.bounds.width + 0.5 }, "nothing overhangs the sides \(label)")
                let slack = view.bounds.height - ChatMetrics.bubblePadV - bottom
                #expect(slack <= style.timeLineHeight + 4 + 0.5, "no blank band under the memo (\(slack) pt) \(label)")
                // The transcript shows its whole laid-out text unless clamped (then exactly 3 lines).
                let lines = MemoBubbleLayout.lineRects(memo.words)
                let visible = lines.count > 3 && memo.info.isTranscript && !open ? ceil(lines[2].maxY) : memo.words.size.height
                #expect(abs(memo.wordsFrame.height - visible) < 0.5, "\(label)")
                #expect(b.timeFrame.maxY <= b.frame.height)
            }
        }
    }

    @Test func clampedTranscriptOpensWithMoreAndLess() throws {
        let style = ChatStyle.make(category: .large)
        let closed = TextLayout.make(try #require(rows(long).first), width: 402, style: style)
        let open = TextLayout.make(try #require(rows(long, open: true).first), width: 402, style: style)
        guard case .bubble(let c) = closed.content, let cm = c.memo, case .bubble(let o) = open.content, let om = o.memo else {
            Issue.record("not memo bubbles"); return
        }
        #expect(cm.moreTitle == "More" && om.moreTitle == "Less")
        #expect(MemoBubbleLayout.lineRects(cm.words).count > 3)
        #expect(open.height > closed.height)
        let three = MemoBubbleLayout.lineRects(cm.words)[2].maxY
        #expect(abs(cm.wordsFrame.height - ceil(three)) < 0.5, "clamped to 3 lines")
        let short = TextLayout.make(try #require(rows(self.short).first), width: 402, style: style)
        guard case .bubble(let s) = short.content else { return }
        #expect(s.memo?.moreFrame == nil)
    }

    /// Playing and the speed button live inside the reserved 44 pt row: a memo that plays (and changes speed) moves
    /// nothing and grows nothing.
    @Test func playingAndSpeedNeverChangeTheHeight() async throws {
        let accountId = "layout-play-\(UUID().uuidString)"
        VoiceTestStores.activate(accountId)
        let recording = try VoiceTestStores.recording(accountId, seconds: 3)
        let saved = UserDefaults.standard.object(forKey: MemoPlayer.speedKey)
        defer {
            MemoPlayer.shared.stop()
            UserDefaults.standard.set(saved, forKey: MemoPlayer.speedKey)
        }
        UserDefaults.standard.set(1.0, forKey: MemoPlayer.speedKey)
        let style = ChatStyle.make(category: .large)
        let row = try #require(rows("MEDIA:\"\(recording.path)\"\n\nVoice memo transcript: Pick up milk.").first)
        let layout = TextLayout.make(row, width: 402, style: style)
        guard case .bubble(let b) = layout.content, let memo = b.memo else { Issue.record("not a memo bubble"); return }
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: nil)
        cell.frame = CGRect(x: 0, y: 0, width: 402, height: layout.height)
        cell.configure(row, layout: layout)
        cell.layoutIfNeeded()
        let view = try #require(MemoViewTests.memoView(in: cell))
        let speed = try #require(view.subviews.first { $0.accessibilityIdentifier == "memo.speed" })
        #expect(speed.isHidden, "no speed at rest at 1×")
        let atRest = MemoViewTests.frames(view)
        MemoPlayer.shared.play(recording.path) { URL(fileURLWithPath: recording.path) }
        #expect(await waitUntil(timeout: .seconds(5)) { MemoPlayer.shared.state(of: recording.path) == .playing })
        #expect(await waitUntil { !speed.isHidden }, "the speed shows while it plays")
        cell.layoutIfNeeded()
        #expect(MemoViewTests.frames(view) == atRest, "playing moves nothing")
        #expect(speed.frame == memo.speedFrame)
        #expect(speed.frame.minY >= memo.waveFrame.maxY, "the speed's target starts under the bars (a tap on them seeks)")
        let capsule = speed.convert(memo.speedCapsule, to: view)
        #expect(memo.cardFrame.contains(capsule), "the capsule sits on the card")
        #expect(speed.frame.maxX <= view.bounds.width, "inside the bubble")
        MemoPlayer.shared.cycleSpeed()
        MemoPlayer.shared.cycleSpeed()
        cell.layoutIfNeeded()
        #expect(MemoViewTests.frames(view) == atRest, "a speed change moves nothing")
        #expect(TextLayout.make(row, width: 402, style: style).height == layout.height)
        #expect(abs(view.bounds.height - b.frame.height) < 0.5)
    }

    @Test func barCountFollowsTheWidth() {
        // 3 pt bars on a 5 pt pitch: n bars need 5n − 2 pt.
        #expect(MemoBubbleLayout.barCount(waveWidth: 260) == 48)
        #expect(MemoBubbleLayout.barCount(waveWidth: 78) == 16)
        #expect(MemoBubbleLayout.barCount(waveWidth: 83) == 17)
        #expect(MemoBubbleLayout.barCount(waveWidth: 2) == 1)
        #expect(MemoBubbleLayout.barHeights([], count: 5) == Array(repeating: 0.18, count: 5))
        let heights = MemoBubbleLayout.barHeights((0..<48).map { Double($0) / 47 }, count: 24)
        #expect(heights.count == 24 && heights.first == 0.12 && heights.allSatisfy { $0 >= 0.12 && $0 <= 1 })
        #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 <= $1 }, "a rising track stays rising")
        #expect(heights.max() == 1, "the loudest bar fills the height")
        // Speech: a quiet word between pauses still shows; the pauses stay low.
        let speech = (0..<48).map { i -> Double in i % 6 == 0 ? 1 : (i % 6 == 3 ? 0.2 : 0.02) }
        let said = MemoBubbleLayout.barHeights(speech, count: 48)
        #expect(said[3] > 0.25 && said[2] < said[3], "\(said)")
        let style = ChatStyle.make(category: .large)
        let row = rows(short).first!
        guard case .bubble(let b) = TextLayout.make(row, width: 402, style: style).content, let memo = b.memo else { return }
        #expect(memo.waveFrame.width == CGFloat(memo.barCount) * MemoBubbleLayout.barPitch - MemoBubbleLayout.barGap,
                "the bars are never clipped (V10)")
        #expect(memo.lengthFrame.minY >= memo.waveFrame.maxY && memo.lengthFrame.minX == memo.waveFrame.minX, "the length sits under the bars")
        #expect(memo.speedFrame.minX + memo.speedCapsule.maxX == memo.waveFrame.maxX && memo.speedFrame.maxX <= b.frame.width,
                "the speed ends where the bars end")
        #expect(memo.waveFrame.maxX <= memo.cardFrame.maxX - 8, "the bars stay inside the card")
    }

    @Test func historyMemoRowsCarryTheirWords() throws {
        let row = try #require(rows("MEDIA:\"/g/voice-memo.m4a\"\n\nVoice memo transcript: (unavailable: speech-to-text is off on the gateway)\n\nAnd typed").first)
        guard case .bubble(let b) = row.kind else { return }
        #expect(b.memo?.wordsText == "No transcript: speech-to-text is off on your gateway.")
        #expect(rows("MEDIA:\"/g/voice-memo.m4a\"\n\nVoice memo transcript: Hi\n\nAnd typed").count == 2, "typed words are the next bubble")
    }
}

@Suite("Memo waveform (A-U7)")
struct MemoWaveformTests {
    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "wave-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    @Test func computesFortyEightPeaksAndTheLength() throws {
        let url = try write(MemoRecorder.fixtureWave(seconds: 3, levels: [0.2, 0.9, 0.4, 0.1, 0.6]))
        let (peaks, seconds) = try MemoWaveform.compute(url)
        #expect(peaks.count == 48)
        #expect(peaks.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(peaks.max() == 1)
        #expect(abs(seconds - 3) < 0.02)
    }

    @Test func refusesOverLongAudio() throws {
        // 700 s at 2 kHz, 16-bit mono (a valid WAV header and silence).
        let rate = 2000, frames = 700 * rate
        var header = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); u32(36 + frames * 2); header.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        header.append(contentsOf: Array("data".utf8)); u32(frames * 2)
        let url = try write(header + Data(count: frames * 2))
        #expect(throws: MemoWaveform.Failure.self) { try MemoWaveform.compute(url) }
    }
}
