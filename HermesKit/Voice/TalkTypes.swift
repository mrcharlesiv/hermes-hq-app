// Live voice (docs/spec/3x-talk.md): the small value types every other voice file shares. No UIKit.

import Foundation

/// What the conversation is doing; the dock and the away pill draw this (`W:src/ui-voice/dock-state.ts`).
nonisolated enum TalkStatus: String, Sendable, Equatable {
    case idle, listening, transcribing, thinking, speaking
}

/// Why a conversation paused without the person asking (§6.4).
nonisolated enum TalkPauseCause: String, Sendable, Equatable {
    /// `background` is no longer raised: since 3x-talk-background.md leaving the app never pauses a conversation (kept
    /// for the loop's tests and the `paused-background` screenshot state).
    case interrupted, background, silence
    case routeLost = "route lost"
}

/// The paused / stopped notice that takes the dock's place (§6.3). Wording comes from `TalkDockState`.
nonisolated struct TalkNotice: Equatable, Sendable {
    enum Kind: String, Sendable { case paused, stopped }
    enum Action: String, Sendable {
        case resume, tryAgain, openSettings
        var title: String {
            switch self {
            case .resume: "Resume"
            case .tryAgain: "Try Again"
            case .openSettings: PrivacySettingsLink.openTitle   // [mac] Mac polish #11: "Open System Settings" on the Mac
            }
        }
    }
    var kind: Kind
    var title: String
    var message: String
    var detail: String?
    var action: Action
    /// The pause's cause, for Voice Diagnostics' "Voice paused" row.
    var cause: TalkPauseCause?
}

/// How a conversation ended (§4.2).
nonisolated enum TalkEnd: Equatable, Sendable {
    /// End on the dock or the pill.
    case user
    /// A spoken or typed stop phrase.
    case said
    /// Another conversation, a memo or a dictation took the microphone.
    case replaced
    /// The chat went away (deleted, archived, signed out): nothing is shown.
    case gone
    case paused(TalkPauseCause, detail: String?)
    case stopped(title: String, message: String, detail: String?)

    /// "Voice chat ended · m:ss" is posted for these (§6.7).
    var showsEndedCaption: Bool { self == .user || self == .said }
}

/// The gateway's voice settings a conversation and a dictation read (§3.1, §4.1). Anything unreadable is the default.
nonisolated struct TalkConfig: Equatable, Sendable {
    var sttEnabled = true
    /// Quiet after speech that ends a take, in milliseconds.
    var silenceMs = TalkConfig.silenceDefaultMs
    var bargeIn = true
    /// `voice.barge_in_threshold_multiplier` when it is a number above zero.
    var bargeMultiplier: Double?
    var stopPhrases: TalkStopWord.Config = .standard
    /// `voice.max_recording_seconds`, 1…600 (dictation's limit).
    var maxRecordingSeconds = 120
    /// `voice.auto_tts` when the gateway answered a boolean: Read Replies Aloud's default until the person chooses (T6).
    var autoTTS: Bool?
    /// [gpt-live] `voice.voice_chat_mode`: which engine a conversation uses unless this device chose.
    var chatMode: TalkEngine = .standard

    static let silenceDefaultMs = 1_250
    static let backendSilenceSeconds = 3.0
    static let recordingLimit = 1...600

    init() {}

    /// `config` is `GET /api/config`; `defaults` is `GET /api/config/defaults` when it was read.
    init(config: JSONValue?, defaults: JSONValue? = nil) {
        if case .bool(false)? = config?["stt"]?["enabled"] { sttEnabled = false }
        let voice = config?["voice"]
        if let seconds = TalkConfig.positive(voice?["silence_duration"]) {
            let usual = TalkConfig.positive(defaults?["voice"]?["silence_duration"]) ?? TalkConfig.backendSilenceSeconds
            // Hermes reports its own default (3.0) for an untouched install; only a changed value replaces 1.25 s.
            if seconds != usual { silenceMs = Int(min(seconds, 60) * 1000) }
        }
        if case .bool(false)? = voice?["barge_in"] { bargeIn = false }
        if case .bool(let on)? = voice?["auto_tts"] { autoTTS = on }
        chatMode = TalkEngine(mode: voice?["voice_chat_mode"]?.string)   // [gpt-live]
        bargeMultiplier = TalkConfig.positive(voice?["barge_in_threshold_multiplier"])
        stopPhrases = TalkStopWord.config(from: voice?["stop_phrases"], defaults: defaults?["voice"]?["stop_phrases"])
        if case .number(let limit)? = voice?["max_recording_seconds"], limit.isFinite {
            maxRecordingSeconds = min(max(Int(limit), TalkConfig.recordingLimit.lowerBound), TalkConfig.recordingLimit.upperBound)
        }
    }

    /// A finite number above zero; a bare boolean or text is not a number here (`V:store/voice-prefs.ts` silenceSeconds).
    private static func positive(_ value: JSONValue?) -> Double? {
        guard case .number(let number)? = value, number.isFinite, number > 0 else { return nil }
        return number
    }
}

/// The windows of §4.1. `scale` divides the long ones for tests (`-HQDebugTalkClock`).
nonisolated struct TalkClock: Equatable, Sendable {
    var scale: Double = 1
    var idleTakeMs: Double { 12_000 / scale }
    var longestTakeMs: Double { 60_000 / scale }
    var stillListening: TimeInterval { 30 / scale }
    var silencePause: TimeInterval { 120 / scale }
    /// A barged-in sentence waits this long for the stopped turn to end before it is sent anyway (T16).
    static let bargeSettle: TimeInterval = 5
    /// How long "the person interrupted" stays attached to the next prompt.
    static let interruptedLifetime: TimeInterval = 120
    static let speechLevel = 0.075
    static let meterFailureMinMs = 750
    static let meterFailureLimit = 2
    static let transcribeFailureLimit = 3
}
