// What a voice failure card says (App Store review walkthrough, build 295): the gateway's own words for a failed
// reading or transcription can be developer text ("TTS chunk 1 failed (edge): No TTS provider available… hermes pm
// install --extra edge-tts"). The card says it plainly; the gateway's words move to the details (Show Details, Copy),
// so nothing is lost for someone fixing their Hermes. The app's own sentences pass through unchanged.

import Foundation

nonisolated enum VoicePlainWords {
    enum Kind: Sendable { case speech, transcription }

    static let speechNotSetUp = "Read Aloud isn’t set up on this Hermes. Hermes needs a text-to-speech provider."
    static let transcriptionNotSetUp = "Voice transcription isn’t set up on this Hermes. Hermes needs a speech-to-text provider."
    static let speechFailed = "Hermes couldn’t make speech for this reply. Try again, or check Text to Speech in Settings › Voice."
    static let transcriptionFailed = "Hermes couldn’t turn your voice into text. Try again, or check Speech to Text in Settings › Voice."

    /// "No TTS provider available", "no speech-to-text provider configured", "STT provider not configured"…
    private static let missingProvider = try! NSRegularExpression(
        pattern: #"\b(no|missing)\b[^.\n]{0,40}\bprovider\b|\bprovider\b[^.\n]{0,40}\b(not (configured|available|installed|set)|unavailable|missing)\b"#,
        options: [.caseInsensitive])
    /// Words only developer text has: engine names, install commands, stack traces, internal step names.
    private static let technical = try! NSRegularExpression(
        pattern: #"\b(tts|stt|chunk|edge-tts|whisper|faster[-_]whisper|traceback|exception|errno|pip|hermes pm|--extra|module|api[_ ]key|stderr|subprocess)\b|\([a-z0-9_-]+\):|[A-Za-z]+Error\b"#,
        options: [.caseInsensitive])

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The card's sentence for `reason`, and the details to keep behind it.
    static func plain(_ failure: VoiceFailure, _ kind: Kind) -> VoiceFailure {
        let reason = failure.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let missing = matches(missingProvider, reason)
        guard missing || matches(technical, reason) else { return failure }
        let said: String
        switch kind {
        case .speech: said = missing ? speechNotSetUp : speechFailed
        case .transcription: said = missing ? transcriptionNotSetUp : transcriptionFailed
        }
        let detail = [reason, failure.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return VoiceFailure(reason: said, detail: detail.isEmpty ? nil : detail)
    }
}
