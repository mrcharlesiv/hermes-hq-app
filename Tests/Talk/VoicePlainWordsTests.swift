// Voice failure cards say plain words; the gateway's developer text stays behind Show Details (VoicePlainWords).

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct VoicePlainWordsTests {
    static let edge = "TTS chunk 1 failed (edge): No TTS provider available. Install one with: hermes pm install --extra edge-tts"

    @Test("A missing text-to-speech provider reads as not set up, with the gateway's words in the details")
    func missingSpeechProvider() {
        let plain = VoicePlainWords.plain(VoiceFailure(reason: Self.edge, detail: "HTTP 503"), .speech)
        #expect(plain.reason == "Read Aloud isn’t set up on this Hermes. Hermes needs a text-to-speech provider.")
        #expect(plain.detail == Self.edge + "\n\nHTTP 503")
        #expect(!plain.reason.contains("hermes pm") && !plain.reason.contains("TTS"))
    }

    @Test("A missing speech-to-text provider reads as not set up")
    func missingTranscriptionProvider() {
        for said in ["No STT provider configured", "Speech-to-text provider not configured", "no speech to text provider available"] {
            let plain = VoicePlainWords.plain(VoiceFailure(reason: said, detail: nil), .transcription)
            #expect(plain.reason == VoicePlainWords.transcriptionNotSetUp, "\(said)")
            #expect(plain.detail == said)
        }
    }

    @Test("Other developer text becomes the plain failure sentence")
    func otherTechnicalText() {
        let trace = "Traceback (most recent call last): RuntimeError: whisper model failed to load"
        let plain = VoicePlainWords.plain(VoiceFailure(reason: trace, detail: nil), .transcription)
        #expect(plain.reason == VoicePlainWords.transcriptionFailed && plain.detail == trace)
        let speech = VoicePlainWords.plain(VoiceFailure(reason: "TTS chunk 2 failed (openai): 429", detail: nil), .speech)
        #expect(speech.reason == VoicePlainWords.speechFailed)
    }

    @Test("The app's own sentences pass through unchanged")
    func ownSentencesUnchanged() {
        for own in ["The computer running Hermes isn’t reachable right now. Try again when it reconnects.", "Your gateway sent no audio.",
                    "This gateway can’t transcribe.", "Couldn’t transcribe. Your gateway ran into a problem (error 500). Try again.", "Cancelled.",
                    "Your gateway’s voice uses a format iPhone can’t play (audio/ogg). Pick another Text to Speech provider in Settings › Voice."] {
            let failure = VoiceFailure(reason: own, detail: "HTTP 500")
            #expect(VoicePlainWords.plain(failure, .speech) == failure, "\(own)")
            #expect(VoicePlainWords.plain(failure, .transcription) == failure, "\(own)")
        }
    }

    @Test("Dictation's card and Talk's fatal playback ending carry the plain words")
    @MainActor func cards() {
        let notice = DictationController.transcriptionFailed(VoiceFailure(reason: "No STT provider available (whisper)", detail: nil))
        #expect(notice.message == VoicePlainWords.transcriptionNotSetUp && notice.detail == "No STT provider available (whisper)")
        var fatal = LoopHarness()
        fatal.listening()
        fatal.say("hello")
        fatal.send(fatal.reply("Here is the answer in words.", pending: true))
        let plain = VoicePlainWords.plain(VoiceFailure(reason: Self.edge, detail: nil), .speech)
        #expect(fatal.send(.speechFailed(reason: plain.reason, fatal: true, detail: plain.detail))
                == [.stopSpeech, .disarmBarge, .ended(.stopped(title: "Voice Playback Failed", message: VoicePlainWords.speechNotSetUp, detail: Self.edge))])
    }
}
