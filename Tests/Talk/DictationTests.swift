// Dictation (docs/spec/3x-talk.md §8, row L541): the flow from "Dictate with Hermes" to the words in the field, every
// card it can end with, what cancels it, and that it always gives the microphone, the lease, the screen lock and the
// take's file back.

import AVFoundation
import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor final class FakeDictationRecorder: DictationCapturing {
    var beginError: DictationCaptureError?
    var beginDelay: Duration = .milliseconds(10)
    var finishDelay: Duration = .milliseconds(5)
    var recordsNothing = false
    private(set) var began = 0
    private(set) var finished = 0
    private(set) var cancelled = 0
    private(set) var file: URL?
    var level: Double = 0.4

    func begin() async throws {
        began += 1
        // One stand-in serves every dictation of a test: only a cancel during this start stops it.
        let before = cancelled
        try? await Task.sleep(for: beginDelay)
        if let beginError { throw beginError }
        if cancelled > before { throw DictationCaptureError.cancelled }
    }

    func finish() async -> DictationTake? {
        finished += 1
        try? await Task.sleep(for: finishDelay)
        guard !recordsNothing else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-test-\(UUID().uuidString).m4a")
        try? Data([1, 2, 3, 4]).write(to: url)
        file = url
        return DictationTake(url: url, mime: "audio/x-m4a", seconds: 1.5)
    }

    func cancel() { cancelled += 1 }
}

@Suite("Dictation", .serialized)
@MainActor
struct DictationTests {
    final class Seen {
        var words: [String] = []
        var notices: [(scope: String, notice: MemoNotice)] = []
        var transcribed: [DictationTake] = []
    }

    private func make(recorder: FakeDictationRecorder = FakeDictationRecorder(), config: TalkConfig = TalkConfig(),
                      result: Result<String, VoiceFailure> = .success("  Buy oat milk  ")) -> (DictationController, FakeDictationRecorder, Seen) {
        KeepAwake.reset()
        AudioSessionCoordinator.shared.reset()
        let seen = Seen()
        let dictation = DictationController()
        dictation.makeRecorder = { recorder }
        dictation.loadConfig = { _ in config }
        dictation.transcribe = { _, take in
            seen.transcribed.append(take)
            try? await Task.sleep(for: .milliseconds(30))
            return result
        }
        dictation.holdsLeases = false
        dictation.haptics = false
        dictation.isOnScreen = { true }
        dictation.onNotice = { scope, notice in seen.notices.append((scope, notice)) }
        return (dictation, recorder, seen)
    }

    private func fileGone(_ url: URL?) async -> Bool {
        guard let url else { return false }
        return await waitUntil { !FileManager.default.fileExists(atPath: url.path) }
    }

    @Test func theWordsGoToTheChatThatAsked() async {
        let (dictation, recorder, seen) = make()
        let chat = FakeTalkChat()
        dictation.start(in: chat) { seen.words.append($0) }
        #expect(dictation.phase == .starting)
        #expect(dictation.isActive(in: chat))
        #expect(KeepAwake.isHeld(.dictation))
        #expect(await waitUntil { dictation.phase == .recording })
        #expect(dictation.limit == 120)
        #expect(dictation.level == 0.4)
        dictation.done()
        #expect(dictation.phase == .transcribing)
        #expect(dictation.level == 0)
        #expect(await waitUntil { !dictation.isActive })
        // Trimmed, typed once, nothing sent to the bot.
        #expect(seen.words == ["Buy oat milk"])
        #expect(seen.notices.isEmpty)
        #expect(seen.transcribed.map(\.mime) == ["audio/x-m4a"])
        #expect(chat.sent.isEmpty)
        #expect(recorder.began == 1 && recorder.finished == 1 && recorder.cancelled == 0)
        // Always at the end: the screen lock and the take's file.
        #expect(!KeepAwake.isHeld(.dictation))
        #expect(await fileGone(recorder.file))
        #expect(dictation.delivered == 1)
    }

    @Test func cancelThrowsTheAudioAwayAndTypesNothing() async {
        let (dictation, recorder, seen) = make()
        let chat = FakeTalkChat()
        dictation.start(in: chat) { seen.words.append($0) }
        #expect(await waitUntil { dictation.phase == .recording })
        dictation.cancel()
        #expect(dictation.phase == .idle)
        #expect(recorder.cancelled == 1)
        #expect(recorder.finished == 0)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(seen.words.isEmpty)
        #expect(seen.notices.isEmpty)
        #expect(seen.transcribed.isEmpty)
        #expect(!KeepAwake.isHeld(.dictation))
    }

    @Test func cancelWhileTheWordsAreFetchedDropsThem() async {
        let (dictation, recorder, seen) = make()
        let chat = FakeTalkChat()
        dictation.start(in: chat) { seen.words.append($0) }
        #expect(await waitUntil { dictation.phase == .recording })
        dictation.done()
        #expect(await waitUntil { seen.transcribed.count == 1 })
        dictation.cancel()
        #expect(dictation.phase == .idle)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(seen.words.isEmpty)
        #expect(seen.notices.isEmpty)
        #expect(await fileGone(recorder.file))
        // A new dictation starts clean afterwards.
        dictation.start(in: chat) { seen.words.append($0) }
        #expect(await waitUntil { dictation.phase == .recording })
        dictation.done()
        #expect(await waitUntil { seen.words == ["Buy oat milk"] })
    }

    @Test func stopBeforeTheMicrophoneStartedIsACancel() async {
        let recorder = FakeDictationRecorder()
        recorder.beginDelay = .milliseconds(200)
        let (dictation, _, seen) = make(recorder: recorder)
        dictation.start(in: FakeTalkChat()) { seen.words.append($0) }
        dictation.done()
        #expect(dictation.phase == .idle)
        #expect(recorder.cancelled == 1)
        try? await Task.sleep(for: .milliseconds(350))
        #expect(dictation.phase == .idle)
        #expect(seen.notices.isEmpty)
        #expect(seen.transcribed.isEmpty)
        #expect(!KeepAwake.isHeld(.dictation))
    }

    @Test func emptyWordsShowNoSpeechDetected() async {
        let (dictation, _, seen) = make(result: .success("  \n "))
        let chat = FakeTalkChat()
        dictation.start(in: chat) { seen.words.append($0) }
        #expect(await waitUntil { dictation.phase == .recording })
        dictation.done()
        #expect(await waitUntil { seen.notices.count == 1 })
        #expect(seen.words.isEmpty)
        #expect(seen.notices[0].scope == chat.memoScope)
        #expect(seen.notices[0].notice == MemoNotice(tone: .warning, title: "No Speech Detected", message: "Try recording again.", action: .retryDictation))
        #expect(seen.notices[0].notice.actionTitle == "Try Again")
        #expect(!dictation.isActive)
    }

    @Test func aFailedTranscriptionShowsTheGatewaysReasonWithTryAgain() async {
        let failure = VoiceFailure(reason: "No speech-to-text provider is set up.", detail: "HTTP 503")
        let (dictation, recorder, seen) = make(result: .failure(failure))
        dictation.start(in: FakeTalkChat()) { seen.words.append($0) }
        #expect(await waitUntil { dictation.phase == .recording })
        dictation.done()
        #expect(await waitUntil { seen.notices.count == 1 })
        let notice = seen.notices[0].notice
        #expect(notice.title == "Voice Transcription Failed")
        // A missing provider reads plainly; the gateway's words stay behind the details (VoicePlainWords).
        #expect(notice.message == VoicePlainWords.transcriptionNotSetUp)
        #expect(notice.detail == "No speech-to-text provider is set up.\n\nHTTP 503")
        #expect(notice.tone == .error)
        #expect(notice.action == .retryDictation)
        #expect(notice.actionTitle == "Try Again")
        #expect(seen.words.isEmpty)
        #expect(await fileGone(recorder.file))
        #expect(!KeepAwake.isHeld(.dictation))
    }

    @Test func speechToTextOffNeverTouchesTheMicrophone() async {
        var config = TalkConfig()
        config.sttEnabled = false
        let (dictation, recorder, seen) = make(config: config)
        dictation.start(in: FakeTalkChat()) { seen.words.append($0) }
        #expect(await waitUntil { seen.notices.count == 1 })
        #expect(recorder.began == 0)
        let notice = seen.notices[0].notice
        #expect(notice.title == "Voice Unavailable")
        #expect(notice.message == "Speech to Text is off on your gateway. Turn it on in Settings › Voice › Speech to Text, then try again.")
        #expect(notice.action == .voiceSettings)
        #expect(!dictation.isActive)
        #expect(!KeepAwake.isHeld(.dictation))
    }

    @Test func microphoneAccessOffShowsTheSettingsCard() async {
        let recorder = FakeDictationRecorder()
        recorder.beginError = .denied
        let (dictation, _, seen) = make(recorder: recorder)
        dictation.start(in: FakeTalkChat()) { seen.words.append($0) }
        #expect(await waitUntil { seen.notices.count == 1 })
        let notice = seen.notices[0].notice
        #expect(notice.title == "Microphone Access Is Off")
        #expect(notice.message == "Turn on Microphone for \(MemoNotice.appName) in Settings to dictate.")
        #expect(notice.action == .openSettings)
        #expect(DictationController.microphoneOff(app: "Hermes HQ").message == "Turn on Microphone for Hermes HQ in Settings to dictate.")
        #expect(!dictation.isActive)
        #expect(!KeepAwake.isHeld(.dictation))
    }

    @Test func aRecordingThatCouldNotStartSaysWhy() async {
        let recorder = FakeDictationRecorder()
        recorder.beginError = .failed("The microphone did not start recording.")
        let (dictation, _, seen) = make(recorder: recorder)
        dictation.start(in: FakeTalkChat()) { seen.words.append($0) }
        #expect(await waitUntil { seen.notices.count == 1 })
        #expect(seen.notices[0].notice == MemoNotice(tone: .error, title: "Voice Recording Failed", message: "The microphone did not start recording."))
        #expect(!dictation.isActive)
    }

    @Test func aTakeWithNothingInItIsAFailedRecording() async {
        let recorder = FakeDictationRecorder()
        recorder.recordsNothing = true
        let (dictation, _, seen) = make(recorder: recorder)
        dictation.start(in: FakeTalkChat()) { seen.words.append($0) }
        #expect(await waitUntil { dictation.phase == .recording })
        dictation.done()
        #expect(await waitUntil { seen.notices.count == 1 })
        #expect(seen.notices[0].notice.title == "Voice Recording Failed")
        #expect(seen.transcribed.isEmpty)
    }

    @Test func itStopsAndTranscribesByItselfAtTheLimit() async {
        var config = TalkConfig()
        config.maxRecordingSeconds = 2
        let (dictation, recorder, seen) = make(config: config)
        dictation.clockScale = 10      // 2 s pass in a fifth of a second
        dictation.start(in: FakeTalkChat()) { seen.words.append($0) }
        #expect(await waitUntil { dictation.phase == .recording })
        #expect(dictation.limit == 2)
        #expect(await waitUntil(timeout: .seconds(5)) { seen.words == ["Buy oat milk"] })
        #expect(recorder.finished == 1)
        #expect(!dictation.isActive)
    }

    @Test func theLimitIsCutToTheWebsRange() {
        func limit(_ value: JSONValue) -> Int { TalkConfig(config: .object(["voice": .object(["max_recording_seconds": value])])).maxRecordingSeconds }
        #expect(TalkConfig().maxRecordingSeconds == 120)
        #expect(limit(.number(0)) == 1)
        #expect(limit(.number(2.9)) == 2)
        #expect(limit(.number(601)) == 600)
        #expect(limit(.number(600)) == 600)
        #expect(limit(.string("soon")) == 120)
    }

    @Test func oneDictationAtATime() async {
        let (dictation, recorder, seen) = make()
        let chat = FakeTalkChat(), other = FakeTalkChat(profile: "ada", stored: "20260929_120000_ddeeff03")
        dictation.start(in: chat) { seen.words.append($0) }
        dictation.start(in: other) { seen.words.append("other: " + $0) }
        #expect(dictation.isActive(in: chat))
        #expect(!dictation.isActive(in: other))
        #expect(dictation.started == 1)
        #expect(await waitUntil { dictation.phase == .recording })
        // Another chat giving up its composer does not touch this one.
        dictation.cancel(in: other)
        #expect(dictation.phase == .recording)
        dictation.cancel(in: nil)
        #expect(dictation.phase == .recording)
        // Its own chat leaving the screen throws it away.
        dictation.cancel(in: chat)
        #expect(dictation.phase == .idle)
        #expect(recorder.cancelled == 1)
        #expect(seen.words.isEmpty)
    }

    @Test func nothingStartsWhileTheAppIsOffScreen() {
        let (dictation, recorder, seen) = make()
        dictation.isOnScreen = { false }
        dictation.start(in: FakeTalkChat()) { seen.words.append($0) }
        #expect(!dictation.isActive)
        #expect(recorder.began == 0)
        #expect(!KeepAwake.isHeld(.dictation))
    }

    @Test func leavingTheAppOrACallCancelsWithoutACard() async {
        let (dictation, recorder, seen) = make()
        dictation.start(in: FakeTalkChat()) { seen.words.append($0) }
        #expect(await waitUntil { dictation.phase == .recording })
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: nil)
        #expect(await waitUntil { !dictation.isActive })
        #expect(recorder.cancelled == 1)
        dictation.start(in: FakeTalkChat()) { seen.words.append($0) }
        #expect(await waitUntil { dictation.phase == .recording })
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        #expect(await waitUntil { !dictation.isActive })
        // The interruption ending starts nothing.
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!dictation.isActive)
        #expect(seen.words.isEmpty && seen.notices.isEmpty)
        #expect(!KeepAwake.isHeld(.dictation))
    }

    @Test func aSlowStartShowsStartingAndAQuickOneNever() async {
        let (dictation, _, seen) = make()
        dictation.start(in: FakeTalkChat()) { seen.words.append($0) }
        #expect(await waitUntil { dictation.phase == .recording })
        #expect(!dictation.startingShown)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(!dictation.startingShown, "a quick start never flashes Starting…")
        dictation.cancel()
        // The voice settings take a while to come back from the gateway.
        let config = dictation.loadConfig
        dictation.loadConfig = { chat in
            try? await Task.sleep(for: .milliseconds(900))
            return await config(chat)
        }
        dictation.start(in: FakeTalkChat()) { seen.words.append($0) }
        #expect(!dictation.startingShown)
        #expect(await waitUntil { dictation.startingShown })
        #expect(dictation.phase == .starting)
        #expect(DictationController.spoken(phase: .starting, elapsed: 0) == "Starting dictation")
        #expect(await waitUntil(timeout: .seconds(3)) { dictation.phase == .recording })
        dictation.cancel()
        #expect(!dictation.startingShown)
    }

    @Test func aTakeAlreadyTranscribingOutlivesACallOrLeavingTheApp() async {
        let (dictation, recorder, seen) = make()
        recorder.finishDelay = .milliseconds(120)
        let cancelled = recorder.cancelled
        dictation.start(in: FakeTalkChat()) { seen.words.append($0) }
        #expect(await waitUntil { dictation.phase == .recording })
        dictation.done()
        #expect(dictation.phase == .transcribing)
        // Done was tapped: the microphone is finished with, so neither throws the words away.
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: nil)
        #expect(dictation.phase == .transcribing)
        #expect(await waitUntil { seen.words == ["Buy oat milk"] })
        #expect(recorder.cancelled == cancelled)
        #expect(!dictation.isActive)
    }

    // MARK: The stand-in microphone and the audio session

    @Test func theStandInRecordsRealAACUnderTheDictationOwner() async throws {
        AudioSessionCoordinator.shared.reset()
        FixtureDictationRecorder.resetForTests()
        let recorder = FixtureDictationRecorder()
        try await recorder.begin()
        #expect(AudioSessionCoordinator.shared.owner == .dictation)
        #expect(recorder.level > 0)
        try? await Task.sleep(for: .milliseconds(400))
        let take = try #require(await recorder.finish())
        #expect(AudioSessionCoordinator.shared.owner == nil)
        #expect(take.mime == "audio/x-m4a")
        #expect(take.url.pathExtension == "m4a")
        #expect(take.url.path.contains("/Caches/talk/"))
        let file = try AVAudioFile(forReading: take.url)
        #expect(file.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC)
        #expect(file.fileFormat.sampleRate == 24000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(Double(file.length) / 24000 > 0.3)
        #expect(recorder.level == 0)
        #expect(await recorder.finish() == nil)
        try? FileManager.default.removeItem(at: take.url)
    }

    @Test func theStandInFailsAndRefusesAsAsked() async {
        AudioSessionCoordinator.shared.reset()
        FixtureDictationRecorder.resetForTests()
        FixtureDictationRecorder.failure = "The stand-in microphone was told to fail."
        await #expect(throws: DictationCaptureError.failed("The stand-in microphone was told to fail.")) {
            try await FixtureDictationRecorder().begin()
        }
        FixtureDictationRecorder.permission = "denied"
        await #expect(throws: DictationCaptureError.denied) { try await FixtureDictationRecorder().begin() }
        // Cancelled while it starts: nothing is left holding the audio session.
        FixtureDictationRecorder.permission = "granted"
        FixtureDictationRecorder.startDelay = 0.2
        let recorder = FixtureDictationRecorder()
        let begun = Task { try await recorder.begin() }
        try? await Task.sleep(for: .milliseconds(60))
        recorder.cancel()
        await #expect(throws: DictationCaptureError.cancelled) { try await begun.value }
        #expect(AudioSessionCoordinator.shared.owner == nil)
        FixtureDictationRecorder.resetForTests()
    }

    @Test func aConversationTakingTheMicrophoneCancelsTheDictation() async {
        AudioSessionCoordinator.shared.reset()
        FixtureDictationRecorder.resetForTests()
        let audio = AudioSessionCoordinator.shared
        let kept = audio.onRecordingPreempted
        defer { audio.onRecordingPreempted = kept }
        let (dictation, _, seen) = make()
        dictation.makeRecorder = { FixtureDictationRecorder() }
        audio.onRecordingPreempted = { owner in if owner == .dictation { dictation.cancel() } }
        dictation.start(in: FakeTalkChat()) { seen.words.append($0) }
        #expect(await waitUntil { dictation.phase == .recording })
        #expect(audio.owner == .dictation)
        audio.simulatedOwners.insert(.conversation)
        try? await audio.acquire(.conversation)
        #expect(!dictation.isActive)
        #expect(audio.owner == .conversation)
        audio.release(.conversation)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(seen.words.isEmpty && seen.notices.isEmpty)
        FixtureDictationRecorder.resetForTests()
    }

    // MARK: The row and the field

    @Test func theClockAndWhatVoiceOverReads() {
        #expect(DictationController.clock(0) == "0:00")
        #expect(DictationController.clock(7.9) == "0:07")
        #expect(DictationController.clock(134) == "2:14")
        #expect(DictationController.clock(600) == "10:00")
        #expect(DictationController.clock(-3) == "0:00")
        #expect(DictationController.clock(.nan) == "0:00")
        #expect(DictationController.spoken(phase: .recording, elapsed: 7) == "Dictating, 0:07")
        #expect(DictationController.spoken(phase: .transcribing, elapsed: 7) == "Transcribing")
        // The last ten seconds count down (it had stopped at the limit with no warning).
        #expect(DictationController.secondsLeft(elapsed: 109.9, limit: 120) == nil)
        #expect(DictationController.secondsLeft(elapsed: 110, limit: 120) == 10)
        #expect(DictationController.secondsLeft(elapsed: 118.2, limit: 120) == 2)
        #expect(DictationController.secondsLeft(elapsed: 120, limit: 120) == nil)
        #expect(DictationController.secondsLeft(elapsed: 3, limit: 6) == 3, "a short limit warns for its second half")
        #expect(DictationController.secondsLeft(elapsed: 5, limit: 0) == nil)
        #expect(DictationController.spoken(phase: .recording, elapsed: 111, limit: 120) == "Dictating, 1:51, 9 seconds left")
        #expect(DictationController.spoken(phase: .recording, elapsed: 7, limit: 120) == "Dictating, 0:07")
    }

    @Test func theFiveBarsFollowTheWebsWeights() {
        #expect(DictationBars.weights == [0.5, 0.78, 1, 0.78, 0.5])
        #expect(DictationBars.share(weight: 1, level: 0) == 0.25)
        #expect(abs(DictationBars.share(weight: 0.5, level: 0.4) - 0.45) < 0.0001)
        #expect(abs(DictationBars.share(weight: 1, level: 1) - 0.93) < 0.0001)
        #expect(DictationBars.share(weight: 1, level: .nan) == 0.25)
        #expect(abs(DictationBars.share(weight: 1, level: 7) - 0.93) < 0.0001)
    }

    @Test func theWordsGoInAtTheCursor() {
        func insert(_ text: String, _ location: Int, _ length: Int = 0, _ words: String = "buy oat milk") -> (String, Int) {
            let result = ComposerView.dictationInsert(into: text, selection: NSRange(location: location, length: length), words: words)
            return (result.text, result.caret)
        }
        #expect(insert("", 0) == ("buy oat milk", 12))
        // A space is added when the text before the cursor does not end in white space.
        #expect(insert("Remember to", 11) == ("Remember to buy oat milk", 24))
        #expect(insert("Remember to ", 12) == ("Remember to buy oat milk", 24))
        #expect(insert("Line one\n", 9) == ("Line one\nbuy oat milk", 21))
        // In the middle, and over a selection.
        #expect(insert("AB", 1) == ("A buy oat milkB", 14))
        #expect(insert("Hello there", 6, 5, "world") == ("Hello world", 11))
        // A cursor iOS reports past the end, or not at all, means the end.
        #expect(insert("Hi", 99) == ("Hi buy oat milk", 15))
        #expect(insert("Hi", NSNotFound) == ("Hi buy oat milk", 15))
        // Offsets are UTF-16, as the text view counts them.
        #expect(insert("👍", 2, 0, "ok") == ("👍 ok", 5))
    }

    @Test func theRowShowsDictatingThenTranscribing() {
        let row = DictationRow(frame: CGRect(x: 0, y: 0, width: 304, height: 40))
        row.show(phase: .recording, elapsed: 7.4, level: 0.5)
        row.layoutIfNeeded()
        func find(_ id: String, in view: UIView) -> UIView? {
            if view.accessibilityIdentifier == id { return view }
            for sub in view.subviews { if let hit = find(id, in: sub) { return hit } }
            return nil
        }
        let status = find("dictation.status", in: row), done = find("dictation.done", in: row), cancel = find("dictation.cancel", in: row)
        #expect(status?.accessibilityLabel == "Dictating, 0:07")
        #expect(status?.isAccessibilityElement == true)
        #expect(cancel?.accessibilityLabel == "Cancel dictation")
        #expect(cancel?.frame.width == 44 && cancel?.frame.height == 44)
        #expect(done?.isHidden == false)
        #expect((done?.frame.width ?? 0) >= 44 && done?.frame.height == 44)
        #expect(row.accessibilityElements?.count == 3)
        var tapped = ""
        row.onCancel = { tapped += "cancel" }
        row.onDone = { tapped += "done" }
        (cancel as? UIButton)?.sendActions(for: .touchUpInside)
        (done as? UIButton)?.sendActions(for: .touchUpInside)
        #expect(tapped == "canceldone")
        row.show(phase: .transcribing, elapsed: 7.4, level: 0.5)
        row.layoutIfNeeded()
        #expect(status?.accessibilityLabel == "Transcribing")
        // Nothing left for Done to do; ✕ still cancels.
        #expect(done?.isHidden == true)
        #expect(row.accessibilityElements?.count == 2)
    }

    @Test func stopDictationWorksWhileTheChatReconnects() {
        func pick(enabled: Bool, hasText: Bool = false, dictating: Bool, running: Bool = false) -> ComposerView.Primary {
            ComposerView.choosePrimary(memoSend: nil, enabled: enabled, preparing: false, hasText: hasText, attachments: 0, memoChip: false,
                                       dictating: dictating, running: running, talkAvailable: true)
        }
        #expect(pick(enabled: false, dictating: true) == .stopDictation)
        #expect(pick(enabled: false, dictating: true, running: true) == .stopDictation)
        #expect(pick(enabled: false, dictating: false) == .disabled)
        // Words already in the field don't take the circle from the dictation (they go with its words, later).
        #expect(pick(enabled: false, hasText: true, dictating: true) == .stopDictation)
        #expect(pick(enabled: false, hasText: true, dictating: false) == .disabled)
        #expect(pick(enabled: true, dictating: true, running: true) == .stopDictation)
    }

    // MARK: [live words] (docs/spec/3x-live-words.md §3.3)

    @Test func theWordsHeardHereAreTypedWithoutTheGateway() async {
        let (dictation, recorder, seen) = make()
        dictation.tapsMicrophone = false
        dictation.makeWords = { ScriptedLiveWords(script: "Add a caption to this photo", onText: $0) }
        final class Shown { var words: [LiveWordsText] = [] }
        let shown = Shown()
        let token = NotificationCenter.default.addObserver(forName: DictationController.wordsChanged, object: dictation, queue: .main) { _ in
            MainActor.assumeIsolated { shown.words.append(dictation.words) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let chat = FakeTalkChat()
        dictation.start(in: chat) { seen.words.append($0) }
        #expect(await waitUntil { dictation.phase == .recording })
        #expect(dictation.hearsWords, "the words row opens with Listening… at once")
        #expect(await waitUntil(timeout: .seconds(3)) { dictation.words.whole.hasPrefix("Add a caption") })
        dictation.done()
        #expect(await waitUntil { !dictation.isActive })
        #expect(seen.words == ["Add a caption to this photo"])
        #expect(seen.transcribed.isEmpty, "no speech to text on the gateway")
        #expect(seen.notices.isEmpty)
        #expect(dictation.heardHere == 1)
        #expect(dictation.words.isEmpty && !dictation.hearsWords, "the row clears with the take")
        #expect(shown.words.contains { !$0.isEmpty }, "the screen was told as the words came")
        #expect(await fileGone(recorder.file))
    }

    @Test func nothingHeardHereGoesToTheGateway() async {
        let (dictation, _, seen) = make()
        dictation.tapsMicrophone = false
        let listener = CountingListener(words: "  ")
        dictation.makeWords = { _ in listener }
        let chat = FakeTalkChat()
        dictation.start(in: chat) { seen.words.append($0) }
        #expect(await waitUntil { dictation.phase == .recording })
        dictation.done()
        #expect(await waitUntil { !dictation.isActive })
        #expect(listener.finished)
        #expect(seen.transcribed.count == 1)
        #expect(seen.words == ["Buy oat milk"])
        #expect(dictation.heardHere == 0)
    }

    @Test func aCancelledDictationLetsItsListenerGo() async {
        let (dictation, _, seen) = make()
        dictation.tapsMicrophone = false
        let listener = CountingListener(words: "never typed")
        dictation.makeWords = { _ in listener }
        dictation.start(in: FakeTalkChat()) { seen.words.append($0) }
        #expect(await waitUntil { dictation.phase == .recording })
        dictation.cancel()
        #expect(listener.cancelled)
        #expect(!listener.finished)
        #expect(!dictation.hearsWords)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(seen.words.isEmpty)
    }
}

private func == (a: (String, Int), b: (String, Int)) -> Bool { a.0 == b.0 && a.1 == b.1 }
