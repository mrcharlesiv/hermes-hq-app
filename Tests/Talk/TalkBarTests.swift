// The conversation bar (docs/spec/3x-talk.md §6.1, T6): the desktop's voice controls in the composer's row, Speak
// Replies while Talk runs, Read Replies Aloud's default from the gateway's `voice.auto_tts`, and one turn's failure on
// one short line with its whole text under Copy Details (build 305's 15 orange lines of a speech service's address).

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@Suite("Talk bar")
struct TalkBarStateTests {
    private func view(_ status: TalkStatus, muted: Bool = false, reconnecting: Bool = false, listened: Bool = true) -> TalkDockView {
        TalkDockState.view(status: status, muted: muted, reconnecting: reconnecting, lostSpeech: false, silence: .ok,
                           listened: listened, name: "Ivy")
    }

    @Test("Stop shows only while it does something; Mute is mic, or mic.slash when muted")
    func controlsPerState() {
        var bar = TalkDockState.bar(view(.listening), muted: false)
        #expect(bar.showsCenter && bar.centerTitle == "Stop" && bar.centerLabel == "Stop Listening and Send" && bar.centerSymbol == "stop.fill")
        #expect(bar.muteSymbol == "mic" && bar.muteTitle == "Mute" && bar.muteLabel == "Mute Microphone")
        bar = TalkDockState.bar(view(.thinking), muted: false)
        #expect(bar.showsCenter && bar.centerTitle == "Stop" && bar.centerLabel == "Stop")
        bar = TalkDockState.bar(view(.speaking), muted: false)
        #expect(bar.showsCenter && bar.centerTitle == "Interrupt" && bar.centerSymbol == "hand.raised.fill")
        bar = TalkDockState.bar(view(.transcribing), muted: false)
        #expect(!bar.showsCenter)
        bar = TalkDockState.bar(view(.listening, reconnecting: true), muted: false)
        #expect(!bar.showsCenter)
        bar = TalkDockState.bar(view(.idle, listened: false), muted: false)
        #expect(!bar.showsCenter)
        bar = TalkDockState.bar(view(.listening, muted: true), muted: true)
        #expect(!bar.showsCenter && bar.muteSymbol == "mic.slash" && bar.muteTitle == "Unmute" && bar.muteLabel == "Unmute Microphone")
    }

    @Test("Speak Replies: the same speaker glyph on and off, never a slash")
    func speakRepliesGlyph() {
        #expect(TalkDockState.speakRepliesSymbol(true) == "speaker.wave.2.fill")
        #expect(TalkDockState.speakRepliesSymbol(false) == "speaker.wave.2")
        #expect(!TalkDockState.speakRepliesSymbol(false).contains("slash") && !TalkDockState.speakRepliesSymbol(true).contains("slash"))
        #expect(TalkDockState.speakRepliesLabel == "Speak Replies")
        #expect(TalkDockState.speakRepliesValue(true) == "On" && TalkDockState.speakRepliesValue(false) == "Off")
    }

    @Test("No notice line in a normal state; one for a failure or speech dropped while reconnecting")
    func noticeOnlyForAProblem() {
        for status in [TalkStatus.idle, .listening, .transcribing, .thinking, .speaking] {
            #expect(TalkDockState.barNotice(view(status), problem: nil) == nil, "\(status)")
        }
        #expect(TalkDockState.barNotice(view(.listening, muted: true), problem: nil) == nil)
        #expect(TalkDockState.barNotice(view(.listening, reconnecting: true), problem: nil) == nil)
        let still = TalkDockState.view(status: .listening, muted: false, reconnecting: false, lostSpeech: false, silence: .still, listened: true, name: "Ivy")
        #expect(TalkDockState.barNotice(still, problem: nil) == nil)
        #expect(TalkDockState.barNotice(view(.thinking), problem: "Voice Playback Failed.") == "Voice Playback Failed.")
        #expect(TalkDockState.barNotice(view(.thinking), problem: "") == nil)
        let lost = TalkDockState.view(status: .listening, muted: false, reconnecting: false, lostSpeech: true, silence: .ok, listened: true, name: "Ivy")
        #expect(TalkDockState.barNotice(lost, problem: nil) == "Didn’t send what you said while reconnecting. Say it again.")
    }

    @Test("The hint is the status for the first listening turn ever, then plain Listening")
    func hintOnce() {
        var hint = TalkListenHint(seen: false)
        var stored = hint.observe(.starting)
        #expect(!stored && !hint.showing)
        stored = hint.observe(.listening)
        #expect(!stored && hint.showing)
        #expect(TalkDockState.barStatus(view(.listening), firstHint: hint.showing) == "Go ahead. It sends when you pause.")
        stored = hint.observe(.listening)
        #expect(!stored && hint.showing, "still the first turn")
        stored = hint.observe(.transcribing)
        #expect(stored, "the first turn ended: store it")
        #expect(hint.seen && !hint.showing)
        stored = hint.observe(.listening)
        #expect(!stored && !hint.showing)
        #expect(TalkDockState.barStatus(view(.listening), firstHint: hint.showing) == "Listening")
        // Seen in an earlier launch: never shown.
        var later = TalkListenHint(seen: true)
        stored = later.observe(.listening)
        #expect(!stored && !later.showing)
        // The bar went away while it showed (End during the first turn): seen.
        var ended = TalkListenHint(seen: false)
        _ = ended.observe(.listening)
        stored = ended.finish()
        #expect(stored && ended.seen)
        stored = ended.finish()
        #expect(!stored, "only once")
        // Other states never show it.
        #expect(TalkDockState.barStatus(view(.thinking), firstHint: true) == "Thinking…")
        #expect(TalkDockState.barStatus(view(.speaking), firstHint: true) == "Speaking", "the name is on the line under it")
        #expect(view(.speaking).title == "Ivy is speaking", "VoiceOver still hears the whole title")
        #expect(TalkDockState.barDetail(name: "Ivy", elapsed: "0:03") == "Ivy · 0:03")
    }

    @Test("The speaker button: loudspeaker on or off on the phone's own route, the route's glyph and its picker otherwise")
    func speakerButton() {
        for kind in [TalkRouteKind.none, .receiver, .speaker] {
            #expect(TalkDockState.speakerButton(kind: kind, portType: "Speaker", portName: nil, loudspeaker: true)
                == TalkSpeakerButton(symbol: "speaker.wave.2.fill", on: true, picker: false, label: "Speaker", value: "On"))
            #expect(TalkDockState.speakerButton(kind: kind, portType: "Receiver", portName: nil, loudspeaker: false)
                == TalkSpeakerButton(symbol: "speaker.wave.2", on: false, picker: false, label: "Speaker", value: "Off"))
        }
        #expect(TalkDockState.speakerButton(kind: .other, portType: "BluetoothA2DPOutput", portName: "AirPods Pro", loudspeaker: true)
            == TalkSpeakerButton(symbol: "airpods.pro", on: false, picker: true, label: "Audio Output", value: "AirPods Pro"))
        #expect(TalkDockState.speakerButton(kind: .headphones, portType: "Headphones", portName: "Headphones", loudspeaker: true)
            == TalkSpeakerButton(symbol: "headphones", on: false, picker: true, label: "Audio Output", value: "Headphones"))
        #expect(TalkDockState.speakerButton(kind: .other, portType: "CarAudio", portName: nil, loudspeaker: true).symbol == "car.fill")
    }

    @Test("The route shows in the row only when it is external; its glyph follows the port")
    func routeOnlyWhenExternal() {
        #expect(!TalkDockState.routeIsExternal(.none) && !TalkDockState.routeIsExternal(.receiver) && !TalkDockState.routeIsExternal(.speaker))
        #expect(TalkDockState.routeIsExternal(.headphones) && TalkDockState.routeIsExternal(.other))
        #expect(TalkDockState.routeSymbol(portType: "BluetoothA2DPOutput", name: "Alex’s AirPods Pro") == "airpods.pro")
        #expect(TalkDockState.routeSymbol(portType: "BluetoothHFP", name: "AirPods") == "airpods")
        #expect(TalkDockState.routeSymbol(portType: "BluetoothA2DPOutput", name: "AirPods Max") == "airpods.max")
        #expect(TalkDockState.routeSymbol(portType: "BluetoothLE", name: "Beats") == "headphones")
        #expect(TalkDockState.routeSymbol(portType: "Headphones", name: nil) == "headphones")
        #expect(TalkDockState.routeSymbol(portType: "CarAudio", name: "CarPlay") == "car.fill")
        #expect(TalkDockState.routeSymbol(portType: "AirPlay", name: "Kitchen") == "airplayaudio")
        let choices = TalkDockState.routeChoices(inputs: [("hfp", "BluetoothHFP", "AirPods Pro"), ("mic", "MicrophoneBuiltIn", "iPhone Microphone")],
                                                 current: "hfp")
        #expect(choices == [TalkRouteChoice(uid: "mic", title: "Speaker", symbol: "speaker.wave.2", current: false),
                            TalkRouteChoice(uid: "hfp", title: "AirPods Pro", symbol: "airpods.pro", current: true)])
        #expect(TalkDockState.routeChoices(inputs: [], current: nil).isEmpty)
    }

    @Test("T6: the gateway's auto_tts until the person chooses; then the choice wins; nothing known is off")
    func readRepliesDefault() {
        #expect(!TalkDockState.readsRepliesAloud(chosen: nil, gateway: nil))
        #expect(TalkDockState.readsRepliesAloud(chosen: nil, gateway: true))
        #expect(!TalkDockState.readsRepliesAloud(chosen: nil, gateway: false))
        #expect(!TalkDockState.readsRepliesAloud(chosen: false, gateway: true))
        #expect(TalkDockState.readsRepliesAloud(chosen: true, gateway: false))
    }

    @Test("voice.auto_tts is read only when it is a boolean")
    func autoTTSParsed() throws {
        func parse(_ json: String) throws -> TalkConfig { TalkConfig(config: try JSONValue.parse(Data(json.utf8))) }
        #expect(try parse(#"{"voice":{"auto_tts":true}}"#).autoTTS == true)
        #expect(try parse(#"{"voice":{"auto_tts":false}}"#).autoTTS == false)
        #expect(try parse(#"{"voice":{}}"#).autoTTS == nil)
        #expect(try parse(#"{"voice":{"auto_tts":"yes"}}"#).autoTTS == nil)
        #expect(TalkConfig().autoTTS == nil)
    }

    /// Build 305: what the owner's phone showed in orange, word for word apart from the tokens.
    private static let raw = "TTS chunk 1 failed (edge): TTS generation failed (edge): 403, message='Invalid response status', "
        + "url='wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4"
        + "&ConnectionId=7c1e9a0b2f3d4e5f8a9b0c1d2e3f4a5b&Sec-MS-GEC=B2C9D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3'"

    @Test("A raw provider failure is one short line; Copy Details has its whole text without the address or tokens")
    func rawFailureIsShort() {
        #expect(TalkDockState.shortReason(Self.raw) == nil)
        #expect(TalkDockState.problemLine("Voice Playback Failed", reason: Self.raw) == "Voice Playback Failed.")
        #expect(TalkDockState.problemLine("Voice Playback Failed", reason: "The gateway didn’t answer.") == "Voice Playback Failed. The gateway didn’t answer.")
        #expect(TalkDockState.shortReason("two\nlines") == nil)
        #expect(TalkDockState.shortReason(String(repeating: "a ", count: 100)) == nil)
        let copied = TalkDockState.problemDetail("Voice Playback Failed", reason: Self.raw, detail: "HTTP 403")
        #expect(copied.hasPrefix("Voice Playback Failed. TTS chunk 1 failed (edge)") && copied.hasSuffix("\nHTTP 403"))
        #expect(copied.contains("403, message='Invalid response status'"))
        for secret in ["wss://", "speech.platform.bing.com", "TrustedClientToken", "6A5AA1D4EAFF4E9FB37E23D68491D6F4", "Sec-MS-GEC"] {
            #expect(!copied.contains(secret), "\(secret)")
        }
        // A stopped notice keeps a plain reason as its message, and carries a raw one only in its detail.
        #expect(TalkDockState.noticeDetail(reason: "No speech provider", detail: "400") == "400")
        #expect(TalkDockState.noticeDetail(reason: "No speech provider", detail: nil) == nil)
        let detail = TalkDockState.noticeDetail(reason: Self.raw, detail: nil) ?? ""
        #expect(detail.contains("TTS chunk 1 failed") && !detail.contains("wss://"))
    }

    @Test("Copy Details adds the recent voice events, so a notice with no detail of its own still says what happened")
    func copyWithEvents() {
        let zone = TimeZone(identifier: "UTC")!
        let at = Date(timeIntervalSince1970: 3600 * 10 + 61)
        let notice = TalkDockState.stoppedNotice(title: "", message: String(format: TalkLoop.meterFailure, "Hermes HQ"), detail: nil)
        let text = TalkDockState.copyText(TalkDockState.noticeText(notice),
                                          events: [VoiceEvent(at: at, text: "take ended: no level"), VoiceEvent(at: at, text: "conversation stopped")], zone: zone)
        #expect(text == "Voice Stopped\nThe microphone isn’t giving a level, so Hermes HQ can’t tell when you stop talking.\n"
                + "Recent voice events:\n  10:01:01  take ended: no level\n  10:01:01  conversation stopped")
        #expect(TalkDockState.copyText("only", events: []) == "only")
    }

    @Test("Long gateway failures: the loop's line is short, its detail whole; a third transcription failure stops with it")
    func loopKeepsFailuresShort() {
        var loop = LoopHarness()
        loop.listening()
        loop.say("hello")
        loop.send(loop.reply("Here is the answer in words.", pending: false))
        loop.send(.turnRunning(false))
        loop.send(.speechFailed(reason: Self.raw, fatal: false))
        #expect(loop.state.problem == "Voice Playback Failed.")
        #expect(loop.state.problemDetail?.contains("403, message='Invalid response status'") == true)
        #expect(loop.state.problemDetail?.contains("wss://") == false)

        var stops = LoopHarness()
        stops.listening()
        for _ in 1...3 {
            stops.send(.takeEnded(file: stops.file, heardSpeech: true, meterFailed: false, ms: 2000))
            stops.send(.transcribeFailed(reason: Self.raw, detail: nil))
        }
        guard case .stopped(let title, let message, let detail)? = stops.ends.last else { Issue.record("no stop"); return }
        #expect(title == "Voice Transcription Failed" && message == "The computer running Hermes couldn’t turn speech into text.")
        #expect(detail?.contains("TTS chunk 1 failed") == true && detail?.contains("TrustedClientToken") == false)
    }

    @Test("Speak Replies switched off mid-reply: the voice stops, the turn carries on as text")
    func speakRepliesOffMidReply() {
        var loop = LoopHarness()
        loop.listening()
        loop.say("hello")
        loop.send(loop.reply("Here is a long answer.", pending: true))
        loop.send(.speechStarted)
        #expect(loop.state.status == .speaking)
        let effects = loop.send(.speaksReplies(false))
        #expect(effects.contains(.stopSpeech) && !effects.contains(.stopTurn))
        #expect(loop.state.status == .thinking && !loop.state.speaksReplies)
        // The rest of the reply is not spoken; the turn's end listens again.
        #expect(loop.send(loop.reply("Here is a long answer, finished.", pending: false)).isEmpty)
        #expect(loop.send(.turnRunning(false)).contains(.beginTake))
        #expect(loop.state.status == .listening)

        // Switched on while the bot thinks: the reply is spoken.
        var on = LoopHarness(speaks: false)
        on.listening()
        on.say("hello")
        #expect(on.send(.speaksReplies(true)).isEmpty)
        #expect(on.send(on.reply("Spoken now.", pending: false)).contains(.openSpeech(messageId: "m1")))
    }
}

@Suite("Talk bar: Read Replies Aloud", .serialized)
@MainActor
struct TalkReadRepliesDefaultTests {
    /// The two keys as they were, put back after each test (the test host is the app).
    private func preserving(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let keys = [TalkController.readRepliesAloudKey, TalkController.readRepliesAloudGatewayKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        body()
        for (key, value) in zip(keys, saved) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    @Test func followsTheGatewayUntilChosenAnywhere() {
        preserving {
            var posts = 0
            let observer = NotificationCenter.default.addObserver(forName: TalkController.readRepliesAloudChanged, object: nil, queue: nil) { _ in posts += 1 }
            defer { NotificationCenter.default.removeObserver(observer) }
            #expect(!TalkController.readsRepliesAloud && !TalkController.readRepliesAloudChosen)
            var config = TalkConfig()
            TalkController.gatewayVoiceRead(config)                  // no auto_tts in the answer: nothing changes
            #expect(!TalkController.readsRepliesAloud && posts == 0)
            config.autoTTS = true
            TalkController.gatewayVoiceRead(config)
            #expect(TalkController.readsRepliesAloud && posts == 1, "the gateway's auto_tts is the default")
            TalkController.gatewayVoiceRead(config)
            #expect(posts == 1, "an unchanged default posts nothing")
            // The person switches it (the bar, the voice options, Settings all set this): their choice wins from now on.
            TalkController.readsRepliesAloud = false
            #expect(!TalkController.readsRepliesAloud && TalkController.readRepliesAloudChosen && posts == 2)
            TalkController.gatewayVoiceRead(config)
            #expect(!TalkController.readsRepliesAloud && posts == 2)
            config.autoTTS = false
            TalkController.gatewayVoiceRead(config)
            TalkController.readsRepliesAloud = true
            #expect(TalkController.readsRepliesAloud)
        }
    }

    @Test func choosingTheSameValueStillCounts() {
        preserving {
            var config = TalkConfig()
            config.autoTTS = false
            TalkController.gatewayVoiceRead(config)
            TalkController.readsRepliesAloud = false                  // what the default already was
            #expect(TalkController.readRepliesAloudChosen)
            config.autoTTS = true
            TalkController.gatewayVoiceRead(config)
            #expect(!TalkController.readsRepliesAloud, "the choice outranks a later gateway default")
        }
    }
}

@Suite("Talk bar: layout", .serialized)
@MainActor
struct TalkBarLayoutTests {
    private func view(_ status: TalkStatus, muted: Bool = false) -> TalkDockView {
        TalkDockState.view(status: status, muted: muted, reconnecting: false, lostSpeech: false, silence: .ok, listened: true, name: "Inbox")
    }

    /// Every visible control and label lies inside the bar: nothing runs off it. Nil, or the first one outside.
    private func outside(_ bar: UIView) -> String? {
        func walk(_ view: UIView) -> String? {
            // The system route picker's own button is a 44 pt touch area over the route's glyph, larger by design.
            for sub in view.subviews where !sub.isHidden && sub.alpha > 0.01 && !NSStringFromClass(type(of: sub)).contains("RoutePicker") {
                if sub is UIControl || sub is UILabel {
                    let frame = sub.convert(sub.bounds, to: bar)
                    if frame.minX < -0.5 || frame.maxX > bar.bounds.width + 0.5 || frame.minY < -0.5 || frame.maxY > bar.bounds.height + 0.5 {
                        return "\(type(of: sub)) \(sub.accessibilityIdentifier ?? "") \(frame) in \(bar.bounds)"
                    }
                }
                if let found = walk(sub) { return found }
            }
            return nil
        }
        return walk(bar)
    }

    private func laidOut(_ bar: TalkBarView, width: CGFloat) {
        let height = bar.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
                                                 verticalFittingPriority: .fittingSizeLevel).height
        bar.frame = CGRect(x: 0, y: 0, width: width, height: height)
        bar.layoutIfNeeded()
        let again = bar.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
                                                verticalFittingPriority: .fittingSizeLevel).height
        bar.frame.size.height = again
        bar.layoutIfNeeded()
    }

    /// The test host's UserDefaults and theme, put back after each test.
    private func preserving(desktop: Bool = false, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: TalkBarView.listenHintKey)
        var state = ThemeTable.current.state
        state.desktopLook = desktop
        state.desktopComposer = .box   // [desktop-composer] the bar takes the box's place only with Text Box › Desktop
        TalkBarView.listenHintSeen = true
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(state)) { body() }
        if let saved { defaults.set(saved, forKey: TalkBarView.listenHintKey) } else { defaults.removeObject(forKey: TalkBarView.listenHintKey) }
    }

    /// Screen widths 320, 375 (SE), 402 (17 Pro) and 440 (Pro Max), less the composer's 26 pt sides.
    private static let widths: [CGFloat] = [320, 375, 402, 440].map { $0 - 2 * 26 }   // ChatMetrics.composerSideDown, standard look

    @Test(arguments: [false, true])
    func controlsPerStateAndNothingOutside(desktop: Bool) {
        preserving(desktop: desktop) {
            let bar = TalkBarView(name: "Inbox")
            for (status, muted, center) in [(TalkStatus.listening, false, true), (.thinking, false, true), (.speaking, false, true),
                                            (.transcribing, false, false), (.listening, true, false)] {
                bar.render(view(status, muted: muted), muted: muted, problem: nil, elapsed: 82)
                for width in Self.widths {
                    laidOut(bar, width: width)
                    #expect(bar.debugControls.center == center, "\(status) muted \(muted)")
                    #expect(!bar.debugControls.copy && bar.debugControls.speak)
                    #expect(!bar.debugStripShown, "no second box in a normal state (\(status))")
                    #expect(!bar.debugControls.stacked || width < 300, "one row at \(width)")
                    #expect(outside(bar) == nil, "\(status) at \(width)")
                }
            }
            bar.render(view(.listening), muted: false, problem: "Voice Playback Failed.", elapsed: 82)
            laidOut(bar, width: Self.widths[1])
            #expect(bar.debugStripShown && bar.debugControls.copy, "a failure shows its line, with Copy Details")
            #expect(outside(bar) == nil)
            bar.render(view(.thinking), muted: false, problem: nil, elapsed: 83)
            laidOut(bar, width: Self.widths[1])
            #expect(!bar.debugStripShown, "and the line goes with the next state")
        }
    }

    /// End lies wholly inside the box with the box's inner padding on its three outer sides, and its corners are
    /// concentric with the box's (the owner's build-308 screenshot: End past the box's right border).
    @Test(arguments: [false, true])
    func endInsideTheBox(desktop: Bool) {
        preserving(desktop: desktop) {
            let bar = TalkBarView(name: "A Bot With A Very Long Name Indeed")
            for status in [TalkStatus.listening, .thinking, .speaking, .transcribing] {
                bar.render(view(status), muted: false, problem: nil, elapsed: 3723)
                for width in Self.widths {
                    laidOut(bar, width: width)
                    let (box, end, boxRadius, endRadius) = bar.debugEnd
                    let inset = bar.debugBoxInset
                    #expect(box.contains(end), "End \(end) in box \(box) at \(width)")
                    #expect(end.minX >= -0.5 && end.maxX <= width + 0.5, "End inside the bar's own frame at \(width)")
                    #expect(abs((box.maxX - end.maxX) - inset) < 0.5, "trailing padding \(box.maxX - end.maxX) at \(width)")
                    #expect(abs((box.maxY - end.maxY) - inset) < 0.5, "bottom padding at \(width)")
                    if !bar.debugControls.stacked {
                        #expect(abs((end.minY - box.minY) - inset) < 0.5, "top padding at \(width)")
                    }
                    if desktop {
                        #expect(boxRadius == HQShape.desktopRadius(.field) && endRadius <= boxRadius, "square-ish corners in the Desktop Look")
                    } else {
                        #expect(abs(endRadius - (boxRadius - inset)) < 0.5, "concentric: \(endRadius) = \(boxRadius) − \(inset)")
                    }
                }
            }
        }
    }

    @Test func theHintIsTheFirstListeningTurnsStatusOnce() {
        preserving {
            TalkBarView.listenHintSeen = false
            let bar = TalkBarView(name: "Inbox")
            bar.render(view(.listening), muted: false, problem: nil, elapsed: 1)
            laidOut(bar, width: Self.widths[2])
            #expect(bar.debugStatus == "Go ahead. It sends when you pause.")
            #expect(!bar.debugStripShown, "in the row, not on a line of its own")
            #expect(outside(bar) == nil)
            #expect(!TalkBarView.listenHintSeen)
            bar.render(view(.transcribing), muted: false, problem: nil, elapsed: 4)
            #expect(TalkBarView.listenHintSeen, "stored once the first turn ends")
            bar.render(view(.listening), muted: false, problem: nil, elapsed: 9)
            #expect(bar.debugStatus == "Listening")
            let next = TalkBarView(name: "Inbox")
            next.render(view(.listening), muted: false, problem: nil, elapsed: 1)
            #expect(next.debugStatus == "Listening", "a later conversation never shows it")
        }
    }

    @Test func theSpeakerButtonFollowsTheLoudspeakerAndTheRoute() {
        preserving {
            let coordinator = AudioSessionCoordinator.shared
            defer { TalkRouteButton.debugRoute = nil; coordinator.setLoudspeaker(true) }
            TalkRouteButton.debugRoute = (.speaker, "Speaker", "Speaker")
            let bar = TalkBarView(name: "Inbox")
            bar.route.refresh()
            bar.render(view(.listening), muted: false, problem: nil, elapsed: 3)
            laidOut(bar, width: Self.widths[1])
            coordinator.setLoudspeaker(true)
            #expect(bar.debugSpeaker.on && bar.debugSpeaker.label == "Speaker" && !bar.debugSpeaker.picker)
            coordinator.setLoudspeaker(false)
            #expect(!bar.debugSpeaker.on && bar.debugSpeaker.value == "Off", "the earpiece")
            TalkRouteButton.debugRoute = (.other, "BluetoothA2DPOutput", "AirPods Pro")
            bar.route.refresh()
            laidOut(bar, width: Self.widths[1])
            #expect(bar.debugSpeaker.picker && bar.debugSpeaker.symbol == "airpods.pro", "AirPods: their glyph, and the picker")
            #expect(outside(bar) == nil)
            #expect(!bar.debugControls.stacked)
        }
    }

    /// Owner, 2026-10-27: "a lot of it is too long to show completely". Every state's words show whole on every
    /// iPhone width, in both looks, with a long bot name giving way before the time does.
    @Test(arguments: [false, true])
    func theWordsShowWhole(desktop: Bool) {
        preserving(desktop: desktop) {
            for name in ["Max", "Inbox", "A Bot With A Very Long Name Indeed"] {
                let bar = TalkBarView(name: name)
                for (status, muted, reconnecting) in [(TalkStatus.listening, false, false), (.thinking, false, false), (.speaking, false, false),
                                                      (.transcribing, false, false), (.listening, true, false), (.idle, false, true)] {
                    let state = TalkDockState.view(status: status, muted: muted, reconnecting: reconnecting, lostSpeech: false, silence: .ok,
                                                   listened: true, name: name)
                    bar.render(state, muted: muted, problem: nil, elapsed: 3723)
                    for width in Self.widths.dropFirst() {
                        laidOut(bar, width: width)
                        let lines = bar.debugLines
                        #expect(lines.status == TalkDockState.shortTitle(state), "\(status) at \(width)")
                        #expect(lines.elapsed?.hasSuffix("1:02:03") == true, "the time always shows (\(name), \(width))")
                        if name.count < 10 { #expect(lines.name == name, "a short name shows (\(width))") }
                        #expect(bar.debugTextFits(name: name.count < 10), "\(name) \(state.title) at \(width): \(lines)")
                        #expect(outside(bar) == nil)
                    }
                }
            }
        }
    }

    @Test func accessibilitySizesStackAndStillFit() {
        preserving {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
            let bar = TalkBarView(name: "Inbox")
            window.addSubview(bar)
            bar.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            bar.updateTraitsIfNeeded()
            for problem in [nil, "Voice Playback Failed."] as [String?] {
                bar.render(view(.speaking), muted: false, problem: problem, elapsed: 82)
                laidOut(bar, width: 323)
                #expect(bar.debugControls.stacked)
                #expect(outside(bar) == nil)
                let (box, end, _, _) = bar.debugEnd
                #expect(box.contains(end))
            }
        }
    }

    @Test func theBarSitsWhereTheComposerRowSits() {
        let chat = ChatViewController(session: SpyChatSession())
        chat.loadViewIfNeeded()
        chat.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let bar = TalkBarView(name: "Inbox")
        bar.render(view(.listening), muted: false, problem: nil, elapsed: 3)
        chat.setDock(bar, for: .voice, animated: false)
        chat.view.layoutIfNeeded()
        #expect(abs(bar.frame.minX - ChatMetrics.composerSideDown) < 0.5 && abs(chat.view.bounds.width - bar.frame.maxX - ChatMetrics.composerSideDown) < 0.5,
                "\(bar.frame)")
        #expect(chat.view.bounds.height - bar.frame.maxY >= ChatMetrics.composerBottomDown - 0.5, "\(bar.frame)")
        #expect(chat.dockSideInset == ChatMetrics.composerSideDown)
        chat.setDock(nil, for: .voice, animated: false)
    }

    /// [live words] Heard words take a row of their own at the top of the box, as typed words do in the composer's two
    /// rows: the controls keep their row and End its padding under them, nothing runs off the bar, and the row goes with
    /// the words.
    @Test(arguments: [false, true])
    func heardWordsTakeTheTopRow(desktop: Bool) {
        preserving(desktop: desktop) {
            let bar = TalkBarView(name: "Inbox")
            bar.render(view(.listening), muted: false, problem: nil, elapsed: 3)
            laidOut(bar, width: Self.widths[2])
            let oneRow = bar.bounds.height
            let before = bar.debugEnd.end
            bar.showWords(LiveWordsText(settled: "What's on my calendar for tomorrow, and can you move the dentist", pending: "to Thursday"))
            laidOut(bar, width: Self.widths[2])
            #expect(bar.bounds.height > oneRow + 20, "a row for the words")
            let (box, end, _, _) = bar.debugEnd
            #expect(abs((box.maxY - end.maxY) - bar.debugBoxInset) < 0.5, "End keeps its padding at the bottom")
            #expect(abs(end.height - before.height) < 0.5)
            #expect(outside(bar) == nil)
            func find(_ view: UIView) -> LiveWordsView? {
                if let words = view as? LiveWordsView { return words }
                for sub in view.subviews { if let found = find(sub) { return found } }
                return nil
            }
            guard let words = find(bar) else { Issue.record("no words view"); return }
            #expect(!words.isHidden && words.convert(words.bounds, to: bar).maxY <= end.minY + 0.5, "above the controls")
            bar.showWords(LiveWordsText())
            laidOut(bar, width: Self.widths[2])
            #expect(abs(bar.bounds.height - oneRow) < 0.5, "and it goes with them")
            #expect(words.isHidden)
        }
    }
}
