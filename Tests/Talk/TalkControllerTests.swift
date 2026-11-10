// `TalkController` (docs/spec/3x-talk.md §4, §5.7, §6): one conversation, driven by the stand-in microphone, a
// speaker with no audio and a chat that records what it is asked. The reducer's own rules are in `TalkLoopTests`;
// these check that the controller turns its effects into the right calls, and what it leaves behind when it ends.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Talk controller", .serialized)
@MainActor
struct TalkControllerTests {
    private func make(script: String, transcripts: [String] = ["What is the plan"], config: TalkConfig = TalkConfig(),
                      permission: String = "granted") -> (TalkController, FakeSpeaker, Transcripts) {
        AudioSessionCoordinator.shared.reset()
        KeepAwake.reset()
        FixtureTalkCapture.script = TalkFixtureStep.parse(script)
        FixtureTalkCapture.permission = permission
        FixtureTalkCapture.startDelay = 0.02
        let talk = TalkController()
        let speaker = FakeSpeaker()
        let words = Transcripts(transcripts)
        var fast = config
        fast.silenceMs = 300
        talk.makeCapture = { FixtureTalkCapture(clock: $0) }
        talk.speaker = speaker
        talk.loadConfig = { _ in fast }
        talk.transcribe = { _, _ in words.next() }
        talk.holdsLeases = false
        talk.isOnScreen = { true }
        talk.speaksReplies = { true }
        return (talk, speaker, words)
    }

    @MainActor final class Transcripts {
        var queue: [Result<String, VoiceFailure>]
        private(set) var asked = 0
        init(_ words: [String]) { queue = words.map { .success($0) } }
        func next() -> Result<String, VoiceFailure> {
            asked += 1
            return queue.isEmpty ? .success("") : queue.removeFirst()
        }
    }

    private func phase(_ talk: TalkController) -> TalkDockView.Phase? { talk.view?.phase }

    private func takeFiles() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: TalkCaptureCore.takesFolder.path)) ?? []).count
    }

    @Test func aSpokenTurnGoesOutIsAnsweredAloudAndListensAgain() async throws {
        let (talk, speaker, words) = make(script: "say:0.5;hold")
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(talk.isLive(in: chat))
        #expect(phase(talk) == .starting)
        #expect(chat.voiceHold)
        #expect(KeepAwake.isHeld(.conversation))
        #expect(await waitUntil { phase(talk) == .listening })
        // The words are heard, transcribed and sent as an ordinary message.
        #expect(await waitUntil(timeout: .seconds(6)) { chat.sent.count == 1 })
        #expect(chat.sent.first?.text == "What is the plan")
        #expect(chat.sent.first?.interrupted == false)
        #expect(words.asked == 1)
        #expect(await waitUntil { phase(talk) == .thinking })
        #expect(talk.view?.center == .stop)
        // The reply streams: it is spoken as it arrives.
        chat.reply("m1", "Here is", done: false)
        #expect(await waitUntil { speaker.sessions.count == 1 })
        #expect(speaker.sessions.first?.messageId == "m1")
        speaker.begin()
        #expect(await waitUntil { phase(talk) == .speaking })
        #expect(talk.view?.title == "Ivy is speaking")
        chat.reply("m1", "Here is the plan.", done: true)
        #expect(await waitUntil { speaker.sessions.first?.finished == true })
        #expect(speaker.sessions.first?.appended.last == "Here is the plan.")
        speaker.complete()
        #expect(await waitUntil { phase(talk) == .listening })
        // Ending leaves nothing behind but the caption.
        talk.end()
        #expect(await waitUntil { !talk.isLive })
        #expect(!chat.voiceHold)
        #expect(chat.onVoiceChange == nil)
        #expect(!KeepAwake.isHeld(.conversation))
        #expect(talk.endedCaption(for: chat.memoScope)?.hasPrefix("Voice chat ended · ") == true)
        await talk.resetForTests()
        #expect(takeFiles() == 0)
        #expect(AudioSessionCoordinator.shared.owner == nil)
    }

    @Test func withReadRepliesAloudOffTheReplyStaysTextAndTheMicrophoneComesBack() async throws {
        let (talk, speaker, _) = make(script: "say:0.4;hold")
        talk.speaksReplies = { false }
        let chat = FakeTalkChat()
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil(timeout: .seconds(6)) { chat.sent.count == 1 })
        chat.reply("m1", "Here is the plan.", done: true)
        #expect(await waitUntil { phase(talk) == .listening })
        #expect(speaker.sessions.isEmpty)
        await talk.resetForTests()
    }

    /// Tester, 2026-11-08: "On voice chat, STT works but response is not read back". A conversation speaks its
    /// replies until its own Speak Replies is switched off, whatever Read Replies Aloud (the chat on screen) says.
    @Test func aConversationSpeaksUntilItsOwnSwitchIsOff() {
        let defaults = UserDefaults.standard
        let keys = [TalkController.conversationSpeaksKey, TalkController.readRepliesAloudKey, TalkController.readRepliesAloudGatewayKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        keys.forEach(defaults.removeObject(forKey:))
        #expect(!TalkController.readsRepliesAloud)
        #expect(TalkController.speaksInConversation)
        #expect(TalkController().speaksReplies())
        TalkController.speaksInConversation = false
        #expect(!TalkController().speaksReplies())
        #expect(!TalkController.readsRepliesAloud)
        TalkController.readsRepliesAloud = true
        #expect(!TalkController.speaksInConversation, "Read Replies Aloud is the chat's, not the conversation's")
        #expect(VoiceSettingsCatalog.readRepliesHint.contains("A voice conversation always speaks its replies."))
    }

    @Test func endingAwayFromTheChatLeavesNoCaption() async throws {
        let (talk, _, _) = make(script: "hold")
        let chat = FakeTalkChat()
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { phase(talk) == .listening })
        talk.end()
        #expect(!talk.isLive)
        #expect(talk.endedCaption(for: chat.memoScope) == nil)
        await talk.resetForTests()
    }

    @Test("Ending during Starting… leaves the audio session off, whether iOS was still asking for the microphone or the session was coming up")
    func endingWhileStartingLeavesTheSessionOff() async throws {
        for permission in ["undetermined", "granted"] {
            let (talk, _, _) = make(script: "hold", permission: permission)
            FixtureTalkCapture.startDelay = 0.3
            let chat = FakeTalkChat()
            talk.start(in: chat, name: "Ivy")
            #expect(phase(talk) == .starting)
            try await Task.sleep(for: .milliseconds(permission == "granted" ? 80 : 20))
            talk.end()
            #expect(!talk.isLive)
            try await Task.sleep(for: .milliseconds(700))
            #expect(AudioSessionCoordinator.shared.owner == nil, "\(permission): nothing holds the session")
            #expect(!talk.isLive)
            await talk.resetForTests()
        }
        FixtureTalkCapture.startDelay = 0.02
    }

    @Test func aStartThatCannotHappenSaysWhyAndLeavesNoConversation() async throws {
        var failures: [TalkController.StartFailure] = []
        // Speech to Text off on the gateway.
        var off = TalkConfig()
        off.sttEnabled = false
        var (talk, _, _) = make(script: "hold", config: off)
        talk.onStartFailure = { _, failure, _ in failures.append(failure) }
        let chat = FakeTalkChat()
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { failures.count == 1 })
        #expect(failures.last == .speechToTextOff)
        #expect(!talk.isLive)
        #expect(!chat.voiceHold)
        #expect(!KeepAwake.isHeld(.conversation))
        await talk.resetForTests()
        // The microphone is not allowed.
        (talk, _, _) = make(script: "hold", permission: "denied")
        talk.onStartFailure = { _, failure, _ in failures.append(failure) }
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { failures.count == 2 })
        #expect(failures.last == .microphoneDenied)
        #expect(!talk.isLive)
        await talk.resetForTests()
        // The engine does not start.
        (talk, _, _) = make(script: "fail")
        talk.onStartFailure = { _, failure, _ in failures.append(failure) }
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { failures.count == 3 })
        #expect(failures.last == .engine(detail: "The stand-in microphone was told to fail."))
        #expect(talk.notice(for: chat.memoScope) == nil)
        await talk.resetForTests()
        // The app is not on screen.
        (talk, _, _) = make(script: "hold")
        talk.onStartFailure = { _, failure, _ in failures.append(failure) }
        talk.isOnScreen = { false }
        talk.start(in: chat, name: "Ivy")
        #expect(failures.last == .notOnScreen)
        #expect(!talk.isLive)
        #expect(talk.started == 0)
        FixtureTalkCapture.permission = "granted"
    }

    @Test func theStartNoticesUseTheSpecsWords() {
        let denied = TalkWiring.startNotice(.microphoneDenied, name: "Ivy", app: "Hermes HQ")
        #expect(denied.title == "Microphone Access Is Off")
        #expect(denied.message == "Turn on Microphone for Hermes HQ in Settings to talk with Ivy.")
        #expect(denied.action == .openSettings)
        #expect(denied.tone == .warning)
        let off = TalkWiring.startNotice(.speechToTextOff, name: "Ivy", app: "Hermes HQ")
        #expect(off.title == "Voice Unavailable")
        #expect(off.message == "Speech to Text is off on your gateway. Turn it on in Settings › Voice › Speech to Text, then try again.")
        #expect(off.actionTitle == "Voice Settings…")
        let engine = TalkWiring.startNotice(.engine(detail: "AVAudioEngine error -10875"), name: "Ivy", app: "Hermes HQ")
        #expect(engine.title == "Voice Didn’t Start")
        #expect(engine.message == "Couldn’t start microphone recording.")
        #expect(engine.detail == "AVAudioEngine error -10875")
        #expect(engine.actionTitle == "Try Again")
        #expect(engine.tone == .error)
        let none = TalkWiring.startNotice(.noMicrophone, name: "Ivy", app: "Hermes HQ")
        #expect(none.title == "Voice Didn’t Start")
        #expect(none.message == "No microphone was found.")
        #expect(none.action == nil)
        let away = TalkWiring.startNotice(.notOnScreen, name: "Ivy", app: "Hermes HQ")
        #expect(away.message == "Talk starts while Hermes HQ is on screen, then keeps going when you leave. Tap Talk to start again.")
        #expect(away.tone == .info)
    }

    @Test func startingInAnotherChatEndsTheFirst() async throws {
        let (talk, _, _) = make(script: "hold;hold")
        let first = FakeTalkChat(profile: "ivy"), second = FakeTalkChat(profile: "ada", stored: "20260929_120000_aabbcc03")
        talk.start(in: first, name: "Ivy")
        #expect(await waitUntil { phase(talk) == .listening })
        talk.start(in: second, name: "Ada")
        #expect(talk.isLive(in: second))
        #expect(!talk.isLive(in: first))
        #expect(!first.voiceHold)
        #expect(first.onVoiceChange == nil)
        #expect(second.voiceHold)
        #expect(talk.started == 2)
        #expect(talk.notice(for: first.memoScope) == nil)
        #expect(await waitUntil(timeout: .seconds(5)) { phase(talk) == .listening })
        #expect(talk.view?.hint == "Go ahead. It sends when you pause.")
        await talk.resetForTests()
        #expect(AudioSessionCoordinator.shared.owner == nil)
    }

    @Test func aTypedStopPhraseEndsItAndIsNotSent() async throws {
        let (talk, _, _) = make(script: "hold")
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        #expect(!talk.interceptsTyped(text: "stop", attachments: 0))          // nothing live: an ordinary message
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { phase(talk) == .listening })
        #expect(!talk.interceptsTyped(text: "stop", attachments: 1))          // with an attachment it is a message
        #expect(talk.isLive)
        #expect(!talk.interceptsTyped(text: "please stop the build", attachments: 0))
        #expect(talk.isLive)
        #expect(talk.interceptsTyped(text: "Stop.", attachments: 0))
        #expect(!talk.isLive)
        #expect(talk.endedCaption(for: chat.memoScope) != nil)
        #expect(chat.sent.isEmpty)
        await talk.resetForTests()
    }

    @Test func aSpokenStopPhraseEndsItAndIsNotSent() async throws {
        let (talk, _, _) = make(script: "say:0.4", transcripts: ["Stop listening."])
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil(timeout: .seconds(6)) { !talk.isLive })
        #expect(chat.sent.isEmpty)
        #expect(talk.endedCaption(for: chat.memoScope) != nil)
        await talk.resetForTests()
    }

    @Test func aSystemInterruptionPausesWithAResumeNotice() async throws {
        let (talk, _, _) = make(script: "hold;hold")
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { phase(talk) == .listening })
        talk.debugInterrupt(.interrupted, detail: "interruption began (reason 1)")
        #expect(!talk.isLive)
        #expect(!KeepAwake.isHeld(.conversation))
        let notice = try #require(talk.notice(for: chat.memoScope))
        #expect(notice.kind == .paused)
        #expect(notice.action == .resume)
        #expect(notice.title == "Voice Paused")
        #expect(notice.detail == "interruption began (reason 1)")
        #expect(talk.endedCaption(for: chat.memoScope) == nil)
        // Resume: an explicit start clears the notice and begins clean.
        talk.start(in: chat, name: "Ivy")
        #expect(talk.notice(for: chat.memoScope) == nil)
        #expect(await waitUntil(timeout: .seconds(5)) { phase(talk) == .listening })
        // [talk-background] Leaving the screen does not pause it: the conversation goes on with the app away.
        talk.debugLeaveScreen()
        #expect(talk.notice(for: chat.memoScope) == nil)
        #expect(talk.isLive)
        #expect(phase(talk) == .listening)
        await talk.resetForTests()
    }

    /// [talk-background] A conversation holds the gateway socket through the background for as long as it runs, and its
    /// Live Activity follows the dock's words.
    @Test func aConversationHoldsTheSocketAndShowsOnTheLockScreen() async throws {
        let (talk, _, _) = make(script: "hold;hold")
        let chat = FakeTalkChat()
        let client = try #require(chat.voiceClient as? FakeGatewayClient)
        talk.start(in: chat, name: "Ivy")
        #expect(client.holds == [true])
        #expect(await waitUntil { phase(talk) == .listening })
        #expect(TalkActivity.shared.debugShown?.phase == "listening")
        #expect(TalkActivity.shared.debugShown?.title == "Listening")
        talk.debugLeaveScreen()
        #expect(talk.isLive)
        talk.toggleMute()
        #expect(await waitUntil { TalkActivity.shared.debugShown?.muted == true })
        #expect(TalkActivity.shared.debugShown?.phase == "muted")
        talk.end()
        #expect(await waitUntil { !talk.isLive })
        #expect(client.holds == [true, false])
        #expect(TalkActivity.shared.debugShown == nil)
        await talk.resetForTests()
    }

    // [mac-audit #27] 2026-11-02: no Lock Screen (and no TalkActivityKit) on the Mac, as TalkActivity.launched.
    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    /// A conversation that pauses by itself with the app away leaves its card saying so (it had just vanished, with no
    /// sound and no word); one the person ends goes at once.
    @Test func aPauseWithTheAppAwayLeavesTheCardSayingSo() async throws {
        let (talk, _, _) = make(script: "hold;hold")
        let chat = FakeTalkChat()
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { phase(talk) == .listening })
        talk.isOnScreen = { false }
        talk.debugInterrupt(.silence, detail: nil)
        #expect(await waitUntil { !talk.isLive })
        #expect(TalkActivity.shared.debugShown == nil)
        #expect(TalkActivity.shared.lastEnded == "Paused after 2 minutes of silence")
        talk.isOnScreen = { true }
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { phase(talk) == .listening })
        talk.isOnScreen = { false }
        talk.end()
        #expect(await waitUntil { !talk.isLive })
        #expect(TalkActivity.shared.lastEnded == nil)
        #expect(TalkController.lockScreenWords(.stopped(title: "Voice Transcription Failed", message: "", detail: nil)) == "Voice Transcription Failed")
        #expect(TalkController.lockScreenWords(.paused(.interrupted, detail: nil)) == "Voice Paused")
        #expect(TalkController.lockScreenWords(.replaced) == nil)
        await talk.resetForTests()
    }

    /// [talk-background] The Lock Screen's buttons reach the conversation (`TalkActivityActions`, wired at launch).
    @Test func theLockScreenButtonsMuteAndEnd() async throws {
        let (talk, _, _) = make(script: "hold;hold")
        TalkActivity.shared.launched()
        let chat = FakeTalkChat()
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { phase(talk) == .listening })
        TalkActivityActions.handler?(.toggleMute)
        #expect(await waitUntil { phase(talk) == .muted })
        TalkActivityActions.handler?(.end)
        #expect(await waitUntil { !talk.isLive })
        await talk.resetForTests()
    }
    #endif

    @Test func muteStopsListeningAndUnmuteListensAgain() async throws {
        let (talk, _, _) = make(script: "hold;hold")
        let chat = FakeTalkChat()
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { phase(talk) == .listening })
        talk.toggleMute()
        #expect(phase(talk) == .muted)
        #expect(talk.view?.hint == "Ivy can’t hear you. Tap Mute to talk again.")
        #expect(talk.view?.centerEnabled == false)
        talk.toggleMute()
        #expect(phase(talk) == .listening)
        await talk.resetForTests()
        #expect(takeFiles() == 0)
    }

    @Test func aChatThatGoesAwayEndsItWithNothingShown() async throws {
        let (talk, _, _) = make(script: "hold")
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { phase(talk) == .listening })
        talk.chatGone(chat)
        #expect(!talk.isLive)
        #expect(talk.notice(for: chat.memoScope) == nil)
        #expect(talk.endedCaption(for: chat.memoScope) == nil)
        #expect(!chat.voiceHold)
        await talk.resetForTests()
    }

    @Test func talkingOverTheBotStopsItAndSendsTheWordsAsAnInterruption() async throws {
        let (talk, speaker, _) = make(script: "say:0.4;barge:0.5;hold", transcripts: ["Start the build", "Actually wait"])
        let chat = FakeTalkChat()
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil(timeout: .seconds(6)) { chat.sent.count == 1 })
        #expect(await waitUntil { phase(talk) == .thinking })
        // The person talks while the bot works: the turn is stopped, then their words go out marked interrupted.
        #expect(await waitUntil(timeout: .seconds(8)) { chat.stops == 1 })
        #expect(await waitUntil(timeout: .seconds(8)) { chat.sent.count == 2 })
        #expect(chat.sent.last?.text == "Actually wait")
        #expect(chat.sent.last?.interrupted == true)
        #expect(speaker.sessions.isEmpty)
        await talk.resetForTests()
        #expect(takeFiles() == 0)
    }

    @Test func threeFailedTranscriptionsStopWithTheGatewaysOwnWords() async throws {
        let (talk, _, words) = make(script: "say:0.3;say:0.3;say:0.3;hold")
        let failure = VoiceFailure(reason: "Transcription failed", detail: "HTTP 500: Synthetic transcription failure")
        words.queue = [.failure(failure), .failure(failure), .failure(failure)]
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil(timeout: .seconds(12)) { !talk.isLive })
        #expect(words.asked == 3)
        #expect(chat.sent.isEmpty)
        let notice = try #require(talk.notice(for: chat.memoScope))
        #expect(notice.kind == .stopped)
        #expect(notice.action == .tryAgain)
        #expect(notice.detail == "HTTP 500: Synthetic transcription failure")
        await talk.resetForTests()
    }
}
