// [voice picker] The voices GPT-Live and Grok Live speak with, and where each bot keeps its choice (owner 2026-11-04: "It'd
// be nice if I could very easily like change the voices"). Both read the voice from the bot's own config.yaml when a
// conversation starts: `voice.gpt_live.voice` (Hermes, `HA:tools/voice_live.py` GPT_LIVE_VOICES, default marin) and
// `voice.grok_live.voice` (the add-on's grok_live.py, default eve). Every voice has a short recorded sample in the app
// (App/Resources/VoiceSamples, "Hi, I'm <name>. This is how I'll sound when we talk."), so the ▶ costs nothing.

import Foundation

nonisolated struct LiveVoice: Sendable, Equatable, Identifiable {
    /// What config.yaml holds (lower case).
    var id: String
    var name: String
    /// A few words on how it sounds: its pitch from the sample, and xAI's own words for Grok's.
    var feel: String
}

nonisolated enum LiveVoices {
    static func key(_ engine: TalkEngine) -> String? {
        switch engine {
        case .gptLive: "voice.gpt_live.voice"
        case .grokLive: "voice.grok_live.voice"
        case .standard: nil
        }
    }

    static func defaultVoice(_ engine: TalkEngine) -> String {
        switch engine {
        case .gptLive: "marin"
        case .grokLive: "eve"
        case .standard: ""
        }
    }

    /// In the order the list shows them: higher voices first.
    static func voices(_ engine: TalkEngine) -> [LiveVoice] {
        switch engine {
        case .gptLive: gptLive
        case .grokLive: grokLive
        case .standard: []
        }
    }

    private static let gptLive: [LiveVoice] = [
        .init(id: "delta", name: "Delta", feel: "Higher"),
        .init(id: "bossa", name: "Bossa", feel: "Higher"),
        .init(id: "quartz", name: "Quartz", feel: "Higher"),
        .init(id: "marin", name: "Marin", feel: "Higher"),
        .init(id: "willow", name: "Willow", feel: "Middle"),
        .init(id: "gleam", name: "Gleam", feel: "Middle"),
        .init(id: "cedar", name: "Cedar", feel: "Lower"),
        .init(id: "beacon", name: "Beacon", feel: "Lower"),
        .init(id: "cinder", name: "Cinder", feel: "Lower"),
        .init(id: "stone", name: "Stone", feel: "Lower"),
        .init(id: "vesper", name: "Vesper", feel: "Lower"),
        .init(id: "tempo", name: "Tempo", feel: "Lower"),
        .init(id: "ripple", name: "Ripple", feel: "Deep"),
        .init(id: "meridian", name: "Meridian", feel: "Deep"),
    ]

    private static let grokLive: [LiveVoice] = [
        .init(id: "ara", name: "Ara", feel: "Higher · warm, friendly"),
        .init(id: "eve", name: "Eve", feel: "Higher · energetic, upbeat"),
        .init(id: "sal", name: "Sal", feel: "Middle · smooth, balanced"),
        .init(id: "leo", name: "Leo", feel: "Lower"),
        .init(id: "rex", name: "Rex", feel: "Lower · confident, clear"),
    ]

    /// The voice a bot's config names, else the engine's default. A voice the list does not know is kept as written.
    static func current(_ engine: TalkEngine, config: JSONValue?) -> String {
        guard let key = key(engine) else { return "" }
        return normalized(ConfigText.text(config.flatMap { ConfigPath.get($0, key) }), engine)
    }

    static func normalized(_ raw: String?, _ engine: TalkEngine) -> String {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? defaultVoice(engine) : text.lowercased()
    }

    static func name(_ id: String, _ engine: TalkEngine) -> String {
        voices(engine).first { $0.id == id }?.name ?? (id.isEmpty ? "" : id.prefix(1).uppercased() + id.dropFirst())
    }

    /// `PUT /api/config` deep-merges objects, so only the one voice changes.
    static func patch(_ engine: TalkEngine, voice: String) -> JSONValue? {
        switch engine {
        case .gptLive: .object(["voice": .object(["gpt_live": .object(["voice": .string(voice)])])])
        case .grokLive: .object(["voice": .object(["grok_live": .object(["voice": .string(voice)])])])
        case .standard: nil
        }
    }

    /// The bundled sample's resource name (`.m4a`).
    static func sampleName(_ engine: TalkEngine, _ id: String) -> String { "voice-\(engine.rawValue)-\(id)" }

    static func sampleURL(_ engine: TalkEngine, _ id: String, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: sampleName(engine, id), withExtension: "m4a")
    }
}
