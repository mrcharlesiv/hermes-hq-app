// Live voice against the running voice stand-in gateway (scripts/fixtures/voice-gateway.py; docs/spec/3x-talk.md §3,
// §12). Enabled only when the run passes
//   TEST_RUNNER_HQ_TALK_FIXTURE="http://127.0.0.1:9900|$PWD/build/fixtures/talk-dev.json" scripts/talk-unit.sh <udid>
// One password sign-in per test (never in a loop); every word and sound is the fixture's invention. No audio device is
// used: the speaker is the stand-in output, which only counts bytes.

import Foundation
import Testing
@testable import HermesHQNative

nonisolated enum TalkFixture {
    static var config: (base: URL, username: String, password: String)? {
        guard let raw = ProcessInfo.processInfo.environment["HQ_TALK_FIXTURE"], let bar = raw.firstIndex(of: "|"),
              let base = URL(string: String(raw[..<bar])),
              let data = FileManager.default.contents(atPath: String(raw[raw.index(after: bar)...])),
              let creds = try? ChatJSON.parse(data), let user = creds["username"]?.string, let pass = creds["password"]?.string,
              ["127.0.0.1", "localhost", "::1"].contains(base.host() ?? "") else { return nil }
        return (base, user, pass)
    }
    static var available: Bool { config != nil }
    static var port: UInt16 { UInt16(config?.base.port ?? 9900) }

    /// One second of a 220 Hz tone as a 16 kHz mono 16-bit WAV, like a take.
    static func take(seconds: Double = 1) throws -> URL {
        let rate = 16_000, count = Int(Double(rate) * seconds)
        var pcm = Data(capacity: count * 2)
        for index in 0..<count {
            let sample = Int16(8_000 * sin(2 * Double.pi * 220 * Double(index) / Double(rate)))
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var wav = Data("RIFF".utf8)
        func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
        func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
        wav += le32(36 + pcm.count) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
        wav += Data("data".utf8) + le32(pcm.count) + pcm
        let url = FileManager.default.temporaryDirectory.appending(path: "talk-test-\(UUID().uuidString).wav")
        try wav.write(to: url)
        return url
    }
}

@Suite("Talk fixture (live)", .serialized, .enabled(if: TalkFixture.available))
@MainActor
struct VoiceGatewayLiveTests {
    let ivy = "20260929_120000_aabbcc02"

    private func signIn() async throws -> LiveGatewayClient {
        let config = try #require(TalkFixture.config)
        let vault = Fixtures.testVault("talk")
        vault.removeAll()
        let service = SignInService(store: AccountStore(vault: vault))
        let account = try await service.signInWithPassword(address: config.base.absoluteString, username: config.username,
                                                           password: config.password)
        let client = service.client(for: account)
        try await waitFor(client, .ready)
        VoiceGateway.forgetConfig()
        return client
    }

    @discardableResult
    private func control(_ json: [String: Any]) async throws -> JSONValue {
        try await Fixtures.control(TalkFixture.port, "/__fixture/voice", json: json)
    }

    private func ledger() async throws -> JSONValue {
        try await Fixtures.control(TalkFixture.port, "/__fixture/voice-state", method: "GET")
    }

    private func session(_ client: LiveGatewayClient) async -> LiveChatSession {
        let s = LiveChatSession(client: client, account: client.account, profile: "ivy", storedSessionId: ivy, title: "Ivy",
                                head: nil, cache: makeTempCache(), resolveSessionId: nil)   // real frames: the conversation listens to them
        s.start()
        _ = await waitUntil(timeout: .seconds(10)) { s.openSettled }
        return s
    }

    private func finish(_ client: LiveGatewayClient) {
        client.shutdown()
        Fixtures.testVault("talk").removeAll()
    }

    // MARK: Settings

    @Test func theVoiceSettingsAreReadOnceAndKept() async throws {
        try await control(["reset": true])
        let client = try await signIn()
        defer { finish(client) }
        let first = await VoiceGateway.config(client: client, profile: "ivy")
        #expect(first.sttEnabled)
        #expect(first.bargeIn)
        // The gateway's untouched 3.0 s is its default, not the person's choice: the phone keeps 1.25 s.
        #expect(first.silenceMs == 1_250)
        #expect(first.bargeMultiplier == 3)
        #expect(first.maxRecordingSeconds == 120)
        let reads = try await ledger()["configReads"]?.array?.count ?? 0
        _ = await VoiceGateway.config(client: client, profile: "ivy")
        #expect(try await ledger()["configReads"]?.array?.count == reads)       // kept for a minute
        #expect(VoiceGateway.knownConfig(client: client, profile: "ivy") == first)
        // Changed on the gateway: read again once forgotten.
        try await control(["voiceConfig": ["voice": ["silence_duration": 2, "barge_in": false, "stop_phrases": ["enough", "halt"]],
                                           "stt": ["enabled": false]]])
        VoiceGateway.forgetConfig()
        let second = await VoiceGateway.config(client: client, profile: "ivy")
        #expect(!second.sttEnabled)
        #expect(!second.bargeIn)
        #expect(second.silenceMs == 2_000)
        #expect(TalkStopWord.isStop("Enough.", config: second.stopPhrases))
        #expect(!TalkStopWord.isStop("stop", config: second.stopPhrases))
        #expect(try await ledger()["forbidden"]?.array?.isEmpty == true)
    }

    // MARK: Speech to text

    @Test func aTakeIsTranscribedAndAFailureIsTheGatewaysOwnWords() async throws {
        try await control(["reset": true])
        try await control(["transcripts": ["Hello there"]])
        let client = try await signIn()
        defer { finish(client) }
        let take = try TalkFixture.take()
        defer { try? FileManager.default.removeItem(at: take) }
        let heard = await VoiceGateway.transcribe(client: client, file: take, mime: "audio/wav", profile: "ivy")
        #expect(heard == .success("Hello there"))
        var state = try await ledger()
        let call = try #require(state["transcribes"]?.array?.first)
        #expect(call["profile"]?.string == "ivy")
        #expect(call["mime"]?.string == "audio/wav")
        #expect(call["sampleRate"]?.int == 16_000)
        #expect(call["channels"]?.int == 1)
        #expect(call["keys"]?.array?.compactMap(\.string).sorted() == ["data_url", "mime_type"])
        // Silence is an answer.
        try await control(["transcribeEmpty": true])
        #expect(await VoiceGateway.transcribe(client: client, file: take, mime: "audio/wav", profile: "ivy") == .success(""))
        try await control(["transcribeEmpty": false])
        // A refusal is shown word for word, with the status as the detail.
        try await control(["transcribeFail": ["status": 503, "detail": "No speech-to-text provider is configured."]])
        let refused = await VoiceGateway.transcribe(client: client, file: take, mime: "audio/wav", profile: "ivy")
        guard case .failure(let failure) = refused else { Issue.record("a 503 must be a failure"); return }
        #expect(failure.reason == "No speech-to-text provider is configured.")
        #expect(failure.detail?.hasPrefix("HTTP 503") == true)
        // Bad data never crashes and never reads as words.
        try await control(["transcribeFail": NSNull(), "transcribeRaw": ["status": 200, "body": "<html>not json</html>"]])
        let garbled = await VoiceGateway.transcribe(client: client, file: take, mime: "audio/wav", profile: "ivy")
        guard case .failure(let odd) = garbled else { Issue.record("a non-JSON answer must be a failure"); return }
        #expect(odd.reason == "Your gateway’s answer wasn’t understood.")
        state = try await ledger()
        #expect(state["transcribes"]?.array?.count == 4)
        #expect(state["forbidden"]?.array?.isEmpty == true)
    }

    // MARK: Text to speech

    @Test func aClipIsFetchedAndAnUnplayableKindIsNamed() async throws {
        try await control(["reset": true])
        let client = try await signIn()
        defer { finish(client) }
        let clip = try await VoiceGateway.speak(client: client, text: "Good morning.", profile: "ivy")
        #expect(clip.mime == "audio/wav")
        #expect(clip.data.prefix(4) == Data("RIFF".utf8))
        let said = try #require(try await ledger()["speaks"]?.array?.first)
        #expect(said["text"]?.string == "Good morning.")
        #expect(said["profile"]?.string == "ivy")
        #expect(said["keys"]?.array?.compactMap(\.string) == ["text"])
        try await control(["speakMime": "audio/ogg"])
        do {
            _ = try await VoiceGateway.speak(client: client, text: "Good morning.", profile: "ivy")
            Issue.record("Ogg cannot be played and must throw")
        } catch let failure as VoiceFailure {
            #expect(failure.detail == "unplayable")
            #expect(failure.reason == VoiceWire.unplayable("audio/ogg"))
        }
        try await control(["speakMime": NSNull(), "speakFail": ["status": 502, "detail": "The voice provider is out of credits."]])
        do {
            _ = try await VoiceGateway.speak(client: client, text: "Good morning.", profile: "ivy")
            Issue.record("a 502 must throw")
        } catch let failure as VoiceFailure {
            #expect(failure.reason == "The voice provider is out of credits.")
        }
    }

    // MARK: Bad data (stress plan S-D1 and S-D2)

    @Test func badTranscriptionAnswersAreFailuresInWordsOrNothingHeard() async throws {
        try await control(["reset": true])
        let client = try await signIn()
        defer { finish(client) }
        let take = try TalkFixture.take()
        defer { try? FileManager.default.removeItem(at: take) }
        func heard(_ body: String) async throws -> Result<String, VoiceFailure> {
            try await control(["transcribeRaw": ["status": 200, "body": body]])
            return await VoiceGateway.transcribe(client: client, file: take, mime: "audio/wav", profile: "ivy")
        }
        func json(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
        // Not an object: a failure in words, with the start of what came as the detail.
        for body in ["[1, 2, 3]", "\"just words\"", "", "null", "{\"transcript\": "] {
            guard case .failure(let failure) = try await heard(body) else { Issue.record("\(body) must be a failure"); continue }
            #expect(failure.reason == "Your gateway’s answer wasn’t understood.", "\(body)")
        }
        // ok: false, with and without a reason.
        guard case .failure(let bare) = try await heard(json(["ok": false])) else { Issue.record("ok false must fail"); return }
        #expect(bare.reason == "The gateway could not transcribe that.")
        guard case .failure(let said) = try await heard(json(["ok": false, "error": "The model is busy."])) else { Issue.record("ok false must fail"); return }
        #expect(said.reason == "The model is busy.")
        // No transcript, a transcript that is not text, only spaces: nothing was heard.
        #expect(try await heard(json(["ok": true])) == .success(""))
        #expect(try await heard(json(["ok": true, "transcript": 123])) == .success(""))
        #expect(try await heard(json(["ok": true, "transcript": "  \n\t  "])) == .success(""))
        // Long text comes whole; emoji and right-to-left text come as they are.
        let long = Array(repeating: "word", count: 4_000).joined(separator: " ")
        #expect(long.count >= 19_999)
        #expect(try await heard(json(["ok": true, "transcript": long])) == .success(long))
        let mixed = "مرحبا 👋🏽 שלום — ok"
        #expect(try await heard(json(["ok": true, "transcript": mixed])) == .success(mixed))
        // The stop words: a bare one ends a conversation, a sentence that starts with it is sent.
        #expect(TalkStopWord.isStop("Stop.") && !TalkStopWord.isStop("stop the deploy"))
        #expect(try await ledger()["forbidden"]?.array?.isEmpty == true)
    }

    @Test func badSpeechAnswersAreFailuresInWords() async throws {
        try await control(["reset": true])
        let client = try await signIn()
        defer { finish(client) }
        func spoken(_ body: String) async throws -> Result<SpeechClip, VoiceFailure> {
            try await control(["speakRaw": ["status": 200, "body": body]])
            do { return .success(try await VoiceGateway.speak(client: client, text: "Good morning.", profile: "ivy")) }
            catch let failure as VoiceFailure { return .failure(failure) }
        }
        func reason(_ result: Result<SpeechClip, VoiceFailure>) -> String? { if case .failure(let failure) = result { failure.reason } else { nil } }
        #expect(reason(try await spoken("<html>")) == "Your gateway’s answer wasn’t understood.")
        #expect(reason(try await spoken("{\"ok\": true}")) == "Your gateway sent no audio.")
        #expect(reason(try await spoken("{\"ok\": true, \"data_url\": \"data:audio/wav;base64,!!!!\", \"mime_type\": \"audio/wav\"}")) == "Your gateway sent no audio.",
                "bad base64")
        #expect(reason(try await spoken("{\"ok\": true, \"data_url\": \"data:audio/wav;base64,\", \"mime_type\": \"audio/wav\"}")) == "Your gateway sent no audio.",
                "an empty clip")
        #expect(reason(try await spoken("{\"ok\": true, \"data_url\": \"https://example.invalid/a.wav\"}")) == "Your gateway sent no audio.", "a link is not a clip")
        #expect(reason(try await spoken("{\"ok\": false, \"detail\": \"No voice is set up.\"}")) == "No voice is set up.")
        // The kind missing from the answer is read from the clip's own header.
        let clip = Data("RIFFxxxxWAVEfmt ".utf8).base64EncodedString()
        guard case .success(let made) = try await spoken("{\"ok\": true, \"data_url\": \"data:audio/wav;base64,\(clip)\"}") else {
            Issue.record("a clip without mime_type is still a clip"); return
        }
        #expect(made.mime == "audio/wav" && made.data.prefix(4) == Data("RIFF".utf8))
        // A kind this phone cannot play is named.
        let ogg = try await spoken("{\"ok\": true, \"data_url\": \"data:audio/ogg;base64,\(clip)\"}")
        #expect(reason(ogg) == VoiceWire.unplayable("audio/ogg"))
    }

    private func speaker() -> (TalkSpeaker, FixtureSpeechOutput) {
        let output = FixtureSpeechOutput()
        output.clipSeconds = 0.2
        return (TalkSpeaker(output: output), output)
    }

    @Test func aReplyIsStreamedAsItArrives() async throws {
        try await control(["reset": true])
        try await control(["streamPace": 0.05])
        let client = try await signIn()
        defer { finish(client) }
        let (speaker, output) = speaker()
        var started = 0
        let session = speaker.open(messageId: "m1", profile: "ivy", client: client, owner: .conversation, host: nil)
        session.onStarted = { started += 1 }
        #expect(speaker.state == .preparing("m1"))
        session.append("Here is **the plan**.")
        session.append("Here is **the plan**. It has `two` steps.")
        #expect(await waitUntil(timeout: .seconds(6)) { speaker.state == .speaking("m1") })
        session.finish()
        #expect(await session.outcome == .done)
        #expect(started == 1)
        #expect(speaker.state == .idle)
        #expect(speaker.owner == nil)
        #expect(output.begun == 1)
        #expect(output.lastFormat?.rate == 24_000)
        #expect(output.lastFormat?.channels == 1)
        #expect(output.scheduledBytes > 0)
        #expect(output.clips == 0)
        let state = try await ledger()
        let stream = try #require(state["streams"]?.array?.first)
        #expect(state["streams"]?.array?.count == 1)
        #expect(stream["profile"]?.string == "ivy")
        #expect(stream["done"]?.bool == true)
        #expect(stream["stopped"]?.bool == false)
        // The gateway is given the reply as written, every character once (it cleans each sentence itself, as the
        // real one does): the Markdown never reaches the voice, and nothing is said twice.
        let texts = stream["texts"]?.array?.compactMap(\.string) ?? []
        #expect(texts.joined() == "Here is **the plan**. It has `two` steps.")
        let whole = stream["spoken"]?.string ?? ""
        #expect(whole == "Here is the plan. It has two steps.")
        #expect(whole.components(separatedBy: "Here is").count == 2)
        #expect(stream["bytes"]?.int == output.scheduledBytes)
        #expect(state["speaks"]?.array?.isEmpty == true)
        #expect(state["forbidden"]?.array?.isEmpty == true)
    }

    @Test func markdownThatArrivesInPiecesLosesNoLetters() async throws {
        let reply = TalkSpeechFeedTests.reply
        for (mode, step) in [("ok", 5), ("fallback", 5)] {
            try await control(["reset": true])
            try await control(["streamMode": mode, "streamPace": 0])
            let client = try await signIn()
            let (speaker, output) = speaker()
            let session = speaker.open(messageId: "m1", profile: "ivy", client: client, owner: .conversation, host: nil)
            let prefixes = TalkSpeechFeedTests.growing(reply, step: step)
            session.append(prefixes[0])
            // The socket is up and the first piece went out before the rest is written.
            #expect(await waitUntilAsync(timeout: .seconds(15)) { (try? await ledger()["streams"]?[0]?["texts"]?.array?.isEmpty) == false })
            for prefix in prefixes.dropFirst() {
                session.append(prefix)
                try await Task.sleep(for: .milliseconds(30))      // several feed ticks pass while it is written
            }
            session.finish()
            #expect(await session.outcome == .done, "mode \(mode)")
            let state = try await ledger()
            let expected = TalkSpeechFeedTests.words(SpeechText.sanitizeForSpeech(reply))
            if mode == "ok" {
                let stream = try #require(state["streams"]?.array?.first)
                let texts = stream["texts"]?.array?.compactMap(\.string) ?? []
                #expect(texts.count > 3, "the reply went out in pieces: \(texts.count)")
                #expect(texts.joined() == reply)
                let spoken = stream["spoken"]?.string ?? ""
                #expect(spoken.contains("Run npm install to start the server."))
                #expect(spoken.contains("You can read the docs for more detail."))
                #expect(spoken.contains("That lists every file. Done and dusted, with one more span to finish it."))
                #expect(!spoken.contains("`") && !spoken.contains("[") && !spoken.contains("https"))
                #expect(output.scheduledBytes > 0 && output.clips == 0)
            } else {
                // Each clip is asked for while the one before it plays, so two may reach the gateway in either order.
                let spoken = (state["speaks"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: " ")
                #expect(TalkSpeechFeedTests.words(spoken).sorted() == expected.sorted(), "clips: \(spoken)")
                #expect(!spoken.contains("`") && !spoken.contains("[") && !spoken.contains("https") && !spoken.contains("ls -la"), "clips: \(spoken)")
                #expect(output.clips >= 2)
            }
            finish(client)
        }
    }

    @Test func aQuietGatewayMidTurnIsNotTheEndOfTheReply() async throws {
        // "Let me check." is spoken, a tool runs for longer than the stall guard, then the answer comes.
        try await control(["reset": true])
        let quiet = VoiceWire.stallTimeout + 2
        try await control(["streamPace": 0, "streamScript": [["json": ["type": "start", "sample_rate": 24_000, "channels": 1]], ["toneMs": 300],
                                                            ["wait": quiet], ["toneMs": 400], ["json": ["type": "end"]]]])
        let client = try await signIn()
        defer { finish(client) }
        let (speaker, output) = speaker()
        let session = speaker.open(messageId: "m1", profile: "ivy", client: client, owner: .conversation, host: nil)
        session.append("Let me check. ")
        #expect(await waitUntil(timeout: .seconds(6)) { output.scheduledBytes == 14_400 })
        try await Task.sleep(for: .seconds(quiet - 1))
        // Nothing for 16 s and nothing left to play: the session is still open, because the reply is not complete.
        #expect(speaker.owner == .conversation)
        #expect(speaker.state == .speaking("m1"))
        session.append("Let me check. The answer is forty-two.")
        #expect(await waitUntil(timeout: .seconds(8)) { output.scheduledBytes == 14_400 + 19_200 })
        session.finish()
        #expect(await session.outcome == .done)
        #expect(output.scheduledBytes == 33_600, "the second part was scheduled")
        let stream = try #require(try await ledger()["streams"]?.array?.first)
        #expect(stream["texts"]?.array?.compactMap(\.string).joined() == "Let me check. The answer is forty-two.")
    }

    @Test func framesThatSplitASampleAreJoinedNotShifted() async throws {
        // S-D3: the gateway forwards its provider's chunks as they come. Frames of 1001 bytes split every other sample.
        for channels in [1, 2] {
            try await control(["reset": true])
            try await control(["streamPace": 0, "streamChannels": channels,
                               "streamScript": [["bytes": 5], ["json": ["type": "start", "sample_rate": 24_000, "channels": channels]],
                                                ["toneMs": 200, "frameBytes": 1_001], ["json": ["type": "surprise"]],
                                                ["json": ["type": "start", "sample_rate": 8_000, "channels": 1]], ["json": ["type": "end"]]]])
            let client = try await signIn()
            let (speaker, output) = speaker()
            let session = speaker.open(messageId: "m1", profile: "ivy", client: client, owner: .conversation, host: nil)
            session.append("A tone.")
            session.finish()
            #expect(await session.outcome == .done)
            var tone = Data()
            for index in 0..<4_800 {
                let sample = Int16(7_000 * sin(2 * Double.pi * 440 * Double(index) / 24_000))
                for _ in 0..<channels { withUnsafeBytes(of: sample.littleEndian) { tone.append(contentsOf: $0) } }
            }
            #expect(output.scheduled.count == tone.count, "\(channels) channel(s): \(output.scheduled.count)")
            #expect(output.scheduled == tone, "\(channels) channel(s): every sample is where the gateway put it")
            #expect(output.begun == 1)                      // binary before `start` and a second `start` change nothing
            #expect(output.lastFormat?.channels == channels)
            finish(client)
        }
    }

    @Test func aStreamThatNeverEndsIsEndedAfterTheReplyIsComplete() async throws {
        // S-D3: audio, then no `end` ever. Once `done` was sent and the audio played out, the stall guard ends it.
        try await control(["reset": true])
        try await control(["streamPace": 0, "streamScript": [["json": ["type": "start", "sample_rate": 24_000, "channels": 1]], ["toneMs": 200]]])
        let client = try await signIn()
        defer { finish(client) }
        let (speaker, output) = speaker()
        let session = speaker.open(messageId: "m1", profile: "ivy", client: client, owner: .conversation, host: nil)
        session.append("No end.")
        session.finish()
        let began = Date()
        #expect(await session.outcome == .done)
        let took = Date().timeIntervalSince(began)
        #expect(took >= VoiceWire.stallTimeout - 1 && took < VoiceWire.stallTimeout + 8, "ended after \(took) s")
        #expect(output.scheduledBytes == 9_600)
    }

    /// Tester, 2026-11-08 (avoiding cloud services): a provider that makes nothing without failing sends `start`
    /// and `end` with no audio between. The reply is read by the iPhone's voice instead of ending in silence, and later
    /// replies start there.
    @Test func aStreamThatEndsWithoutASoundIsReadByTheIPhone() async throws {
        try await control(["reset": true])
        try await control(["streamPace": 0, "streamScript": [["json": ["type": "start", "sample_rate": 24_000, "channels": 1]],
                                                            ["json": ["type": "end"]]]])
        let client = try await signIn()
        defer { finish(client) }
        let (speaker, output) = speaker()
        let memory = PhoneVoiceFallback()
        speaker.fallback = memory
        speaker.choice = { .computer }
        var renderers: [FixturePhoneSpeechRenderer] = []
        speaker.makePhoneRenderer = {
            let made = FixturePhoneSpeechRenderer()
            made.msPerCharacter = 1
            renderers.append(made)
            return made
        }
        let session = speaker.open(messageId: "m1", profile: "ivy", client: client, owner: .conversation, host: nil)
        session.append("Nothing came back from the provider. Read it here.")
        session.finish()
        #expect(await session.outcome == .done)
        #expect(renderers.flatMap(\.spoken) == ["Nothing came back from the provider.", "Read it here."])
        #expect(output.scheduledBytes > 0)
        #expect(memory.isFailing(PhoneVoiceFallback.key(account: client.account.id, profile: "ivy")))
    }

    @Test func speechToTextTurnedOnIsSeenAtOnce() async throws {
        try await control(["reset": true])
        try await control(["voiceConfig": ["stt": ["enabled": false]]])
        let client = try await signIn()
        defer { finish(client) }
        #expect(await VoiceGateway.config(client: client, profile: "ivy").sttEnabled == false)
        // Turned on from somewhere else (the gateway's own dashboard): "off" is never answered from memory.
        try await control(["voiceConfig": ["stt": ["enabled": true]]])
        #expect(await VoiceGateway.config(client: client, profile: "ivy").sttEnabled)
        // A save in Settings forgets what was kept: the new silence time is read on the next Talk.
        let before = await VoiceGateway.config(client: client, profile: "ivy")
        #expect(VoiceGateway.knownConfig(client: client, profile: "ivy") == before)
        try await GatewaySettingsAPI(client: client).saveConfig(["voice": ["silence_duration": 2]])
        #expect(VoiceGateway.knownConfig(client: client, profile: "ivy") == nil)
        #expect(await VoiceGateway.config(client: client, profile: "ivy").silenceMs == 2_000)
    }

    @Test func aGatewayThatCannotStreamFallsBackToClips() async throws {
        for mode in ["fallback", "refuse"] {
            try await control(["reset": true])
            try await control(["streamMode": mode])
            let client = try await signIn()
            let (speaker, output) = speaker()
            let session = speaker.open(messageId: "m1", profile: "ivy", client: client, owner: .conversation, host: nil)
            session.append("First sentence. Second sentence.")
            session.finish()
            #expect(await session.outcome == .done, "mode \(mode)")
            #expect(output.clips >= 1, "mode \(mode)")
            #expect(output.scheduledBytes == 0, "mode \(mode)")
            let state = try await ledger()
            let spoken = (state["speaks"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: " ")
            #expect(spoken.contains("First sentence.") && spoken.contains("Second sentence."), "mode \(mode): \(spoken)")
            #expect(state["streams"]?.array?.count == 1, "mode \(mode)")
            finish(client)
        }
    }

    @Test func aStreamThatDiesMidReplySaysSoAndStops() async throws {
        try await control(["reset": true])
        try await control(["streamMode": "drop", "streamDropAfterMs": 200, "streamPace": 0.2])
        let client = try await signIn()
        defer { finish(client) }
        let (speaker, output) = speaker()
        let session = speaker.open(messageId: "m1", profile: "ivy", client: client, owner: .conversation, host: nil)
        session.append("A long reply that will not be finished because the socket goes away in the middle of it.")
        session.finish()
        let outcome = await session.outcome
        guard case .failed(_, let fatal) = outcome else { Issue.record("a dropped stream must fail, got \(outcome)"); return }
        #expect(!fatal)
        #expect(output.scheduledBytes > 0)
        #expect(speaker.state == .idle)
    }

    @Test func stopClosesTheStreamAtOnce() async throws {
        try await control(["reset": true])
        let client = try await signIn()
        defer { finish(client) }
        let (speaker, output) = speaker()
        let session = speaker.open(messageId: "m1", profile: "ivy", client: client, owner: .conversation, host: nil)
        session.append("A reply long enough to still be playing when the person interrupts it, with a few more words to be sure.")
        #expect(await waitUntil(timeout: .seconds(6)) { speaker.state == .speaking("m1") })
        speaker.stop()
        #expect(await session.outcome == .stopped)
        #expect(speaker.state == .idle)
        #expect(output.stops >= 1)
        #expect(output.pending == 0)
        #expect(await waitUntilAsync(timeout: .seconds(4)) { (try? await ledger()["streams"]?[0]?["stopped"]?.bool) == true })
        // A new reply replaces one still being spoken: never two streams at once.
        let first = speaker.open(messageId: "m2", profile: "ivy", client: client, owner: .readAloud, host: nil)
        first.append("One more reply that keeps the stream open for a while longer than the test needs.")
        #expect(await waitUntil(timeout: .seconds(6)) { speaker.state == .speaking("m2") })
        let second = speaker.open(messageId: "m3", profile: "ivy", client: client, owner: .readAloud, host: nil)
        #expect(await first.outcome == .stopped)
        second.append("Short.")
        second.finish()
        #expect(await second.outcome == .done)
        #expect(AudioSessionCoordinator.shared.owner == nil)
    }

    // MARK: Leases

    @Test func leasesAreHeldAndReleasedByName() async throws {
        try await control(["reset": true])
        let client = try await signIn()
        defer { finish(client) }
        let name = VoiceWire.leaseName(.conversation, installId: VoiceWire.installId())
        #expect(name.hasPrefix("hqnative:conversation:"))
        VoiceGateway.lease(client: client, kind: .tts, lease: .conversation, active: true, profile: "ivy")
        VoiceGateway.lease(client: client, kind: .stt, lease: .conversation, active: true, profile: "ivy")
        #expect(await waitUntilAsync(timeout: .seconds(5)) {
            let state = try? await ledger()
            return state?["leases"]?["tts"]?.array?.compactMap(\.string) == [name] && state?["leases"]?["stt"]?.array?.compactMap(\.string) == [name]
        })
        VoiceGateway.lease(client: client, kind: .tts, lease: .conversation, active: false, profile: "ivy")
        VoiceGateway.lease(client: client, kind: .stt, lease: .conversation, active: false, profile: "ivy")
        #expect(await waitUntilAsync(timeout: .seconds(5)) {
            let state = try? await ledger()
            return state?["leases"]?["tts"]?.array?.isEmpty == true && state?["leases"]?["stt"]?.array?.isEmpty == true
        })
        let calls = try await ledger()["leaseCalls"]?.array ?? []
        #expect(calls.count == 4)
        #expect(calls.allSatisfy { $0["keys"]?.array?.compactMap(\.string).sorted() == ["active", "lease"] })
        // The bot's own voice is warmed, not the gateway's default one.
        #expect(calls.allSatisfy { $0["profile"]?.string == "ivy" })
        // A quick hold then release (Talk, then End at once) reaches the gateway in that order, every time.
        for _ in 0..<12 {
            VoiceGateway.lease(client: client, kind: .tts, lease: .readAloud, active: true, profile: "ivy")
            VoiceGateway.lease(client: client, kind: .tts, lease: .readAloud, active: false, profile: "ivy")
        }
        #expect(await waitUntilAsync(timeout: .seconds(10)) { (try? await ledger()["leaseCalls"]?.array?.count) == 28 })
        let order = (try await ledger()["leaseCalls"]?.array ?? []).dropFirst(4).compactMap { $0["active"]?.bool }
        #expect(order == (0..<12).flatMap { _ in [true, false] })
        #expect(try await ledger()["leases"]?["tts"]?.array?.isEmpty == true)
        // A gateway that refuses leases never gets in the way.
        try await control(["leaseFail": true])
        VoiceGateway.lease(client: client, kind: .tts, lease: .readAloud, active: true)
        #expect(await waitUntilAsync(timeout: .seconds(5)) { (try? await ledger()["leaseCalls"]?.array?.count) == 29 })
    }

    // MARK: A whole conversation

    @Test func aConversationRunsOverTheRealChatAndTheRealWire() async throws {
        try await control(["reset": true])
        try await control(["transcripts": ["What is the plan", "Stop"], "streamPace": 0.05])
        let client = try await signIn()
        defer { finish(client) }
        let chat = await session(client)
        AudioSessionCoordinator.shared.reset()
        KeepAwake.reset()
        FixtureTalkCapture.script = TalkFixtureStep.parse("say:0.5;say:0.5")
        FixtureTalkCapture.permission = "granted"
        FixtureTalkCapture.startDelay = 0.02
        let (speaker, output) = speaker()
        let talk = TalkController()
        talk.makeCapture = { FixtureTalkCapture(clock: $0) }
        talk.speaker = speaker
        talk.isOnScreen = { true }
        talk.speaksReplies = { true }
        talk.setFront(chat, onScreen: true)
        let before = chat.messages.count
        talk.start(in: chat, name: "Ivy")
        #expect(chat.voiceHold)
        // Heard, transcribed by the gateway, sent as an ordinary message that shows in the chat.
        #expect(await waitUntil(timeout: .seconds(12)) { chat.messages.count > before && chat.messages.contains { $0.plainText == "What is the plan" } })
        // The reply is spoken over the stream, then the microphone listens again; the second take says a stop phrase.
        let ended = await waitUntil(timeout: .seconds(30)) { !talk.isLive }
        #expect(ended, "state: \(String(describing: talk.debugState)) running: \(chat.isRunning) reply: \(String(describing: chat.newestReply)) events: \(VoiceEvents.all.suffix(12).map(\.text))")
        #expect(talk.endedCaption(for: chat.memoScope)?.hasPrefix("Voice chat ended · ") == true)
        #expect(output.scheduledBytes > 0)
        #expect(!chat.voiceHold)
        #expect(!KeepAwake.isHeld(.conversation))
        await talk.resetForTests()
        try await Task.sleep(for: .milliseconds(600))
        let state = try await ledger()
        let prompts = state["prompts"]?.array ?? []
        #expect(prompts.count == 1)                                   // "Stop" ended it and was never sent
        #expect(prompts.first?["text"]?.string == "What is the plan")
        #expect(prompts.first?["interrupted"]?.bool != true)
        #expect(prompts.first?["refused"]?.bool == false)
        #expect(state["transcribes"]?.array?.count == 2)
        #expect(state["streams"]?.array?.count == 1)
        #expect(state["streams"]?[0]?["done"]?.bool == true)
        // Both leases were held for the conversation and are released.
        #expect((state["leaseCalls"]?.array ?? []).count == 4)
        #expect(state["leases"]?["tts"]?.array?.isEmpty == true)
        #expect(state["leases"]?["stt"]?.array?.isEmpty == true)
        #expect(state["forbidden"]?.array?.isEmpty == true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: TalkCaptureCore.takesFolder.path)) ?? []).isEmpty)
    }

    @Test func talkingOverTheReplyMarksTheNextPromptInterrupted() async throws {
        try await control(["reset": true])
        try await control(["transcripts": ["Tell me a long story", "Tell me something else"], "streamPace": 1])
        let client = try await signIn()
        defer { finish(client) }
        let chat = await session(client)
        AudioSessionCoordinator.shared.reset()
        KeepAwake.reset()
        FixtureTalkCapture.script = TalkFixtureStep.parse("say:0.5;barge-speaking:0.6;hold")
        FixtureTalkCapture.permission = "granted"
        FixtureTalkCapture.startDelay = 0.02
        let (speaker, _) = speaker()
        let talk = TalkController()
        talk.makeCapture = { FixtureTalkCapture(clock: $0) }
        talk.speaker = speaker
        talk.isOnScreen = { true }
        talk.speaksReplies = { true }
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntilAsync(timeout: .seconds(30)) { (try? await ledger()["prompts"]?.array?.count) == 2 })
        let prompts = try await ledger()["prompts"]?.array ?? []
        #expect(prompts.first?["interrupted"]?.bool != true)
        #expect(prompts.last?["text"]?.string == "Tell me something else")
        #expect(prompts.last?["interrupted"]?.bool == true)
        #expect(prompts.last?["refused"]?.bool == false)
        // The reply that was cut off stopped being spoken.
        let streams = try await ledger()["streams"]?.array ?? []
        #expect(streams.first?["stopped"]?.bool == true || streams.first?["closedBy"]?.string == "client")
        talk.end()
        await talk.resetForTests()
    }
}
