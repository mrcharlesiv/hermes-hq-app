// [voice picker] Settings › Voice › Voice Conversation's voice list (under Voice Model) and the chat's Voice with … ›
// Voice submenu: GPT-Live's and Grok Live's voices, each with its recorded sample. Settings saves the pick for every bot;
// the chat's menu for that bot alone. A conversation reads the voice when it starts, so a change is heard on the next one.

import AVFoundation
import SwiftUI

// MARK: - The samples

@MainActor @Observable final class LiveVoiceSamples: NSObject, AVAudioPlayerDelegate {
    static let shared = LiveVoiceSamples()

    /// `engine/voice` of the sample playing.
    private(set) var playing: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var holds = false

    static func tag(_ engine: TalkEngine, _ id: String) -> String { "\(engine.rawValue)/\(id)" }

    func toggle(_ engine: TalkEngine, _ id: String) {
        if playing == Self.tag(engine, id) { stop() } else { play(engine, id) }
    }

    func play(_ engine: TalkEngine, _ id: String) {
        stop()
        guard let url = LiveVoices.sampleURL(engine, id) else {
            AppLog.note("voice", "voice sample missing: \(LiveVoices.sampleName(engine, id))")
            return
        }
        let tag = Self.tag(engine, id)
        playing = tag
        Task {
            do { try await AudioSessionCoordinator.shared.acquire(.speech) } catch {
                if playing == tag { playing = nil }
                return
            }
            // Another tap while the session was coming up.
            guard playing == tag else { AudioSessionCoordinator.shared.release(.speech); return }
            holds = true
            do {
                let made = try AVAudioPlayer(contentsOf: url)
                made.delegate = self
                player = made
                made.play()
                AppLog.trace("voice", "voice sample playing: \(tag)")
            } catch {
                AppLog.note("voice", "voice sample failed: \(AppLog.scrub(String(describing: error)))")
                stop()
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
        if holds {
            holds = false
            AudioSessionCoordinator.shared.release(.speech)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current) == finished else { return }
            self.stop()
        }
    }
}

// MARK: - Saving

@MainActor enum LiveVoiceSaver {
    /// Every bot on the gateway: the default one through Settings' shared store (the page shows it at once), the rest on
    /// their own profiles. Answers the names of the bots it could not save for.
    static func saveForEveryBot(_ engine: TalkEngine, voice: String, services: any AppServices) async -> [String] {
        guard let key = LiveVoices.key(engine), let patch = LiveVoices.patch(engine, voice: voice),
              let settings = services as? GatewaySettingsServices, let api = settings.settingsAPI else { return [] }
        if settings.isReadOnlyGateway { return ["your bots"] }
        settings.configStore?.set(key, .string(voice))
        settings.configStore?.flush()
        let others = services.bots.filter { !BotModelPages.isDefault($0.id) }
        // Side by side: twelve bots, one round trip each.
        let saves = others.map { bot in
            Task { @MainActor () -> String? in
                do { try await GatewaySettingsAPI(client: api.client, profile: bot.id).saveConfig(patch); return nil } catch {
                    AppLog.note("voice", "voice save failed for a bot: \(type(of: error))")
                    return bot.name
                }
            }
        }
        var failed: [String] = []
        for save in saves { if let name = await save.value { failed.append(name) } }
        AppLog.note("voice", "\(engine.rawValue) voice set to \(voice) for \(others.count + 1 - failed.count) of \(others.count + 1) bots")
        return failed
    }

    /// One bot (the chat's menu).
    static func save(_ engine: TalkEngine, voice: String, client: any GatewayClient, profile: String?) async throws {
        guard let patch = LiveVoices.patch(engine, voice: voice) else { return }
        let own = profile.map(BotModelPages.isDefault) ?? true
        try await GatewaySettingsAPI(client: client, profile: own ? nil : profile).saveConfig(patch)
        AppLog.note("voice", "\(engine.rawValue) voice set to \(voice) for one bot")
    }
}

// MARK: - Settings' list

/// The section under Voice Model. Standard speaks with the Text to Speech voice, so it points there instead.
struct LiveVoiceSection: View {
    let engine: TalkEngine
    let router: SettingsRouter
    @State private var chosen: String?
    @State private var failed: [String] = []
    @State private var samples = LiveVoiceSamples.shared

    private var store: GatewayConfigStore? { router.gatewaySettings?.configStore }
    private var current: String { chosen ?? LiveVoices.current(engine, config: store?.config) }

    var body: some View {
        if engine.isLive {
            Section {
                ForEach(LiveVoices.voices(engine)) { voice in row(voice) }
                if !LiveVoices.voices(engine).contains(where: { $0.id == current }) {
                    // A voice written by hand in config.yaml: shown, kept until another is picked.
                    HQOptionRowLabel(title: LiveVoices.name(current, engine), selected: true)
                        .hqRowPadding(4)
                        .accessibilityIdentifier("voice.settings.voice.custom")
                }
            } header: { HQSectionLabel {
                Text("\(engine.title) Voice")
            } } footer: { HQSectionFooter {
                Text(footer).accessibilityIdentifier("voice.settings.voice.footer")
            } }
            .onChange(of: engine) { _, _ in chosen = nil; failed = []; samples.stop() }
            .onDisappear { samples.stop() }
        } else {
            Section {
                VoiceHintRow(title: "Standard Voice", hint: "Standard speaks with your Text to Speech voice.") {
                    if let page = ConfigCatalog.page("voice.speech") { ConfigScreens.open(page: page, router: router) }
                }
                .accessibilityIdentifier("voice.settings.voice.standard")
            } header: { HQSectionLabel {
                Text("Voice")
            } }
        }
    }

    private var footer: String {
        var text = "\(DeviceWord.Tap) ▶ to hear a voice. The one you pick is saved for all your bots and is heard the next time you talk. To give one bot its own voice, use Voice with … › Voice in its chat."
        if !failed.isEmpty { text += " Couldn’t save it for \(ListFormatter.localizedString(byJoining: failed))." }
        return text
    }

    private func row(_ voice: LiveVoice) -> some View {
        let selected = current == voice.id
        let isPlaying = samples.playing == LiveVoiceSamples.tag(engine, voice.id)
        return HStack(alignment: .center, spacing: DeviceWord.isMac ? MacForm.radioGap : 12) {
            Button {
                pick(voice)
            } label: {
                HStack(alignment: DeviceWord.isMac ? .firstTextBaseline : .center, spacing: DeviceWord.isMac ? MacForm.radioGap : 16) {
                    HQRadioMark(selected: selected)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.name).foregroundStyle(Color.hqLabel)
                        Text(voice.feel).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    }
                    Spacer(minLength: 0)
                    HQCheckMark(selected: selected)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("voice.settings.voice.\(voice.id)")
            Button {
                Haptics.play(.selection)
                samples.toggle(engine, voice.id)
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))   // a11y-font-ok: a glyph sized to its fixed 44 pt button
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.hqTint)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Stop \(voice.name)" : "Hear \(voice.name)")
            .accessibilityIdentifier("voice.settings.voice.\(voice.id).play")
        }
        .hqRowPadding(0)
        .hqRadioRow()
    }

    private func pick(_ voice: LiveVoice) {
        Haptics.play(.selection)
        samples.play(engine, voice.id)
        guard current != voice.id else { return }
        chosen = voice.id
        failed = []
        let engine = engine, services = router.services
        Task {
            let missed = await LiveVoiceSaver.saveForEveryBot(engine, voice: voice.id, services: services)
            if chosen == voice.id { failed = missed }
        }
    }
}
