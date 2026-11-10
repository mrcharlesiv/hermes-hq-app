// GPT-Live (docs/spec/3x-gpt-live.md): the wire, the reducer, and the controller driving a scripted session. No audio
// and no network: `FixtureLiveVoice` stands in for the WebRTC peer and the gateway's answer is invented.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("GPT-Live wire")
struct GPTLiveWireTests {
    @Test func theGatewaysModeNamesTheEngine() {
        #expect(TalkEngine(mode: "gpt-live") == .gptLive)
        #expect(TalkEngine(mode: "GPT_LIVE") == .gptLive)
        #expect(TalkEngine(mode: " live ") == .gptLive)
        #expect(TalkEngine(mode: "chained") == .standard)
        #expect(TalkEngine(mode: nil) == .standard)
        #expect(TalkConfig(config: ["voice": ["voice_chat_mode": "gpt-live"]]).chatMode == .gptLive)
        #expect(TalkConfig(config: ["voice": [:]]).chatMode == .standard)
    }

    /// Talk runs in every bot's chat: a voice in Otto's chat saying "Hermes is still working" sounds like a hand-off.
    @Test func whatTheVoiceHearsOrSaysNamesNoBot() {
        for text in [LiveVoiceWire.toolNote("Run tests"), LiveVoiceWire.quietWhileWorking, LiveVoiceWire.noSpokenResult,
                     LiveVoiceWire.couldNotReach, LiveVoiceWire.respondNow] {
            #expect(!text.localizedCaseInsensitiveContains("hermes"), "\(text)")
        }
    }

    @Test func statusIsReadOnlyFromAnOkAnswer() {
        let ok = LiveVoiceStatus(json: ["ok": true, "mode": "gpt-live", "available": true, "model": "gpt-live-1", "voice": "cedar"])
        #expect(ok == LiveVoiceStatus(mode: .gptLive, available: true, model: "gpt-live-1", voice: "cedar"))
        let noKey = LiveVoiceStatus(json: ["ok": true, "mode": "gpt-live", "available": false, "reason": "missing_key"])
        #expect(noKey?.available == false && noKey?.reason == "missing_key")
        #expect(LiveVoiceStatus(json: ["detail": "Not Found"]) == nil)
        #expect(LiveVoiceStatus(json: nil) == nil)
    }

    @Test func theEngineIsGPTLiveOnlyWhenTheGatewayCanStartIt() {
        var config = TalkConfig()
        config.chatMode = .gptLive
        let on = LiveVoiceStatus(mode: .gptLive, available: true)
        let off = LiveVoiceStatus(mode: .gptLive, available: false)
        #expect(TalkController.engine(config: config, status: on, chosen: nil) == .gptLive)
        #expect(TalkController.engine(config: config, status: off, chosen: nil) == .standard)
        #expect(TalkController.engine(config: config, status: nil, chosen: .gptLive) == .standard)
        #expect(TalkController.engine(config: config, status: on, chosen: .standard) == .standard)
        #expect(TalkController.engine(config: TalkConfig(), status: on, chosen: .gptLive) == .gptLive)
    }

    @Test func serverEventsAreParsed() {
        #expect(LiveServerEvent.parse(#"{"type":"session.started","session":{"id":"s1"}}"#) == .started(sessionId: "s1"))
        #expect(LiveServerEvent.parse(#"{"type":"session.input_transcript.delta","delta":"hi ","start_ms":10,"end_ms":40}"#)
                == .transcript(LiveTranscriptFragment(speaker: .user, text: "hi ", startMs: 10, endMs: 40)))
        #expect(LiveServerEvent.parse(#"{"type":"session.output_transcript.delta","delta":"Hello"}"#)
                == .transcript(LiveTranscriptFragment(speaker: .assistant, text: "Hello", startMs: 0, endMs: 0)))
        #expect(LiveServerEvent.parse(#"{"type":"session.delegation.created","delegation":{"id":"d1"}}"#) == .delegation(id: "d1"))
        #expect(LiveServerEvent.parse(#"{"type":"session.delegation.created","delegation":{}}"#) == .other(type: "session.delegation.created"))
        #expect(LiveServerEvent.parse(#"{"type":"error","error":{"code":"context_injection_incomplete","message":"x"}}"#) == .other(type: "error"))
        #expect(LiveServerEvent.parse(#"{"type":"error","error":{"message":"rate limited"}}"#) == .error(message: "rate limited"))
        #expect(LiveServerEvent.parse(#"{"type":"session.closed","reason":"close_requested","usage":{"seconds":15}}"#)
                == .closed(reason: "close_requested", usageSeconds: 15))
        #expect(LiveServerEvent.parse("not json") == nil)
    }

    @Test func sentEventsCarryTheDelegationAndStayUnderTheCap() throws {
        let long = String(repeating: "This is a sentence. ", count: 200)
        let chunks = LiveVoiceWire.commentary(delegationId: "d1", long)
        #expect(chunks.count > 1)
        for raw in chunks {
            let json = try #require(try? JSONValue.parse(Data(raw.utf8)))
            #expect(json["type"]?.string == "session.commentary.append")
            #expect(json["delegation_id"]?.string == "d1")
            #expect((json["content"]?.string?.count ?? 0) <= LiveVoiceWire.appendCharLimit)
        }
        let thinking = try #require(LiveVoiceWire.thinking(delegationId: nil, "  working \n on it "))
        let json = try #require(try? JSONValue.parse(Data(thinking.utf8)))
        #expect(json["content"]?.string == "working on it")
        #expect(json["delegation_id"] == .null)
        #expect(LiveVoiceWire.thinking(delegationId: "d", "   ") == nil)
        #expect(LiveVoiceWire.mute(true).contains("session.input_audio.mute"))
        #expect(LiveVoiceWire.mute(false).contains("session.input_audio.unmute"))
    }

    @Test func chunksCutOnSentenceEnds() {
        #expect(LiveVoiceWire.chunks("One. Two.", limit: 100) == ["One. Two."])
        #expect(LiveVoiceWire.chunks("One two. Three four. Five.", limit: 12) == ["One two.", "Three four.", "Five."])
        #expect(LiveVoiceWire.chunks(String(repeating: "a", count: 25), limit: 10).map(\.count) == [10, 10, 5])
        #expect(LiveVoiceWire.chunks("   ").isEmpty)
    }

    @Test func aDelegationAsksWhatWasSaidLastWithTheExchangeAsContext() {
        let fragments = [
            LiveTranscriptFragment(speaker: .user, text: "What's ", startMs: 0, endMs: 100),
            LiveTranscriptFragment(speaker: .user, text: "the weather?", startMs: 100, endMs: 200),
            LiveTranscriptFragment(speaker: .assistant, text: "Let me check.", startMs: 300, endMs: 400),
            LiveTranscriptFragment(speaker: .user, text: "In Boston", startMs: 500, endMs: 600),
        ]
        let (prompt, context) = LiveVoiceWire.delegationPrompt(fragments)
        #expect(prompt == "In Boston")
        #expect(context == "User: What's the weather?\nVoice assistant: Let me check.\nUser: In Boston")
        let old = LiveTranscriptFragment(speaker: .user, text: "old", startMs: 0, endMs: 0)
        let new = LiveTranscriptFragment(speaker: .user, text: "new", startMs: 0, endMs: LiveVoiceWire.contextWindowMs + 1)
        #expect(LiveVoiceWire.contextWindow([old, new]) == [new])
    }

    @Test func theRequestJoinsThePersonsWordsAcrossBackchannels() {
        func user(_ text: String) -> LiveTranscriptFragment { LiveTranscriptFragment(speaker: .user, text: text, startMs: 0, endMs: 0) }
        func voice(_ text: String) -> LiveTranscriptFragment { LiveTranscriptFragment(speaker: .assistant, text: text, startMs: 0, endMs: 0) }
        // Build 407: the voice's "Mm-hmm." mid-sentence left ". I think we should change them to 6.1 Terra too" alone.
        let split = [user("The other bots are on Opus"), voice("Mm-hmm."), user(". I think we should change them "), user("to 6.1 Terra too")]
        #expect(LiveVoiceWire.spokenRequest(split) == "The other bots are on Opus . I think we should change them to 6.1 Terra too")
        #expect(LiveVoiceWire.spokenRequest([voice("Okay."), user(", or, yeah, go ahead")]) == "or, yeah, go ahead")
        // A real answer from the voice starts the request afresh.
        let answered = [user("Hello there"), voice("Hi! I am doing well, thanks for asking, what can I help with today?"), user("Check the server")]
        #expect(LiveVoiceWire.spokenRequest(answered) == "Check the server")
        #expect(LiveVoiceWire.spokenRequest([voice("Let me check.")]).isEmpty)
    }

    @Test func theSeedKeepsTheNewestTurnsWithinItsBudget() {
        let turns = (0..<40).map { (assistant: $0 % 2 == 1, text: "turn \($0)") }
        guard case .array(let items) = LiveVoiceWire.history(turns) else { Issue.record("not an array"); return }
        #expect(items.count == LiveVoiceWire.historyMaxMessages)
        #expect(items.last?["content"]?[0]?["text"]?.string == "turn 39")
        #expect(items.last?["role"]?.string == "assistant")
        #expect(items.last?["content"]?[0]?["type"]?.string == "output_text")
        // Each turn is cut to 1,200 characters: five of six long ones fit the 6,000 budget, the newest five.
        let big = (0..<6).map { (assistant: $0 % 2 == 1, text: "\($0)" + String(repeating: "x", count: 5_000)) }
        guard case .array(let few) = LiveVoiceWire.history(big) else { Issue.record("not an array"); return }
        #expect(few.count == 5)
        #expect(few.first?["content"]?[0]?["text"]?.string?.hasPrefix("1") == true)
        #expect(few.allSatisfy { ($0["content"]?[0]?["text"]?.string?.count ?? 0) == 1_200 })
    }

    @Test func theSessionBodySendsTheOfferAsIsAndReadsTheAnswer() throws {
        let sdp = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n"
        let body = try #require(try? JSONValue.parse(LiveVoiceWire.sessionBody(sdp: sdp, history: .array([]))))
        #expect(body["sdp"]?.string == sdp)
        #expect(body["history"] == nil)
        let answer = Data(#"{"ok":true,"session":{"id":"s"},"transport":{"type":"webrtc","sdp":"v=0\r\nanswer"}}"#.utf8)
        #expect(LiveVoiceWire.answerSDP(answer) == "v=0\r\nanswer")
        #expect(LiveVoiceWire.answerSDP(Data(#"{"ok":false,"detail":"no key"}"#.utf8)) == nil)
    }
}

@Suite("GPT-Live loop")
struct GPTLiveLoopTests {
    private struct Loop {
        var state = TalkLoopState(now: 0, speaksReplies: true)
        var live = LiveTalkState()
        var now: TimeInterval = 0

        @discardableResult
        mutating func send(_ input: LiveTalkInput, at time: TimeInterval? = nil) -> [LiveTalkEffect] {
            if let time { now = time }
            return LiveTalkLoop.reduce(&state, &live, input, now: now)
        }

        mutating func said(_ words: String, at time: TimeInterval) {
            send(.transcript(LiveTranscriptFragment(speaker: .user, text: words, startMs: Int(time * 1000), endMs: Int(time * 1000) + 500)), at: time)
        }

        mutating func ready() {
            send(.start)
            send(.sessionReady)
        }
    }

    @Test func aDelegationBecomesATurnAndItsReplyIsSpokenSentenceBySentence() {
        var loop = Loop()
        loop.ready()
        #expect(loop.state.status == .listening)
        loop.said("Book a table for two", at: 1)
        let submit = loop.send(.delegation(id: "d1"), at: 2)
        #expect(submit == [.submit(text: "Book a table for two", context: "User: Book a table for two")])
        #expect(loop.state.status == .thinking)
        loop.send(.turnRunning(true))
        #expect(loop.send(.reply(SpokenReply(messageId: "m1", text: "Done. I booked", pending: true))) == [.speak(delegationId: "d1", text: "Done.")])
        #expect(loop.send(.reply(SpokenReply(messageId: "m1", text: "Done. I booked it for 7.", pending: true))).isEmpty)
        loop.send(.reply(SpokenReply(messageId: "m1", text: "Done. I booked it for 7.", pending: false)))
        #expect(loop.send(.turnRunning(false)) == [.speak(delegationId: "d1", text: " I booked it for 7.")])
        #expect(loop.state.status == .listening)
    }

    @Test func aReplyAlreadyThereIsNeverSpoken() {
        var loop = Loop()
        loop.ready()
        loop.send(.reply(SpokenReply(messageId: "old", text: "Earlier answer.", pending: false)))
        loop.said("Hello", at: 1)
        loop.send(.delegation(id: "d1"))
        #expect(loop.send(.reply(SpokenReply(messageId: "old", text: "Earlier answer.", pending: false))).isEmpty)
    }

    @Test func aTurnThatEndsWithoutWordsSaysSo() {
        var loop = Loop()
        loop.ready()
        loop.said("Run the backup", at: 1)
        loop.send(.delegation(id: "d1"), at: 1)
        loop.send(.turnRunning(true))
        #expect(loop.send(.tool("Run backup.sh")).isEmpty)
        #expect(loop.send(.turnRunning(false)) == [.think(delegationId: "d1", text: LiveVoiceWire.noSpokenResult)])
        #expect(loop.state.status == .listening)
    }

    @Test func progressNotesComeOnlyIntoALongTurnAndRarely() {
        var loop = Loop()
        loop.ready()
        loop.said("Fix the build", at: 1)
        loop.send(.delegation(id: "d1"), at: 2)
        loop.send(.turnRunning(true))
        #expect(loop.send(.tool("Read file")).isEmpty)
        #expect(loop.send(.tool("Run tests"), at: 10).isEmpty)
        #expect(loop.send(.tick, at: 21).isEmpty)
        #expect(loop.send(.tick, at: 22) == [.think(delegationId: "d1", text: LiveVoiceWire.toolNote("Run tests"))])
        #expect(loop.send(.tool("Edit file"), at: 30).isEmpty)
        #expect(loop.send(.tick, at: 60).isEmpty)
        #expect(loop.send(.tick, at: 67) == [.think(delegationId: "d1", text: LiveVoiceWire.toolNote("Edit file"))])
        #expect(loop.send(.tick, at: 120).isEmpty)
    }

    @Test func theRequestIsEverythingSaidSinceTheLastOne() {
        var loop = Loop()
        let started = loop.send(.start) + loop.send(.sessionReady)
        #expect(started == [.instruct(LiveVoiceWire.quietWhileWorking)])
        loop.said("Switch the other bots", at: 1)
        loop.send(.transcript(LiveTranscriptFragment(speaker: .assistant, text: "Mm-hmm.", startMs: 1500, endMs: 1600)))
        loop.said(" to Terra too", at: 2)
        let first = loop.send(.delegation(id: "d1"), at: 3)
        guard case .submit(let text, _)? = first.first else { Issue.record("no submit"); return }
        #expect(text == "Switch the other bots to Terra too")
        loop.send(.turnRunning(true))
        loop.send(.turnRunning(false))
        loop.said("And the gym bot", at: 10)
        guard case .submit(let next, _)? = loop.send(.delegation(id: "d2"), at: 11).first else { Issue.record("no submit"); return }
        #expect(next == "And the gym bot")
    }

    @Test func aTurnTheVoiceDidNotAskForIsSpokenAndIsNotSilence() {
        var loop = Loop()
        loop.ready()
        loop.send(.reply(SpokenReply(messageId: "old", text: "Earlier answer.", pending: false)))
        // A bot's message starts a turn in this chat.
        loop.send(.turnRunning(true), at: 5)
        #expect(loop.state.status == .thinking)
        #expect(loop.send(.tool("Read inbox")).isEmpty)
        #expect(loop.send(.tick, at: 100).isEmpty)
        #expect(!loop.state.ended)
        loop.send(.reply(SpokenReply(messageId: "m2", text: "The inbox bot says the cleanup ran.", pending: false)))
        #expect(loop.send(.turnRunning(false), at: 101) == [.speak(delegationId: nil, text: "The inbox bot says the cleanup ran.")])
        #expect(loop.state.status == .listening)
        // A silent run says nothing, not even "finished without a spoken result".
        loop.send(.turnRunning(true), at: 110)
        loop.send(.reply(SpokenReply(messageId: "m3", text: "[SILENT]", pending: false)))
        #expect(loop.send(.turnRunning(false), at: 111).isEmpty)
        #expect(loop.state.status == .listening)
    }

    // Owner, 2026-10-28: Hermes answered the juno and inbox bots' results in the gateway (turns the phone never saw
    // running), and the voice, never told, kept saying "still waiting".
    @Test func aReplyOnlyReadFromHistoryIsSaidOnceAsSessionNews() {
        var loop = Loop()
        loop.send(.start)
        let news = SpokenReply(messageId: "g1", text: "Juno says the login worked and the candidates are in.", pending: false)
        #expect(loop.send(.recentReplies([news])).isEmpty)          // no voice to tell yet
        loop.send(.sessionReady)
        #expect(loop.send(.recentReplies([news])) == [.speak(delegationId: nil, text: news.text)])
        #expect(loop.send(.recentReplies([news])).isEmpty)
        // The same words read again under the stored row's id are not said twice; short words like an earlier reply's are.
        #expect(loop.send(.recentReplies([news, SpokenReply(messageId: "6155", text: news.text, pending: false)])).isEmpty)
        let done = SpokenReply(messageId: "g2", text: "The login worked.", pending: false)
        #expect(loop.send(.recentReplies([news, done])) == [.speak(delegationId: nil, text: done.text)])
        // Still streaming, or the bot's way of saying nothing: not passed on.
        #expect(loop.send(.recentReplies([SpokenReply(messageId: "g3", text: "Checking the", pending: true)])).isEmpty)
        #expect(loop.send(.recentReplies([SpokenReply(messageId: "g4", text: "[SILENT]", pending: false)])).isEmpty)
    }

    @Test func aRequestsAnswerIsNotSaidAgainByTheCatchUp() {
        var loop = Loop()
        loop.ready()
        loop.said("Book a table for two", at: 1)
        loop.send(.delegation(id: "d1"), at: 2)
        loop.send(.turnRunning(true))
        #expect(loop.send(.reply(SpokenReply(messageId: "m1", text: "Done. I booked", pending: true))) == [.speak(delegationId: "d1", text: "Done.")])
        // Finished but the turn still runs: the request's stream says the rest, not the catch-up.
        let whole = SpokenReply(messageId: "m1", text: "Done. I booked it for 7.", pending: false)
        loop.send(.reply(whole))
        #expect(loop.send(.recentReplies([whole])).isEmpty)
        #expect(loop.send(.turnRunning(false)) == [.speak(delegationId: "d1", text: " I booked it for 7.")])
        #expect(loop.send(.recentReplies([whole])).isEmpty)
    }

    @Test func aReplyThatLandedJustBeforeARequestIsStillSaid() {
        var loop = Loop()
        loop.ready()
        let news = SpokenReply(messageId: "g1", text: "Inbox says three messages need you.", pending: false)
        loop.send(.reply(news))                                      // the newest row, no turn seen running
        loop.said("What did the inbox bot find?", at: 1)
        loop.send(.delegation(id: "d1"), at: 1)                      // before the catch-up ran
        #expect(loop.send(.recentReplies([news])) == [.speak(delegationId: nil, text: news.text)])
        loop.send(.turnRunning(true))
        loop.send(.reply(SpokenReply(messageId: "m2", text: "Three messages need you.", pending: false)))
        #expect(loop.send(.turnRunning(false)) == [.speak(delegationId: "d1", text: "Three messages need you.")])
    }

    /// A request let go before its answer came (the stopped turn's late "not running", owner 20:49:23): the answer is
    /// still said when it arrives.
    @Test func aRequestEndedEarlyStillHasItsAnswerSaid() {
        var loop = Loop()
        loop.ready()
        loop.said("Look up the decisions API", at: 1)
        loop.send(.delegation(id: "d1"), at: 1)
        loop.send(.turnRunning(true))
        #expect(loop.send(.turnRunning(false)) == [.think(delegationId: "d1", text: LiveVoiceWire.noSpokenResult)])
        let answer = SpokenReply(messageId: "m1", text: "The decisions API takes a POST with the candidate id.", pending: false)
        loop.send(.reply(answer))
        #expect(loop.send(.recentReplies([answer])) == [.speak(delegationId: nil, text: answer.text)])
    }

    @Test func whatTheVoiceWasCutOffSayingIsNotCaughtUp() {
        var loop = Loop()
        loop.ready()
        loop.said("Read me the news", at: 1)
        loop.send(.delegation(id: "d1"), at: 1)
        loop.send(.turnRunning(true))
        #expect(loop.send(.reply(SpokenReply(messageId: "m1", text: "First story. Second", pending: true))) == [.speak(delegationId: "d1", text: "First story.")])
        let whole = SpokenReply(messageId: "m1", text: "First story. Second story.", pending: false)
        loop.send(.reply(whole))
        loop.send(.assistantSpeaking(true))
        loop.send(.stopOrInterrupt)
        loop.send(.turnRunning(false))
        #expect(loop.send(.recentReplies([whole])).isEmpty)
    }

    @Test func aRequestWhileATurnRunsLeavesTheTurnToTheChat() {
        var loop = Loop()
        loop.ready()
        loop.said("Search the inbox", at: 1)
        loop.send(.delegation(id: "d1"), at: 1)
        loop.send(.turnRunning(true))
        #expect(loop.send(.reply(SpokenReply(messageId: "m1", text: "Searching now. Found", pending: true))) == [.speak(delegationId: "d1", text: "Searching now.")])
        loop.said("and the spam folder", at: 4)
        let next = loop.send(.delegation(id: "d2"), at: 4)
        guard next.count == 1, case .submit(let text, _)? = next.first else { Issue.record("not just a submit: \(next)"); return }
        #expect(text == "and the spam folder")
        // The steered reply's answer lands in a new bubble and is the second request's.
        loop.send(.reply(SpokenReply(messageId: "m2", text: "Both are clear.", pending: false)))
        #expect(loop.send(.turnRunning(false)) == [.speak(delegationId: "d2", text: "Both are clear.")])
        #expect(loop.send(.recentReplies([SpokenReply(messageId: "m1", text: "Searching now. Found nothing yet.", pending: false),
                                          SpokenReply(messageId: "m2", text: "Both are clear.", pending: false)])).isEmpty)
    }

    @Test func aRefusedSendIsSpokenAsCouldNotReach() {
        var loop = Loop()
        loop.ready()
        loop.said("Hi", at: 1)
        loop.send(.delegation(id: "d1"))
        #expect(loop.send(.submitFailed) == [.speak(delegationId: "d1", text: LiveVoiceWire.couldNotReach), .haptic(.error)])
        #expect(loop.state.status == .listening)
    }

    @Test func aBareStopEndsTheChatOnlyOnceTheUtteranceSettles() {
        var loop = Loop()
        loop.ready()
        loop.said("stop", at: 1)
        #expect(loop.send(.tick, at: 1.5).isEmpty)
        let effects = loop.send(.tick, at: 2.6)
        #expect(effects == [.closeSession, .ended(.said)])
        var other = Loop()
        other.ready()
        other.said("stop the container", at: 1)
        #expect(other.send(.tick, at: 3).isEmpty)
        #expect(!other.state.ended)
    }

    @Test func muteAndSendNowGoToTheVoice() {
        var loop = Loop()
        loop.ready()
        #expect(loop.send(.sendNow) == [.instruct(LiveVoiceWire.respondNow)])
        #expect(loop.send(.muteToggled) == [.setMuted(true)])
        #expect(loop.send(.sendNow).isEmpty)
        #expect(loop.send(.muteToggled) == [.setMuted(false)])
    }

    @Test func interruptStopsTheTurnAndTellsTheVoice() {
        var loop = Loop()
        loop.ready()
        loop.said("Read me the news", at: 1)
        loop.send(.delegation(id: "d1"))
        loop.send(.turnRunning(true))
        loop.send(.assistantSpeaking(true))
        #expect(loop.state.status == .speaking)
        #expect(loop.send(.stopOrInterrupt) == [.stopTurn, .instruct(LiveVoiceWire.stopTalking)])
        #expect(loop.live.delegationId == nil)
    }

    @Test func theSessionClosingFallsBackInsteadOfEnding() {
        var loop = Loop()
        loop.ready()
        #expect(loop.send(.closed(reason: "connection_lost", usageSeconds: 65)) == [.fallBack(reason: "connection_lost")])
        #expect(!loop.state.ended)
        #expect(loop.live.delegationId == nil)
    }

    @Test func aLongSilenceEndsTheBilledSession() {
        var loop = Loop()
        loop.ready()
        var ended: [LiveTalkEffect] = []
        var time = 0.0
        while time < 200, ended.isEmpty {
            time += 1
            ended = loop.send(.tick, at: time)
        }
        #expect(ended.last == .ended(.paused(.silence, detail: nil)))
        #expect(time <= TalkClock().silencePause + 2)
    }
}

@Suite("GPT-Live controller", .serialized)
@MainActor
struct GPTLiveControllerTests {
    @MainActor final class Box {
        var transport: FixtureLiveVoice?
        var exchanged: [String] = []
        var history: JSONValue?
    }

    private func make(available: Bool = true, exchange: Result<String, VoiceFailure> = .success("v=0\r\nanswer")) -> (TalkController, Box) {
        AudioSessionCoordinator.shared.reset()
        KeepAwake.reset()
        TalkController.chosenEngine = nil
        FixtureLiveVoice.failWith = nil
        FixtureLiveVoice.sent = []
        FixtureLiveVoice.exchanged = []
        FixtureLiveVoice.script = [(0.05, #"{"type":"session.started","session":{"id":"sess_test"}}"#)]
        let talk = TalkController()
        let box = Box()
        var config = TalkConfig()
        config.chatMode = .gptLive
        talk.makeCapture = { FixtureTalkCapture(clock: $0) }
        talk.speaker = FakeSpeaker()
        talk.loadConfig = { _ in config }
        talk.transcribe = { _, _ in .success("") }
        talk.loadLiveStatus = { _ in LiveVoiceStatus(mode: .gptLive, available: available) }
        talk.makeLiveTransport = {
            let transport = FixtureLiveVoice()
            box.transport = transport
            return transport
        }
        talk.exchangeLive = { _, sdp, history in
            box.exchanged.append(sdp)
            box.history = history
            return try exchange.get()
        }
        talk.holdsLeases = false
        talk.isOnScreen = { true }
        talk.speaksReplies = { true }
        return (talk, box)
    }

    private func sent(_ type: String) -> [JSONValue] {
        FixtureLiveVoice.sent.compactMap { try? JSONValue.parse(Data($0.utf8)) }.filter { $0["type"]?.string == type }
    }

    @Test func aConversationDelegatesToTheChatAndSpeaksTheReply() async throws {
        let (talk, box) = make()
        let chat = FakeTalkChat()
        chat.history = [(false, "Earlier question"), (true, "Earlier answer")]
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        #expect(talk.debugSnapshot["engine"] as? String == "gpt-live")
        #expect(box.exchanged.count == 1)
        if case .array(let seed)? = box.history { #expect(seed.count == 2) } else { Issue.record("no seed") }
        let transport = try #require(box.transport)
        transport.play(#"{"type":"session.input_transcript.delta","delta":"What's on my calendar?","start_ms":0,"end_ms":900}"#)
        transport.play(#"{"type":"session.delegation.created","delegation":{"id":"del_1"}}"#)
        #expect(await waitUntil { chat.delegated.count == 1 })
        #expect(chat.delegated.first?.text == "What's on my calendar?")
        #expect(chat.delegated.first?.context.contains("User: What's on my calendar?") == true)
        #expect(talk.view?.phase == .thinking)
        chat.reply("m1", "You have two meetings. The first is at 10.", done: true)
        #expect(await waitUntil { !sent("session.commentary.append").isEmpty })
        let spoken = sent("session.commentary.append").compactMap { $0["content"]?.string }.joined(separator: " ")
        #expect(spoken.contains("You have two meetings.") && spoken.contains("The first is at 10."))
        #expect(sent("session.commentary.append").allSatisfy { $0["delegation_id"]?.string == "del_1" })
        talk.toggleMute()
        #expect(!sent("session.input_audio.mute").isEmpty)
        talk.end()
        #expect(await waitUntil { !talk.isLive })
        await talk.resetForTests()
        #expect(!sent("session.close").isEmpty)
        #expect(!chat.voiceHold)
        #expect(chat.onDelegationRefused == nil)
        #expect(AudioSessionCoordinator.shared.owner == nil)
    }

    /// A reply the chat only read from history (Hermes answering another bot in the gateway) is passed on as news.
    @Test func aReplyFromATurnThePhoneNeverSawIsPassedOn() async throws {
        let (talk, box) = make()
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        _ = try #require(box.transport)
        chat.recent = [SpokenReply(messageId: "g1", text: "Juno says the login worked.", pending: false)]
        chat.newestReply = chat.recent.last
        chat.changed()
        #expect(await waitUntil { !sent("session.commentary.append").isEmpty })
        let said = sent("session.commentary.append")
        #expect(said.compactMap { $0["content"]?.string } == ["Juno says the login worked."])
        #expect(said.allSatisfy { $0["delegation_id"] == .null })
        chat.changed()
        try await Task.sleep(for: .milliseconds(300))
        #expect(sent("session.commentary.append").count == 1)
        await talk.resetForTests()
    }

    @Test func withoutAKeyTheStandardEngineRuns() async throws {
        let (talk, box) = make(available: false)
        FixtureTalkCapture.script = TalkFixtureStep.parse("hold")
        FixtureTalkCapture.permission = "granted"
        FixtureTalkCapture.startDelay = 0.02
        let chat = FakeTalkChat()
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        #expect(talk.debugSnapshot["engine"] as? String == "chained")
        #expect(box.transport == nil)
        await talk.resetForTests()
    }

    private func standardMicrophone() {
        FixtureTalkCapture.script = TalkFixtureStep.parse("hold")
        FixtureTalkCapture.permission = "granted"
        FixtureTalkCapture.startDelay = 0.02
    }

    @Test func aRefusedSessionFallsBackToTheStandardEngine() async throws {
        let (talk, _) = make(exchange: .failure(VoiceFailure(reason: "OpenAI refused the GPT-Live session.", detail: "HTTP 502")))
        standardMicrophone()
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.debugSnapshot["engine"] as? String == "chained" && talk.view?.phase == .listening })
        #expect(talk.isLive)
        #expect(talk.notice(for: chat.memoScope) == nil)
        #expect(chat.onDelegationRefused == nil)
        await talk.resetForTests()
    }

    @Test func aDeniedMicrophoneStillStops() async throws {
        let (talk, _) = make()
        FixtureLiveVoice.failWith = .denied
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { !talk.isLive })
        await talk.resetForTests()
    }

    @Test func theSessionClosingFromOpenAIFallsBack() async throws {
        let (talk, box) = make()
        standardMicrophone()
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        box.transport?.play(#"{"type":"session.closed","reason":"max_duration","usage":{"seconds":1800}}"#)
        #expect(await waitUntil { talk.debugSnapshot["engine"] as? String == "chained" && talk.view?.phase == .listening })
        #expect(talk.isLive)
        #expect(talk.notice(for: chat.memoScope) == nil)
        await talk.resetForTests()
    }

    @Test func aDroppedConnectionFallsBack() async throws {
        let (talk, box) = make()
        standardMicrophone()
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        box.transport?.onDropped?("connection_lost")
        #expect(await waitUntil { talk.debugSnapshot["engine"] as? String == "chained" && talk.view?.phase == .listening })
        #expect(talk.isLive)
        await talk.resetForTests()
    }
}

/// The real WebRTC peer against a stand-in for OpenAI's (`fake_live.py`, aiortc) on this Mac. Runs only when
/// `HQN_FAKE_LIVE_URL` is set (`TEST_RUNNER_HQN_FAKE_LIVE_URL=http://127.0.0.1:9911`): no audio, no key, no cost.
@Suite("GPT-Live WebRTC", .serialized, .enabled(if: ProcessInfo.processInfo.environment["HQN_FAKE_LIVE_URL"] != nil))
@MainActor
struct GPTLiveWebRTCTests {
    private var base: URL { URL(string: ProcessInfo.processInfo.environment["HQN_FAKE_LIVE_URL"] ?? "http://127.0.0.1:9911")! }

    @Test func theRealPeerOpensTheChannelAndCarriesEventsBothWays() async throws {
        WebRTCLiveVoice.withoutAudio = true
        defer { WebRTCLiveVoice.withoutAudio = false }
        let voice = WebRTCLiveVoice()
        var events: [LiveServerEvent] = []
        var dropped: [String] = []
        voice.onEvent = { events.append($0) }
        voice.onDropped = { dropped.append($0) }
        let base = self.base
        try await voice.start(history: .array([])) { sdp in
            var request = URLRequest(url: base.appending(path: "session"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = LiveVoiceWire.sessionBody(sdp: sdp, history: .array([]))
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let answer = LiveVoiceWire.answerSDP(data) else { throw VoiceFailure(reason: "no answer", detail: nil) }
            return answer
        }
        #expect(await waitUntil(timeout: .seconds(15)) { events.contains(.started(sessionId: "sess_fake")) })
        #expect(await waitUntil(timeout: .seconds(5)) { events.contains(.delegation(id: "del_fake")) })
        #expect(events.contains(.transcript(LiveTranscriptFragment(speaker: .user, text: "What's the weather?", startMs: 0, endMs: 900))))
        LiveVoiceWire.commentary(delegationId: "del_fake", "It is sunny.").forEach(voice.send)
        voice.setMuted(true)
        await voice.close()
        #expect(events.contains(.closed(reason: "close_requested", usageSeconds: 3)))
        #expect(dropped.isEmpty)
        let (data, _) = try await URLSession.shared.data(from: base.appending(path: "log"))
        let log = try #require(try? JSONValue.parse(data))
        guard case .array(let sent) = log else { Issue.record("no log"); return }
        let types = sent.compactMap { $0["type"]?.string }
        #expect(types.contains("session.commentary.append"))
        #expect(types.contains("session.input_audio.mute"))
        #expect(types.contains("session.close"))
        #expect(sent.first { $0["type"]?.string == "session.commentary.append" }?["content"]?.string == "It is sunny.")
    }
}
