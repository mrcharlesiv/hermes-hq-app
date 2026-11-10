// Settings › Voice (docs/spec/3x-talk.md §9): where the section sits, what its pages list and in which order, the
// words, the keys a phone never shows (row L546), one provider's fields at a time, and the search entries.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Voice settings catalog")
struct VoiceSettingsCatalogTests {
    private static let schema: [String: ConfigFieldSchema] = {
        var fields: [String: ConfigFieldSchema] = [:]
        for key in VoiceSettingsCatalog.section.keys { fields[key] = ConfigFieldSchema(kind: .string) }
        for key in ["stt.enabled", "stt.echo_transcripts", "stt.elevenlabs.diarize", "voice.auto_tts"] { fields[key] = ConfigFieldSchema(kind: .boolean) }
        fields["voice.max_recording_seconds"] = ConfigFieldSchema(kind: .number)
        // What a gateway may also describe, and a phone never lists.
        for key in ["voice.wake_word", "voice.wake_words", "voice.stop_words", "voice.client_direct", "voice.voice_chat_mode",
                    "voice.gpt_live.instructions", "voice.gpt_live.voice"] {
            fields[key] = ConfigFieldSchema(kind: .string)
        }
        return fields
    }()

    private static let record: JSONValue = [
        "stt": ["enabled": true, "provider": "openai", "openai": ["model": "whisper-1"], "local": ["model": "base"]],
        "tts": ["provider": "elevenlabs", "elevenlabs": ["voice_id": "v1", "model_id": "eleven_v3"], "edge": ["voice": "en-US-AriaNeural"]],
        "voice": ["max_recording_seconds": 120, "auto_tts": false, "wake_word": "hey", "client_direct": true,
                  "gpt_live": ["instructions": "x"]],
    ]

    @Test func voiceSitsBetweenMemoryAndAdvanced() throws {
        let ids = ConfigCatalog.sections.map(\.id)
        let voice = try #require(ids.firstIndex(of: "voice"))
        #expect(ids[voice - 1] == "memory")
        #expect(ids[voice + 1] == "advanced")
        let section = try #require(ConfigCatalog.section("voice"))
        #expect(section.title == "Voice" && section.symbol == "mic")
        #expect(section.pages.map(\.title) == ["Voice Conversation", "Speech to Text", "Text to Speech"])
        #expect(section.pages.map(\.key) == ["voice.conversation", "voice.transcription", "voice.speech"])
        #expect(ConfigCatalog.customPages.isSuperset(of: VoiceSettingsCatalog.customPages))
    }

    @Test func everyKeyHasItsPage() {
        for key in VoiceSettingsCatalog.speechToTextKeys {
            #expect(ConfigCatalog.page(forField: key, in: "voice")?.id == "transcription", "\(key)")
        }
        for key in VoiceSettingsCatalog.textToSpeechKeys {
            #expect(ConfigCatalog.page(forField: key, in: "voice")?.id == "speech", "\(key)")
        }
        // Voice Conversation lists nothing of the gateway: its rows are this iPhone's.
        let conversation = VoiceSettingsCatalog.section.pages[0]
        #expect(ConfigRenderer.fields(page: conversation, schema: Self.schema, config: Self.record).isEmpty)
    }

    @Test func thePagesListTheirFieldsInTheWebsOrder() {
        let pages = VoiceSettingsCatalog.section.pages
        let heard = ConfigRenderer.fields(page: pages[1], schema: Self.schema, config: Self.record).map(\.key)
        #expect(heard == VoiceSettingsCatalog.speechToTextKeys)
        #expect(heard.first == "stt.enabled" && heard.last == "voice.max_recording_seconds")
        let spoken = ConfigRenderer.fields(page: pages[2], schema: Self.schema, config: Self.record).map(\.key)
        #expect(spoken == VoiceSettingsCatalog.textToSpeechKeys)
        #expect(spoken.first == "tts.provider" && spoken.last == "voice.auto_tts")
    }

    @Test func wakeWordsStopWordsAndTheEngineChoiceAreNeverShown() {
        for key in ["voice.wake_word", "voice.wake_words", "voice.wakeword.enabled", "voice.stop_words", "voice.stop_word",
                    "voice.client_direct", "voice.voice_chat_mode", "voice.gpt_live", "voice.gpt_live.instructions", "voice.gpt_live.voice",
                    "Voice.GPT_Live.Voice", "stt.wake.model"] {
            #expect(VoiceSettingsCatalog.isHidden(key), "\(key)")
        }
        for key in VoiceSettingsCatalog.section.keys { #expect(!VoiceSettingsCatalog.isHidden(key), "\(key) is listed") }
        // No page lists one, whatever the gateway's schema and record say.
        for page in VoiceSettingsCatalog.section.pages {
            let keys = ConfigRenderer.fields(page: page, schema: Self.schema, config: Self.record).map(\.key)
            #expect(keys.allSatisfy { !VoiceSettingsCatalog.isHidden($0) })
        }
        // Search cannot find one either.
        let found = SettingsSearch.index(schema: Self.schema)
        #expect(!found.contains { entry in
            if case .field(_, let key) = entry.target { return VoiceSettingsCatalog.isHidden(key) }
            return false
        })
        let words = found.map { "\($0.label) \($0.keywords.joined(separator: " "))".lowercased() }.joined(separator: "\n")
        #expect(!words.contains("wake word") && !words.contains("stop word") && !words.contains("gpt live") && !words.contains("gpt_live"))
    }

    @Test func oneProvidersFieldsShowAtATime() {
        #expect(VoiceSettingsCatalog.provider(of: "stt.openai.model")?.provider == "openai")
        #expect(VoiceSettingsCatalog.provider(of: "tts.elevenlabs.voice_id")?.group == "tts")
        #expect(VoiceSettingsCatalog.provider(of: "stt.enabled") == nil)
        #expect(VoiceSettingsCatalog.provider(of: "tts.provider") == nil)
        #expect(VoiceSettingsCatalog.provider(of: "voice.auto_tts") == nil)

        let pages = VoiceSettingsCatalog.section.pages
        let heard = VoiceSettingsCatalog.hiddenNow(on: pages[1], config: Self.record)
        #expect(!heard.contains("stt.openai.model") && !heard.contains("stt.enabled") && !heard.contains("stt.provider"))
        #expect(!heard.contains("voice.max_recording_seconds") && !heard.contains("stt.echo_transcripts"))
        #expect(heard.contains("stt.local.model") && heard.contains("stt.groq.model") && heard.contains("stt.elevenlabs.diarize"))
        let spoken = VoiceSettingsCatalog.hiddenNow(on: pages[2], config: Self.record)
        #expect(!spoken.contains("tts.elevenlabs.voice_id") && !spoken.contains("tts.elevenlabs.model_id") && !spoken.contains("voice.auto_tts"))
        #expect(spoken.contains("tts.edge.voice") && spoken.contains("tts.openai.voice") && spoken.contains("tts.xai.speed"))
        // Nothing selected yet (or nothing read): only the shared rows.
        let none = VoiceSettingsCatalog.hiddenNow(on: pages[2], config: nil)
        #expect(none == Set(VoiceSettingsCatalog.textToSpeechKeys.filter { VoiceSettingsCatalog.provider(of: $0) != nil }))
        #expect(VoiceSettingsCatalog.isShown("tts.xai.voice_id", config: ["tts": ["provider": " XAI "]]), "case and spaces do not matter")
    }

    @Test func theDictationLimitTakesAWholeNumberFromOneToSixHundred() {
        for fine in [1.0, 60, 120, 600] { #expect(VoiceSettingsCatalog.numberProblem(key: "voice.max_recording_seconds", value: fine) == nil) }
        for bad in [0.0, -5, 0.5, 600.5, 601, 100_000] {
            #expect(VoiceSettingsCatalog.numberProblem(key: "voice.max_recording_seconds", value: bad) == "Type a whole number from 1 to 600.")
        }
        #expect(VoiceSettingsCatalog.numberProblem(key: "tts.xai.speed", value: 0.7) == nil, "other numbers are the gateway's to judge")
    }

    @Test func theWordsAreTheWebs() {
        #expect(ConfigCopy.labels["voice.max_recording_seconds"] == "Max Dictation Length")
        #expect(ConfigCopy.labels["voice.auto_tts"] == "Voice Replies on Messaging Apps")
        #expect(ConfigCopy.labels["stt.enabled"] == "Speech to Text")
        #expect(ConfigCopy.labels["tts.provider"] == "Text to Speech Provider")
        #expect(ConfigCopy.descriptions["voice.max_recording_seconds"] == "Dictation stops and transcribes after this many seconds (up to 600).")
        #expect(ConfigRenderer.optionLabel(key: "tts.provider", "xai") == "xAI")
        #expect(ConfigRenderer.optionLabel(key: "stt.provider", "local") == "Local")
        #expect(ConfigRenderer.optionLabel(key: "stt.local.model", "base") == "Base")
        #expect(ConfigRenderer.optionLabel(key: "tts.edge.voice", "en-GB-SoniaNeural") == "Sonia (UK)")
        #expect(ConfigRenderer.optionLabel(key: "tts.edge.voice", "en-AU-NatashaNeural") == "en-AU-NatashaNeural", "a voice the list doesn't know")
        #expect(ConfigRenderer.optionLabel(key: "tts.provider", "elevenlabs") == "ElevenLabs")
        #expect(ConfigRenderer.optionLabel(key: "tts.xai.language", "pt-BR") == "Portuguese (Brazil)")
        // Every listed key has a label of its own (never a prettified key).
        for key in VoiceSettingsCatalog.section.keys { #expect(ConfigCopy.labels[key] != nil, "\(key)") }
        #expect(VoiceSettingsCatalog.memoNote(sendOnRelease: true).contains("let go to send"))
        #expect(VoiceSettingsCatalog.memoNote(sendOnRelease: false).contains("play it back before you send"))
    }

    @Test func theProviderListsAlsoTakeWhatTheGatewayAdds() {
        let listed = ConfigFieldSchema(kind: .select, options: ["edge", "deepinfra", "acme"])
        let providers = ConfigRenderer.options(key: "tts.provider", schema: listed, value: "edge", config: Self.record) ?? []
        #expect(Array(providers.prefix(10)) == VoiceSettingsCatalog.enumOptions["tts.provider"])
        #expect(Array(providers.suffix(2)) == ["deepinfra", "acme"])
        // A value nobody lists is shown and kept.
        let kept = ConfigRenderer.options(key: "tts.provider", schema: ConfigFieldSchema(kind: .string), value: "mystery", config: Self.record) ?? []
        #expect(kept.last == "mystery")
        // Voice and model names are open-world.
        #expect(ConfigRenderer.control(key: "tts.openai.voice", schema: ConfigFieldSchema(kind: .string), value: "nova", config: Self.record)
                == .choice(options: VoiceSettingsCatalog.enumOptions["tts.openai.voice"]!, free: true, searchable: false))
        #expect(ConfigRenderer.control(key: "stt.enabled", schema: ConfigFieldSchema(kind: .boolean), value: true, config: Self.record) == .toggle)
    }

    @Test func searchFindsThePhonesOwnRows() throws {
        let found = SettingsSearch.index()
        func entry(_ label: String) -> SettingsSearchEntry? { found.first { $0.label == label } }
        #expect(try #require(entry("Read Replies Aloud")).target == .page("voice.speech"))
        #expect(try #require(entry("Voice Diagnostics")).target == .page("voice.conversation"))
        #expect(try #require(entry("Send Memo on Release")).target == .page("voice.conversation"))
        #expect(try #require(entry("How Voice Works")).target == .page("voice.conversation"))
        #expect(try #require(entry("Voice")).target == .root("config:voice"))
        #expect(try #require(entry("Speech to Text")).target == .page("voice.transcription"))
        #expect(try #require(entry("Max Dictation Length")).target == .field(page: "voice.transcription", key: "voice.max_recording_seconds"))
        #expect(try #require(entry("Voice Replies on Messaging Apps")).target == .field(page: "voice.speech", key: "voice.auto_tts"))
    }

    @Test func nothingSaysTheOldName() {
        var words: [String] = [VoiceSettingsCatalog.conversationNote, VoiceSettingsCatalog.howHint, VoiceSettingsCatalog.sendOnReleaseHint,
                               VoiceSettingsCatalog.diagnosticsHint, VoiceSettingsCatalog.readRepliesHint,
                               VoiceSettingsCatalog.memoNote(sendOnRelease: true), VoiceSettingsCatalog.memoNote(sendOnRelease: false)]
        words += VoiceSettingsCatalog.labels.values
        words += VoiceSettingsCatalog.descriptions.values
        words += VoiceSettingsCatalog.providerLabels.values
        words += VoiceSettingsCatalog.searchRows.flatMap { [$0.label, $0.context] + $0.keywords }
        for text in words { #expect(!text.lowercased().contains("dispatch"), "\(text)") }
    }
}

@Suite("Voice settings rows")
struct VoiceSettingsRowsTests {
    private func field(_ key: String, _ control: ConfigControl, _ value: JSONValue?, description: String? = nil) -> ConfigFieldModel {
        ConfigFieldModel(key: key, label: key, description: description, control: control, value: value)
    }

    @Test func emptyLanguageIsAutomaticAndTheLengthHasItsUnit() {
        #expect(ConfigRenderer.summary(field("stt.local.language", .text, .string(""))) == "Automatic")
        #expect(ConfigRenderer.summary(field("stt.local.language", .text, .string("fr"))) == "fr")
        #expect(ConfigRenderer.summary(field("voice.max_recording_seconds", .number, .number(120))) == "120 s")
        #expect(ConfigRenderer.summary(field("tts.xai.speed", .number, nil)) == "Not Set")
    }

    @Test func thePageIsAFewSectionsNotACardPerField() {
        let fields = [
            field("stt.enabled", .toggle, .bool(true), description: "x"),
            field("stt.provider", .text, nil), field("stt.local.model", .text, nil), field("stt.local.language", .text, nil),
            field("stt.echo_transcripts", .toggle, nil, description: "x"),
            field("voice.max_recording_seconds", .number, nil, description: "x"),
            field("tts.xai.speed", .number, nil, description: "x"),
        ]
        let sections = VoiceSettingsCatalog.sections(fields, key: \.key) { $0.control != .toggle && $0.description != nil }
        #expect(sections.map { $0.map(\.key) } == [
            ["stt.enabled"], ["stt.provider", "stt.local.model", "stt.local.language"], ["stt.echo_transcripts", "voice.max_recording_seconds"],
            ["tts.xai.speed"],
        ])
    }
}
