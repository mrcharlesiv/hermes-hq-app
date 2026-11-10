// DEBUG-only launch hooks for live voice, Read Aloud, dictation and the voice pages (docs/spec/3x-talk.md §14.3;
// compiled out of Release). The simulator has no dependable microphone and this Mac must stay silent, so UI tests hear
// through a scripted stand-in microphone and speak through a muted or stand-in speaker:
//
// - `-HQDebugTalkFixture granted|undetermined|denied`   the stand-in microphone (simulator only)
// - `-HQDebugTalkScript "say:2;quiet;barge:1.5;barge-speaking:1;hold;meterfail;fail"`   what it hears, one step per take
//                                                       or per armed barge-in
// - `-HQDebugTalkSpeaker silent|fixture|audible`        silent (the DEBUG simulator default): the real speaker at
//                                                       volume 0; fixture: no audio objects, timing from the bytes;
//                                                       audible: real sound, for a person at the Mac only
// - `-HQDebugPhoneVoice fails`                         the iPhone's own voice fails too (§7.7's last rule)
// - `-HQDebugTalkClock <factor>`                       divides the 30 s, 120 s, 12 s and 60 s windows
// - `-HQDebugTalkInterruptAfter <s>`, `-HQDebugTalkInterruptReason interrupted|route-lost|reset|config|background`
//                                                       raises that system event after a conversation starts
// - `-HQDebugTalkIntroSeen YES|NO`, `-HQDebugReadRepliesAloud YES|NO`   preset the keys (Read Replies Aloud also sets a
//                                                                        conversation's Speak Replies)
// - `-HQDebugTalkListenHintSeen YES|NO`                 preset the bar's one-time "Go ahead…" hint
// - `-HQDebugTalkRoute airpods|headphones|car`          the bar's route reads as that external route
// - `-HQDebugResetVoice YES`                            also forgets the intro, Read Replies Aloud, Speak Replies and
//                                                       the Talk tip
// - `-HQDebugTalkProbe YES`                             an element `talk.debug` whose value is JSON (status, muted,
//                                                       conversations, keep-awake holds, session owner, speech, takes
//                                                       on disk, the last events)
// - `-HQDebugMemoryWarningAfter <s>`                    posts a memory warning
// - `-HQDebugTrayAudio <seconds>`                       a recording of that length lands in the tray of the first chat
//                                                       that opens (0: a file named .m4a that is not audio)
// - `-HQDebugSettingsScroll <pt>`                       where the `settings-root` shot scrolls the Settings list to
// - `-HQDebugTalkShot <state>` (with -HQDebugOpenBot)   shows one state for screenshots (the list is `shots` below),
//                                                       after `-HQDebugTalkShotDelay <s>` (default 1.2)

#if DEBUG
import UIKit

enum TalkDebugHooks {
    private static var defaults: UserDefaults { .standard }

    static let probe = UserDefaults.standard.bool(forKey: "HQDebugTalkProbe")
    /// The states `-HQDebugTalkShot` knows.
    static let shots = ["starting", "listening", "still", "muted", "reconnecting", "transcribing", "thinking", "speaking", "lost",
                        "problem", "problem-raw", "paused-silence", "paused-interrupted", "paused-background", "paused-route", "stopped",
                        "stopped-denied", "intro", "info", "ended", "tip", "circle", "read-preparing", "read-speaking", "pill", "pill-problem", "pill-paused", "pill-stopped",
                        "dictating", "dictation-transcribing", "dictation-empty", "dictation-failed", "dictation-denied",
                        "settings-root", "settings-voice", "settings-conversation", "settings-stt", "settings-tts", "settings-eleven",
                        "diag", "diag-recording", "diag-recorded", "diag-played", "diag-transcribed", "diag-denied", "diag-busy",
                        "audio-preview", "audio-preview-playing"]

    /// More states, added by the features that own them (the pill, dictation, Read Aloud, the settings pages).
    static var extraShots: [String: @MainActor (ChatViewController) -> Void] = [:]

    static func applyBeforeLaunch() {
        if defaults.bool(forKey: "HQDebugResetVoice") {
            for key in [TalkIntroSheet.seenKey, TalkController.readRepliesAloudKey, TalkController.readRepliesAloudGatewayKey,
                        TalkController.conversationSpeaksKey, MemoTips.key(.talk),
                        TalkBarView.listenHintKey] { defaults.removeObject(forKey: key) }
            TalkCaptureCore.emptyTakesFolder()
        }
        if defaults.object(forKey: "HQDebugTalkIntroSeen") != nil { TalkIntroSheet.seen = defaults.bool(forKey: "HQDebugTalkIntroSeen") }
        if defaults.object(forKey: "HQDebugTalkListenHintSeen") != nil { TalkBarView.listenHintSeen = defaults.bool(forKey: "HQDebugTalkListenHintSeen") }
        switch defaults.string(forKey: "HQDebugTalkRoute") {
        case "airpods": TalkRouteButton.debugRoute = (.other, "BluetoothA2DPOutput", "AirPods Pro")
        case "headphones": TalkRouteButton.debugRoute = (.headphones, "Headphones", "Headphones")
        case "car": TalkRouteButton.debugRoute = (.other, "CarAudio", "CarPlay")
        default: break
        }
        if defaults.object(forKey: "HQDebugReadRepliesAloud") != nil {
            TalkController.readsRepliesAloud = defaults.bool(forKey: "HQDebugReadRepliesAloud")
            // The UI tests' "speaks" is both switches: a conversation's own Speak Replies is on until switched off.
            TalkController.speaksInConversation = defaults.bool(forKey: "HQDebugReadRepliesAloud")
        }
        switch defaults.string(forKey: "HQDebugTalkSpeaker") {
        case "fixture": TalkSpeaker.shared.output = FixtureSpeechOutput()
        case "audible": EngineSpeechOutput.silent.withLock { $0 = false }
        case "silent": EngineSpeechOutput.silent.withLock { $0 = true }
        default: break
        }
        // §7.7: the iPhone's voice fails too, so a failing computer voice ends the reading with its reason (§7.6).
        if defaults.string(forKey: "HQDebugPhoneVoice") == "fails" {
            TalkSpeaker.shared.makePhoneRenderer = {
                let renderer = FixturePhoneSpeechRenderer()
                renderer.fails = true
                return renderer
            }
        }
        if defaults.object(forKey: "HQDebugTalkClock") != nil {
            let factor = defaults.double(forKey: "HQDebugTalkClock")
            if factor > 0 {
                TalkController.shared.clock = TalkClock(scale: factor)
                DictationController.shared.clockScale = factor
                FixtureDictationRecorder.scale = factor
            }
        }
        #if targetEnvironment(simulator)
        if let permission = defaults.string(forKey: "HQDebugTalkFixture"), ["granted", "undetermined", "denied"].contains(permission) {
            useFixtureMicrophone(permission: permission, script: defaults.string(forKey: "HQDebugTalkScript") ?? "")
        }
        #endif
        if defaults.object(forKey: "HQDebugMemoryWarningAfter") != nil {
            let seconds = max(0.1, defaults.double(forKey: "HQDebugMemoryWarningAfter"))
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                VoiceEvents.note("debug: memory warning")
                NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
            }
        }
        if defaults.object(forKey: "HQDebugTalkInterruptAfter") != nil {
            let seconds = max(0.1, defaults.double(forKey: "HQDebugTalkInterruptAfter"))
            let reason = defaults.string(forKey: "HQDebugTalkInterruptReason") ?? "interrupted"
            var armed = true
            interruptObserver = NotificationCenter.default.addObserver(forName: TalkController.didChange, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard armed, TalkController.shared.debugState?.micReady == true else { return }
                    armed = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { raise(reason) }
                }
            }
        }
    }

    private static var interruptObserver: (any NSObjectProtocol)?

    /// Runs `work` once the conversation's microphone is up (≤ 6 s).
    private static func whenListening(attempts: Int, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                if TalkController.shared.debugState?.micReady == true {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { work() } }
                } else if attempts > 0 {
                    whenListening(attempts: attempts - 1, work)
                }
            }
        }
    }

    static func useFixtureMicrophone(permission: String, script: String) {
        FixtureTalkCapture.permission = permission
        FixtureTalkCapture.script = TalkFixtureStep.parse(script)
        TalkController.shared.makeCapture = { FixtureTalkCapture(clock: $0) }
        // Dictation's stand-in microphone goes with it.
        FixtureDictationRecorder.permission = permission
        FixtureDictationRecorder.failure = defaults.string(forKey: "HQDebugDictationFail")
        DictationController.shared.makeRecorder = { FixtureDictationRecorder() }
        // Voice Diagnostics' test take is recorded with the same stand-in.
        VoiceDiagnosticsModel.makeCapture = { FixtureTalkCapture(clock: $0) }
        VoiceDiagnosticsModel.readPermission = {
            switch FixtureTalkCapture.permission {
            case "denied": .denied
            case "undetermined": .notAsked
            default: .allowed
            }
        }
    }

    private static func raise(_ reason: String) {
        let talk = TalkController.shared
        switch reason {
        case "route-lost": talk.debugInterrupt(.routeLost, detail: "debug: the route went away")
        case "reset": talk.debugInterrupt(.interrupted, detail: "iOS reset its audio services")
        case "config": talk.debugInterrupt(.routeLost, detail: "debug: the audio engine's configuration changed")
        case "background": talk.debugLeaveScreen()
        default: talk.debugInterrupt(.interrupted, detail: "interruption began (debug)")
        }
    }

    // MARK: The probe

    static func applyAfterLaunch(_ root: UIViewController) {
        guard probe else { return }
        let view = TalkProbeView()
        root.view.addSubview(view)
        view.start()
    }

    static var snapshot: [String: Any] {
        var json = TalkController.shared.debugSnapshot
        json.merge(ReadAloudCenter.shared.debugSnapshot) { _, new in new }
        json.merge(DictationController.shared.debugSnapshot) { _, new in new }
        json["readReplies"] = TalkController.readsRepliesAloud
        json["keepAwake"] = KeepAwake.count
        json["activity"] = TalkActivity.shared.debugShown?.phase ?? ""   // [talk-background] the Lock Screen's state
        json["owner"] = AudioSessionCoordinator.shared.owner?.rawValue ?? ""
        json["borrower"] = AudioSessionCoordinator.shared.borrower?.rawValue ?? ""
        switch TalkSpeaker.shared.state {
        case .idle: json["speech"] = "idle"
        case .preparing: json["speech"] = "preparing"
        case .speaking: json["speech"] = "speaking"
        }
        json["idleTimerOff"] = UIApplication.shared.isIdleTimerDisabled
        let takes = (try? FileManager.default.contentsOfDirectory(atPath: TalkCaptureCore.takesFolder.path)) ?? []
        json["takes"] = takes.count
        json["events"] = VoiceEvents.all.suffix(12).map(\.text)
        json["eventsTotal"] = VoiceEvents.total
        json["copied"] = VoiceClipboard.last
        json["pill"] = TalkAwayPill.isShowing            // what the Bots list's Undo pill asks (§2.5)
        if let fixture = TalkSpeaker.shared.output as? FixtureSpeechOutput {
            json["spokenBytes"] = fixture.scheduledBytes
            json["clips"] = fixture.clips
            json["speechStops"] = fixture.stops
        }
        return json
    }

    // MARK: Audio in the tray

    /// `-HQDebugTrayAudio <seconds>`: a recording of that length lands in the open chat's tray, through the pickers'
    /// own import code.
    static func trayAudioIfAsked(_ chat: ChatViewController) {
        guard defaults.object(forKey: "HQDebugTrayAudio") != nil else { return }
        let seconds = defaults.double(forKey: "HQDebugTrayAudio")       // 0 or less: a file that is not audio
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak chat] in
            MainActor.assumeIsolated { if let chat { trayAudio(chat, seconds: seconds) } }
        }
    }

    private static var trayAudioDone = false

    private static func trayAudio(_ chat: ChatViewController, seconds: Double) {
        guard !trayAudioDone else { return }
        trayAudioDone = true
        let folder = FileManager.default.temporaryDirectory.appending(path: "HQNDebugTrayAudio-" + UUID().uuidString, directoryHint: .isDirectory)
        let file = folder.appending(path: "Field recording.m4a")
        Task { [weak chat] in
            let made = await Task.detached {
                if seconds > 0 { return FixtureDictationRecorder.writeTone(file, seconds: seconds) }
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return (try? Data(repeating: 0x2E, count: 2_048).write(to: file)) != nil
            }.value
            guard made, let chat else { return }
            chat.attachments?.importFiles([file])
        }
    }

    private static func find(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for child in view.subviews { if let found = find(identifier, in: child) { return found } }
        return nil
    }

    // MARK: Settings › Voice and Voice Diagnostics

    private static func showSettings(_ shot: String, from chat: ChatViewController) {
        guard let model = TalkWiring.model else { return }
        func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
        }
        SettingsScreens.presentSettings(from: chat, services: model) { navigation in
            guard let root = navigation.viewControllers.first as? SettingsRootController else { return }
            let router = root.router
            let pages = VoiceSettingsCatalog.section.pages
            @MainActor func page(_ id: String) -> UIViewController? {
                guard let page = pages.first(where: { $0.id == id }) else { return nil }
                return VoiceSettingsScreens.makePage(page, router: router)
            }
            let section = VoiceSettingsScreens.makeSection(router: router)
            switch shot {
            case "settings-root":
                // The Voice row sits below the fold: the list is scrolled to it.
                after(1.0) {
                    guard let list = firstScroll(in: root.view) else { return }
                    let wanted = CGFloat(defaults.object(forKey: "HQDebugSettingsScroll") != nil ? defaults.double(forKey: "HQDebugSettingsScroll") : 700)
                    let most = max(0, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
                    list.setContentOffset(CGPoint(x: 0, y: min(wanted, most)), animated: false)
                }
            case "settings-voice": router.push([section])
            case "settings-conversation": router.push([section, page("conversation")].compactMap { $0 })
            case "settings-stt": router.push([section, page("transcription")].compactMap { $0 })
            case "settings-tts": router.push([section, page("speech")].compactMap { $0 })
            case "settings-eleven":
                guard let store = router.gatewaySettings?.configStore else { return }
                router.push([section, page("speech")].compactMap { $0 })
                after(1.5) {
                    router.push(SettingsPageController(title: "ElevenLabs Voice", ElevenLabsVoicePage(store: store, services: router.services)))
                }
            default:
                if shot == "diag-denied" { FixtureTalkCapture.permission = "denied" }
                if shot == "diag-recording" { VoiceDiagnosticsModel.takeSeconds = 600 }
                router.push([section, page("conversation")].compactMap { $0 })
                after(0.9) {
                    VoiceSettingsScreens.openDiagnostics(router: router)
                    after(1.2) {
                        guard let diagnostics = VoiceDiagnosticsModel.current else { return }
                        switch shot {
                        case "diag-recording", "diag-recorded", "diag-denied": diagnostics.record()
                        case "diag-played":
                            diagnostics.record()
                            after(4.2) { diagnostics.play() }
                        case "diag-transcribed":
                            diagnostics.record()
                            after(4.2) { diagnostics.transcribe() }
                        case "diag-busy":
                            Task {
                                AudioSessionCoordinator.shared.simulatedOwners.insert(.memoRecording)
                                try? await AudioSessionCoordinator.shared.acquire(.memoRecording)
                                diagnostics.refresh()
                            }
                        default: break
                        }
                    }
                }
            }
        }
    }

    private static func firstScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.bounds.height > 300 { return scroll }
        for child in view.subviews { if let found = firstScroll(in: child) { return found } }
        return nil
    }

    // MARK: Screenshots

    static func chatShown(_ chat: ChatViewController) {
        trayAudioIfAsked(chat)
        guard let shot = defaults.string(forKey: "HQDebugTalkShot") else { return }
        let delay = defaults.object(forKey: "HQDebugTalkShotDelay") != nil ? defaults.double(forKey: "HQDebugTalkShotDelay") : 1.2
        func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
        }
        if shot != "tip" {
            // Every other state is shown without the Talk tip over it.
            MemoTips.finish(.talk)
            chat.voice.memoDismissTip()
        }
        if shot == "read-preparing" || shot == "read-speaking" {
            // Read Aloud on the newest reply, held in one state.
            after(delay) {
                guard let reply = chat.session.messages.last(where: { $0.role == .assistant }) else { return }
                ReadAloudCenter.shared.debugShow(shot == "read-preparing" ? .preparing(reply.id) : .speaking(reply.id), scope: chat.voice.scope)
            }
            return
        }
        if shot.hasPrefix("settings-") || shot.hasPrefix("diag") {
            after(delay) { showSettings(shot, from: chat) }
            return
        }
        if shot.hasPrefix("audio-preview") {
            // An audio file in the tray, opened in its preview sheet (silent on the Simulator).
            after(delay) {
                trayAudio(chat, seconds: 12)
                after(2.2) {
                    guard let tile = find("composer.tray.tile.0", in: chat.view) as? UIControl else { return }
                    tile.sendActions(for: .touchUpInside)
                    if shot == "audio-preview-playing" {
                        after(1.6) {
                            let top = chat.presentedViewController as? UINavigationController
                            (top?.viewControllers.first as? AudioPreviewController)?.debugPlay(from: 0.35)
                        }
                    }
                }
            }
            return
        }
        if shot.hasPrefix("dictat") {
            let scope = chat.voice.scope
            switch shot {
            case "dictating", "dictation-transcribing":
                useFixtureMicrophone(permission: "granted", script: "")
                DictationController.shared.holdsLeases = false
                if shot == "dictation-transcribing" {
                    DictationController.shared.transcribe = { _, _ in
                        try? await Task.sleep(for: .seconds(600))
                        return .success("")
                    }
                }
                after(delay) {
                    chat.voice.dictation.begin()
                    if shot == "dictation-transcribing" { after(1.6) { DictationController.shared.done() } }
                }
            case "dictation-empty":
                after(delay) { MemoController.shared.post(DictationController.noSpeech, scope: scope) }
            case "dictation-failed":
                after(delay) {
                    let failure = VoiceFailure(reason: "Couldn’t understand that. Check Speech to Text in Settings › Voice.",
                                               detail: "HTTP 500: Transcription failed")
                    MemoController.shared.post(DictationController.transcriptionFailed(failure), scope: scope)
                }
            default:
                after(delay) { MemoController.shared.post(DictationController.microphoneOff(), scope: scope) }
            }
            return
        }
        if let extra = extraShots[shot] {
            after(delay) { extra(chat) }
            return
        }
        guard shots.contains(shot) else { return }
        let talk = TalkController.shared
        let host = chat.voice.talk
        guard let turns = chat.session as? ChatVoiceTurns else { return }
        let name = host.name, app = MemoNotice.appName
        switch shot {
        case "intro":
            TalkIntroSheet.seen = false
            after(delay) { chat.beginTalk() }
            return
        case "info":
            after(delay) { host.showHowVoiceWorks() }
            return
        case "tip":
            after(delay) { chat.voice.memoShowTip(.talk) }
            return
        case "circle":
            return
        case "ended":
            after(delay) { talk.debugEnded(scope: host.scope, seconds: 134) }
            return
        case "paused-silence":
            after(delay) { talk.debugKeep(TalkDockState.pausedNotice(.silence, name: name, app: app), chat: turns, name: name) }
            return
        case "paused-interrupted":
            after(delay) {
                talk.debugKeep(TalkDockState.pausedNotice(.interrupted, name: name, detail: "interruption began (reason 1)", app: app), chat: turns, name: name)
            }
            return
        case "paused-background":
            after(delay) { talk.debugKeep(TalkDockState.pausedNotice(.background, name: name, app: app), chat: turns, name: name) }
            return
        case "paused-route":
            after(delay) {
                talk.debugKeep(TalkDockState.pausedNotice(.routeLost, name: name, detail: "old device unavailable: AirPods Pro", app: app), chat: turns, name: name)
            }
            return
        case "stopped":
            after(delay) {
                talk.debugKeep(TalkDockState.stoppedNotice(title: "Voice Transcription Failed", message: "Couldn’t understand that. Check Speech to Text in Settings › Voice.",
                                                          detail: "HTTP 500: Transcription failed"), chat: turns, name: name)
            }
            return
        case "pill-paused":
            after(delay) {
                talk.debugKeep(TalkDockState.pausedNotice(.background, name: name, app: app), chat: turns, name: name)
                after(0.6) { chat.navigationController?.popViewController(animated: true) }
            }
            return
        case "pill-stopped":
            after(delay) {
                talk.debugKeep(TalkDockState.stoppedNotice(title: "Voice Transcription Failed", message: "Couldn’t understand that. Check Speech to Text in Settings › Voice.",
                                                          detail: nil), chat: turns, name: name)
                after(0.6) { chat.navigationController?.popViewController(animated: true) }
            }
            return
        case "stopped-denied":
            after(delay) { MemoController.shared.post(TalkWiring.startNotice(.microphoneDenied, name: name), scope: host.scope) }
            return
        default: break
        }
        // A live dock, frozen in one state: the stand-in microphone holds a take open so nothing moves by itself.
        TalkIntroSheet.seen = true
        useFixtureMicrophone(permission: "granted", script: "hold")
        TalkSpeaker.shared.output = FixtureSpeechOutput()
        talk.holdsLeases = false
        after(delay) {
            chat.beginTalk()
            whenListening(attempts: 60) {
                talk.debugFreeze { state in
                    state.problem = nil
                    state.muted = false
                    state.connectionOpen = true
                    state.lostSpeech = false
                    state.silenceState = .ok
                    state.listened = true
                    state.status = .listening
                    switch shot {
                    case "starting": state.status = .idle; state.listened = false
                    case "still": state.silenceState = .still
                    case "muted": state.muted = true
                    case "reconnecting": state.connectionOpen = false
                    case "transcribing": state.status = .transcribing
                    case "thinking": state.status = .thinking
                    case "speaking": state.status = .speaking
                    case "lost": state.lostSpeech = true
                    case "problem": state.problem = "Didn’t catch that. Try again."
                    case "problem-raw":
                        // Build 305's speech failure: a provider's raw error with its address and tokens.
                        let raw = "TTS chunk 1 failed (edge): TTS generation failed (edge): 403, message='Invalid response status', "
                            + "url='wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=0000&ConnectionId=1111'"
                        state.problem = TalkDockState.problemLine("Voice Playback Failed", reason: raw)
                        state.problemDetail = TalkDockState.problemDetail("Voice Playback Failed", reason: raw, detail: nil)
                    case "pill-problem": state.status = .thinking
                    default: break
                    }
                }
                talk.debugLevel(shot == "speaking" ? 0.7 : 0.45)
                if shot.hasPrefix("pill") {
                    // The pill: the same conversation, seen from the list.
                    after(0.4) {
                        chat.navigationController?.popViewController(animated: true)
                        if shot == "pill-problem" { after(0.8) { talk.debugProblemAway() } }
                    }
                }
            }
        }
    }
}

/// `talk.debug`: one accessibility element whose value is the snapshot as JSON, refreshed four times a second.
final class TalkProbeView: UIView {
    private var timer: Timer?

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        isAccessibilityElement = true
        accessibilityIdentifier = "talk.debug"
        accessibilityTraits = .staticText
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func start() {
        refresh()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        guard let data = try? JSONSerialization.data(withJSONObject: TalkDebugHooks.snapshot, options: [.sortedKeys]) else { return }
        accessibilityValue = String(decoding: data, as: UTF8.self)
        superview?.bringSubviewToFront(self)
    }
}
#endif
