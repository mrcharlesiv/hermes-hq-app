// The ways into voice that are menus (docs/spec/3x-talk.md §5.4-§5.6) and the one place that opens Settings › Voice
// from a chat.

import UIKit

@MainActor enum TalkMenus {
    // MARK: The voice options menu (§5.2)

    enum Option: String { case start, readReplies = "read-replies", dictate, how, settings }
    enum Dictation { case hidden, on, speechToTextOff }

    /// Dictation starts through this (set by the dictation feature, §8). Nil: the item is left out.
    static var dictate: ((ChatViewController) -> Void)?

    /// The menu's model, in the web's order (`W:src/ui-voice/voice-menu.ts:51-64`). `asList` is the form VoiceOver's
    /// "Voice options" action shows (an action sheet has no checkmarks, so the switch says what a tap will do).
    /// `voice`: [voice picker] the live engine's Voice submenu, under Start Voice Conversation (nil for Standard).
    static func optionNodes(readsAloud: Bool, dictation: Dictation, asList: Bool = false, voice: BotMenuNode? = nil,
                            pick: @escaping (Option) -> Void) -> [BotMenuNode] {
        func item(_ option: Option, _ title: String, _ symbol: String) -> BotMenuNode {
            var node = BotMenuNode.action(title, symbol) { pick(option) }
            node.identifier = "voice.options.\(option.rawValue)"
            return node
        }
        var read = item(.readReplies, asList ? (readsAloud ? "Turn Off Read Replies Aloud" : "Turn On Read Replies Aloud") : "Read Replies Aloud",
                        "speaker.wave.2")
        read.checked = readsAloud && !asList
        read.keepsOpen = !asList
        var middle = [read]
        if dictation != .hidden {
            var dictate = item(.dictate, "Dictate with Hermes", "mic")
            if dictation == .speechToTextOff {
                dictate.disabled = true
                dictate.subtitle = "Speech to Text is off"
            }
            middle.append(dictate)
        }
        var top = [item(.start, "Start Voice Conversation", "waveform")]
        if let voice { top.append(voice) }
        return [
            BotMenuNode(title: "", kind: .inline(top)),
            BotMenuNode(title: "", kind: .inline(middle)),
            BotMenuNode(title: "", kind: .inline([item(.how, "How Voice Works", "info.circle"), item(.settings, "Voice Settings…", "gearshape")])),
        ]
    }

    static func optionsTitle(name: String) -> String { "Voice with \(name)" }

    /// Dictate with Hermes for one chat screen: offered, and whether the bot's Speech to Text is off (unknown counts as on).
    /// [mac] The Chat menu's Dictate item reads it too.
    static func dictation(for screen: ChatViewController) -> Dictation {
        guard dictate != nil else { return .hidden }
        let chat = screen.voice.talk.chat
        let known = chat.flatMap { VoiceGateway.knownConfig(client: $0.voiceClient, profile: $0.profile.isEmpty ? nil : $0.profile) }
        return known?.sttEnabled == false ? .speechToTextOff : .on
    }

    /// The menu for one chat screen. "Speech to Text is off" is known from the settings kept for the bot; unknown
    /// counts as on.
    static func options(for screen: ChatViewController, asList: Bool = false) -> [BotMenuNode] {
        let dictation = dictation(for: screen)
        let voice = asList ? nil : voiceNode(for: screen)
        return optionNodes(readsAloud: TalkController.readsRepliesAloud, dictation: dictation, asList: asList, voice: voice) { [weak screen] option in
            guard let screen else { return }
            switch option {
            case .start: screen.beginTalk()
            case .readReplies:
                TalkController.readsRepliesAloud.toggle()
                screen.composer.refreshTalkMenu()
                screen.voice.reader.saySwitch()   // [mac] the ⋯ and Chat menus' "Read Replies Aloud is on/off" (Mac only)
            case .dictate: dictate?(screen)
            case .how: screen.voice.talk.showHowVoiceWorks()
            case .settings: openVoiceSettings(from: screen)
            }
        }
    }

    // MARK: [voice picker] Voice ▸ (this bot's GPT-Live or Grok Live voice)

    /// The engine Talk would start with here, as far as this device knows without asking: nil for Standard.
    private static func liveEngine(for chat: any ChatVoiceTurns) -> TalkEngine? {
        let profile = chat.profile.isEmpty ? nil : chat.profile
        let mode = VoiceGateway.knownConfig(client: chat.voiceClient, profile: profile)?.chatMode
        let engine = TalkController.chosenEngine ?? mode ?? .standard
        return engine.isLive ? engine : nil
    }

    static func voiceNode(for screen: ChatViewController) -> BotMenuNode? {
        guard let chat = screen.voice.talk.chat, let engine = liveEngine(for: chat) else { return nil }
        let client = chat.voiceClient, profile = chat.profile.isEmpty ? nil : chat.profile, name = screen.voice.talk.name
        let known: String? = switch engine {
        case .gptLive: VoiceGateway.knownLiveStatus(client: client, profile: profile)?.voice
        case .grokLive: VoiceGateway.knownGrokStatus(client: client, profile: profile)?.voice
        case .standard: nil
        }
        let load: @MainActor (@escaping @MainActor ([BotMenuNode]) -> Void) -> Void = { [weak screen] done in
            Task { @MainActor in
                let raw: String? = switch engine {
                case .gptLive: await VoiceGateway.liveStatus(client: client, profile: profile)?.voice
                case .grokLive: await VoiceGateway.grokStatus(client: client, profile: profile)?.voice
                case .standard: nil
                }
                let current = LiveVoices.normalized(raw, engine)
                var nodes: [BotMenuNode] = []
                if !LiveVoices.voices(engine).contains(where: { $0.id == current }) {
                    // A voice written by hand in config.yaml: shown ticked, kept until another is picked.
                    var own = BotMenuNode.action(LiveVoices.name(current, engine), nil) {}
                    own.checked = true
                    own.identifier = "voice.options.voice.custom"
                    nodes.append(own)
                }
                done(nodes + LiveVoices.voices(engine).map { voice in
                    var node = BotMenuNode.action(voice.name, nil) {
                        guard voice.id != current else { return }
                        Haptics.play(.selection)
                        Task { @MainActor in
                            do {
                                try await LiveVoiceSaver.save(engine, voice: voice.id, client: client, profile: profile)
                                MenusHUD.show("\(name) will speak as \(voice.name)", symbol: "waveform", in: screen?.view)
                            } catch {
                                Haptics.play(.error)
                                MenusHUD.show("Couldn’t change the voice", symbol: "exclamationmark.triangle", in: screen?.view)
                            }
                        }
                    }
                    node.subtitle = voice.feel
                    node.checked = voice.id == current
                    node.identifier = "voice.options.voice.\(voice.id)"
                    return node
                })
            }
        }
        var node = BotMenuNode(title: "Voice", kind: .submenu([BotMenuNode(title: "", kind: .deferred(load))]))
        node.image = "person.wave.2"
        node.subtitle = known.map { LiveVoices.name(LiveVoices.normalized($0, engine), engine) }
        node.identifier = "voice.options.voice"
        return node
    }

    static func optionsMenu(for screen: ChatViewController) -> UIMenu {
        BotMenuNode.uiMenu(options(for: screen), title: optionsTitle(name: screen.voice.talk.name)).menu
    }

    /// VoiceOver's "Voice options": the same choices as a list.
    static func presentOptionsList(from screen: ChatViewController) {
        guard screen.presentedViewController == nil else { return }
        BotMoreSheet.present(options(for: screen, asList: true), title: optionsTitle(name: screen.voice.talk.name), from: screen,
                             source: screen.composer.primaryView)
    }

    // MARK: The + menu (§5.4)

    /// Voice Memo and Talk with <name>, each left out when it could not work.
    static func plusItems(micAvailable: Bool, talkAllowed: Bool, name: String, memo: @escaping () -> Void, talk: @escaping () -> Void)
        -> (memo: [UIMenuElement], talk: [UIMenuElement]) {
        var memoItems: [UIMenuElement] = [], talkItems: [UIMenuElement] = []
        if micAvailable {
            let action = UIAction(title: "Voice Memo", image: UIImage(systemName: "mic")) { _ in memo() }
            action.accessibilityIdentifier = "composer.plus.memo"
            memoItems.append(action)
        }
        if talkAllowed {
            let action = UIAction(title: "Talk with \(name)", image: UIImage(systemName: "waveform")) { _ in talk() }
            action.accessibilityIdentifier = "composer.plus.talk"
            talkItems.append(action)
        }
        return (memoItems, talkItems)
    }

    // MARK: Settings

    /// Settings, on its Voice section when there is one (set by the settings wiring), from `presenter`.
    static func openVoiceSettings(from presenter: UIViewController) {
        guard let model = TalkWiring.model else { return }
        var top = presenter
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        SettingsScreens.presentSettings(from: top, services: model) { navigation in
            guard let root = navigation.viewControllers.first as? SettingsRootController,
                  let page = TalkWiring.voiceSettingsPage?(model, root.router) else { return }
            root.router.push(page)
        }
    }
}
