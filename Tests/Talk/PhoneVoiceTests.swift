// Reading aloud always works (docs/spec/3x-talk.md §7.7): when the computer's voice fails the iPhone's reads the reply
// from where it failed; the failure is remembered per gateway and profile for a while, then the computer is asked
// again; "iPhone Voice" chosen in Settings never asks the computer; the notice is shown once; the log is scrubbed.
// No audio device and no synthesizer: the speaker is the stand-in output and the iPhone's voice the stand-in renderer.

import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@Suite("iPhone voice", .serialized)
@MainActor
struct PhoneVoiceTests {
    /// What Hermes answered on the owner's phone (build 305) for a profile with no `tts:` section: Edge, refused.
    nonisolated static let edgeRefusal = "TTS chunk 1 failed (edge): TTS generation failed (edge): 403, message='Invalid response status', "
        + "url='wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4&ConnectionId=a1b2c3'"

    nonisolated final class Clock: @unchecked Sendable {
        private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        var now: Date { value.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
    }

    struct Rig {
        let speaker: TalkSpeaker
        let output: FixtureSpeechOutput
        let renderers: Renderers
        let memory: PhoneVoiceFallback
        let clock: Clock
    }

    @MainActor final class Renderers {
        var made: [FixturePhoneSpeechRenderer] = []
        var spoken: [String] { made.flatMap(\.spoken) }
    }

    private func rig(choice: PhoneVoiceChoice = .computer) -> Rig {
        let output = FixtureSpeechOutput()
        output.clipSeconds = 0.05
        let speaker = TalkSpeaker(output: output)
        let renderers = Renderers()
        speaker.makePhoneRenderer = {
            let made = FixturePhoneSpeechRenderer()
            made.msPerCharacter = 1
            renderers.made.append(made)
            return made
        }
        let clock = Clock()
        let memory = PhoneVoiceFallback(now: { clock.now })
        speaker.fallback = memory
        speaker.choice = { choice }
        return Rig(speaker: speaker, output: output, renderers: renderers, memory: memory, clock: clock)
    }

    /// A gateway whose clip route answers `speak` for each sentence (nil: the 500 Hermes answers when its provider fails).
    private func gateway(_ speak: @escaping @Sendable (String) -> String? = { _ in nil }) -> VoiceFakeClient {
        let client = VoiceFakeClient()
        client.onRest { method, path, body in
            guard method == "POST", path == "/api/audio/speak" else { return Data("{}".utf8) }
            let sentence = (try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: String])?["text"] ?? ""
            guard let answer = speak(sentence) else {
                throw HTTPError(status: 500, body: ChatJSON.stringify(["detail": .string(PhoneVoiceTests.edgeRefusal)]))
            }
            return Data(answer.utf8)
        }
        return client
    }

    /// A short WAV the stand-in output times from its header.
    nonisolated static let wavAnswer: String = {
        var wav = Data("RIFF".utf8)
        func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
        func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
        let pcm = Data(count: 1_600)
        wav += le32(36 + pcm.count) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(16_000) + le32(32_000) + le16(2) + le16(16)
        wav += Data("data".utf8) + le32(pcm.count) + pcm
        return "{\"ok\": true, \"data_url\": \"data:audio/wav;base64,\(wav.base64EncodedString())\", \"mime_type\": \"audio/wav\"}"
    }()

    private func read(_ rig: Rig, _ text: String, client: any GatewayClient, profile: String? = "inbox") async -> SpeechOutcome {
        let session = rig.speaker.open(messageId: "m\(rig.speaker.opened + 1)", profile: profile, client: client, owner: .conversation, host: nil)
        session.append(text)
        session.finish()
        return await session.outcome
    }

    nonisolated final class Seen: @unchecked Sendable {
        private let value = Mutex<[[String: String]]>([])
        var all: [[String: String]] { value.withLock { $0 } }
        func add(_ info: [String: String]) { value.withLock { $0.append(info) } }
    }

    private func watchNotices() -> (Seen, any NSObjectProtocol) {
        let seen = Seen()
        let token = NotificationCenter.default.addObserver(forName: PhoneVoiceFallback.started, object: nil, queue: nil) { note in
            seen.add((note.userInfo as? [String: String]) ?? [:])
        }
        return (seen, token)
    }

    // MARK: Fallback

    @Test func aBrokenComputerVoiceIsReadByTheIPhoneInstead() async {
        let rig = rig()
        let client = gateway()
        let (seen, token) = watchNotices()
        defer { NotificationCenter.default.removeObserver(token) }
        VoiceEvents.clear()
        var started = 0
        let session = rig.speaker.open(messageId: "m1", profile: "inbox", client: client, owner: .conversation, host: nil)
        session.onStarted = { started += 1 }
        session.append("Here is **the plan** for the week. It has two steps, both short.")
        session.finish()
        // Not an error: the reply is read to its end.
        #expect(await session.outcome == .done)
        #expect(started == 1)
        #expect(rig.renderers.spoken == ["Here is the plan for the week.", "It has two steps, both short."])
        #expect(rig.output.scheduledBytes > 0)
        #expect(rig.output.clips == 0)
        #expect(rig.speaker.phoneSessions == 1)
        #expect(rig.speaker.state == .idle)
        // The computer was asked first.
        #expect(client.entries("POST /api/audio/speak").count >= 1)
        // The person is told (the chat on screen claims it once); the notice names the gateway and profile.
        #expect(seen.all.count == 1)
        #expect(seen.all.first?["profile"] == "inbox")
        #expect(seen.all.first?["account"] == client.account.id)
        // The log has the computer's failure, scrubbed: no address, no token.
        let log = VoiceEvents.all.map(\.text).joined(separator: "\n")
        #expect(log.contains("computer voice failed: TTS chunk 1 failed (edge)"), "\(log)")
        #expect(log.contains("403"))
        #expect(!log.contains("bing.com") && !log.contains("TrustedClientToken") && !log.contains("6A5AA1D4"), "\(log)")
        #expect(log.contains("reading with the iPhone voice"))
    }

    @Test func theIPhoneVoiceStartsWhereTheComputerStopped() async {
        let rig = rig()
        // The first sentence is spoken by the computer; the second fails.
        let client = gateway { $0.hasPrefix("One") ? PhoneVoiceTests.wavAnswer : nil }
        let outcome = await read(rig, "One sentence is fine here. Two is where it all breaks. Three follows after that.", client: client)
        #expect(outcome == .done)
        #expect(rig.output.clips == 1)
        #expect(rig.renderers.spoken == ["Two is where it all breaks.", "Three follows after that."])
    }

    @Test func aComputerThatNeverAnswersIsNotWaitedOnForeverButIsAskedAgain() async {
        let rig = rig()
        rig.speaker.phoneVoiceAfter = 0.4
        let client = gateway { _ in PhoneVoiceTests.wavAnswer }
        client.delay("POST /api/audio/speak", .seconds(30))
        let began = Date()
        let outcome = await read(rig, "Slow voice here.", client: client)
        #expect(outcome == .done)
        #expect(Date().timeIntervalSince(began) < 5)
        #expect(rig.renderers.spoken == ["Slow voice here."])
        // Slow is not broken: the next reply asks the computer first again.
        #expect(!rig.memory.isFailing(PhoneVoiceFallback.key(account: client.account.id, profile: "inbox")))
        #expect(VoiceWire.phoneVoiceAfter == 20)
        #expect(ReadAloudCenter.answerTimeout > VoiceWire.phoneVoiceAfter)
    }

    @Test func whenTheIPhoneVoiceFailsTooTheComputersReasonIsSaid() async {
        let rig = rig()
        rig.speaker.makePhoneRenderer = {
            let made = FixturePhoneSpeechRenderer()
            made.fails = true
            return made
        }
        let outcome = await read(rig, "Nothing works.", client: gateway())
        guard case .failed(let reason, _) = outcome else { Issue.record("expected a failure, got \(outcome)"); return }
        #expect(reason.hasPrefix("TTS chunk 1 failed (edge)"))
    }

    // MARK: Remembered, then asked again

    @Test func aFailureIsRememberedPerGatewayAndProfileThenTheComputerIsAskedAgain() async {
        let rig = rig()
        let client = gateway()
        #expect(await read(rig, "First reply.", client: client) == .done)
        #expect(rig.speaker.gatewayTries == 1)
        let asked = client.entries("POST /api/audio/speak").count
        #expect(asked >= 1)
        // The next reply goes straight to the iPhone's voice: no failing round trip.
        #expect(await read(rig, "Second reply.", client: client) == .done)
        #expect(rig.speaker.gatewayTries == 1)
        #expect(client.entries("POST /api/audio/speak").count == asked)
        #expect(rig.renderers.spoken.suffix(1) == ["Second reply."])
        // Another bot on the same gateway still asks its own voice.
        #expect(await read(rig, "Other bot.", client: client, profile: "ivy") == .done)
        #expect(rig.speaker.gatewayTries == 2)
        // Half an hour later the computer is asked again.
        rig.clock.advance(PhoneVoiceFallback.lifetime + 1)
        #expect(await read(rig, "Later reply.", client: client) == .done)
        #expect(rig.speaker.gatewayTries == 3)
    }

    @Test func savingVoiceSettingsAsksTheComputerAgainAtOnce() async {
        let rig = rig()
        let client = gateway()
        #expect(await read(rig, "First reply.", client: client) == .done)
        let key = PhoneVoiceFallback.key(account: client.account.id, profile: "inbox")
        #expect(rig.memory.isFailing(key))
        rig.memory.forget()
        #expect(!rig.memory.isFailing(key))
        // The shared memory is what a settings save clears.
        PhoneVoiceFallback.shared.remember(key)
        VoiceGateway.forgetConfig()
        #expect(!PhoneVoiceFallback.shared.isFailing(key))
    }

    @Test func aWorkingComputerVoiceIsNeverReplaced() async {
        let rig = rig()
        let client = gateway { _ in PhoneVoiceTests.wavAnswer }
        #expect(await read(rig, "All good with this voice. Still good after that.", client: client) == .done)
        #expect(rig.output.clips == 2)
        #expect(rig.renderers.spoken.isEmpty)
        #expect(rig.speaker.phoneSessions == 0)
        #expect(!rig.memory.isFailing(PhoneVoiceFallback.key(account: client.account.id, profile: "inbox")))
    }

    // MARK: Chosen

    @Test func iPhoneVoiceChosenNeverAsksTheComputerAndSaysNothing() async {
        let rig = rig(choice: .phone)
        let client = gateway { _ in PhoneVoiceTests.wavAnswer }
        let (seen, token) = watchNotices()
        defer { NotificationCenter.default.removeObserver(token) }
        #expect(await read(rig, "Read on the phone.", client: client) == .done)
        #expect(rig.renderers.spoken == ["Read on the phone."])
        #expect(client.log.isEmpty)
        #expect(rig.speaker.gatewayTries == 0)
        #expect(seen.all.isEmpty)
    }

    @Test func theChoiceIsKeptOnThisDeviceOnly() {
        let defaults = UserDefaults(suiteName: "phone-voice-\(UUID().uuidString)")!
        #expect(PhoneVoiceChoice.current(defaults) == .computer)
        PhoneVoiceChoice.set(.phone, defaults: defaults)
        #expect(PhoneVoiceChoice.current(defaults) == .phone)
        #expect(defaults.string(forKey: PhoneVoiceChoice.key) == "iphone")
        defaults.set("nonsense", forKey: PhoneVoiceChoice.key)
        #expect(PhoneVoiceChoice.current(defaults) == .computer)
        #expect(PhoneVoiceChoice.computer.title == "Computer’s Voice")
        #expect(PhoneVoiceChoice.phone.title == "iPhone Voice")
        // It is not a gateway setting: the Text to Speech page's keys stay the gateway's.
        #expect(!VoiceSettingsCatalog.textToSpeechKeys.contains { $0.contains("iphone") })
    }

    // MARK: The notice

    @Test func theNoticeIsShownOncePerBot() {
        let memory = PhoneVoiceFallback()
        let inbox = PhoneVoiceFallback.key(account: "acct", profile: "inbox")
        #expect(memory.claimNotice(inbox))
        #expect(!memory.claimNotice(inbox))
        #expect(memory.claimNotice(PhoneVoiceFallback.key(account: "acct", profile: "ivy")))
        #expect(memory.claimNotice(PhoneVoiceFallback.key(account: "other", profile: "inbox")))
        // The chat on screen shows it only for its own bot.
        #expect(ChatReadAloudHost.noticeBelongs(account: "acct", profile: "inbox", chatAccount: "acct", chatProfile: "inbox"))
        #expect(!ChatReadAloudHost.noticeBelongs(account: "acct", profile: "inbox", chatAccount: "acct", chatProfile: "ivy"))
        #expect(ChatReadAloudHost.noticeBelongs(account: "acct", profile: "", chatAccount: "acct", chatProfile: ""))
    }

    @Test func theNoticeIsPlainWordsWithAFixAction() {
        let text = PhoneVoiceWords.notice(botName: "Inbox")
        #expect(text == "Inbox’s voice isn’t working, so the iPhone’s voice is reading.")
        #expect(PhoneVoiceWords.notice(botName: " ") == "Your bot’s voice isn’t working, so the iPhone’s voice is reading.")
        #expect(PhoneVoiceWords.fix == "Fix…")
        for words in [text, PhoneVoiceWords.fix, PhoneVoiceChoice.footer(), PhoneVoiceChoice.phone.title] {
            #expect(!words.lowercased().contains("dispatch") && !words.contains("GPT") && !words.lowercased().contains("wake"))
            #expect(!words.contains("edge") && !words.contains("403"))
        }
    }

    // MARK: Scrubbing

    @Test func theFailureIsScrubbedForTheLog() {
        let line = PhoneVoiceWords.logLine(VoiceFailure(reason: Self.edgeRefusal, detail: "HTTP 500\n{\"detail\": \"…\"}"))
        #expect(line.hasPrefix("speech: computer voice failed: TTS chunk 1 failed (edge)"))
        #expect(!line.contains("wss://") && !line.contains("TrustedClientToken=6A") && !line.contains("\n"))
        #expect(VoiceReport.scrub("refused ?api_key=abc123&x=1") == "refused ?api_key=(hidden)&x=1")
        #expect(VoiceReport.scrub("Authorization: Bearer abc.def-123") == "Authorization: Bearer (hidden)")
        #expect(VoiceReport.scrub("key sk-proj-abcdefgh12 bad") == "key (hidden) bad")
        #expect(VoiceReport.scrub("ticket=xyz and token=q") == "ticket=(hidden) and token=(hidden)")
        #expect(VoiceReport.scrub("speech: finished") == "speech: finished")
    }

    // MARK: Which voice

    @Test func theBestVoiceForTheRepliesLanguage() {
        let voices = [
            PhoneVoiceCandidate(identifier: "a", language: "en-US", name: "Samantha", quality: 1),
            PhoneVoiceCandidate(identifier: "b", language: "en-US", name: "Ava", quality: 3),
            PhoneVoiceCandidate(identifier: "c", language: "en-GB", name: "Daniel", quality: 3),
            PhoneVoiceCandidate(identifier: "d", language: "en-US", name: "Bubbles", quality: 3, excluded: true),
            PhoneVoiceCandidate(identifier: "e", language: "es-ES", name: "Mónica", quality: 1),
            PhoneVoiceCandidate(identifier: "f", language: "es-MX", name: "Paulina", quality: 2),
        ]
        // The best quality first, then the person's own region; novelty voices never.
        #expect(PhoneVoicePicker.pick(language: "en", candidates: voices, preferred: ["en-US"])?.identifier == "b")
        #expect(PhoneVoicePicker.pick(language: "en", candidates: voices, preferred: ["en-GB"])?.identifier == "c")
        #expect(PhoneVoicePicker.pick(language: "es", candidates: voices, preferred: ["en-US"])?.identifier == "f")
        #expect(PhoneVoicePicker.pick(language: "es", candidates: voices, preferred: ["en-US", "es-ES"])?.identifier == "f")
        // Equal quality: the person's region.
        let plain = [PhoneVoiceCandidate(identifier: "g", language: "es-ES", name: "Mónica", quality: 1),
                     PhoneVoiceCandidate(identifier: "h", language: "es-MX", name: "Paulina", quality: 1)]
        #expect(PhoneVoicePicker.pick(language: "es", candidates: plain, preferred: ["es-MX"])?.identifier == "h")
        #expect(PhoneVoicePicker.pick(language: "es", candidates: plain, preferred: ["en-US"], defaultRegion: "es-ES")?.identifier == "g")
        #expect(PhoneVoicePicker.pick(language: "fr", candidates: voices, preferred: ["en-US"]) == nil)
        // The reply's language.
        #expect(PhoneVoicePicker.language(of: "Hola, ¿cómo estás? Hoy vamos a revisar el plan de la semana juntos.", preferred: ["en-US"]) == "es")
        #expect(PhoneVoicePicker.language(of: "Ok.", preferred: ["de-DE"]) == "de")
        #expect(PhoneVoicePicker.language(of: "The meeting moved to three o’clock tomorrow afternoon.", preferred: ["fr-FR"]) == "en")
    }

    @Test func settingsSuggestsAnEnhancedVoiceOnlyWhenNoneIsInstalled() {
        let compact = [PhoneVoiceCandidate(identifier: "a", language: "en-US", name: "Samantha", quality: 1),
                       PhoneVoiceCandidate(identifier: "x", language: "fr-FR", name: "Thomas", quality: 3)]
        #expect(PhoneVoicePicker.suggestsBetterVoice(candidates: compact, preferred: ["en-US"]))
        #expect(!PhoneVoicePicker.suggestsBetterVoice(candidates: compact, preferred: ["fr-FR"]))
        let enhanced = compact + [PhoneVoiceCandidate(identifier: "b", language: "en-GB", name: "Daniel", quality: 2)]
        #expect(!PhoneVoicePicker.suggestsBetterVoice(candidates: enhanced, preferred: ["en-US"]))
        #expect(PhoneVoicePicker.suggestsBetterVoice(candidates: [], preferred: ["en-US"]))
        #expect(PhoneVoiceWords.enhancedHint == "For a more natural voice, download an Enhanced voice in Settings › Accessibility › Spoken Content › Voices.")
        #expect(!PhoneVoiceWords.enhancedHint.contains("://"))
    }

    // MARK: The person's own voice (tester, 2026-11-08: "very robotic and not the same as 'Speak'")

    @Test func aPickedVoiceWinsForItsLanguageOnly() throws {
        let voices = [
            PhoneVoiceCandidate(identifier: "a", language: "en-US", name: "Samantha", quality: 1),
            PhoneVoiceCandidate(identifier: "b", language: "en-US", name: "Ava", quality: 3),
            PhoneVoiceCandidate(identifier: "f", language: "es-MX", name: "Paulina", quality: 2),
            PhoneVoiceCandidate(identifier: "d", language: "en-US", name: "Bubbles", quality: 3, excluded: true),
        ]
        #expect(PhoneVoicePicker.pick(language: "en", candidates: voices, preferred: ["en-US"], chosen: "a")?.identifier == "a")
        // A Spanish reply is not read by an English voice; a removed or novelty voice is not picked.
        #expect(PhoneVoicePicker.pick(language: "es", candidates: voices, preferred: ["en-US"], chosen: "a")?.identifier == "f")
        #expect(PhoneVoicePicker.pick(language: "en", candidates: voices, preferred: ["en-US"], chosen: "gone")?.identifier == "b")
        #expect(PhoneVoicePicker.pick(language: "en", candidates: voices, preferred: ["en-US"], chosen: "d")?.identifier == "b")
        // Automatic follows Spoken Content for the person's own language only, and never over a picked voice.
        #expect(PhoneVoicePicker.followsSpokenContent(language: "en", chosen: nil, preferred: ["en-US"]))
        #expect(!PhoneVoicePicker.followsSpokenContent(language: "es", chosen: nil, preferred: ["en-US"]))
        #expect(!PhoneVoicePicker.followsSpokenContent(language: "en", chosen: voices[0], preferred: ["en-US"]))
        // Settings: the person's languages, theirs first, best quality first; never a novelty voice.
        let offered = PhoneVoicePicker.offered(voices, preferred: ["en-US", "es-MX", "de-DE"])
        #expect(offered.map(\.language) == ["en", "es"])
        #expect(offered.first?.voices.map(\.identifier) == ["b", "a"])
        #expect(voices.map(\.title) == ["Samantha", "Ava (Premium)", "Paulina (Enhanced)", "Bubbles (Premium)"])
        let english = try #require(offered.first)
        #expect(english.title(for: voices[1], locale: Locale(identifier: "en_US")) == "Ava (Premium)", "one region: no region")
        let mixed = PhoneVoiceGroup(language: "en", voices: [voices[1], PhoneVoiceCandidate(identifier: "c", language: "en-GB", name: "Daniel", quality: 1)])
        #expect(mixed.title(for: mixed.voices[1], locale: Locale(identifier: "en_US")) == "Daniel · United Kingdom")
        #expect(PhoneVoicePreference.label("b", candidates: voices) == "Ava (Premium)")
        #expect(PhoneVoicePreference.label("gone", candidates: voices) == "Automatic")
        #expect(PhoneVoicePreference.label(nil, candidates: voices) == "Automatic")
    }

    @Test func thePickedVoiceIsKeptOnThisDevice() throws {
        let defaults = try #require(UserDefaults(suiteName: "phone-voice-" + UUID().uuidString))
        #expect(PhoneVoicePreference.current(defaults) == nil)
        PhoneVoicePreference.set("com.apple.voice.premium.en-US.Ava", defaults: defaults)
        #expect(PhoneVoicePreference.current(defaults) == "com.apple.voice.premium.en-US.Ava")
        PhoneVoicePreference.set(nil, defaults: defaults)
        #expect(PhoneVoicePreference.current(defaults) == nil)
        #expect(PhoneVoicePreference.automaticHint.contains("Spoken Content"))
    }

    // MARK: Audio shape

    @Test func synthesizerBuffersBecomeInt16AndSlicesForTheMeter() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22_050, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        for index in 0..<4_410 { buffer.floatChannelData![0][index] = index == 0 ? 1.5 : 0.5 }
        let pcm = try #require(PhonePCMConvert.int16(buffer))
        #expect(pcm.sampleRate == 22_050 && pcm.channels == 1)
        #expect(pcm.data.count == 8_820)
        let first = pcm.data.withUnsafeBytes { $0.load(as: Int16.self) }
        let second = pcm.data.withUnsafeBytes { $0.load(fromByteOffset: 2, as: Int16.self) }
        #expect(first == 32_767)          // clamped
        #expect(second == 16_383)
        let slices = PhonePCMConvert.slices(pcm)
        #expect(slices.count == 3)         // 80 ms pieces of 200 ms
        #expect(slices.reduce(0) { $0 + $1.count } == pcm.data.count)
        #expect(slices.allSatisfy { $0.count % 2 == 0 })
    }
}
