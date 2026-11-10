// Settings › Voice › Voice Conversation › Voice Diagnostics (docs/spec/3x-talk.md §9.4): a 3 second test take recorded
// with the microphone a conversation uses, played back and sent to the gateway's speech to text; the audio facts of
// this moment, refreshed once a second; the last 30 audio events; and a plain-text report to copy. The wording and the
// rows are in HermesKit/Voice/VoiceDiagnosticsFacts.swift.

import AVFAudio
import SwiftUI
import UIKit

/// What the audio queue reads from iOS for the rows.
nonisolated struct VoiceRouteRead: Sendable, Equatable {
    var category: String
    var mode: String
    var input: String?
    var outputKind: TalkRouteKind
    var outputName: String?

    /// On the audio queue.
    static func now() -> VoiceRouteRead {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let output = route.outputs.first
        return VoiceRouteRead(category: session.category.rawValue, mode: session.mode.rawValue, input: route.inputs.first?.portName,
                              outputKind: output.map { TalkRouteButton.kind($0.portType) } ?? .none, outputName: output?.portName)
    }
}

@MainActor @Observable final class VoiceDiagnosticsModel {
    /// The page on screen (one at a time): what loses the microphone or the speaker is told through it.
    private(set) static weak var current: VoiceDiagnosticsModel?

    /// The length of the test take, as the button says it.
    static let seconds = 3

    // What tests and the debug hooks swap.
    @ObservationIgnored static var makeCapture: @MainActor (TalkClock) -> any TalkCapturing = { TalkEngineCapture(clock: $0) }
    @ObservationIgnored static var readPermission: @MainActor () -> VoiceAudioFacts.Permission = {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .allowed
        case .denied: .denied
        default: .notAsked
        }
    }
    /// Run on the audio queue; nil reads iOS.
    @ObservationIgnored static var readRoute: (@Sendable () -> VoiceRouteRead)?
    /// How long the take really runs (tests shorten it, a screenshot holds it).
    @ObservationIgnored static var takeSeconds: TimeInterval = TimeInterval(seconds)
    @ObservationIgnored var transcribeTake: @MainActor (URL) async -> Result<String, VoiceFailure>
    @ObservationIgnored var isConnected: @MainActor () -> Bool
    @ObservationIgnored var copyText: @MainActor (String) -> Void = { VoiceClipboard.copy($0) }
    @ObservationIgnored var now: () -> Date = { Date() }

    struct Take: Equatable {
        var url: URL
        var bytes: Int
        var seconds: Double
    }

    private(set) var running: VoiceTestButtons.Running?
    private(set) var status = VoiceTestStatus.start
    private(set) var facts = VoiceAudioFacts()
    private(set) var events: [VoiceEvent] = VoiceEvents.newestFirst
    private(set) var copied = false
    private(set) var take: Take?
    private(set) var connected = false

    @ObservationIgnored private var capture: (any TalkCapturing)?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playerDelegate: VoiceTestPlayerDelegate?
    @ObservationIgnored private var playing = false
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var test = 0
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var copiedTimer: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var shown = false

    init(services: any AppServices) {
        let model = services as? AppModel
        transcribeTake = { [weak model] file in
            guard let client = model?.client else { return .failure(VoiceFailure(reason: "Your gateway isn’t connected.", detail: nil)) }
            return await VoiceGateway.transcribe(client: client, file: file, mime: "audio/wav", profile: nil)
        }
        isConnected = { [weak services] in services?.connection == .ready }
        connected = isConnected()
    }

    /// For tests: no gateway behind it.
    init(transcribe: @escaping @MainActor (URL) async -> Result<String, VoiceFailure>, connected: @escaping @MainActor () -> Bool = { true }) {
        transcribeTake = transcribe
        isConnected = connected
        self.connected = connected()
    }

    // MARK: What the page shows

    /// Another voice feature records: a test would take its microphone.
    var microphoneBusy: Bool {
        guard let owner = facts.owner, owner != .diagnostics else { return false }
        return owner.records
    }
    var canRecord: Bool { VoiceTestButtons.canRecord(running: running, microphoneBusy: microphoneBusy) }
    var canPlay: Bool { VoiceTestButtons.canPlay(running: running, hasTake: take != nil) }
    var canTranscribe: Bool { VoiceTestButtons.canTranscribe(running: running, hasTake: take != nil, connected: connected) }
    /// The status line: "Voice is in use…" takes the place of the first hint while another feature records.
    var shownStatus: VoiceTestStatus { status == .start && microphoneBusy ? .busy : status }

    var report: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return VoiceReport.text(appName: MemoNotice.appName,
                                version: info["CFBundleShortVersionString"] as? String ?? "?",
                                build: info["CFBundleVersion"] as? String ?? "?",
                                device: Self.deviceModel,
                                system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
                                now: now(), rows: facts.rows, test: status.reportLine, events: VoiceEvents.all)
    }

    static var deviceModel: String { AppRoot.deviceModel }

    // MARK: The page comes and goes

    func pageShown() {
        guard !shown else { return }
        shown = true
        Self.current = self
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: VoiceEvents.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.events = VoiceEvents.newestFirst }
        })
        observers.append(center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endTest(note: "the app left the screen") }
        })
        events = VoiceEvents.newestFirst
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        refresh()
    }

    /// Leaving the page ends a test in progress and throws the take away.
    func pageLeft() {
        guard shown else { return }
        shown = false
        if Self.current === self { Self.current = nil }
        ticker?.invalidate()
        ticker = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        copiedTimer?.cancel()
        endTest(note: "the page was left")
        discardTake()
    }

    /// Once a second, and after anything the page did.
    func refresh() {
        connected = isConnected()
        let read = Self.readRoute ?? { VoiceRouteRead.now() }
        Task { [weak self] in
            let route = await AudioWork.perform { read() }
            self?.apply(route)
        }
    }

    private func apply(_ route: VoiceRouteRead) {
        let audio = AudioSessionCoordinator.shared
        var next = VoiceAudioFacts()
        next.permission = Self.readPermission()
        next.owner = audio.owner
        next.borrower = audio.borrower
        var input = route.input
        if let owner = audio.owner {
            next.category = route.category
            next.mode = route.mode
            #if DEBUG
            // A stand-in never touches the real session: the rows say what the coordinator would have set.
            if audio.simulatedOwners.contains(owner), let names = VoiceAudioFacts.sessionNames(for: owner) {
                next.category = names.category
                next.mode = names.mode
                if owner.records, input == nil { input = "\(TalkRouteButton.device) Microphone" }
            }
            #endif
            if !owner.records { input = nil }
        } else {
            input = nil
        }
        next.input = input
        next.output = TalkDockState.routeName(route.outputKind, portName: route.outputName, device: TalkRouteButton.device)
        next.voiceProcessing = TalkEngineFacts.voiceProcessing.withLock { $0 }
        next.paused = TalkController.shared.waitingNotices.compactMap { $0.notice.cause?.rawValue }.last
        next.holds = KeepAwake.count
        next.liveWords = LiveWords.diagnosticsLine
        if next != facts { facts = next }
    }

    // MARK: Record 3 s

    func record() {
        guard running == nil else { return }
        // Looked at now, not a second ago.
        if let owner = AudioSessionCoordinator.shared.owner, owner != .diagnostics, owner.records {
            status = .busy
            return
        }
        stopPlayer()
        discardTake()
        test += 1
        let id = test
        running = .recording
        status = .recording(seconds: Self.seconds)
        Haptics.play(.light)
        let capture = Self.makeCapture(TalkClock())
        capture.audioOwner = .diagnostics
        capture.onTakeEnded = { [weak self] take in self?.takeEnded(take, id: id) }
        capture.onInterrupted = { [weak self] _, detail in self?.recordFailed(detail, id: id) }
        self.capture = capture
        KeepAwake.hold(.diagnostics, cap: 30)
        VoiceEvents.note("diagnostics: test take began")
        let length = Self.takeSeconds
        work = Task { [weak self] in
            do {
                try await capture.prepare()
            } catch {
                self?.prepareFailed(error, id: id)
                return
            }
            guard let self, self.test == id, self.running == .recording else { return }
            self.refresh()
            capture.beginTake(silenceMs: 600_000, words: nil)   // the take ends when the 3 seconds are up, never on a pause
            try? await Task.sleep(for: .seconds(length))
            guard self.test == id, self.running == .recording, !Task.isCancelled else { return }
            capture.finishTake()
        }
    }

    private func prepareFailed(_ error: any Error, id: Int) {
        guard test == id, running == .recording else { return }
        switch error as? TalkCaptureError {
        case .denied: finishRecording(.microphoneOff)
        case .noMicrophone: finishRecording(.recordFailed("No microphone was found."))
        case .busy: finishRecording(.recordFailed("Another app is using the microphone."))
        case .failed(let reason): finishRecording(.recordFailed(reason))
        case nil: finishRecording(.recordFailed(TalkEngineCapture.describe(error)))
        }
    }

    private func recordFailed(_ detail: String, id: Int) {
        guard test == id, running == .recording else { return }
        finishRecording(.recordFailed(detail.isEmpty ? "The microphone stopped." : detail))
    }

    private func takeEnded(_ ended: TalkTake, id: Int) {
        guard test == id, running == .recording else {
            TalkCaptureCore.discard(ended.url)
            return
        }
        if ended.meterFailed {
            TalkCaptureCore.discard(ended.url)
            finishRecording(.recordFailed("The microphone gave no sound."))
            return
        }
        let read = Self.readRoute ?? { VoiceRouteRead.now() }
        let url = ended.url
        #if DEBUG
        let standIn = AudioSessionCoordinator.shared.simulatedOwners.contains(.diagnostics)
        #else
        let standIn = false
        #endif
        work = Task { [weak self] in
            // The input's name and the file's size, read while the session is still this test's.
            let (route, bytes): (VoiceRouteRead, Int) = await AudioWork.perform {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                return (read(), size)
            }
            guard let self, self.test == id, self.running == .recording else {
                TalkCaptureCore.discard(url)
                return
            }
            guard bytes > 44 else {
                TalkCaptureCore.discard(url)
                self.finishRecording(.recordFailed("Nothing was recorded."))
                return
            }
            self.take = Take(url: url, bytes: bytes, seconds: Double(ended.ms) / 1000)
            let input = route.input ?? (standIn ? "\(TalkRouteButton.device) Microphone" : nil)
            VoiceEvents.note("diagnostics: test take ended \(ended.ms) ms, \(ended.heardSpeech ? "speech heard" : "no speech heard")")
            self.finishRecording(.recorded(bytes: bytes, mime: "audio/wav", input: input))
        }
    }

    private func finishRecording(_ result: VoiceTestStatus) {
        status = result
        running = nil
        KeepAwake.release(.diagnostics)
        if case .recordFailed(let reason) = result { VoiceEvents.note("diagnostics: test take failed: \(reason)") }
        if result == .microphoneOff { VoiceEvents.note("diagnostics: the microphone is not allowed") }
        let capture = self.capture
        self.capture = nil
        Task { [weak self] in
            await capture?.shutDown()
            self?.refresh()
        }
    }

    // MARK: Play

    func play() {
        guard running == nil, let take else { return }
        test += 1
        let id = test
        running = .playing
        let url = take.url
        // Read Aloud gives the speaker up; a memo that plays is paused by the session changing hands.
        if AudioSessionCoordinator.shared.owner == .speech { TalkSpeaker.shared.stop() }
        let silent = EngineSpeechOutput.silent.withLock { $0 }
        work = Task { [weak self] in
            do {
                try await AudioSessionCoordinator.shared.acquire(.speech)
                let made: UncheckedTestPlayer = try await AudioWork.run {
                    let player = try AVAudioPlayer(contentsOf: url)
                    if silent { player.volume = 0 }
                    guard player.prepareToPlay() else { throw VoiceFailure(reason: "The test take can’t be played.", detail: nil) }
                    return UncheckedTestPlayer(player)
                }
                guard let self, self.test == id, self.running == .playing else {
                    AudioSessionCoordinator.shared.release(.speech)
                    return
                }
                let player = made.value
                let length = player.duration
                let delegate = VoiceTestPlayerDelegate { [weak self] ok in self?.playEnded(seconds: length, ok: ok, id: id) }
                player.delegate = delegate
                self.player = player
                self.playerDelegate = delegate
                self.playing = true
                VoiceEvents.note("diagnostics: playing the test take")
                let started = await AudioWork.perform { made.value.play() }
                if !started { self.playEnded(seconds: 0, ok: false, id: id) }
                self.refresh()
            } catch {
                guard let self, self.test == id, self.running == .playing else { return }
                AudioSessionCoordinator.shared.release(.speech)
                self.running = nil
                let reason = (error as? VoiceFailure)?.reason ?? TalkEngineCapture.describe(error)
                self.status = .playFailed(reason)
                VoiceEvents.note("diagnostics: playback failed: \(reason)")
                self.refresh()
            }
        }
    }

    private func playEnded(seconds: Double, ok: Bool, id: Int) {
        guard test == id, running == .playing else { return }
        stopPlayer()
        running = nil
        status = ok ? .played(seconds: seconds) : .playFailed("The test take can’t be played.")
        VoiceEvents.note(ok ? "diagnostics: played \(String(format: "%.1f", seconds)) s" : "diagnostics: playback failed")
        refresh()
    }

    private func stopPlayer() {
        guard playing || player != nil else { return }
        if let player {
            let boxed = UncheckedTestPlayer(player)
            AudioWork.later { boxed.value.stop() }
        }
        player = nil
        playerDelegate = nil
        playing = false
        AudioSessionCoordinator.shared.release(.speech)
    }

    // MARK: Transcribe

    func transcribe() {
        connected = isConnected()
        guard running == nil, let take, connected else { return }
        test += 1
        let id = test
        running = .transcribing
        let url = take.url
        let started = Date()
        VoiceEvents.note("diagnostics: transcribing the test take")
        work = Task { [weak self] in
            guard let transcribe = self?.transcribeTake else { return }
            let answer = await transcribe(url)
            guard let self, self.test == id, self.running == .transcribing else { return }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            self.running = nil
            switch answer {
            case .success(let words):
                self.status = .transcribed(words)
                VoiceEvents.note("diagnostics: transcription answered in \(ms) ms, \(words.isEmpty ? "no speech" : "speech found")")
            case .failure(let failure):
                let generic = failure.reason == "The gateway could not transcribe that."
                self.status = .transcribeFailed(generic ? nil : failure.reason)
                VoiceEvents.note("diagnostics: transcription failed after \(ms) ms")
            }
            self.refresh()
        }
    }

    // MARK: Ends

    /// A conversation, a memo or a dictation took the microphone, or something else took the speaker.
    func audioTaken(_ owner: AudioSessionCoordinator.Owner) {
        switch (owner, running) {
        case (.diagnostics, .recording):
            test += 1
            work?.cancel()
            finishRecording(.recordFailed("Another voice feature took the microphone."))
        case (.speech, .playing):
            test += 1
            work?.cancel()
            stopPlayer()
            running = nil
            status = .playFailed("Something else started playing.")
            refresh()
        default:
            break
        }
    }

    /// The page went, or the app left the screen: whatever runs stops, and the status goes back to the start.
    private func endTest(note: String) {
        guard running != nil || playing else { return }
        let was = running
        test += 1
        work?.cancel()
        work = nil
        stopPlayer()
        running = nil
        if was == .recording {
            KeepAwake.release(.diagnostics)
            let capture = self.capture
            self.capture = nil
            capture?.cancelTake()
            Task { [weak self] in
                await capture?.shutDown()
                self?.refresh()
            }
        }
        if was != nil {
            status = .start
            VoiceEvents.note("diagnostics: test ended, \(note)")
        }
    }

    private func discardTake() {
        if let take { TalkCaptureCore.discard(take.url) }
        take = nil
    }

    // MARK: Copy report

    func copy() {
        copyText(report)
        Haptics.play(.success)
        copied = true
        copiedTimer?.cancel()
        copiedTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    /// [mac] Mac polish #11: the microphone's Privacy pane on the Mac.
    func openSystemSettings() { PrivacySettingsLink.open(.microphone) }
}

private nonisolated struct UncheckedTestPlayer: @unchecked Sendable {
    let value: AVAudioPlayer
    init(_ value: AVAudioPlayer) { self.value = value }
}

private final class VoiceTestPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    private let ended: @MainActor (Bool) -> Void
    init(ended: @escaping @MainActor (Bool) -> Void) { self.ended = ended }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.ended(flag) } }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.ended(false) } }
    }
}

// MARK: - The page

struct VoiceDiagnosticsView: View {
    let model: VoiceDiagnosticsModel
    @Environment(\.dynamicTypeSize) private var typeSize

    static let intro = "Record a short test and play it back. If voice misbehaves, copy the report at the end of this page."

    var body: some View {
        List { Group {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text(Self.intro)
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel2)
                        .fixedSize(horizontal: false, vertical: true)
                    buttons
                    statusLine
                }
                .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                // The list's own row inset, so the block lines up with the section labels and rows below.
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(Array(model.facts.rows.enumerated()), id: \.offset) { index, row in
                    factRow(VoiceAudioFacts.display(row)).accessibilityIdentifier("voice.diag.row.\(index)")
                }
            } header: { HQSectionLabel { Text("Right Now") } }
            Section {
                if model.events.isEmpty {
                    Text("None yet.")
                        .foregroundStyle(Color.hqLabel2)
                        .accessibilityIdentifier("voice.diag.events.none")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(model.events.enumerated()), id: \.offset) { _, event in eventLine(event) }
                    }
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("voice.diag.events")
                }
            } header: { HQSectionLabel {
                Text("Recent Audio Events")
            } } footer: { HQSectionFooter {
                Text("What was said is never kept here, and neither is your gateway’s address.")
            } }
            Section {
                Button(action: model.copy) {
                    Text(model.copied ? "Copied" : "Copy Report")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                .accessibilityIdentifier("voice.diag.copy")
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .onAppear { model.pageShown() }
        .onDisappear { model.pageLeft() }
        .accessibilityIdentifier("voice.diag")
    }

    // MARK: The three buttons

    @ViewBuilder private var buttons: some View {
        let record = testButton(VoiceTestButtons.recordTitle(model.running, seconds: VoiceDiagnosticsModel.seconds), id: "voice.diag.record",
                                enabled: model.canRecord, action: model.record)
        let play = testButton(VoiceTestButtons.playTitle(model.running), id: "voice.diag.play", enabled: model.canPlay, action: model.play)
        let transcribe = testButton(VoiceTestButtons.transcribeTitle(model.running), id: "voice.diag.transcribe",
                                    enabled: model.canTranscribe, action: model.transcribe)
        if typeSize.isAccessibilitySize {
            VStack(spacing: 10) { record; play; transcribe }
        } else {
            HStack(spacing: 8) { record; play; transcribe }
        }
    }

    private func testButton(_ title: String, id: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Font.hq(.subheadline).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .hqGlassButtonStyle()
        .disabled(!enabled)
        .accessibilityIdentifier(id)
    }

    // MARK: The status line

    @ViewBuilder private var statusLine: some View {
        let status = model.shownStatus
        let text = Text(status.text)
            .font(Font.hq(.subheadline))
            .foregroundStyle(Color.hqLabel)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("voice.diag.status")
        if status == .microphoneOff {
            let open = Button(PrivacySettingsLink.openTitle, action: model.openSystemSettings)
                .font(Font.hq(.subheadline).weight(.semibold))
                .buttonStyle(.borderless)
                .accessibilityIdentifier("voice.diag.open-settings")
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { text; open }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    text
                    Spacer(minLength: 0)
                    open
                }
            }
        } else {
            text.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Rows

    private func factRow(_ row: VoiceReport.Row) -> some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name).foregroundStyle(Color.hqLabel)
                    Text(row.value).foregroundStyle(Color.hqLabel2)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.name).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(row.value).foregroundStyle(Color.hqLabel2).multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.name)
        .accessibilityValue(row.value)
    }

    private func eventLine(_ event: VoiceEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(VoiceReport.time(event.at))
                .font(Font.hq(.footnote).monospacedDigit())
                .foregroundStyle(Color.hqLabel2)
            Text(event.text)
                .font(Font.hq(.footnote))
                .foregroundStyle(Color.hqLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
