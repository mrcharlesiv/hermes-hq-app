// More Accurate Words (docs/spec/3x-live-words.md §2.2): how a take is heard again as it grows, where a long one is
// cut, and what ends it. The model itself doesn't run in simulators (it is a 470 MB download): a stand-in "hears" one
// word per second of sound, and the model is checked on a Mac with `-HQDebugLiveWordsFile` (spec §7).

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

/// "Hears" a stretch as its length: 3.2 s of sound is "w w w" (and counts the passes).
nonisolated final class SecondsHearing: ParakeetHearing {
    let passes = Mutex<[Int]>([])
    let fails: Bool
    let delay: Duration

    init(fails: Bool = false, delay: Duration = .zero) {
        self.fails = fails
        self.delay = delay
    }

    func words(_ samples: [Float]) async -> String? {
        passes.withLock { $0.append(samples.count) }
        if delay > .zero { try? await Task.sleep(for: delay) }
        if fails { return nil }
        return Array(repeating: "w", count: samples.count / ParakeetCut.rate).joined(separator: " ")
    }
}

@Suite struct ParakeetWordsTests {
    private func feed(_ listener: any LiveWordsListening, seconds: Double, level: Int16 = 8_000) {
        let sound = [Int16](repeating: level, count: Int(seconds * Double(ParakeetCut.rate)))
        sound.withUnsafeBufferPointer { listener.feed($0) }
    }

    private func wait(_ seconds: Double = 2, until done: @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while await !done(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// A long take is cut where it is quietest, never in a word, and enough stays unsettled on both sides.
    @Test func aLongTakeIsCutAtItsQuietestMoment() {
        var sound = [Float](repeating: 0.5, count: 15 * ParakeetCut.rate)
        for index in (9 * ParakeetCut.rate)..<(9 * ParakeetCut.rate + ParakeetCut.rate / 2) { sound[index] = 0 }
        let cut = ParakeetCut.pause(in: sound)
        #expect(cut > 9 * ParakeetCut.rate && cut < 9 * ParakeetCut.rate + ParakeetCut.rate / 2)
        // A pause too early or too late isn't used: the cut stays between 6 s and 2 s from the end.
        var edges = [Float](repeating: 0.5, count: 15 * ParakeetCut.rate)
        for index in 0..<(3 * ParakeetCut.rate) { edges[index] = 0 }
        for index in (14 * ParakeetCut.rate)..<(15 * ParakeetCut.rate) { edges[index] = 0 }
        let kept = ParakeetCut.pause(in: edges)
        #expect(kept >= ParakeetCut.head && kept <= edges.count - ParakeetCut.tail)
    }

    /// The words so far show while the take runs, and the take's end settles them.
    @MainActor @Test func aTakeShowsItsWordsThenSettlesThem() async {
        let hearing = SecondsHearing()
        var shown: [LiveWordsText] = []
        let listener = ParakeetLiveWords(hearing: hearing) { shown.append($0) }
        feed(listener, seconds: 3)
        await wait { shown.last?.pending == "w w w" }
        #expect(shown.last == LiveWordsText(settled: "", pending: "w w w"))
        feed(listener, seconds: 2)
        let words = await listener.finish()
        #expect(words == "w w w w w")
        await wait { shown.last?.pending == "" }
        #expect(shown.last == LiveWordsText(settled: "w w w w w", pending: ""))
    }

    /// Past 14 s the oldest part settles, and no sound is heard twice or dropped: every second is one word.
    @MainActor @Test func aLongTakeSettlesInPartsAndKeepsEveryWord() async {
        let hearing = SecondsHearing()
        var shown: [LiveWordsText] = []
        let listener = ParakeetLiveWords(hearing: hearing) { shown.append($0) }
        for _ in 0..<4 {
            feed(listener, seconds: 10)
            try? await Task.sleep(for: .milliseconds(150))
        }
        let words = await listener.finish()
        // The cuts fall inside a second, so a part's last second and the next part's first can each lose their word.
        let count = words.split(separator: " ").count
        #expect(count >= 36 && count <= 40)
        #expect(shown.contains { !$0.settled.isEmpty && !$0.pending.isEmpty })
        #expect(hearing.passes.withLock { $0.allSatisfy { $0 <= 40 * ParakeetCut.rate } })
    }

    /// A model that fails gives no words, so the gateway hears the recording instead of half a memo going.
    @MainActor @Test func aFailedModelGivesNoWords() async {
        let listener = ParakeetLiveWords(hearing: SecondsHearing(fails: true)) { _ in }
        feed(listener, seconds: 3)
        #expect(await listener.finish() == "")
    }

    /// A cancelled take shows nothing more.
    @MainActor @Test func aCancelledTakeShowsNothingMore() async {
        var shown = 0
        let listener = ParakeetLiveWords(hearing: SecondsHearing(delay: .milliseconds(200))) { _ in shown += 1 }
        feed(listener, seconds: 3)
        listener.cancel()
        try? await Task.sleep(for: .milliseconds(500))
        #expect(shown == 0)
    }

    /// A tap of the microphone (under a fifth of a second) never reaches the model.
    @MainActor @Test func aTapIsNotHeard() async {
        let hearing = SecondsHearing()
        let listener = ParakeetLiveWords(hearing: hearing) { _ in }
        feed(listener, seconds: 0.1)
        #expect(await listener.finish() == "")
        #expect(hearing.passes.withLock { $0.isEmpty })
    }

    /// Live Words hands out the larger model's listener when it is ready, and Apple's (none in a simulator) when not.
    @MainActor @Test func liveWordsUsesTheLargerModelWhenItIsReady() async {
        let was = UserDefaults.standard.object(forKey: ParakeetWords.settingKey)
        defer {
            UserDefaults.standard.set(was, forKey: ParakeetWords.settingKey)
            ParakeetWords.resetForTests()
        }
        UserDefaults.standard.set(true, forKey: ParakeetWords.settingKey)
        ParakeetWords.resetForTests(SecondsHearing())
        #expect(LiveWords.canListen)
        let listener = LiveWords.listen { _ in }
        #expect(listener != nil)
        if let listener {
            feed(listener, seconds: 2)
            #expect(await listener.finish() == "w w")
        }
        #expect(LiveWords.diagnosticsLine == "on this device, larger model (Parakeet, English)")
        UserDefaults.standard.set(false, forKey: ParakeetWords.settingKey)
        #expect(ParakeetWords.listen { _ in } == nil)
    }

    /// The footer under the switches says where the download stands, and nothing once the model is ready.
    @MainActor @Test func theSettingsNoteFollowsTheDownload() {
        #expect(VoiceSettingsCatalog.betterWordsNote(on: true, readiness: .ready) == nil)
        #expect(VoiceSettingsCatalog.betterWordsNote(on: false, readiness: .downloading(40)) == nil)
        #expect(VoiceSettingsCatalog.betterWordsNote(on: true, readiness: .downloading(40))?.contains("40%") == true)
        #expect(VoiceSettingsCatalog.betterWordsNote(on: true, readiness: .waitingForWiFi)?.contains("Wi-Fi") == true)
        #expect(VoiceSettingsCatalog.betterWordsNote(on: true, readiness: .unavailable("English only"))?.contains("English only") == true)
    }
}
