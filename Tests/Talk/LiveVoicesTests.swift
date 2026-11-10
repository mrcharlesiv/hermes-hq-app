// [voice picker] GPT-Live's and Grok Live's voices: the lists, what is saved where, the bundled samples and the chat
// menu's Voice ▸.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Live voices")
@MainActor
struct LiveVoicesTests {
    @Test func everyVoiceHasItsSampleInTheApp() {
        for engine in [TalkEngine.gptLive, .grokLive] {
            #expect(!LiveVoices.voices(engine).isEmpty)
            for voice in LiveVoices.voices(engine) {
                #expect(LiveVoices.sampleURL(engine, voice.id) != nil, "no sample for \(engine.rawValue) \(voice.id)")
                #expect(voice.id == voice.id.lowercased())
            }
        }
        #expect(LiveVoices.voices(.standard).isEmpty)
    }

    @Test func theListsMatchWhatTheVendorsTake() {
        // Hermes's GPT_LIVE_VOICES (tools/voice_live.py) and xAI's five.
        #expect(Set(LiveVoices.voices(.gptLive).map(\.id)) == ["marin", "cedar", "quartz", "ripple", "vesper", "willow", "stone", "gleam",
                                                              "meridian", "bossa", "tempo", "beacon", "delta", "cinder"])
        #expect(Set(LiveVoices.voices(.grokLive).map(\.id)) == ["ara", "eve", "leo", "rex", "sal"])
        #expect(LiveVoices.voices(.gptLive).contains { $0.id == LiveVoices.defaultVoice(.gptLive) })
        #expect(LiveVoices.voices(.grokLive).contains { $0.id == LiveVoices.defaultVoice(.grokLive) })
    }

    @Test func aBotsVoiceIsReadFromItsConfig() {
        let config: JSONValue = ["voice": ["gpt_live": ["voice": " Cedar "], "grok_live": ["model": "grok-voice-latest"]]]
        #expect(LiveVoices.current(.gptLive, config: config) == "cedar")
        // Not set: the engine's default.
        #expect(LiveVoices.current(.grokLive, config: config) == "eve")
        #expect(LiveVoices.current(.gptLive, config: nil) == "marin")
        // A voice written by hand is kept and named as written.
        #expect(LiveVoices.current(.grokLive, config: ["voice": ["grok_live": ["voice": "custom1"]]]) == "custom1")
        #expect(LiveVoices.name("custom1", .grokLive) == "Custom1")
        #expect(LiveVoices.name("rex", .grokLive) == "Rex")
    }

    @Test func aPickChangesOnlyTheOneVoice() {
        #expect(LiveVoices.patch(.gptLive, voice: "quartz") == ["voice": ["gpt_live": ["voice": "quartz"]]])
        #expect(LiveVoices.patch(.grokLive, voice: "rex") == ["voice": ["grok_live": ["voice": "rex"]]])
        #expect(LiveVoices.patch(.standard, voice: "x") == nil)
        #expect(LiveVoices.key(.gptLive) == "voice.gpt_live.voice")
        #expect(LiveVoices.key(.grokLive) == "voice.grok_live.voice")
    }

    @Test func theChatMenuShowsVoiceUnderStart() {
        var voice = BotMenuNode(title: "Voice", kind: .submenu([]))
        voice.identifier = "voice.options.voice"
        let nodes = TalkMenus.optionNodes(readsAloud: false, dictation: .on, voice: voice) { _ in }
        #expect(nodes.count == 3)
        guard case .inline(let top) = nodes[0].kind else { Issue.record("first group not inline"); return }
        #expect(top.map(\.identifier) == ["voice.options.start", "voice.options.voice"])
    }
}
