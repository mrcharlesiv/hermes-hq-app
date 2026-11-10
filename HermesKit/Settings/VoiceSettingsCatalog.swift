// Settings › Voice (docs/spec/3x-talk.md §9): the section, its three pages, the gateway keys they list, their words
// and choices as the web app has them (`vendor/.../app/settings/constants.ts` with the phone build's rewrites in
// `build/fe-voice-gates.ts` and `build/fe-platform-gates.ts`, and `src/voice-settings.tsx` for the makers' names), and
// the keys a phone never shows (`build/voice-gates.ts` voiceFieldVisible, row L546).

import Foundation

nonisolated enum VoiceSettingsCatalog {
    static let speechToTextKeys = [
        "stt.enabled", "stt.provider", "stt.local.model", "stt.local.language", "stt.openai.model", "stt.groq.model",
        "stt.mistral.model", "stt.elevenlabs.model_id", "stt.elevenlabs.language_code", "stt.elevenlabs.tag_audio_events",
        "stt.elevenlabs.diarize", "stt.echo_transcripts", "voice.max_recording_seconds",
    ]

    static let textToSpeechKeys = [
        "tts.provider", "tts.edge.voice", "tts.openai.model", "tts.openai.voice", "tts.elevenlabs.voice_id", "tts.elevenlabs.model_id",
        "tts.xai.voice_id", "tts.xai.language", "tts.xai.speed", "tts.xai.auto_speech_tags", "tts.xai.optimize_streaming_latency",
        "tts.xai.sample_rate", "tts.xai.bit_rate", "tts.minimax.model", "tts.minimax.voice_id", "tts.mistral.model",
        "tts.mistral.voice_id", "tts.gemini.model", "tts.gemini.voice", "tts.neutts.model", "tts.neutts.device",
        "tts.kittentts.model", "tts.kittentts.voice", "tts.piper.voice", "tts.deepinfra.model", "tts.deepinfra.voice", "voice.auto_tts",
    ]

    /// Between Memory and Advanced, as on the web (`constants.ts:761`); the page titles are the phone build's.
    static let section = ConfigSection(id: "voice", title: "Voice", symbol: "mic", keys: speechToTextKeys + textToSpeechKeys, pages: [
        ConfigPage(section: "voice", id: "conversation", title: "Voice Conversation", symbol: "waveform"),
        ConfigPage(section: "voice", id: "transcription", title: "Speech to Text", symbol: "mic",
                   fields: ["voice.max_recording_seconds"], prefixes: ["stt."]),
        ConfigPage(section: "voice", id: "speech", title: "Text to Speech", symbol: "speaker.wave.2",
                   fields: ["voice.auto_tts"], prefixes: ["tts."]),
    ])

    static let customPages: Set<String> = ["voice.conversation", "voice.transcription", "voice.speech"]

    // MARK: Never shown (row L546)

    /// Wake words, stop words, the engine choice and everything of GPT-Live: no page lists them and search cannot
    /// find them, whatever the gateway's schema says.
    static func isHidden(_ key: String) -> Bool {
        let lower = key.lowercased()
        if lower.contains("wake") || lower.contains("stop_word") { return true }
        if lower == "voice.client_direct" || lower == "voice.voice_chat_mode" { return true }
        return lower == "voice.gpt_live" || lower.hasPrefix("voice.gpt_live.")
    }

    // MARK: One provider's fields at a time (`voice-provider-fields.tsx`)

    /// `stt.openai.model` belongs to (`stt`, `openai`); `stt.enabled` and `tts.provider` to nobody.
    static func provider(of key: String) -> (group: String, provider: String)? {
        let parts = key.split(separator: ".").map(String.init)
        guard parts.count >= 3, parts[0] == "stt" || parts[0] == "tts" else { return nil }
        return (parts[0], parts[1])
    }

    /// A provider's fields show only while that provider is the one selected.
    static func isShown(_ key: String, config: JSONValue?) -> Bool {
        guard !isHidden(key) else { return false }
        guard let owner = provider(of: key) else { return true }
        let selected = config.flatMap { ConfigPath.get($0, "\(owner.group).provider") }
        return ConfigText.text(selected).trimmingCharacters(in: .whitespaces).lowercased() == owner.provider
    }

    /// The keys of `page` that are not shown now.
    static func hiddenNow(on page: ConfigPage, config: JSONValue?) -> Set<String> {
        Set(section.keys.filter { page.contains($0) && !isShown($0, config: config) })
    }

    // MARK: Numbers with a range

    static let recordingLimit = 1...600

    /// Why a typed number is refused, or nil when it is fine.
    static func numberProblem(key: String, value: Double) -> String? {
        guard key == "voice.max_recording_seconds" else { return nil }
        let whole = value.rounded(.towardZero)
        guard value == whole, recordingLimit.contains(Int(whole)) else { return "Type a whole number from 1 to 600." }
        return nil
    }

    // MARK: Words

    /// The name on the Home Screen (the web's copy says "Hermes HQ"; this build says its own name).
    static let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Hermes HQ"

    static let labels: [String: String] = [
        "stt.enabled": "Speech to Text",
        "stt.provider": "Speech to Text Provider",
        "stt.local.model": "Local Transcription Model",
        "stt.local.language": "Transcription Language",
        "stt.openai.model": "OpenAI STT Model",
        "stt.groq.model": "Groq STT Model",
        "stt.mistral.model": "Mistral STT Model",
        "stt.elevenlabs.model_id": "ElevenLabs STT Model",
        "stt.elevenlabs.language_code": "ElevenLabs Language",
        "stt.elevenlabs.tag_audio_events": "Tag Audio Events",
        "stt.elevenlabs.diarize": "Speaker Diarization",
        "stt.echo_transcripts": "Echo Transcripts",
        "voice.max_recording_seconds": "Max Dictation Length",
        "voice.auto_tts": "Voice Replies on Messaging Apps",
        "tts.provider": "Text to Speech Provider",
        "tts.edge.voice": "Edge Voice",
        "tts.openai.model": "OpenAI TTS Model",
        "tts.openai.voice": "OpenAI Voice",
        "tts.elevenlabs.voice_id": "ElevenLabs Voice",
        "tts.elevenlabs.model_id": "ElevenLabs Model",
        "tts.xai.voice_id": "xAI (Grok) Voice",
        "tts.xai.language": "xAI Language",
        "tts.xai.speed": "xAI Playback Speed",
        "tts.xai.auto_speech_tags": "xAI Auto Speech Tags",
        "tts.xai.optimize_streaming_latency": "xAI Streaming Latency Optimization",
        "tts.xai.sample_rate": "xAI Sample Rate",
        "tts.xai.bit_rate": "xAI Bit Rate",
        "tts.minimax.model": "MiniMax TTS Model",
        "tts.minimax.voice_id": "MiniMax Voice",
        "tts.mistral.model": "Mistral TTS Model",
        "tts.mistral.voice_id": "Mistral Voice",
        "tts.gemini.model": "Gemini TTS Model",
        "tts.gemini.voice": "Gemini Voice",
        "tts.neutts.model": "NeuTTS Model",
        "tts.neutts.device": "NeuTTS Device",
        "tts.kittentts.model": "KittenTTS Model",
        "tts.kittentts.voice": "KittenTTS Voice",
        "tts.piper.voice": "Piper Voice",
        "tts.deepinfra.model": "DeepInfra TTS Model",
        "tts.deepinfra.voice": "DeepInfra Voice",
    ]

    static let descriptions: [String: String] = [
        "stt.enabled": "Turns voice messages and dictation into text.",
        "stt.echo_transcripts": "Post the transcript of each voice message back to the chat.",
        "stt.elevenlabs.language_code": "Optional ISO-639-3 language code. Blank lets ElevenLabs auto-detect.",
        // The local block's last field, so this is its footer: where "Local" runs, said once.
        "stt.local.language": "Local transcribes on \(HostWord.phrase). Leave the language empty to detect it.",
        "voice.max_recording_seconds": "Dictation stops and transcribes after this many seconds (up to 600).",
        "voice.auto_tts": "Messaging apps (Telegram, Discord…) answer voice messages with a spoken reply. To hear replies in \(appName), turn on Read Replies Aloud above.",
        "tts.xai.voice_id": "xAI voice ID (e.g. eve) or a custom voice ID.",
        "tts.xai.language": "The language replies are spoken in. Automatic detects it from the text.",
        "tts.xai.speed": "Playback speed. 0.7 = slower, 1.0 = normal, 1.5 = faster.",
        "tts.xai.auto_speech_tags": "Let an LLM insert expressive audio tags ([laughing], [sighs]) into the script before synthesis.",
        "tts.xai.optimize_streaming_latency": "Latency vs. quality trade-off. 0 = best quality, 2 = lowest latency.",
        "tts.xai.sample_rate": "Audio sample rate in Hz. Higher = better quality, larger files.",
        "tts.xai.bit_rate": "Audio quality of spoken replies.",
        "tts.neutts.device": "Local inference device for NeuTTS.",
    ]

    static let enumOptions: [String: [String]] = [
        "stt.provider": ["local", "groq", "openai", "mistral", "xai", "elevenlabs"],
        "stt.local.model": ["tiny", "base", "small", "medium", "large-v3"],
        "stt.openai.model": ["whisper-1", "gpt-4o-mini-transcribe", "gpt-4o-transcribe", "gpt-transcribe"],
        "stt.mistral.model": ["voxtral-mini-latest", "voxtral-mini-2602"],
        "stt.elevenlabs.model_id": ["scribe_v2", "scribe_v1"],
        "tts.provider": ["edge", "elevenlabs", "openai", "xai", "minimax", "mistral", "gemini", "neutts", "kittentts", "piper"],
        "tts.edge.voice": ["en-US-AriaNeural", "en-US-JennyNeural", "en-US-AndrewNeural", "en-US-BrianNeural", "en-US-GuyNeural",
                           "en-GB-SoniaNeural"],
        "tts.openai.model": ["gpt-4o-mini-tts", "tts-1", "tts-1-hd"],
        "tts.openai.voice": ["alloy", "ash", "ballad", "cedar", "coral", "echo", "fable", "marin", "nova", "onyx", "sage", "shimmer", "verse"],
        "tts.elevenlabs.model_id": ["eleven_v3", "eleven_ttv_v3", "eleven_multilingual_v2", "eleven_turbo_v2", "eleven_turbo_v2_5",
                                    "eleven_flash_v2", "eleven_flash_v2_5"],
        "tts.xai.voice_id": ["eve"],
        "tts.xai.language": ["auto", "en", "es", "fr", "de", "it", "pt", "pt-BR", "nl", "pl", "ru", "uk", "tr", "ar", "hi", "ja", "ko", "zh",
                             "id", "vi", "sv"],
        "tts.minimax.model": ["speech-02-hd", "speech-02-turbo"],
        "tts.mistral.model": ["voxtral-mini-tts-2603"],
        "tts.gemini.model": ["gemini-2.5-flash-preview-tts", "gemini-2.5-pro-preview-tts"],
        "tts.gemini.voice": ["Zephyr", "Puck", "Charon", "Kore", "Fenrir", "Leda", "Orus", "Aoede", "Callirrhoe", "Autonoe", "Enceladus",
                             "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi", "Laomedeia", "Achernar",
                             "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird", "Zubenelgenubi", "Vindemiatrix", "Sadachbia",
                             "Sadaltager", "Sulafat"],
        "tts.neutts.model": ["neuphonic/neutts-air-q4-gguf", "neuphonic/neutts-air-q8-gguf", "neuphonic/neutts-air"],
        "tts.neutts.device": ["cpu", "cuda", "mps"],
        "tts.kittentts.model": ["KittenML/kitten-tts-nano-0.8-int8", "KittenML/kitten-tts-micro-0.8-int8", "KittenML/kitten-tts-mini-0.8-int8"],
        "tts.kittentts.voice": ["Jasper"],
        "tts.piper.voice": ["en_US-lessac-medium", "en_US-amy-medium", "en_US-ryan-high", "en_GB-alan-medium"],
    ]

    /// Lists that also take whatever the gateway's schema adds (a provider installed on the gateway, DeepInfra).
    static let schemaExtendedKeys: Set<String> = ["tts.provider", "stt.provider"]

    /// Every voice and model name is open-world: a value the lists do not know is shown and kept, never replaced.
    static let freeInputKeys: Set<String> = [
        "tts.edge.voice", "tts.openai.model", "tts.openai.voice", "tts.elevenlabs.voice_id", "tts.elevenlabs.model_id", "stt.openai.model",
        "tts.gemini.model", "tts.gemini.voice", "tts.xai.voice_id", "tts.xai.language", "tts.minimax.model", "tts.minimax.voice_id",
        "tts.mistral.model", "tts.mistral.voice_id", "tts.neutts.model", "tts.kittentts.model", "tts.kittentts.voice", "tts.piper.voice",
        "tts.deepinfra.model", "tts.deepinfra.voice", "stt.local.model", "stt.mistral.model", "stt.elevenlabs.model_id",
    ]

    /// Provider names as their makers write them (`VOICE_PROVIDER_LABELS`).
    static let providerLabels: [String: String] = [
        "xai": "xAI", "openai": "OpenAI", "elevenlabs": "ElevenLabs", "groq": "Groq", "mistral": "Mistral",
        "local": "Local", "edge": "Microsoft Edge", "gemini": "Google Gemini", "minimax": "MiniMax",
        "neutts": "NeuTTS", "kittentts": "KittenTTS", "piper": "Piper", "deepinfra": "DeepInfra",
    ]

    static let languageLabels: [String: String] = [
        "auto": "Automatic", "en": "English", "es": "Spanish", "fr": "French", "de": "German", "it": "Italian", "pt": "Portuguese",
        "pt-BR": "Portuguese (Brazil)", "nl": "Dutch", "pl": "Polish", "ru": "Russian", "uk": "Ukrainian", "tr": "Turkish", "ar": "Arabic",
        "hi": "Hindi", "ja": "Japanese", "ko": "Korean", "zh": "Chinese", "id": "Indonesian", "vi": "Vietnamese", "sv": "Swedish",
    ]

    static let optionLabels: [String: [String: String]] = [
        "stt.provider": providerLabels,
        "tts.provider": providerLabels,
        "tts.xai.language": languageLabels,
        "tts.neutts.device": ["cpu": "CPU", "cuda": "CUDA", "mps": "MPS"],
        "stt.local.model": ["tiny": "Tiny", "base": "Base", "small": "Small", "medium": "Medium", "large-v3": "Large v3"],
        // Microsoft's voice names read as a name and an accent; the id is what is saved.
        "tts.edge.voice": ["en-US-AriaNeural": "Aria (US)", "en-US-JennyNeural": "Jenny (US)", "en-US-AndrewNeural": "Andrew (US)",
                           "en-US-BrianNeural": "Brian (US)", "en-US-GuyNeural": "Guy (US)", "en-GB-SoniaNeural": "Sonia (UK)"],
    ]

    /// What an empty value means, where it means something (the gateway detects the language).
    static let emptyLabels: [String: String] = [
        "stt.local.language": "Automatic",
        "stt.elevenlabs.language_code": "Automatic",
    ]

    /// The unit a number is shown with on its row.
    static let units: [String: String] = ["voice.max_recording_seconds": "s"]

    // MARK: Grouping a page's fields (UX study #48)

    /// The selected provider's block: the picker and the fields that belong to one provider.
    static func isProviderField(_ key: String) -> Bool {
        key == "stt.provider" || key == "tts.provider" || provider(of: key) != nil
    }

    /// A page's fields in sections, as one inset list rather than a card each: a new section starts where the provider
    /// block starts or ends, and after a field whose description is its section's footer (`closesSection`).
    static func sections<Field>(_ fields: [Field], key: (Field) -> String, closesSection: (Field) -> Bool) -> [[Field]] {
        var sections: [[Field]] = []
        var current: [Field] = []
        var open = true
        for field in fields {
            if let last = current.last, !open || isProviderField(key(last)) != isProviderField(key(field)) {
                sections.append(current)
                current = []
            }
            current.append(field)
            open = !closesSection(field)
        }
        if !current.isEmpty { sections.append(current) }
        return sections
    }

    // MARK: This iPhone's rows (`src/voice-settings.tsx`)

    static let conversationNote = "To talk with a bot, \(DeviceWord.tap) Talk, the round button next to the message field."
    static let howHint = "Talking with a bot, voice memos, and what to do when a conversation pauses."

    // [gpt-live] Voice Model (docs/spec/3x-gpt-live.md §2)
    static func engineTitle(_ engine: TalkEngine) -> String { engine.title }
    static func engineHint(_ engine: TalkEngine) -> String {
        switch engine {
        case .gptLive:
            "OpenAI’s GPT-Live model talks with you, answers at once and can be talked over, while Hermes does the work. About 5¢\u{00A0}a\u{00A0}minute."   // #98: never "a minute." alone on a line
        // [grok-live] (docs/spec/3x-grok-live.md §2)
        case .grokLive:
            "Grok talks with you and can be talked over, while your bot does the work. Uses your SuperGrok or X Premium+ login on the computer, never an API\u{00A0}key."
        case .standard:
            "Your speech to text, the bot’s reply, then text to speech."
        }
    }
    static var engineNote: String { "GPT-Live needs an OpenAI key on the bot’s gateway; Grok Live needs the Hermes HQ add-on and your Grok login on the computer. If either can’t start, or the connection drops, Talk carries on with Standard. \(DeviceWord.onlyHere)" }
    static let sendOnReleaseHint = "When this is off, letting go stops the recording so you can play it back before sending."
    // [live words] (docs/spec/3x-live-words.md §5)
    static let liveWordsTitle = "Words as You Speak"
    static let liveWordsHint = "Your words show while you record a voice memo, dictate or talk with a bot, and they’re what gets sent."
    /// Under the switch: what happens on this device now.
    static func liveWordsNote(on: Bool, readiness: LiveWords.Readiness) -> String {
        let after = "Hermes turns your speech into text after you stop."
        let how: String
        switch (on, readiness) {
        case (false, _): how = "Off: \(after)"
        case (true, .downloading): how = "This \(DeviceWord.name) is getting its speech model ready. Until then, \(after)"
        case (true, .unavailable): how = "This \(DeviceWord.name) can’t show your words as you speak, so \(after)"
        case (true, _): how = "This \(DeviceWord.name) turns your speech into text as you talk, so memos, Dictate and Talk skip the speech to text on Hermes."
        }
        return "\(how) \(DeviceWord.onlyHere)"
    }
    // [live words] Word Fixes (spec 3x-live-words §5): fixes learned from memos fixed in review, and added here.
    static let wordFixesTitle = "Word Fixes"
    static let addWordFixTitle = "Add Word Fix"
    static func wordFixesValue(_ count: Int) -> String? { count == 0 ? nil : "\(count)" }
    static func wordFixHeard(_ heard: String) -> String { "Heard as “\(heard)”" }
    static var wordFixesNote: String {
        "Words you fix in a voice memo before you send it are kept here, and written that way the next time you speak. Your bots’ names, Hermes and Claude Code are always spelled right, and “uh” and “um” are left out. \(DeviceWord.onlyHere)"
    }
    static var wordFixesEmpty: String {
        "No fixes yet. To fix a word, stop a voice memo before sending it, then \(DeviceWord.tap) its words. Your bots’ names, Hermes and Claude Code are always spelled right, and “uh” and “um” are left out."
    }
    static let addWordFixNote = "Whenever you say the first, the second is written instead."
    static let diagnosticsHint = "Test the microphone, playback and transcription, and copy what \(DeviceWord.system) reports about audio."
    static var readRepliesHint: String { "Speaks each new reply in the chat on screen with the voice below. A voice conversation always speaks its replies. \(DeviceWord.onlyHere)" }

    static func memoNote(sendOnRelease: Bool) -> String {
        // [mac] Stress test 2026-10-28 #27: a mouse clicks and holds, and a Mac has no on-screen keyboard: its
        // Dictation types by voice.
        if DeviceWord.isMac {
            return sendOnRelease
                ? "Voice memos: click and hold the mic to record, let go to send. Click it to record hands-free. Type by voice with macOS Dictation."
                : "Voice memos: click and hold the mic to record, let go to play it back before you send. Click it to record hands-free. Type by voice with macOS Dictation."
        }
        return sendOnRelease
            ? "Voice memos: hold the mic to record, let go to send. \(DeviceWord.Tap) it to record hands-free. Type by voice with the keyboard’s mic."
            : "Voice memos: hold the mic to record, let go to play it back before you send. \(DeviceWord.Tap) it to record hands-free. Type by voice with the keyboard’s mic."
    }

    /// The phone's own rows in Settings search; each opens its page.
    static let searchRows: [SettingsSearchEntry] = [
        .init(id: "app:read-replies", label: "Read Replies Aloud", context: "Text to Speech",
              keywords: ["read aloud", "speak replies", "auto speak", "voice", "tts"], target: .page("voice.speech")),
        .init(id: "app:reply-voice", label: "\(DeviceWord.name) Voice", context: "Text to Speech",
              keywords: ["read aloud", "voice", "on-device voice", "computer voice", "tts", "speech"], target: .page("voice.speech")),
        .init(id: "app:voice-diagnostics", label: "Voice Diagnostics", context: "Voice Conversation",
              keywords: ["microphone test", "playback", "transcription", "audio report", "voice"], target: .page("voice.conversation")),
        .init(id: "app:send-on-release", label: "Send Memo on Release", context: "Voice Conversation",
              keywords: ["voice memo", "hold to record", "review", "mic"], target: .page("voice.conversation")),
        .init(id: "app:how-voice-works", label: "How Voice Works", context: "Voice Conversation",
              keywords: ["talk", "voice conversation", "help", "memo"], target: .page("voice.conversation")),
    ]
}
