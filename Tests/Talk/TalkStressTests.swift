// The pieces of the stress plan (docs/spec/3x-talk.md §15) that need no screen, as repeatable tests: load on the
// conversation (S-L1 scaled, S-L4, S-L7), the 600 s dictation file (S-L8), and bad files in the audio preview
// (S-D11) with the preview's words. The on-screen half of the plan is the stress tester's and UITests/talk.

import AVFoundation
import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@Suite("Talk stress (conversation)", .serialized)
@MainActor
struct TalkStressConversationTests {
    @MainActor final class Words {
        var queue: [String]
        private(set) var asked = 0
        init(_ queue: [String]) { self.queue = queue }
        func next() -> Result<String, VoiceFailure> {
            asked += 1
            return .success(queue.isEmpty ? "" : queue.removeFirst())
        }
    }

    private func make(script: String, words: [String] = []) -> (TalkController, FakeSpeaker, Words) {
        AudioSessionCoordinator.shared.reset()
        KeepAwake.reset()
        FixtureTalkCapture.script = TalkFixtureStep.parse(script)
        FixtureTalkCapture.permission = "granted"
        FixtureTalkCapture.startDelay = 0.01
        let talk = TalkController()
        let speaker = FakeSpeaker()
        let queue = Words(words)
        var config = TalkConfig()
        config.silenceMs = 250
        talk.makeCapture = { FixtureTalkCapture(clock: $0) }
        talk.speaker = speaker
        talk.loadConfig = { _ in config }
        talk.transcribe = { _, _ in queue.next() }
        talk.holdsLeases = false
        talk.isOnScreen = { true }
        talk.speaksReplies = { true }
        return (talk, speaker, queue)
    }

    private func takeFiles() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: TalkCaptureCore.takesFolder.path)) ?? []).count
    }

    @Test("S-L1 (scaled to 30 turns): every turn is sent once, in order, spoken once, and no take file is kept")
    func manyTurns() async throws {
        let count = 30
        let said = (1...count).map { "Turn number \($0)" }
        let (talk, speaker, words) = make(script: Array(repeating: "say:0.4", count: count).joined(separator: ";") + ";hold", words: said)
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        var mostFiles = 0
        for turn in 1...count {
            guard await waitUntil(timeout: .seconds(10), { chat.sent.count == turn }) else {
                Issue.record("turn \(turn) was never sent (\(chat.sent.count) sent, phase \(String(describing: talk.view?.phase)))")
                break
            }
            mostFiles = max(mostFiles, takeFiles())
            chat.reply("m\(turn)", "Answer \(turn)", done: false)
            #expect(await waitUntil { speaker.sessions.count == turn }, "turn \(turn) opens one speech session")
            speaker.begin()
            chat.reply("m\(turn)", "Answer \(turn) is complete.", done: true)
            #expect(await waitUntil { speaker.sessions.last?.finished == true })
            speaker.complete()
        }
        #expect(chat.sent.map(\.text) == said, "in order, none twice")
        #expect(chat.sent.allSatisfy { !$0.interrupted })
        #expect(words.asked == count)
        #expect(speaker.sessions.count == count)
        #expect(speaker.sessions.map(\.messageId) == (1...count).map { "m\($0)" })
        #expect(mostFiles <= 2, "takes are deleted as they are used (\(mostFiles) at most)")
        #expect(await waitUntil { talk.view?.phase == .listening })
        #expect(talk.started == 1 && talk.isLive)
        talk.end()
        await talk.resetForTests()
        #expect(takeFiles() == 0)
        #expect(KeepAwake.count == 0)
        #expect(AudioSessionCoordinator.shared.owner == nil)
    }

    @Test("S-L4: Talk and End fifty times as fast as the calls land, then Mute a hundred times")
    func startEndAndMute() async throws {
        let (talk, speaker, words) = make(script: "")
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        for round in 0..<50 {
            talk.start(in: chat, name: "Ivy")
            #expect(talk.isLive(in: chat))
            if round % 5 == 0 { try await Task.sleep(for: .milliseconds(30)) }      // some reach the microphone, most do not
            talk.end()
            #expect(!talk.isLive)
        }
        #expect(talk.started == 50)
        #expect(!chat.voiceHold && chat.onVoiceChange == nil)
        #expect(KeepAwake.count == 0, "no hold is left (\(KeepAwake.owners))")
        await talk.resetForTests()
        #expect(AudioSessionCoordinator.shared.owner == nil)
        #expect(takeFiles() == 0)
        #expect(chat.sent.isEmpty && words.asked == 0 && speaker.sessions.isEmpty, "nothing was sent or spoken")

        // One conversation, muted and unmuted a hundred times: it ends where it began.
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        for _ in 0..<100 { talk.toggleMute() }
        #expect(await waitUntil { talk.view?.phase == .listening }, "an even number of taps leaves it listening (\(String(describing: talk.view?.phase)))")
        talk.toggleMute()
        #expect(await waitUntil { talk.view?.phase == .muted })
        #expect(KeepAwake.count == 1 && KeepAwake.isHeld(.conversation), "one hold however often it is muted")
        #expect(AudioSessionCoordinator.shared.owner == .conversation)
        talk.end()
        await talk.resetForTests()
        #expect(KeepAwake.count == 0 && AudioSessionCoordinator.shared.owner == nil && takeFiles() == 0)
        #expect(chat.sent.isEmpty)
    }

    @Test("S-L7: Talk in ten chats one after another: always exactly one is live and the nine others leave nothing")
    func tenChats() async throws {
        let (talk, _, _) = make(script: "")
        let chats = (0..<10).map { FakeTalkChat(profile: "bot\($0)", stored: "20260929_120000_aabbcc\(10 + $0)") }
        for (index, chat) in chats.enumerated() {
            talk.setFront(chat, onScreen: true)
            talk.start(in: chat, name: "Bot \(index)")
            if index % 3 == 0 { _ = await waitUntil { talk.view?.phase == .listening } }
            #expect(talk.isLive(in: chat))
            #expect(chats.filter { talk.isLive(in: $0) }.count == 1, "one live after start \(index)")
            #expect(chats.filter(\.voiceHold).count == 1)
            #expect(KeepAwake.count == 1)
        }
        for chat in chats.dropLast() {
            #expect(talk.notice(for: chat.memoScope) == nil, "an ended conversation leaves no notice")
            #expect(chat.onVoiceChange == nil)
        }
        #expect(talk.started == 10)
        #expect(await waitUntil { talk.view?.phase == .listening })
        #expect(talk.view?.title == "Listening")
        talk.end()
        await talk.resetForTests()
        #expect(KeepAwake.count == 0 && AudioSessionCoordinator.shared.owner == nil && takeFiles() == 0)
        #expect(talk.pillContent == nil)
    }
}

@Suite("Talk stress (files)")
struct TalkStressFileTests {
    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "talk-stress-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    #if DEBUG && targetEnvironment(simulator)
    @Test("S-L8: ten minutes of dictation is an AAC file under 3 MB")
    func tenMinutesOfDictation() async throws {
        let home = folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appending(path: "dictation.m4a")
        let made = await Task.detached { FixtureDictationRecorder.writeTone(file, seconds: 600) }.value
        #expect(made)
        let bytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        #expect(bytes > 100_000 && bytes < 3_000_000, "\(bytes) bytes")
        let audio = try AVAudioFile(forReading: file)
        #expect(abs(Double(audio.length) / audio.fileFormat.sampleRate - 600) < 1, "600 s long")
        #expect(audio.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC)
        #expect(audio.fileFormat.channelCount == 1)
        // The upload's body (base64 in JSON) stays under the gateway's 25 MB limit by a wide margin.
        let (body, _) = try await MemoUploader.transcribeBody(file: file, mime: DictationRecorder.mime)
        #expect(body.count < 4_500_000, "\(body.count) bytes of JSON")
    }

    @MainActor @Test("S-D11: a corrupt and an empty recording say so; a real one is measured and does not play by itself")
    func previewOfBadFiles() async throws {
        let home = folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let corrupt = home.appending(path: "Corrupt.m4a"), empty = home.appending(path: "Empty.m4a"), good = home.appending(path: "Good.m4a")
        try Data(repeating: 0x2E, count: 4_096).write(to: corrupt)
        try Data().write(to: empty)
        #expect(await Task.detached { FixtureDictationRecorder.writeTone(good, seconds: 3) }.value)
        for bad in [corrupt, empty, home.appending(path: "Missing.m4a")] {
            let model = AudioPreviewModel(item: .local(bad, bytes: nil))
            #expect(model.phase == .loading)
            model.appeared()
            #expect(await waitUntil(timeout: .seconds(5)) { model.phase == .failed }, "\(bad.lastPathComponent) fails in words (\(model.phase))")
            #expect(!model.playing && model.total == 0)
            model.closed()
        }
        let model = AudioPreviewModel(item: .local(good, bytes: 24_000))
        model.appeared()
        #expect(await waitUntil(timeout: .seconds(5)) { model.phase == .ready })
        #expect(abs(model.total - 3) < 0.3, "measured from the file (\(model.total) s)")
        #expect(!model.playing && model.elapsed == 0, "nothing plays until Play")
        #expect(AudioSessionCoordinator.shared.owner == nil)
        model.closed()
    }
    #endif

    @Test("The audio preview's words")
    func previewWords() {
        #expect(AudioPreviewText.loading == "Loading…")
        #expect(AudioPreviewText.failed == "Couldn’t load this recording.")
        #expect(AudioPreviewText.detail(bytes: 128_400, name: "Field recording.m4a") == "128 KB · M4A audio")
        #expect(AudioPreviewText.detail(bytes: 1_240_000, name: "talk.MP3") == "1.2 MB · MP3 audio")
        #expect(AudioPreviewText.detail(bytes: 900, name: "a.wav") == "900 bytes · WAV audio")
        #expect(AudioPreviewText.detail(bytes: 1, name: "a.wav") == "1 byte · WAV audio")
        #expect(AudioPreviewText.detail(bytes: 210_000_000, name: "long.flac") == "210 MB · FLAC audio")
        #expect(AudioPreviewText.detail(bytes: nil, name: "voice-memo.wav") == "WAV audio")
        #expect(AudioPreviewText.detail(bytes: 0, name: "recording") == "Audio")
        #expect(AudioPreviewText.kind(name: "odd.name.with-a-very-long-extension") == "Audio")
        #expect(AudioPreviewText.clock(0) == "0:00" && AudioPreviewText.clock(4.9) == "0:04" && AudioPreviewText.clock(750) == "12:30")
        #expect(AudioPreviewText.clock(-3) == "0:00" && AudioPreviewText.clock(.nan) == "0:00" && AudioPreviewText.clock(.infinity) == "0:00")
        #expect(AudioPreviewText.spokenPosition(elapsed: 4.2, total: 12) == "4 seconds of 12 seconds")
        #expect(AudioPreviewText.spokenPosition(elapsed: 1, total: 61).hasPrefix("1 second of "))
        #expect(AudioPreviewText.isAudio(typeIdentifier: "public.mpeg-4-audio", name: "x"))
        #expect(AudioPreviewText.isAudio(typeIdentifier: nil, name: "Field recording.M4A"))
        #expect(AudioPreviewText.isAudio(typeIdentifier: "public.data", name: "song.mp3"))
        #expect(!AudioPreviewText.isAudio(typeIdentifier: "public.png", name: "photo.png"))
        #expect(!AudioPreviewText.isAudio(typeIdentifier: nil, name: "notes"))
        #expect(!AudioPreviewText.isAudio(typeIdentifier: nil, name: "clip.mp4"), "a film is not opened as audio")
    }
}
