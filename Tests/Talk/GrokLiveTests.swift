// Grok Live (docs/spec/3x-grok-live.md): the wire, the session's call bookkeeping, the shared reducer in Grok's mode,
// and the controller driving a scripted session. No audio and no network: `FixtureGrokLiveVoice` stands in for xAI's
// socket and the add-on's answer is invented.

import Foundation
import Testing
@testable import HermesHQNative

private func json(_ raw: String) -> JSONValue? { try? JSONValue.parse(Data(raw.utf8)) }

private func sends(_ actions: [GrokAction]) -> [JSONValue] {
    actions.compactMap { if case .send(let raw) = $0 { return json(raw) } else { return nil } }
}

private let sessionAnswer = #"{"ok":true,"client_secret":"sec_1","expires_at":1790000000,"auth":"subscription","url":"wss://api.x.ai/v1/realtime?model=m","model":"m","voice":"eve","instructions":"You are Ivy's voice."}"#

@Suite("Grok Live wire")
struct GrokLiveWireTests {
    @Test func statusIsReadOnlyFromAnOkAnswer() {
        let on = GrokLiveStatus(json: json(#"{"ok":true,"available":true,"auth":"subscription","model":"m","voice":"eve"}"#))
        #expect(on == GrokLiveStatus(available: true, auth: "subscription", model: "m", voice: "eve"))
        let off = GrokLiveStatus(json: json(#"{"ok":true,"available":false,"auth":null,"reason":"no_credentials"}"#))
        #expect(off?.available == false && off?.reason == "no_credentials" && off?.auth == nil)
        #expect(GrokLiveStatus(json: json(#"{"detail":"Not Found"}"#)) == nil)
        #expect(GrokLiveStatus(json: nil) == nil)
    }

    @Test func theSessionNeedsASecretAndASocketAddress() throws {
        let session = try #require(GrokLiveSession(json: json(sessionAnswer)))
        #expect(session.clientSecret == "sec_1")
        #expect(session.url.absoluteString == "wss://api.x.ai/v1/realtime?model=m")
        #expect(session.voice == "eve" && session.instructions == "You are Ivy's voice." && session.auth == "subscription")
        #expect(GrokLiveSession(json: json(#"{"ok":true,"client_secret":"s","url":"https://x"}"#)) == nil)
        #expect(GrokLiveSession(json: json(#"{"ok":true,"url":"wss://x"}"#)) == nil)
        #expect(GrokLiveSession(json: json(#"{"detail":"no_credentials"}"#)) == nil)
        #expect(GrokLiveWire.subprotocol("sec_1") == "xai-client-secret.sec_1")
    }

    @Test func theEngineIsGrokOnlyWhenChosenAndAvailable() {
        let on = GrokLiveStatus(available: true), off = GrokLiveStatus(available: false)
        #expect(TalkController.grokEngine(status: on, chosen: .grokLive) == .grokLive)
        #expect(TalkController.grokEngine(status: off, chosen: .grokLive) == .standard)
        #expect(TalkController.grokEngine(status: nil, chosen: .grokLive) == .standard)
        #expect(TalkController.grokEngine(status: on, chosen: nil) == .standard)
        #expect(TalkController.grokEngine(status: on, chosen: .gptLive) == .standard)
        // A device that chose Grok never runs GPT-Live, whatever the gateway's mode.
        var config = TalkConfig()
        config.chatMode = .gptLive
        #expect(TalkController.engine(config: config, status: LiveVoiceStatus(mode: .gptLive, available: true), chosen: .grokLive) == .standard)
        // No gateway mode names Grok.
        #expect(TalkEngine(mode: "grok-live") == .standard)
        #expect(TalkEngine(rawValue: "grok-live") == .grokLive)
        #expect(TalkEngine.grokLive.isLive && TalkEngine.gptLive.isLive && !TalkEngine.standard.isLive)
    }

    @Test func theSessionUpdateCarriesTheToolAndTheAudioFormat() throws {
        let update = try #require(json(GrokLiveWire.sessionUpdate(voice: "eve", instructions: "Be brief.")))
        #expect(update["type"]?.string == "session.update")
        let session = try #require(update["session"])
        #expect(session["voice"]?.string == "eve")
        #expect(session["instructions"]?.string == "Be brief.")
        #expect(session["turn_detection"]?["type"]?.string == "server_vad")
        #expect(session["audio"]?["input"]?["format"]?["type"]?.string == "audio/pcm")
        #expect(session["audio"]?["input"]?["format"]?["rate"]?.int == 24_000)
        #expect(session["audio"]?["output"]?["format"]?["rate"]?.int == 24_000)
        let tool = try #require(session["tools"]?[0])
        #expect(tool["type"]?.string == "function" && tool["name"]?.string == "ask_agent")
        #expect(tool["parameters"]?["required"]?[0]?.string == "request")
        #expect(json(GrokLiveWire.sessionUpdate(voice: nil, instructions: nil))?["session"]?["voice"] == nil)
    }

    @Test func theSeedIsOneItemPerMessage() throws {
        let history = LiveVoiceWire.history([(false, "Hi"), (true, "Hello there")])
        let items = GrokLiveWire.historyItems(history).compactMap(json)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0["type"]?.string == "conversation.item.create" && $0["item"]?["type"]?.string == "message" })
        #expect(items[1]["item"]?["role"]?.string == "assistant")
    }

    @Test func outgoingEventsAreShapedAsXAIExpects() throws {
        let pcm = Data([1, 0, 255, 127])
        let append = try #require(json(GrokLiveWire.append(pcm)))
        #expect(append["type"]?.string == "input_audio_buffer.append")
        #expect(append["audio"]?.string.flatMap { Data(base64Encoded: $0) } == pcm)

        let output = try #require(json(GrokLiveWire.functionOutput(callId: "c1", answer: String(repeating: "a", count: 5_000))))
        #expect(output["type"]?.string == "conversation.item.create")
        #expect(output["item"]?["type"]?.string == "function_call_output" && output["item"]?["call_id"]?.string == "c1")
        let inner = try #require(output["item"]?["output"]?.string.flatMap(json))
        #expect(inner["answer"]?.string?.count == GrokLiveWire.answerLimit)
        #expect(inner["note"] == nil)
        let empty = try #require(json(GrokLiveWire.functionOutput(callId: "c1", answer: "", note: GrokLiveWire.noWordsNote))?["item"]?["output"]?.string.flatMap(json))
        #expect(empty["answer"]?.string == "" && empty["note"]?.string == "The agent finished without a reply.")

        let news = try #require(json(GrokLiveWire.agentSays("The  backup\nfinished")))
        #expect(news["item"]?["role"]?.string == "user")
        #expect(news["item"]?["content"]?[0]?["type"]?.string == "input_text")
        #expect(news["item"]?["content"]?[0]?["text"]?.string == "(Not from the person — your agent says:) The backup finished. Tell the person this briefly.")

        #expect(json(GrokLiveWire.responseCreate())?["type"]?.string == "response.create")
        #expect(json(GrokLiveWire.responseCreate(instructions: "Answer now."))?["response"]?["instructions"]?.string == "Answer now.")
        #expect(json(GrokLiveWire.responseCancel)?["type"]?.string == "response.cancel")
    }

    /// Talk runs in every bot's chat: nothing told to the voice names a bot.
    @Test func notesNameNoBot() {
        for text in [GrokLiveWire.noWordsNote, GrokLiveWire.notSentNote, GrokLiveWire.replacedNote, GrokLiveWire.agentSays("x")] {
            #expect(!text.localizedCaseInsensitiveContains("hermes"), "\(text)")
        }
    }

    @Test func serverEventsAreParsed() {
        #expect(GrokServerEvent.parse(#"{"type":"session.created","session":{}}"#) == .sessionCreated)
        #expect(GrokServerEvent.parse(#"{"type":"session.updated"}"#) == .sessionUpdated)
        #expect(GrokServerEvent.parse(#"{"type":"ping"}"#) == .ping)
        #expect(GrokServerEvent.parse(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i1","transcript":"Hi there"}"#)
                == .inputTranscript(itemId: "i1", text: "Hi there", final: true))
        #expect(GrokServerEvent.parse(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"i1","delta":"Hi"}"#)
                == .inputTranscript(itemId: "i1", text: "Hi", final: false))
        #expect(GrokServerEvent.parse(#"{"type":"response.output_audio_transcript.delta","delta":"Sure"}"#) == .outputTranscript("Sure"))
        #expect(GrokServerEvent.parse(#"{"type":"response.output_audio.delta","delta":"AQI="}"#) == .audio(Data([1, 2])))
        #expect(GrokServerEvent.parse(#"{"type":"input_audio_buffer.speech_started"}"#) == .speechStarted)
        #expect(GrokServerEvent.parse(#"{"type":"response.created"}"#) == .responseCreated)
        #expect(GrokServerEvent.parse(#"{"type":"response.done"}"#) == .responseDone)
        #expect(GrokServerEvent.parse(#"{"type":"response.function_call_arguments.done","name":"ask_agent","call_id":"c1","arguments":"{\"request\":\"Check my mail\"}"}"#)
                == .functionCall(callId: "c1", name: "ask_agent", arguments: #"{"request":"Check my mail"}"#))
        #expect(GrokServerEvent.parse(#"{"type":"error","error":{"message":"bad","code":"invalid_value"}}"#) == .error(message: "bad", code: "invalid_value"))
        #expect(GrokServerEvent.parse(#"{"type":"response.output_item.done"}"#) == .other(type: "response.output_item.done"))
        #expect(GrokServerEvent.parse("nope") == nil)
        #expect(GrokLiveWire.request(fromArguments: #"{"request":"  Book   a table "}"#) == "Book a table")
        #expect(GrokLiveWire.request(fromArguments: "{") == nil)
    }
}

@Suite("Grok Live calls")
struct GrokLiveCallsTests {
    @Test func theSessionIsReadyOnceUpdated() {
        var calls = GrokLiveCalls()
        #expect(calls.receive(.sessionCreated, ms: 0).isEmpty)
        #expect(calls.receive(.sessionUpdated, ms: 0) == [.event(.started(sessionId: nil))])
        #expect(calls.receive(.sessionUpdated, ms: 0).isEmpty)
        #expect(calls.ready)
    }

    @Test func aCallBecomesADelegationAndItsAnswerGoesBackOnce() {
        var calls = GrokLiveCalls()
        let asked = calls.receive(.functionCall(callId: "c1", name: "ask_agent", arguments: #"{"request":"What's on today?"}"#), ms: 0)
        #expect(asked == [.event(.askAgent(callId: "c1", request: "What's on today?"))])
        let answered = sends(calls.speak(delegationId: "c1", text: "Two meetings."))
        #expect(answered.count == 2)
        #expect(answered[0]["item"]?["call_id"]?.string == "c1")
        #expect(answered[0]["item"]?["output"]?.string.flatMap(json)?["answer"]?.string == "Two meetings.")
        #expect(answered[1]["type"]?.string == "response.create")
        #expect(calls.open.isEmpty)
        // Said again for the same call (a late reply): news, not a second output.
        let again = sends(calls.speak(delegationId: "c1", text: "Also lunch."))
        #expect(again.first?["item"]?["type"]?.string == "message")
    }

    @Test func aTurnWithoutWordsAndARefusedSendStillAnswerTheCall() {
        var calls = GrokLiveCalls()
        _ = calls.receive(.functionCall(callId: "c1", name: "ask_agent", arguments: #"{"request":"Run it"}"#), ms: 0)
        let none = sends(calls.think(delegationId: "c1", text: LiveVoiceWire.noSpokenResult))
        #expect(none.first?["item"]?["output"]?.string.flatMap(json)?["note"]?.string == GrokLiveWire.noWordsNote)
        #expect(none.last?["type"]?.string == "response.create")
        _ = calls.receive(.functionCall(callId: "c2", name: "ask_agent", arguments: #"{"request":"Again"}"#), ms: 0)
        let refused = sends(calls.speak(delegationId: "c2", text: LiveVoiceWire.couldNotReach))
        #expect(refused.first?["item"]?["output"]?.string.flatMap(json)?["note"]?.string == GrokLiveWire.notSentNote)
        // Progress notes never reach Grok.
        _ = calls.receive(.functionCall(callId: "c3", name: "ask_agent", arguments: #"{"request":"Slow one"}"#), ms: 0)
        #expect(calls.think(delegationId: "c3", text: LiveVoiceWire.toolNote("Search")).isEmpty)
        #expect(calls.open == ["c3"])
    }

    @Test func aNewerCallClosesTheOpenOne() {
        var calls = GrokLiveCalls()
        _ = calls.receive(.functionCall(callId: "c1", name: "ask_agent", arguments: #"{"request":"One"}"#), ms: 0)
        let actions = calls.receive(.functionCall(callId: "c2", name: "ask_agent", arguments: #"{"request":"Two"}"#), ms: 0)
        let closed = sends(actions)
        #expect(closed.count == 1)
        #expect(closed[0]["item"]?["call_id"]?.string == "c1")
        #expect(closed[0]["item"]?["output"]?.string.flatMap(json)?["note"]?.string == GrokLiveWire.replacedNote)
        #expect(actions.last == .event(.askAgent(callId: "c2", request: "Two")))
        #expect(calls.open == ["c2"])
    }

    @Test func anUnknownToolIsAnsweredAndNotDelegated() {
        var calls = GrokLiveCalls()
        let actions = calls.receive(.functionCall(callId: "x", name: "web_search", arguments: "{}"), ms: 0)
        #expect(!actions.contains { if case .event = $0 { return true } else { return false } })
        #expect(sends(actions).last?["type"]?.string == "response.create")
        #expect(calls.open.isEmpty)
    }

    @Test func speakingOverTheVoiceFlushesItAndCancelsTheResponse() {
        var calls = GrokLiveCalls()
        #expect(calls.receive(.speechStarted, ms: 0) == [.flushPlayback])
        _ = calls.receive(.responseCreated, ms: 0)
        #expect(calls.receive(.audio(Data([0, 1])), ms: 0) == [.play(Data([0, 1]))])
        #expect(calls.receive(.speechStarted, ms: 0) == [.flushPlayback, .send(GrokLiveWire.responseCancel)])
        _ = calls.receive(.responseDone, ms: 0)
        #expect(calls.receive(.speechStarted, ms: 0) == [.flushPlayback])
    }

    @Test func unrequestedNewsIsToldAndInterruptCancels() {
        var calls = GrokLiveCalls()
        let news = sends(calls.speak(delegationId: nil, text: "The nightly job finished."))
        #expect(news.first?["item"]?["role"]?.string == "user")
        #expect(news.last?["type"]?.string == "response.create")
        #expect(calls.speak(delegationId: nil, text: "  ").isEmpty)
        #expect(calls.instruct(LiveVoiceWire.quietWhileWorking).isEmpty)
        #expect(calls.instruct(LiveVoiceWire.stopTalking) == [.flushPlayback, .send(GrokLiveWire.responseCancel)])
        #expect(sends(calls.instruct(LiveVoiceWire.respondNow)).first?["response"]?["instructions"]?.string == LiveVoiceWire.respondNow)
    }

    @Test func transcriptsBecomeFragmentsWithoutRepeats() {
        var calls = GrokLiveCalls()
        func text(_ actions: [GrokAction]) -> String? {
            if case .event(.transcript(let fragment))? = actions.first { return fragment.text } else { return nil }
        }
        #expect(text(calls.receive(.inputTranscript(itemId: "i1", text: "Book a", final: false), ms: 10)) == "Book a")
        #expect(text(calls.receive(.inputTranscript(itemId: "i1", text: "Book a table", final: true), ms: 20)) == " table ")
        #expect(text(calls.receive(.inputTranscript(itemId: "i2", text: "for two", final: true), ms: 30)) == "for two ")
        #expect(calls.receive(.inputTranscript(itemId: "i3", text: "", final: true), ms: 40).isEmpty)
        if case .event(.transcript(let fragment))? = calls.receive(.outputTranscript("Sure"), ms: 50).first {
            #expect(fragment.speaker == .assistant && fragment.endMs == 50)
        } else { Issue.record("no assistant fragment") }
    }
}

@Suite("Grok Live loop")
struct GrokLiveLoopTests {
    private struct Loop {
        var state = TalkLoopState(now: 0, speaksReplies: true)
        var live = LiveTalkState(engine: .grokLive)
        var now: TimeInterval = 0

        @discardableResult
        mutating func send(_ input: LiveTalkInput, at time: TimeInterval? = nil) -> [LiveTalkEffect] {
            if let time { now = time }
            return LiveTalkLoop.reduce(&state, &live, input, now: now)
        }
    }

    @Test func theRequestIsTheToolsArgumentAndTheAnswerGoesOnceWhole() {
        var loop = Loop()
        loop.send(.start)
        loop.send(.sessionReady)
        #expect(loop.state.status == .listening)
        loop.send(.transcript(LiveTranscriptFragment(speaker: .user, text: "uh can you book a table ", startMs: 0, endMs: 900)))
        let submit = loop.send(.askAgent(id: "c1", request: "Book a table for two at seven"), at: 1)
        #expect(submit == [.submit(text: "Book a table for two at seven", context: "User: uh can you book a table")])
        #expect(loop.state.status == .thinking)
        loop.send(.turnRunning(true))
        // No sentence-by-sentence: Grok gets one function output.
        #expect(loop.send(.reply(SpokenReply(messageId: "m1", text: "Done. I booked", pending: true))).isEmpty)
        loop.send(.reply(SpokenReply(messageId: "m1", text: "Done. I booked it for 7.", pending: false)))
        #expect(loop.send(.turnRunning(false)) == [.speak(delegationId: "c1", text: "Done. I booked it for 7.")])
        #expect(loop.state.status == .listening)
    }

    @Test func anEmptyRequestFallsBackToWhatWasHeard() {
        var loop = Loop()
        loop.send(.start)
        loop.send(.sessionReady)
        loop.send(.transcript(LiveTranscriptFragment(speaker: .user, text: "Check my inbox ", startMs: 0, endMs: 500)))
        #expect(loop.send(.askAgent(id: "c1", request: "")).first == .submit(text: "Check my inbox", context: "User: Check my inbox"))
    }

    @Test func aTurnTheVoiceDidNotAskForIsToldWhole() {
        var loop = Loop()
        loop.send(.start)
        loop.send(.sessionReady)
        loop.send(.turnRunning(true), at: 1)
        #expect(loop.send(.reply(SpokenReply(messageId: "b1", text: "The build passed. All green.", pending: true))).isEmpty)
        loop.send(.reply(SpokenReply(messageId: "b1", text: "The build passed. All green.", pending: false)))
        #expect(loop.send(.turnRunning(false)) == [.speak(delegationId: nil, text: "The build passed. All green.")])
    }

    @Test func theProblemLineNamesGrok() {
        var loop = Loop()
        loop.send(.start)
        loop.send(.sessionReady)
        loop.send(.vendorError("rate limited"))
        #expect(loop.state.problem?.contains("Grok Live") == true)
    }
}

@Suite("Grok Live controller", .serialized)
@MainActor
struct GrokLiveControllerTests {
    @MainActor final class Box {
        var transport: FixtureGrokLiveVoice?
        var sessions = 0
    }

    private func make(available: Bool = true, answer: Result<String, VoiceFailure> = .success(sessionAnswer)) -> (TalkController, Box) {
        AudioSessionCoordinator.shared.reset()
        KeepAwake.reset()
        TalkController.chosenEngine = .grokLive
        FixtureGrokLiveVoice.failWith = nil
        FixtureGrokLiveVoice.sent = []
        FixtureGrokLiveVoice.flushes = 0
        FixtureGrokLiveVoice.played = 0
        FixtureGrokLiveVoice.sessions = []
        FixtureGrokLiveVoice.script = [(0.05, #"{"type":"session.created"}"#), (0.08, #"{"type":"session.updated"}"#)]
        let talk = TalkController()
        let box = Box()
        talk.makeCapture = { FixtureTalkCapture(clock: $0) }
        talk.speaker = FakeSpeaker()
        talk.loadConfig = { _ in TalkConfig() }
        talk.transcribe = { _, _ in .success("") }
        talk.loadLiveStatus = { _ in Issue.record("GPT-Live status asked"); return nil }
        talk.loadGrokStatus = { _ in GrokLiveStatus(available: available) }
        talk.makeLiveTransport = { Issue.record("GPT-Live transport made"); return FixtureLiveVoice() }
        talk.makeGrokTransport = {
            let transport = FixtureGrokLiveVoice()
            box.transport = transport
            return transport
        }
        talk.openGrokSession = { _ in
            box.sessions += 1
            return try answer.get()
        }
        talk.holdsLeases = false
        talk.isOnScreen = { true }
        talk.speaksReplies = { true }
        return (talk, box)
    }

    private func sent(_ type: String) -> [JSONValue] {
        FixtureGrokLiveVoice.sent.compactMap(json).filter { $0["type"]?.string == type }
    }

    private func outputs() -> [JSONValue] {
        sent("conversation.item.create").filter { $0["item"]?["type"]?.string == "function_call_output" }
    }

    private func standardMicrophone() {
        FixtureTalkCapture.script = TalkFixtureStep.parse("hold")
        FixtureTalkCapture.permission = "granted"
        FixtureTalkCapture.startDelay = 0.02
    }

    @Test func aCallIsDelegatedToTheChatAndAnsweredWithTheReply() async throws {
        defer { TalkController.chosenEngine = nil }
        let (talk, box) = make()
        let chat = FakeTalkChat()
        chat.history = [(false, "Earlier question"), (true, "Earlier answer")]
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        #expect(talk.debugSnapshot["engine"] as? String == "grok-live")
        #expect(box.sessions == 1)
        #expect(sent("session.update").first?["session"]?["voice"]?.string == "eve")
        #expect(sent("conversation.item.create").filter { $0["item"]?["type"]?.string == "message" }.count == 2)
        let transport = try #require(box.transport)

        transport.play(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i1","transcript":"What's on my calendar?"}"#)
        transport.play(#"{"type":"response.created"}"#)
        transport.play(#"{"type":"response.function_call_arguments.done","name":"ask_agent","call_id":"call_1","arguments":"{\"request\":\"What is on my calendar today?\"}"}"#)
        transport.play(#"{"type":"response.done"}"#)
        #expect(await waitUntil { chat.delegated.count == 1 })
        #expect(chat.delegated.first?.text == "What is on my calendar today?")
        #expect(chat.delegated.first?.context.contains("User: What's on my calendar?") == true)
        #expect(talk.view?.phase == .thinking)

        chat.reply("m1", "You have two meetings. The first is at 10.", done: true)
        #expect(await waitUntil { !outputs().isEmpty })
        let output = try #require(outputs().first)
        #expect(output["item"]?["call_id"]?.string == "call_1")
        #expect(output["item"]?["output"]?.string.flatMap(json)?["answer"]?.string == "You have two meetings. The first is at 10.")
        #expect(FixtureGrokLiveVoice.sent.last.flatMap(json)?["type"]?.string == "response.create")
        #expect(outputs().count == 1)

        // Mute stops the appends; un-mute lets them through again.
        transport.hear(Data([1, 0]))
        talk.toggleMute()
        transport.hear(Data([2, 0]))
        #expect(await waitUntil { talk.isMuted })
        #expect(sent("input_audio_buffer.append").count == 1)

        talk.end()
        #expect(await waitUntil { !talk.isLive })
        await talk.resetForTests()
        #expect(!chat.voiceHold)
        #expect(AudioSessionCoordinator.shared.owner == nil)
    }

    @Test func bargeInFlushesThePlayback() async throws {
        defer { TalkController.chosenEngine = nil }
        let (talk, box) = make()
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        let transport = try #require(box.transport)
        transport.play(#"{"type":"response.created"}"#)
        transport.play(#"{"type":"response.output_audio.delta","delta":"AAAAAA=="}"#)
        #expect(FixtureGrokLiveVoice.played == 1)
        transport.play(#"{"type":"input_audio_buffer.speech_started"}"#)
        #expect(FixtureGrokLiveVoice.flushes == 1)
        #expect(sent("response.cancel").count == 1)
        await talk.resetForTests()
    }

    @Test func aBotsOwnMessageIsToldAsNews() async throws {
        defer { TalkController.chosenEngine = nil }
        let (talk, box) = make()
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        _ = try #require(box.transport)
        chat.recent = [SpokenReply(messageId: "g1", text: "Juno says the login worked.", pending: false)]
        chat.newestReply = chat.recent.last
        chat.changed()
        #expect(await waitUntil { sent("conversation.item.create").contains { $0["item"]?["role"]?.string == "user" } })
        let news = sent("conversation.item.create").filter { $0["item"]?["role"]?.string == "user" }
        #expect(news.count == 1)
        #expect(news.first?["item"]?["content"]?[0]?["text"]?.string?.contains("Juno says the login worked.") == true)
        await talk.resetForTests()
    }

    @Test func withoutCredentialsTheStandardEngineRuns() async throws {
        defer { TalkController.chosenEngine = nil }
        let (talk, box) = make(available: false)
        standardMicrophone()
        let chat = FakeTalkChat()
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        #expect(talk.debugSnapshot["engine"] as? String == "chained")
        #expect(box.transport == nil)
        await talk.resetForTests()
    }

    @Test func aRefusedSessionFallsBackToTheStandardEngine() async throws {
        defer { TalkController.chosenEngine = nil }
        let (talk, _) = make(answer: .failure(VoiceFailure(reason: "no_credentials", detail: "HTTP 503")))
        standardMicrophone()
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.debugSnapshot["engine"] as? String == "chained" && talk.view?.phase == .listening })
        #expect(talk.isLive)
        #expect(talk.notice(for: chat.memoScope) == nil)
        await talk.resetForTests()
    }

    @Test func aDroppedSocketFallsBack() async throws {
        defer { TalkController.chosenEngine = nil }
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

    @Test func aDeniedMicrophoneStillStops() async throws {
        defer { TalkController.chosenEngine = nil }
        let (talk, _) = make()
        FixtureGrokLiveVoice.failWith = .denied
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { !talk.isLive })
        await talk.resetForTests()
    }
}

@Suite("Grok Live stages")
struct GrokLiveStagesTests {
    private func event(_ raw: String) -> GrokServerEvent { GrokServerEvent.parse(raw)! }

    @Test func eachStageIsLoggedOnceInOrder() {
        var stages = GrokLiveStages()
        #expect(stages.note(event(#"{"type":"session.created"}"#), ready: false, ms: 100) == nil)
        #expect(stages.note(event(#"{"type":"session.updated"}"#), ready: false, ms: 300) == "grok-live setup confirmed at 300 ms")
        #expect(stages.note(event(#"{"type":"session.updated"}"#), ready: true, ms: 310) == nil)
        #expect(stages.note(event(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i","transcript":"Lights on"}"#), ready: true, ms: 4000)
            == "grok-live first words heard at 4000 ms")
        #expect(stages.note(event(#"{"type":"response.output_audio_transcript.delta","delta":"On it"}"#), ready: true, ms: 4200)
            == "grok-live first reply words at 4200 ms")
        #expect(stages.note(event(#"{"type":"response.output_audio.delta","delta":"AAAA"}"#), ready: true, ms: 4300)
            == "grok-live first voice audio back at 4300 ms")
        #expect(stages.note(event(#"{"type":"response.output_audio.delta","delta":"AAAA"}"#), ready: true, ms: 4310) == nil)
        #expect(stages.note(event(#"{"type":"response.function_call_arguments.done","call_id":"c1","name":"ask_agent","arguments":"{}"}"#), ready: true, ms: 4400)
            == "grok-live first tool call (ask_agent) at 4400 ms, handed to the bot")
        stages.sent = 40
        #expect(stages.summary(ready: true) == "setup confirmed 300 ms, mic pieces sent 40 (held before setup 0), voice audio back 2 (first 4300 ms), "
            + "words heard first 4000 ms, reply words first 4200 ms, tool calls 1 (first 4400 ms), errors 0")
    }

    @Test func aSessionThatNeverConfirmedSaysSo() {
        var stages = GrokLiveStages()
        stages.held = 12
        _ = stages.note(event(#"{"type":"error","error":{"message":"bad","code":"x"}}"#), ready: false, ms: 50)
        #expect(stages.summary(ready: false) == "setup confirmed no, mic pieces sent 0 (held before setup 12), voice audio back 0 (first never), "
            + "words heard first never, reply words first never, tool calls 0 (first never), errors 1")
        #expect(GrokLiveWire.setupTimeout == 5)
    }
}
