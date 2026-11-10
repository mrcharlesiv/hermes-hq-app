// What Voice Diagnostics says (docs/spec/3x-talk.md §9.4): the eleven "Right Now" rows built from plain facts, and the
// words of the status line under the three buttons. Pure, so the wording and the report are unit-tested; the page and
// its model live in App/Settings/Voice/VoiceDiagnostics.swift.

import Foundation

/// The audio facts of this moment (DECISION T18: what iOS and the app's own audio pieces report, nothing guessed).
nonisolated struct VoiceAudioFacts: Equatable, Sendable {
    enum Permission: String, Sendable { case allowed, notAsked = "not asked", denied }
    enum Processing: String, Sendable { case on, off, unavailable }

    var permission = Permission.notAsked
    /// The session's category and mode as iOS names them; nil while nothing of the app holds the session.
    var category: String?
    var mode: String?
    var owner: AudioSessionCoordinator.Owner?
    /// Memo playback or speech playing inside a conversation's session.
    var borrower: AudioSessionCoordinator.Owner?
    var voiceProcessing = Processing.off
    /// The cause of a paused notice that is waiting in a chat.
    var paused: String?
    var input: String?
    var output = ""
    var holds = 0
    /// [live words] Who turns speech into words (`LiveWords.diagnosticsLine`; docs/spec/3x-live-words.md §6).
    var liveWords = "not checked yet"

    static func ownerName(_ owner: AudioSessionCoordinator.Owner?) -> String {
        switch owner {
        case nil: "nothing"
        case .memoRecording: "voice memo"
        case .memoPlayback: "memo playback"
        case .conversation: "conversation"
        case .dictation: "dictation"
        case .speech: "read aloud"
        case .diagnostics: "diagnostics"
        }
    }

    /// "AVAudioSessionCategoryPlayAndRecord" and "AVAudioSessionModeSpokenAudio" read "playAndRecord, spokenAudio".
    static func sessionName(category: String?, mode: String?) -> String {
        guard let category, !category.isEmpty else { return "not active" }
        let mode = mode.flatMap { $0.isEmpty ? nil : $0 } ?? "AVAudioSessionModeDefault"
        return "\(short(category, dropping: "AVAudioSessionCategory")), \(short(mode, dropping: "AVAudioSessionMode"))"
    }

    private static func short(_ name: String, dropping prefix: String) -> String {
        let rest = name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
        guard let first = rest.first else { return name }
        return first.lowercased() + rest.dropFirst()
    }

    /// What the coordinator sets for an owner (the stand-ins of a DEBUG simulator never touch the real session).
    static func sessionNames(for owner: AudioSessionCoordinator.Owner?) -> (category: String, mode: String)? {
        guard let owner else { return nil }
        return owner.records ? ("AVAudioSessionCategoryPlayAndRecord", "AVAudioSessionModeDefault")
            : ("AVAudioSessionCategoryPlayback", "AVAudioSessionModeSpokenAudio")
    }

    var inUseBy: String {
        guard let borrower, borrower != owner else { return Self.ownerName(owner) }
        return "\(Self.ownerName(owner)), \(Self.ownerName(borrower))"
    }

    var microphoneRunning: Bool { owner?.records == true }

    /// The eleven rows, in the page's order (also the report's).
    var rows: [VoiceReport.Row] {
        [
            .init(name: "Microphone permission", value: permission.rawValue),
            .init(name: "Audio session", value: Self.sessionName(category: category, mode: mode)),
            .init(name: "Audio in use by", value: inUseBy),
            .init(name: "Microphone running", value: microphoneRunning ? "yes" : "no"),
            .init(name: "Voice processing", value: voiceProcessing.rawValue),
            .init(name: "Voice paused", value: paused.flatMap { $0.isEmpty ? nil : $0 } ?? "no"),
            .init(name: "Input route", value: input.flatMap { $0.isEmpty ? nil : $0 } ?? "none"),
            .init(name: "Output route", value: output),
            .init(name: "Screen kept awake", value: VoiceReport.holds(holds)),
            .init(name: "Voice memo recording", value: owner == .memoRecording ? "yes" : "no"),
            .init(name: "Live words", value: liveWords),
        ]
    }

    /// The page's names for the rows (UX study #185); the copied report keeps `rows`' own names, which support reads.
    static let displayNames: [String: String] = [
        "Microphone permission": "Microphone Access",
        "Audio session": "Audio Session",
        "Audio in use by": "Audio In Use By",
        "Microphone running": "Microphone On",
        "Voice processing": "Echo Cancellation",
        "Voice paused": "Voice Paused",
        "Input route": "Input",
        "Output route": "Output",
        "Screen kept awake": "Screen Kept Awake",
        "Voice memo recording": "Recording a Memo",
        "Live words": "Words as You Speak",
    ]

    /// A row as the page shows it: its Title Case name, and a value that starts with a capital ("not active" reads
    /// "Not Active", "yes (2 holds)" "Yes (2 holds)"). A value with a capital of its own is a name and stays as it is
    /// ("iPhone Microphone", "playAndRecord, default").
    static func display(_ row: VoiceReport.Row) -> VoiceReport.Row {
        let value = row.value
        let shown: String
        if row.name == "Live words" {
            // A sentence that names a language ("on this device (en_US)"): only its first letter rises.
            shown = value.prefix(1).uppercased() + value.dropFirst()
        } else if value.contains(where: \.isUppercase) {
            shown = value
        } else if value.allSatisfy({ $0.isLetter || $0 == " " || $0 == "," }) {
            shown = value.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        } else {
            shown = value.prefix(1).uppercased() + value.dropFirst()
        }
        return .init(name: displayNames[row.name] ?? row.name, value: shown)
    }
}

/// The line under the three buttons.
nonisolated enum VoiceTestStatus: Equatable, Sendable {
    case start
    case recording(seconds: Int)
    case recorded(bytes: Int, mime: String, input: String?)
    case recordFailed(String)
    case microphoneOff
    case busy
    case played(seconds: Double)
    case playFailed(String)
    case transcribed(String)
    /// nil: the gateway refused without saying why.
    case transcribeFailed(String?)

    var text: String {
        switch self {
        case .start: "Transcribe sends the test recording to your Speech to Text provider."
        case .recording(let seconds): "Recording \(seconds) seconds…"
        case .recorded(let bytes, let mime, let input):
            if let input, !input.isEmpty { "Recorded \(VoiceReport.size(bytes)) (\(mime)) from “\(input)”." }
            else { "Recorded \(VoiceReport.size(bytes)) (\(mime))." }
        case .recordFailed(let reason): "Recording failed: \(Self.sentence(reason))"
        case .microphoneOff: "Allow the microphone in \(PrivacySettingsLink.place)"   // [mac] Mac polish #11
        case .busy: "Voice is in use. End the conversation, memo or dictation to run a test."
        case .played(let seconds): "Played \(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds))) s."
        case .playFailed(let reason): "Playback failed: \(Self.sentence(reason))"
        case .transcribed(let words):
            words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Transcribed: (no speech detected)"
                : "Transcribed: “\(words.trimmingCharacters(in: .whitespacesAndNewlines))”"
        case .transcribeFailed(let reason):
            if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { "Transcription failed: \(Self.sentence(reason))" }
            else { "Transcription failed on the gateway." }
        }
    }

    /// What the report's "Test:" line says (the web's report carries the test result too); nothing until a test did something.
    var reportLine: String? {
        switch self {
        case .start, .busy, .recording: nil
        default: text
        }
    }

    /// A reason reads as one sentence: trimmed, one line, with its full stop.
    static func sentence(_ reason: String) -> String {
        let one = VoiceReport.scrub(reason.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines))
        guard let last = one.last else { return "Unknown reason." }
        return ".!?…".contains(last) ? one : one + "."
    }
}

/// What each of the three buttons says and whether it can be pressed.
nonisolated enum VoiceTestButtons {
    enum Running: Equatable, Sendable { case recording, playing, transcribing }

    static func recordTitle(_ running: Running?, seconds: Int) -> String { running == .recording ? "Recording…" : "Record \(seconds) s" }
    static func playTitle(_ running: Running?) -> String { running == .playing ? "Playing…" : "Play" }
    static func transcribeTitle(_ running: Running?) -> String { running == .transcribing ? "Transcribing…" : "Transcribe" }

    static func canRecord(running: Running?, microphoneBusy: Bool) -> Bool { running == nil && !microphoneBusy }
    static func canPlay(running: Running?, hasTake: Bool) -> Bool { running == nil && hasTake }
    static func canTranscribe(running: Running?, hasTake: Bool, connected: Bool) -> Bool { running == nil && hasTake && connected }
}
