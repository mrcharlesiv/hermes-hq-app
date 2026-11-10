// Voice Diagnostics (docs/spec/3x-talk.md §9.4): the eleven rows, the status line's words, the three buttons, the report,
// and the test take itself, recorded with the conversation's microphone (its stand-in) under the diagnostics owner.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Voice diagnostics wording")
struct VoiceDiagnosticsWordingTests {
    @Test func theElevenRowsInOrder() {
        var facts = VoiceAudioFacts()
        facts.output = "iPhone"
        #expect(facts.rows.map(\.name) == ["Microphone permission", "Audio session", "Audio in use by", "Microphone running", "Voice processing",
                                           "Voice paused", "Input route", "Output route", "Screen kept awake", "Voice memo recording", "Live words"])
        #expect(facts.rows.map(\.value) == ["not asked", "not active", "nothing", "no", "off", "no", "none", "iPhone", "no", "no",
                                           "not checked yet"])

        facts.permission = .allowed
        facts.owner = .conversation
        facts.borrower = .speech
        facts.category = "AVAudioSessionCategoryPlayAndRecord"
        facts.mode = "AVAudioSessionModeDefault"
        facts.voiceProcessing = .on
        facts.paused = "silence"
        facts.input = "iPhone Microphone"
        facts.output = "Speaker"
        facts.holds = 2
        #expect(facts.rows.map(\.value) == ["allowed", "playAndRecord, default", "conversation, read aloud", "yes", "on", "silence",
                                           "iPhone Microphone", "Speaker", "yes (2 holds)", "no", "not checked yet"])

        facts = VoiceAudioFacts(permission: .denied, category: "AVAudioSessionCategoryPlayback", mode: "AVAudioSessionModeSpokenAudio",
                                owner: .speech, voiceProcessing: .unavailable, output: "AirPods Pro", holds: 1)
        #expect(facts.rows.map(\.value) == ["denied", "playback, spokenAudio", "read aloud", "no", "unavailable", "no", "none", "AirPods Pro",
                                           "yes (1 hold)", "no", "not checked yet"])
        facts.owner = .memoRecording
        #expect(facts.rows[2].value == "voice memo" && facts.rows[3].value == "yes" && facts.rows[9].value == "yes")
    }

    @Test func thePageShowsTitleCaseRows() {
        var facts = VoiceAudioFacts()
        facts.output = "iPhone"
        let shown = facts.rows.map(VoiceAudioFacts.display)
        #expect(shown.map(\.name) == ["Microphone Access", "Audio Session", "Audio In Use By", "Microphone On", "Echo Cancellation",
                                      "Voice Paused", "Input", "Output", "Screen Kept Awake", "Recording a Memo", "Words as You Speak"])
        #expect(shown.map(\.value) == ["Not Asked", "Not Active", "Nothing", "No", "Off", "No", "None", "iPhone", "No", "No",
                                       "Not checked yet"])
        facts.liveWords = "on this device (en_US)"
        #expect(facts.rows.map(VoiceAudioFacts.display).last?.value == "On this device (en_US)")
        facts.liveWords = "gateway (device not supported)"
        #expect(facts.rows.map(VoiceAudioFacts.display).last?.value == "Gateway (device not supported)")

        facts.owner = .conversation
        facts.borrower = .speech
        facts.category = "AVAudioSessionCategoryPlayAndRecord"
        facts.input = "iPhone Microphone"
        facts.holds = 2
        let busy = facts.rows.map(VoiceAudioFacts.display)
        #expect(busy[1].value == "playAndRecord, default" && busy[2].value == "Conversation, Read Aloud")
        #expect(busy[6].value == "iPhone Microphone" && busy[8].value == "Yes (2 holds)")
        // The report keeps its own names.
        #expect(facts.rows[0].name == "Microphone permission")
    }

    @Test func everyOwnerHasAPlainName() {
        let names: [AudioSessionCoordinator.Owner?: String] = [
            nil: "nothing", .memoRecording: "voice memo", .memoPlayback: "memo playback", .conversation: "conversation",
            .dictation: "dictation", .speech: "read aloud", .diagnostics: "diagnostics",
        ]
        for (owner, name) in names { #expect(VoiceAudioFacts.ownerName(owner) == name) }
        #expect(VoiceAudioFacts.sessionName(category: nil, mode: nil) == "not active")
        #expect(VoiceAudioFacts.sessionName(category: "AVAudioSessionCategoryPlayAndRecord", mode: nil) == "playAndRecord, default")
        #expect(VoiceAudioFacts.sessionName(category: "AVAudioSessionCategoryPlayback", mode: "AVAudioSessionModeSpokenAudio") == "playback, spokenAudio")
        #expect(VoiceAudioFacts.sessionNames(for: .diagnostics)?.category == "AVAudioSessionCategoryPlayAndRecord")
        #expect(VoiceAudioFacts.sessionNames(for: .memoPlayback)?.mode == "AVAudioSessionModeSpokenAudio")
        #expect(VoiceAudioFacts.sessionNames(for: nil) == nil)
    }

    @Test func theStatusLine() {
        #expect(VoiceTestStatus.start.text == "Transcribe sends the test recording to your Speech to Text provider.")
        #expect(VoiceTestStatus.recording(seconds: 3).text == "Recording 3 seconds…")
        #expect(VoiceTestStatus.recorded(bytes: 96_044, mime: "audio/wav", input: "iPhone Microphone").text
                == "Recorded 94 KB (audio/wav) from “iPhone Microphone”.")
        #expect(VoiceTestStatus.recorded(bytes: 900, mime: "audio/wav", input: nil).text == "Recorded 900 bytes (audio/wav).")
        #expect(VoiceTestStatus.recordFailed("The microphone gave no sound").text == "Recording failed: The microphone gave no sound.")
        #expect(VoiceTestStatus.microphoneOff.text == "Allow the microphone in Settings")
        #expect(VoiceTestStatus.busy.text == "Voice is in use. End the conversation, memo or dictation to run a test.")
        #expect(VoiceTestStatus.played(seconds: 3.04).text == "Played 3.0 s.")
        #expect(VoiceTestStatus.playFailed("The test take can’t be played.").text == "Playback failed: The test take can’t be played.")
        #expect(VoiceTestStatus.transcribed(" hello testing one two ").text == "Transcribed: “hello testing one two”")
        #expect(VoiceTestStatus.transcribed("  ").text == "Transcribed: (no speech detected)")
        #expect(VoiceTestStatus.transcribeFailed(nil).text == "Transcription failed on the gateway.")
        #expect(VoiceTestStatus.transcribeFailed("No STT provider is configured").text == "Transcription failed: No STT provider is configured.")
        // A reason never carries an address into the page or the report.
        #expect(VoiceTestStatus.transcribeFailed("could not reach https://gw.example.ts.net/api/audio").text
                == "Transcription failed: could not reach (address).")
        // The report's Test line: only once a test did something.
        #expect(VoiceTestStatus.start.reportLine == nil && VoiceTestStatus.busy.reportLine == nil && VoiceTestStatus.recording(seconds: 3).reportLine == nil)
        #expect(VoiceTestStatus.played(seconds: 3).reportLine == "Played 3.0 s.")
    }

    @Test func theThreeButtons() {
        #expect(VoiceTestButtons.recordTitle(nil, seconds: 3) == "Record 3 s")
        #expect(VoiceTestButtons.recordTitle(.recording, seconds: 3) == "Recording…")
        #expect(VoiceTestButtons.playTitle(nil) == "Play" && VoiceTestButtons.playTitle(.playing) == "Playing…")
        #expect(VoiceTestButtons.transcribeTitle(nil) == "Transcribe" && VoiceTestButtons.transcribeTitle(.transcribing) == "Transcribing…")
        #expect(VoiceTestButtons.canRecord(running: nil, microphoneBusy: false))
        #expect(!VoiceTestButtons.canRecord(running: nil, microphoneBusy: true))
        #expect(!VoiceTestButtons.canRecord(running: .playing, microphoneBusy: false))
        #expect(!VoiceTestButtons.canPlay(running: nil, hasTake: false) && VoiceTestButtons.canPlay(running: nil, hasTake: true))
        #expect(!VoiceTestButtons.canPlay(running: .transcribing, hasTake: true))
        #expect(VoiceTestButtons.canTranscribe(running: nil, hasTake: true, connected: true))
        #expect(!VoiceTestButtons.canTranscribe(running: nil, hasTake: true, connected: false))
        #expect(!VoiceTestButtons.canTranscribe(running: nil, hasTake: false, connected: true))
        #expect(!VoiceTestButtons.canTranscribe(running: .recording, hasTake: true, connected: true))
    }

    @Test func theReportIsPlainText() throws {
        var facts = VoiceAudioFacts()
        facts.permission = .allowed
        facts.output = "iPhone"
        let zone = try #require(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_791_688_365)   // 2026-10-11T03:12:45Z
        let events = [VoiceEvent(at: now.addingTimeInterval(-4), text: "audio session: diagnostics acquired"),
                      VoiceEvent(at: now.addingTimeInterval(-1), text: "diagnostics: test take ended 3000 ms, no speech heard")]
        let text = VoiceReport.text(appName: "Hermes HQ", version: "1.0", build: "251", device: "iPhone17,1", system: "iOS 27.0", now: now,
                                    rows: facts.rows, test: VoiceTestStatus.recorded(bytes: 96_044, mime: "audio/wav", input: "iPhone Microphone").reportLine,
                                    events: events, zone: zone)
        let lines = text.components(separatedBy: "\n")
        #expect(lines[0] == "Hermes HQ voice diagnostics")
        #expect(lines[1] == "Time: 2026-10-11T03:12:45Z")
        #expect(lines[2] == "App: Hermes HQ 1.0 (251) · iPhone17,1 · iOS 27.0")
        #expect(lines[3] == "Microphone permission: allowed")
        #expect(lines[4] == "Audio session: not active")
        #expect(lines[12] == "Voice memo recording: no")
        #expect(lines[13] == "Live words: not checked yet")
        #expect(lines[14] == "Test: Recorded 94 KB (audio/wav) from “iPhone Microphone”.")
        #expect(lines[15] == "Recent audio events:")
        #expect(lines[16] == "  03:12:41 audio session: diagnostics acquired")
        #expect(lines[17] == "  03:12:44 diagnostics: test take ended 3000 ms, no speech heard")
        #expect(lines.count == 18)
        // Before any test, and with nothing logged.
        let empty = VoiceReport.text(appName: "HQ Native", version: "1.0", build: "1", device: "iPhone17,1", system: "iOS 27.0", now: now,
                                     rows: facts.rows, test: nil, events: [], zone: zone)
        #expect(empty.hasPrefix("HQ Native voice diagnostics\n"))
        #expect(empty.hasSuffix("Recent audio events:\n  None yet."))
        #expect(!empty.contains("Test:"))
    }
}

@Suite("Voice diagnostics test take", .serialized)
@MainActor
struct VoiceDiagnosticsTests {
    final class Seen {
        var transcribed: [URL] = []
        var copied: [String] = []
        var connected = true
    }

    private func make(answer: Result<String, VoiceFailure> = .success("hello testing one two"), seconds: TimeInterval = 0.3)
        -> (VoiceDiagnosticsModel, Seen) {
        KeepAwake.reset()
        AudioSessionCoordinator.shared.reset()
        AudioSessionCoordinator.shared.simulatedOwners.formUnion([.diagnostics, .speech, .memoRecording])
        FixtureTalkCapture.permission = "granted"
        FixtureTalkCapture.script = []
        FixtureTalkCapture.startDelay = 0.02
        VoiceDiagnosticsModel.makeCapture = { FixtureTalkCapture(clock: $0) }
        VoiceDiagnosticsModel.readPermission = { FixtureTalkCapture.permission == "denied" ? .denied : .allowed }
        VoiceDiagnosticsModel.readRoute = {
            VoiceRouteRead(category: "AVAudioSessionCategoryPlayAndRecord", mode: "AVAudioSessionModeDefault", input: "Test Microphone",
                           outputKind: .speaker, outputName: "Speaker")
        }
        VoiceDiagnosticsModel.takeSeconds = seconds
        let seen = Seen()
        let model = VoiceDiagnosticsModel(transcribe: { file in
            seen.transcribed.append(file)
            try? await Task.sleep(for: .milliseconds(40))
            return answer
        }, connected: { seen.connected })
        model.copyText = { seen.copied.append($0) }
        model.pageShown()
        return (model, seen)
    }

    private func finish(_ model: VoiceDiagnosticsModel) async {
        model.pageLeft()
        await AudioWork.drain()
        VoiceDiagnosticsModel.takeSeconds = TimeInterval(VoiceDiagnosticsModel.seconds)
        VoiceDiagnosticsModel.readRoute = nil
        FixtureTalkCapture.startDelay = 0.08
    }

    @Test func recordPlayTranscribe() async throws {
        let (model, seen) = make()
        #expect(model.status == .start && model.shownStatus == .start)
        #expect(model.canRecord && !model.canPlay && !model.canTranscribe)

        model.record()
        #expect(model.running == .recording)
        #expect(model.status == .recording(seconds: 3))
        #expect(!model.canRecord && !model.canPlay && !model.canTranscribe)
        #expect(KeepAwake.isHeld(.diagnostics))
        // The conversation's microphone, under the diagnostics owner.
        #expect(await waitUntil { AudioSessionCoordinator.shared.owner == .diagnostics })
        #expect(await waitUntil { model.facts.owner == .diagnostics })
        #expect(model.facts.rows[2].value == "diagnostics" && model.facts.rows[3].value == "yes")
        #expect(model.facts.rows[1].value == "playAndRecord, default")
        #expect(!model.microphoneBusy, "its own test is not somebody else's microphone")

        #expect(await waitUntil(timeout: .seconds(6)) { model.running == nil })
        guard case .recorded(let bytes, let mime, let input) = model.status else {
            Issue.record("expected a recorded take, got \(model.status)")
            await finish(model)
            return
        }
        #expect(mime == "audio/wav" && input == "Test Microphone")
        // 16 kHz, 16-bit mono: about 32 KB a second, with the pre-roll a little more than was asked.
        #expect(bytes > 6_000 && bytes < 40_000, "\(bytes) bytes for 0.3 s")
        let take = try #require(model.take)
        #expect(FileManager.default.fileExists(atPath: take.url.path))
        #expect(take.seconds > 0.2 && take.seconds < 1.2)
        #expect(!KeepAwake.isHeld(.diagnostics))
        #expect(await waitUntil { AudioSessionCoordinator.shared.owner == nil }, "the microphone is given back")
        #expect(model.canRecord && model.canPlay && model.canTranscribe)

        model.play()
        #expect(model.running == .playing)
        #expect(await waitUntil(timeout: .seconds(8)) { model.running == nil })
        guard case .played(let seconds) = model.status else {
            Issue.record("expected a played take, got \(model.status)")
            await finish(model)
            return
        }
        #expect(abs(seconds - take.seconds) < 0.2)
        #expect(AudioSessionCoordinator.shared.owner == nil, "the speaker is given back")

        model.transcribe()
        #expect(model.running == .transcribing)
        #expect(await waitUntil { model.running == nil })
        #expect(model.status == .transcribed("hello testing one two"))
        #expect(seen.transcribed == [take.url])

        // The log says what happened and never what was said.
        let log = VoiceEvents.all.map(\.text).joined(separator: "\n")
        #expect(log.contains("audio session: diagnostics acquired") && log.contains("audio session: diagnostics released"))
        #expect(log.contains("diagnostics: test take ended"))
        #expect(!log.contains("hello testing"))

        // Leaving the page throws the take away.
        await finish(model)
        #expect(model.take == nil)
        #expect(await waitUntil { !FileManager.default.fileExists(atPath: take.url.path) })
    }

    @Test func theGatewayRefusingSaysSo() async {
        let (model, _) = make(answer: .failure(VoiceFailure(reason: "The gateway could not transcribe that.", detail: nil)), seconds: 0.2)
        model.record()
        #expect(await waitUntil(timeout: .seconds(6)) { model.running == nil && model.take != nil })
        model.transcribe()
        #expect(await waitUntil { model.running == nil })
        #expect(model.status == .transcribeFailed(nil))
        #expect(model.status.text == "Transcription failed on the gateway.")
        await finish(model)

        let (other, _) = make(answer: .failure(VoiceFailure(reason: "No STT provider is configured", detail: nil)), seconds: 0.2)
        other.record()
        #expect(await waitUntil(timeout: .seconds(6)) { other.running == nil && other.take != nil })
        other.transcribe()
        #expect(await waitUntil { other.running == nil })
        #expect(other.status.text == "Transcription failed: No STT provider is configured.")
        await finish(other)
    }

    @Test func nothingHeardIsAnAnswer() async {
        let (model, _) = make(answer: .success(""), seconds: 0.2)
        model.record()
        #expect(await waitUntil(timeout: .seconds(6)) { model.running == nil && model.take != nil })
        model.transcribe()
        #expect(await waitUntil { model.running == nil })
        #expect(model.status.text == "Transcribed: (no speech detected)")
        await finish(model)
    }

    @Test func transcribeWaitsForTheGateway() async {
        let (model, seen) = make(seconds: 0.2)
        model.record()
        #expect(await waitUntil(timeout: .seconds(6)) { model.running == nil && model.take != nil })
        seen.connected = false
        model.refresh()
        #expect(!model.canTranscribe && model.canPlay)
        model.transcribe()
        #expect(model.running == nil && seen.transcribed.isEmpty, "nothing is sent while the gateway is away")
        seen.connected = true
        model.refresh()
        #expect(model.canTranscribe)
        await finish(model)
    }

    @Test func aMicrophoneThatIsNotAllowedLeadsToSettings() async {
        let (model, _) = make()
        FixtureTalkCapture.permission = "denied"
        model.record()
        #expect(await waitUntil { model.running == nil })
        #expect(model.status == .microphoneOff)
        #expect(model.take == nil && !model.canPlay)
        #expect(!KeepAwake.isHeld(.diagnostics))
        #expect(AudioSessionCoordinator.shared.owner == nil)
        model.refresh()
        #expect(await waitUntil { model.facts.permission == .denied })
        FixtureTalkCapture.permission = "granted"
        await finish(model)
    }

    @Test func aMicrophoneThatFailsSaysWhy() async {
        let (model, _) = make()
        FixtureTalkCapture.script = [.fail]
        model.record()
        #expect(await waitUntil { model.running == nil })
        #expect(model.status.text == "Recording failed: The stand-in microphone was told to fail.")
        #expect(!KeepAwake.isHeld(.diagnostics))
        await finish(model)
    }

    @Test func aMicrophoneThatGivesNoSoundSaysSo() async {
        let (model, _) = make(seconds: 5)
        FixtureTalkCapture.script = [.meterFail]
        model.record()
        #expect(await waitUntil(timeout: .seconds(6)) { model.running == nil })
        #expect(model.status.text == "Recording failed: The microphone gave no sound.")
        #expect(model.take == nil)
        #expect(await waitUntil { AudioSessionCoordinator.shared.owner == nil })
        await finish(model)
    }

    @Test func anotherVoiceFeatureKeepsItsMicrophone() async throws {
        let (model, _) = make()
        try await AudioSessionCoordinator.shared.acquire(.memoRecording)
        model.refresh()
        #expect(await waitUntil { model.microphoneBusy })
        #expect(!model.canRecord)
        #expect(model.shownStatus == .busy)
        #expect(model.facts.rows[2].value == "voice memo" && model.facts.rows[9].value == "yes")
        // Even pressed through VoiceOver before the page caught up: the memo keeps recording.
        model.record()
        #expect(model.running == nil && model.status == .busy)
        #expect(AudioSessionCoordinator.shared.owner == .memoRecording)
        AudioSessionCoordinator.shared.release(.memoRecording)
        model.refresh()
        #expect(await waitUntil { !model.microphoneBusy })
        #expect(model.canRecord)
        await finish(model)
    }

    @Test func aConversationTakesTheMicrophoneFromATest() async {
        let (model, _) = make(seconds: 5)
        model.record()
        #expect(await waitUntil { AudioSessionCoordinator.shared.owner == .diagnostics })
        // What the wiring does when another owner takes the session.
        model.audioTaken(.diagnostics)
        #expect(model.running == nil)
        #expect(model.status.text == "Recording failed: Another voice feature took the microphone.")
        #expect(!KeepAwake.isHeld(.diagnostics))
        #expect(await waitUntil { AudioSessionCoordinator.shared.owner == nil })
        await finish(model)
    }

    @Test func leavingThePageEndsATestInProgress() async {
        let (model, _) = make(seconds: 5)
        model.record()
        #expect(await waitUntil { AudioSessionCoordinator.shared.owner == .diagnostics })
        let takes = (try? FileManager.default.contentsOfDirectory(atPath: TalkCaptureCore.takesFolder.path))?.count ?? 0
        model.pageLeft()
        #expect(model.running == nil && model.status == .start && model.take == nil)
        #expect(!KeepAwake.isHeld(.diagnostics))
        #expect(await waitUntil { AudioSessionCoordinator.shared.owner == nil })
        await AudioWork.drain()
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: TalkCaptureCore.takesFolder.path))?.count ?? 0) <= takes, "no take is left behind")
        #expect(VoiceDiagnosticsModel.current == nil)
        await finish(model)
    }

    @Test func copyReportCopiesThePlainText() async {
        let (model, seen) = make()
        #expect(await waitUntil { model.facts.output == "Speaker" })
        model.copy()
        #expect(model.copied)
        let text = seen.copied.first ?? ""
        let lines = text.components(separatedBy: "\n")
        #expect(lines.first == "\(MemoNotice.appName) voice diagnostics")
        #expect(lines.count > 2 && lines[1].hasPrefix("Time: 20") && lines[1].hasSuffix("Z"))
        #expect(lines.count > 2 && lines[2].hasPrefix("App: \(MemoNotice.appName) "))
        #expect(text.contains("\nMicrophone permission: allowed\n"))
        #expect(text.contains("\nAudio session: not active\n"))
        #expect(text.contains("\nOutput route: Speaker\n"))
        #expect(text.contains("\nRecent audio events:\n"))
        #expect(!text.contains("Test:"), "no test yet")
        #expect(!text.lowercased().contains("dispatch"))
        #expect(await waitUntil(timeout: .seconds(4)) { !model.copied }, "Copied goes back to Copy report")
        await finish(model)
    }
}
