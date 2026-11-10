// A-U2 (MemoPolicy) and A-U3 (MemoText) from docs/spec/1x-voice.md §9.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Memo policy (A-U2)")
struct MemoPolicyTests {
    @Test func finishTable() {
        #expect(MemoPolicy.finish(reason: .limit, elapsed: 0.2) == .await)
        #expect(MemoPolicy.finish(reason: .limit, elapsed: 600) == .await)
        #expect(MemoPolicy.finish(reason: .cancel, elapsed: 30) == .discard)
        for reason in [MemoStopReason.interrupted, .routeLost, .reset, .background, .error] {
            #expect(MemoPolicy.finish(reason: reason, elapsed: 1) == .draft)
            #expect(MemoPolicy.finish(reason: reason, elapsed: 12) == .draft)
            #expect(MemoPolicy.finish(reason: reason, elapsed: 0.99) == .discard)
        }
    }

    @Test func retryOnlyForTheSameLiveTake() {
        #expect(MemoPolicy.mayRetry(sameTake: true, stopped: false, active: true, backgrounded: false))
        #expect(!MemoPolicy.mayRetry(sameTake: false, stopped: false, active: true, backgrounded: false))
        #expect(!MemoPolicy.mayRetry(sameTake: true, stopped: true, active: true, backgrounded: false))
        #expect(!MemoPolicy.mayRetry(sameTake: true, stopped: false, active: false, backgrounded: false))
        #expect(!MemoPolicy.mayRetry(sameTake: true, stopped: false, active: true, backgrounded: true))
    }

    @Test func levels() {
        #expect(MemoPolicy.level(power: -50) == 0)
        #expect(MemoPolicy.level(power: -160) == 0)
        #expect(MemoPolicy.level(power: 0) == 1)
        #expect(MemoPolicy.level(power: 3) == 1)
        #expect(MemoPolicy.level(power: -25) == 0.5)
    }

    @Test func peaksStretchAndKeepEachStretchsLoudest() {
        let three = MemoPolicy.peaks([0.1, 0.5, 0.25], count: 48)
        #expect(three.count == 48)
        #expect(three.first == 0.1)
        #expect(three[16] == 0.5)
        #expect(three.last == 0.25)
        #expect(Set(three) == [0.1, 0.5, 0.25])
        // Many samples: each bar is its stretch's loudest, three decimals.
        let many = (0..<480).map { Double($0 % 10) / 9 }
        let bars = MemoPolicy.peaks(many)
        #expect(bars.count == 48)
        #expect(bars.allSatisfy { $0 == 1 })
        #expect(MemoPolicy.peaks([0.12345]).first == 0.123)
        #expect(MemoPolicy.peaks([]) == Array(repeating: 0, count: 48))
    }

    @Test func limitSeconds() {
        #expect(MemoPolicy.limitSeconds(limitBytes: 32 * 1024 * 1024) == 600)
        #expect(MemoPolicy.limitSeconds() == 600)
        // The spec's 512 KB example gives 83 s (0.95 × 524,288 / 6,000); a 60 KB limit is the one too small to record.
        #expect(MemoPolicy.limitSeconds(limitBytes: 512 * 1024) == 83)
        #expect(MemoPolicy.limitSeconds(limitBytes: 60_000) < MemoPolicy.minimumLimit)
    }

    @Test func lengthsRoundDown() {
        #expect(MemoPolicy.length(4.69) == "0:04")
        #expect(MemoPolicy.length(90) == "1:30")
        #expect(MemoPolicy.length(600) == "10:00")
        #expect(MemoPolicy.length(-3) == "0:00")
        #expect(MemoPolicy.length(.nan) == "0:00")
    }

    /// A finished memo's total rounds to the nearest second (Telegram): a 2.0 s hold records about 1.9 s.
    @Test func totalsRound() {
        #expect(MemoPolicy.total(1.9) == "0:02")
        #expect(MemoPolicy.total(1.49) == "0:01")
        #expect(MemoPolicy.total(59.6) == "1:00")
        #expect(MemoPolicy.total(.nan) == "0:00")
        #expect(MemoPolicy.length(1.9) == "0:01", "a running clock still rounds down")
    }
}

@Suite("Memo text (A-U3)")
struct MemoTextTests {
    private let gateway = "/Users/owner/.hermes/profiles/ivy/attachments/voice-memo-2.m4a"

    @Test func storedRoundTrip() throws {
        let text = MemoText.reference(path: gateway, said: .text("Pick up milk on the way home."))
        #expect(text == "MEDIA:\"\(gateway)\"\n\nVoice memo transcript: Pick up milk on the way home.")
        let memo = try #require(VoiceMemo.parse(text))
        #expect(memo.path == gateway)
        #expect(memo.transcript == .text("Pick up milk on the way home."))
        #expect(memo.rest.isEmpty)
        #expect(memo.title == "Voice Memo")
    }

    @Test func optimisticFailedOffEmptyAndTyped() throws {
        let local = "/var/mobile/Containers/Data/Application/X/Library/Application Support/memos/abc/1/voice-memo.m4a"
        let optimistic = try #require(VoiceMemo.parse(MemoText.optimistic(localPath: local, typed: "")))
        #expect(optimistic.path == local)
        #expect(optimistic.transcript == .pending)
        let typed = try #require(VoiceMemo.parse(MemoText.optimistic(localPath: local, typed: "  and this  ")))
        #expect(typed.rest == "and this")

        #expect(try #require(VoiceMemo.parse(MemoText.reference(path: gateway, said: .failed))).transcript == .failed)
        #expect(try #require(VoiceMemo.parse(MemoText.reference(path: gateway, said: .off))).transcript == .off)
        let empty = MemoText.reference(path: gateway, said: .empty)
        #expect(empty.hasSuffix("Voice memo transcript: (No speech detected)"))
        #expect(try #require(VoiceMemo.parse(empty)).transcript == .text("(No speech detected)"))
        #expect(MemoText.reference(path: gateway, said: .text("   ")).hasSuffix("(No speech detected)"))

        let withText = MemoText.prompt(reference: MemoText.reference(path: gateway, said: .text("Hello.")), typed: "See you at six")
        let both = try #require(VoiceMemo.parse(withText))
        #expect(both.transcript == .text("Hello."))
        #expect(both.rest == "See you at six")
        #expect(MemoText.prompt(reference: "R", typed: "") == "R")
    }

    @Test func missingTranscriptsAreNotReused() {
        #expect(MemoText.transcriptMissing(MemoText.reference(path: gateway, said: .off)))
        #expect(MemoText.transcriptMissing(MemoText.reference(path: gateway, said: .failed)))
        #expect(!MemoText.transcriptMissing(MemoText.reference(path: gateway, said: .text("Hi"))))
        #expect(!MemoText.transcriptMissing(MemoText.reference(path: gateway, said: .empty)))
    }

    @Test func gatewayMemoPath() {
        #expect(MemoText.gatewayMemoPath("/a/voice-memo.m4a") == "/a/voice-memo.m4a")
        #expect(MemoText.gatewayMemoPath("C:\\x\\voice-memo.wav") == "C:\\x\\voice-memo.wav")
        #expect(MemoText.gatewayMemoPath("C:/x/voice-memo.wav") == "C:/x/voice-memo.wav")
        #expect(MemoText.gatewayMemoPath("/a/voi\"ce.m4a") == nil)          // a quote
        #expect(MemoText.gatewayMemoPath("/a/voice\nmemo.m4a") == nil)      // a newline
        #expect(MemoText.gatewayMemoPath("a/voice-memo.m4a") == nil)        // relative
        #expect(MemoText.gatewayMemoPath("/a\\b/voice-memo.m4a") == nil)    // a backslash in a POSIX path
        #expect(MemoText.gatewayMemoPath("/a/notes.txt") == nil)            // not audio
        #expect(MemoText.gatewayMemoPath(nil) == nil)
    }

    /// The bubble's words for every transcript state (spec §4.5, §5).
    @Test func bubbleWords() throws {
        let stored = try #require(VoiceMemo.parse(MemoText.reference(path: gateway, said: .off)))
        #expect(MemoBubbleInfo.make(stored, pending: false, failed: false, open: false).wordsText
                == "No transcript: speech-to-text is off on your gateway.")
        let pending = try #require(VoiceMemo.parse("MEDIA:\"\(gateway)\""))
        #expect(MemoBubbleInfo.make(pending, pending: true, failed: false, open: false).wordsText == "Transcribing…")
        #expect(MemoBubbleInfo.make(pending, pending: false, failed: false, open: false).wordsText == "No transcript")
        #expect(MemoBubbleInfo.make(pending, pending: true, failed: true, open: false).wordsText
                == "Transcription unavailable. Check the memo’s delivery status.")
        let failed = try #require(VoiceMemo.parse(MemoText.reference(path: gateway, said: .failed)))
        #expect(MemoBubbleInfo.make(failed, pending: false, failed: false, open: false).wordsText == "No transcript")
    }
}
