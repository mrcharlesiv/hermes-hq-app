// Every word the voice dock, its notices and the away pill show (docs/spec/3x-talk.md §6), ported line for line from
// the web app's `src/ui-voice/dock-state.ts`. Pure: no UIKit, no clocks of its own.

import Foundation

nonisolated enum TalkSilence: String, Sendable, Equatable { case ok, still, pause }

nonisolated struct TalkDockView: Equatable, Sendable {
    enum Phase: String, Sendable { case starting, listening, stillListening, lostSpeech, transcribing, thinking, speaking, muted, reconnecting }
    enum Visual: String, Sendable { case listen, speak, think, muted, wait }
    enum Center: String, Sendable {
        case sendNow, spinner, stop, interrupt
        var label: String {
            switch self {
            case .sendNow: "Send Now"
            case .spinner: "Transcribing"
            case .stop: "Stop"
            case .interrupt: "Interrupt"
            }
        }
        var symbol: String? {
            switch self {
            case .sendNow: "arrow.up"
            case .spinner: nil
            case .stop: "stop.fill"
            case .interrupt: "hand.raised.fill"
            }
        }
    }
    var phase: Phase
    var title: String
    var hint: String
    var visual: Visual
    var center: Center
    var centerEnabled: Bool
    var centerLabel: String { center.label }
}

nonisolated enum TalkDockState {
    /// First match wins (§6.2's ten rows). `bargeIn: false` drops the half of two hints that would no longer be true.
    static func view(status: TalkStatus, muted: Bool, reconnecting: Bool, lostSpeech: Bool, silence: TalkSilence, listened: Bool,
                     name: String, bargeIn: Bool = true) -> TalkDockView {
        func view(_ phase: TalkDockView.Phase, _ title: String, _ hint: String, _ visual: TalkDockView.Visual,
                  _ center: TalkDockView.Center, _ enabled: Bool) -> TalkDockView {
            TalkDockView(phase: phase, title: title, hint: hint, visual: visual, center: center, centerEnabled: enabled)
        }
        if muted { return view(.muted, "Muted", "\(name) can’t hear you. \(DeviceWord.Tap) Mute to talk again.", .muted, .sendNow, false) }
        if reconnecting { return view(.reconnecting, "Reconnecting…", "Waiting for your gateway.", .wait, .sendNow, false) }
        switch status {
        case .transcribing:
            return view(.transcribing, "Transcribing…", "Turning your words into text.", .think, .spinner, false)
        case .thinking:
            return view(.thinking, "Thinking…", bargeIn ? "\(name) is working on it. Talking now interrupts." : "\(name) is working on it.",
                        .think, .stop, true)
        case .speaking:
            return view(.speaking, "\(name) is speaking", bargeIn ? "Start talking or \(DeviceWord.tap) Interrupt to cut in." : "\(DeviceWord.Tap) Interrupt to cut in.",
                        .speak, .interrupt, true)
        case .listening:
            if lostSpeech {
                return view(.lostSpeech, "Listening", "Didn’t send what you said while reconnecting. Say it again.", .listen, .sendNow, true)
            }
            if silence != .ok { return view(.stillListening, "Still Listening", "Talk when you’re ready, or \(DeviceWord.tap) End.", .listen, .sendNow, true) }
            return view(.listening, "Listening", "Go ahead. It sends when you pause.", .listen, .sendNow, true)
        case .idle:
            return listened
                ? view(.listening, "Listening", "Go ahead. It sends when you pause.", .listen, .sendNow, false)
                : view(.starting, "Starting…", "Getting the microphone ready.", .wait, .sendNow, false)
        }
    }

    static func silence(now: TimeInterval, lastSpeechAt: TimeInterval, listening: Bool, clock: TalkClock = TalkClock()) -> TalkSilence {
        guard listening else { return .ok }
        let quiet = now - lastSpeechAt
        return quiet >= clock.silencePause ? .pause : quiet >= clock.stillListening ? .still : .ok
    }

    /// 0:07, 2:14, 1:02:03.
    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.isFinite ? seconds : 0)), hours = whole / 3600, minutes = (whole / 60) % 60, rest = whole % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", whole / 60, rest)
    }

    /// The word the away pill shows for a status (§6.6): idle reads Listening.
    static func pillStatus(_ status: TalkStatus, muted: Bool) -> String {
        if muted { return "Muted" }
        switch status {
        case .idle, .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        }
    }

    static func pausedWhy(_ cause: TalkPauseCause, app: String) -> String {
        switch cause {
        case .interrupted: "A call or Siri took the microphone."
        case .background: "Voice stops when \(app) leaves the screen."
        case .silence: "Paused after 2 minutes of silence."
        case .routeLost: "The headset or microphone disconnected."
        }
    }

    static func pausedNotice(_ cause: TalkPauseCause, name: String, detail: String? = nil, app: String) -> TalkNotice {
        TalkNotice(kind: .paused, title: "Voice Paused", message: "\(pausedWhy(cause, app: app)) Your chat with \(name) is saved.",
                   detail: detail?.isEmpty == false ? detail : nil, action: .resume, cause: cause)
    }

    /// The failure's own title heads the card ("Voice Transcription Failed") and the message is only the explanation,
    /// so the card never reads two headlines; "Voice Stopped" heads it when the failure has no title.
    static func stoppedNotice(title: String, message: String, detail: String? = nil) -> TalkNotice {
        let all = "\(message) \(detail ?? "")"
        let denied = all.range(of: "microphone", options: [.regularExpression, .caseInsensitive]) != nil
            && all.range(of: "denied|not allowed|allow|turn on|access is off", options: [.regularExpression, .caseInsensitive]) != nil
        var body = message
        if !title.isEmpty, message.hasPrefix(title) {
            let rest = message.dropFirst(title.count).drop { $0 == "." || $0 == " " }
            if !rest.isEmpty { body = String(rest) }
        }
        return TalkNotice(kind: .stopped, title: title.isEmpty ? "Voice Stopped" : title, message: body,
                          detail: detail?.isEmpty == false ? detail : nil, action: denied ? .openSettings : .tryAgain, cause: nil)
    }

    /// Copy Details: title, message and detail, one per line.
    static func noticeText(_ notice: TalkNotice) -> String {
        [notice.title, notice.message, notice.detail ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// `problem`: a turn failed since the person left the chat; the word says so beside the pill's warning glyph.
    static func pillLabel(name: String, status: TalkStatus, muted: Bool, elapsed: TimeInterval, problem: Bool = false) -> String {
        "\(name) · \(problem ? "Problem" : pillStatus(status, muted: muted)) · \(formatElapsed(elapsed))"
    }

    /// Names the bot, so with several chats away the person knows which one the pill opens.
    static func pillLabel(notice: TalkNotice, name: String) -> String {
        "\(name) · \(notice.kind == .paused ? "Voice Paused" : "Voice Stopped") · \(DeviceWord.Tap) for details"
    }

    static func endedCaption(elapsed: TimeInterval) -> String { "Voice chat ended · \(formatElapsed(elapsed))" }

    /// The audio route's name as the dock shows it (§6.5).
    static func routeName(_ kind: TalkRouteKind, portName: String?, device: String) -> String {
        switch kind {
        case .none, .receiver: return device
        case .speaker: return "Speaker"
        case .headphones: return "Headphones"
        case .other:
            let name = (portName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? device : name
        }
    }
}

// MARK: - The conversation bar (the desktop's ConversationPill)

/// What the bar in the composer's row shows for one dock state (docs/spec/3x-talk.md §6.1): the desktop's
/// `ConversationPill` (`V:app/chat/composer/controls.tsx`) in one row: the level and the status on the left, then
/// Speak Replies, Mute, Stop (only while it does something) and the tinted End capsule (its words only).
nonisolated struct TalkBarControls: Equatable, Sendable {
    /// The centre action (Stop / Interrupt) shows only when it can be used; a disabled one is left out, as the desktop does.
    var showsCenter: Bool
    var centerTitle: String
    var centerLabel: String
    var centerSymbol: String
    var muteSymbol: String
    var muteTitle: String
    var muteLabel: String
}

nonisolated struct TalkSpeakerButton: Equatable, Sendable {
    var symbol: String
    /// The loudspeaker plays: the button is drawn selected.
    var on: Bool
    /// An external route: a tap opens the system's route picker instead of switching.
    var picker: Bool
    var label: String
    var value: String
}

nonisolated extension TalkDockState {
    static func bar(_ view: TalkDockView, muted: Bool) -> TalkBarControls {
        let shows = view.centerEnabled && view.center != .spinner
        let title: String, label: String, symbol: String
        switch view.center {
        case .sendNow: (title, label, symbol) = ("Stop", "Stop Listening and Send", "stop.fill")
        case .stop: (title, label, symbol) = ("Stop", "Stop", "stop.fill")
        case .interrupt: (title, label, symbol) = ("Interrupt", "Interrupt", "hand.raised.fill")
        case .spinner: (title, label, symbol) = ("Transcribing", "Transcribing", "ellipsis")
        }
        return TalkBarControls(showsCenter: shows, centerTitle: title, centerLabel: label, centerSymbol: symbol,
                               muteSymbol: muted ? "mic.slash" : "mic", muteTitle: muted ? "Unmute" : "Mute",
                               muteLabel: muted ? "Unmute Microphone" : "Mute Microphone")
    }

    /// The bar's status words: the state's title; the very first listening turn ever shows the hint instead
    /// (`TalkListenHint`), so the one-time advice needs no line of its own.
    static func barStatus(_ view: TalkDockView, firstHint: Bool) -> String {
        firstHint && view.phase == .listening ? view.hint : shortTitle(view)
    }

    /// The status where the bot's name is already shown beside it (the bar's second line, the Live Activity's
    /// heading): "Speaking", not "Ivy is speaking" (owner, 2026-10-27: the bar's words were cut off). Every other
    /// state's title is already a word or two. VoiceOver still hears the whole title.
    static func shortTitle(_ view: TalkDockView) -> String { view.phase == .speaking ? "Speaking" : view.title }

    /// The bar's second line: who, and for how long ("Ivy · 0:03").
    static func barDetail(name: String, elapsed: String) -> String { "\(name) · \(elapsed)" }

    /// The bar's speaker button (owner, 2026-10-27: it should turn the speaker on). On the phone's own route it
    /// switches loudspeaker and earpiece; with headphones, Bluetooth, CarPlay or AirPlay it shows that route's glyph
    /// and opens the system's picker.
    static func speakerButton(kind: TalkRouteKind, portType: String, portName: String?, loudspeaker: Bool) -> TalkSpeakerButton {
        if routeIsExternal(kind) {
            let name = routeName(kind, portName: portName, device: "")
            return TalkSpeakerButton(symbol: routeSymbol(portType: portType, name: portName), on: false, picker: true,
                                     label: "Audio Output", value: name.isEmpty ? "Other" : name)
        }
        return TalkSpeakerButton(symbol: loudspeaker ? "speaker.wave.2.fill" : "speaker.wave.2", on: loudspeaker, picker: false,
                                 label: "Speaker", value: loudspeaker ? "On" : "Off")
    }

    /// The one line above the bar, or nil: there is none in a normal state (owner, after build 308: two stacked boxes
    /// were heavy). One turn's failure, or the speech dropped while reconnecting (§6.2 row 6), shows there.
    static func barNotice(_ view: TalkDockView, problem: String?) -> String? {
        if let problem, !problem.isEmpty { return problem }
        return view.phase == .lostSpeech ? view.hint : nil
    }

    /// Bluetooth, wired headphones, CarPlay, AirPlay: a route worth showing in the row. The built-in speaker and
    /// receiver are what a person expects, so the row shows nothing for them (§6.5).
    static func routeIsExternal(_ kind: TalkRouteKind) -> Bool { kind == .headphones || kind == .other }

    /// The route's glyph in the row, from the output port's type (`AVAudioSession.Port` raw value) and its name.
    static func routeSymbol(portType: String, name: String?) -> String {
        let name = (name ?? "").lowercased()
        switch portType {
        case "CarAudio": return "car.fill"
        case "AirPlay": return "airplayaudio"
        case "Headphones", "HeadsetMicrophone": return "headphones"
        case "BluetoothA2DPOutput", "BluetoothHFP", "BluetoothLE":
            if name.contains("airpods max") { return "airpods.max" }
            if name.contains("airpods pro") { return "airpods.pro" }
            if name.contains("airpods") { return "airpods" }
            return "headphones"
        default: return "hifispeaker.fill"
        }
    }

    // MARK: Read Replies Aloud (T6)

    /// Until the person has chosen once (anywhere: the bar, the voice options, Settings), Read Replies Aloud follows the
    /// gateway's `voice.auto_tts` as last read; after that their choice wins. Nothing known: off. The desktop's rule
    /// (`V:store/voice-prefs.ts` `applyAutoSpeakFromConfig`).
    static func readsRepliesAloud(chosen: Bool?, gateway: Bool?) -> Bool { chosen ?? gateway ?? false }

    /// The Speak Replies switch in the bar: its glyph (never a slash: beside the mic a slashed speaker read as muted,
    /// owner after build 308; off is the same glyph in grey) and its words.
    static func speakRepliesSymbol(_ on: Bool) -> String { on ? "speaker.wave.2.fill" : "speaker.wave.2" }
    static let speakRepliesLabel = "Speak Replies"
    static func speakRepliesValue(_ on: Bool) -> String { on ? "On" : "Off" }

    // MARK: One turn's failure

    /// A failure's reason when it reads as a sentence: one line, no address or key in it, at most 160 characters. Nil:
    /// raw provider output (build 305 showed 15 orange lines of a speech service's address and tokens), which only Copy
    /// Details carries.
    static func shortReason(_ reason: String) -> String? {
        let line = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line.count <= 160, !line.contains(where: \.isNewline), VoiceReport.scrub(line, limit: .max) == line else { return nil }
        return line
    }

    /// The bar's one line for a turn that failed: "<title>. <reason>" when the reason is a sentence, else "<title>.".
    static func problemLine(_ title: String, reason: String) -> String {
        shortReason(reason).map { "\(title). \($0)" } ?? "\(title)."
    }

    /// What Copy Details copies for that turn: the title with the whole reason, then the detail, scrubbed.
    static func problemDetail(_ title: String, reason: String, detail: String?) -> String {
        let reason = VoiceReport.scrub(reason.trimmingCharacters(in: .whitespacesAndNewlines), limit: 2000)
        let more = detail.map { VoiceReport.scrub($0, limit: 2000) } ?? ""
        return [reason.isEmpty ? title : "\(title). \(reason)", more].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// A stopped notice's detail: the raw reason (scrubbed) when the message could not carry it, then the detail.
    static func noticeDetail(reason: String, detail: String?) -> String? {
        let raw = shortReason(reason) == nil ? VoiceReport.scrub(reason.trimmingCharacters(in: .whitespacesAndNewlines), limit: 2000) : ""
        let more = detail.map { VoiceReport.scrub($0, limit: 2000) } ?? ""
        let joined = [raw, more].filter { !$0.isEmpty }.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    /// Copy Details: `text`, then the recent voice events (newest last), so a failure with no detail of its own still
    /// copies what led to it.
    static func copyText(_ text: String, events: [VoiceEvent], zone: TimeZone = .current) -> String {
        guard !events.isEmpty else { return text }
        return ([text, "Recent voice events:"] + events.map { "  \(VoiceReport.line($0, zone: zone))" }).joined(separator: "\n")
    }
}

/// The kind of output port, as far as the route's name needs it.
nonisolated enum TalkRouteKind: Sendable, Equatable { case none, receiver, speaker, headphones, other }

/// Counts quiet time while the conversation waits for the person (§4.2 rule 11).
nonisolated struct SilenceClock: Equatable, Sendable {
    private(set) var lastSpeechAt: TimeInterval
    var clock = TalkClock()
    init(now: TimeInterval, clock: TalkClock = TalkClock()) {
        lastSpeechAt = now
        self.clock = clock
    }
    mutating func reset(now: TimeInterval) { lastSpeechAt = now }
    mutating func observe(status: TalkStatus, level: Double, muted: Bool, now: TimeInterval) {
        if muted || status == .thinking || status == .speaking || level >= TalkClock.speechLevel { lastSpeechAt = now }
    }
    func state(status: TalkStatus, muted: Bool, now: TimeInterval) -> TalkSilence {
        TalkDockState.silence(now: now, lastSpeechAt: lastSpeechAt,
                              listening: !muted && (status == .listening || status == .idle || status == .transcribing), clock: clock)
    }
}

/// "Go ahead. It sends when you pause." is the bar's status for the first listening turn of the first conversation
/// ever, then plain "Listening" (owner, after build 308). `seen` is kept by the caller (UserDefaults).
nonisolated struct TalkListenHint: Equatable, Sendable {
    private(set) var seen: Bool
    private(set) var showing = false

    init(seen: Bool) { self.seen = seen }

    /// The state the bar now shows. True when `seen` has just become true (the caller stores it).
    mutating func observe(_ phase: TalkDockView.Phase) -> Bool {
        if phase == .listening {
            if !seen { showing = true }
            return false
        }
        return finish()
    }

    /// The first turn left listening, or the bar went away while it showed: never again.
    mutating func finish() -> Bool {
        guard showing else { return false }
        showing = false
        seen = true
        return true
    }
}

/// One line of the bar's long-press route menu (§6.5): an input the session offers (the conversation records and plays
/// on one route: Bluetooth HFP, a wired headset, CarPlay), or the built-in one, which plays on the speaker.
nonisolated struct TalkRouteChoice: Equatable, Sendable {
    var uid: String
    var title: String
    var symbol: String
    var current: Bool
}

nonisolated extension TalkDockState {
    /// The menu's routes from `AVAudioSession.availableInputs` as (uid, port type raw value, name): the built-in
    /// microphone first, named "Speaker" (the conversation plays there, `.defaultToSpeaker`), then the others in the
    /// session's order. `current` is the uid of the route's input.
    static func routeChoices(inputs: [(uid: String, type: String, name: String)], current: String?) -> [TalkRouteChoice] {
        let builtIn = inputs.filter { $0.type == "MicrophoneBuiltIn" }
        let others = inputs.filter { $0.type != "MicrophoneBuiltIn" }
        return builtIn.prefix(1).map { TalkRouteChoice(uid: $0.uid, title: "Speaker", symbol: "speaker.wave.2", current: $0.uid == current) }
            + others.map { TalkRouteChoice(uid: $0.uid, title: $0.name, symbol: routeSymbol(portType: inputPortOutput($0.type), name: $0.name),
                                           current: $0.uid == current) }
    }

    /// An input port's output twin, for its glyph.
    private static func inputPortOutput(_ type: String) -> String {
        switch type {
        case "BluetoothHFP": "BluetoothHFP"
        case "HeadsetMicrophone": "Headphones"
        case "CarAudio": "CarAudio"
        default: type
        }
    }
}
