// Settings › Voice › Text to Speech › Voice: which installed voice the iPhone's voice reads with (`PhoneVoicePreference`).
// Tester, 2026-11-08: Read Aloud "sounds very robotic and not the same as 'Speak' everywhere else on iPhone".
// Automatic follows the Spoken Content voice for the person's own language; a voice picked here wins for its language.
// A tap picks and plays a short sample.

import AVFAudio
import SwiftUI

struct PhoneVoicePage: View {
    static var title: String { "\(DeviceWord.name) Voice" }

    @State private var chosen = PhoneVoicePreference.current()
    @State private var groups: [PhoneVoiceGroup] = []
    @State private var loaded = false
    @State private var suggestsBetterVoice = false
    @State private var sample = PhoneVoiceSample()

    var body: some View {
        List { Group {
            Section {
                row(title: PhoneVoicePreference.automatic, identifier: nil)
            } footer: { HQSectionFooter {
                Text(PhoneVoicePreference.automaticHint)
            } }
            ForEach(groups) { group in
                Section {
                    ForEach(group.voices, id: \.identifier) { voice in
                        row(title: group.title(for: voice), identifier: voice.identifier)
                    }
                } header: { HQSectionLabel {
                    Text(Locale.current.localizedString(forLanguageCode: group.language) ?? group.language)
                } }
            }
            if loaded, suggestsBetterVoice || groups.isEmpty {
                Section {} footer: { HQSectionFooter {
                    Text(PhoneVoiceWords.enhancedHint).accessibilityIdentifier("voice.phone-voice.enhanced-hint")
                } }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .task {
            let candidates = await PhoneVoiceList.load()
            groups = PhoneVoicePicker.offered(candidates)
            suggestsBetterVoice = PhoneVoicePicker.suggestsBetterVoice(candidates: candidates)
            loaded = true
        }
        .onDisappear { sample.stop() }
        .accessibilityIdentifier("voice.phone-voice.list")
    }

    private func row(title: String, identifier: String?) -> some View {
        Button {
            Haptics.play(.selection)
            chosen = identifier
            PhoneVoicePreference.set(identifier)
            sample.play(identifier)
        } label: {
            HQOptionRowLabel(title: title, selected: chosen == identifier)   // [mac] a leading radio on the Mac
            .hqRowPadding(4)
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(chosen == identifier ? .isSelected : [])
        .accessibilityIdentifier("voice.phone-voice.\(identifier ?? "automatic")")
        .hqRadioRow()
    }
}

/// The sample a tap plays: Automatic with the Spoken Content voice, a picked voice with itself.
@MainActor final class PhoneVoiceSample {
    private let synthesizer = AVSpeechSynthesizer()

    func play(_ identifier: String?) {
        synthesizer.stopSpeaking(at: .immediate)
        let voice = identifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
        let english = PhoneVoicePicker.base(voice?.language ?? Locale.preferredLanguages.first ?? "en") == "en"
        let utterance = AVSpeechUtterance(string: english ? "This is how replies will sound." : (voice?.name ?? ""))
        guard !utterance.speechString.isEmpty else { return }
        utterance.voice = voice
        utterance.prefersAssistiveTechnologySettings = identifier == nil
        synthesizer.speak(utterance)
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}
