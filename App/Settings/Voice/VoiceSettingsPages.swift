// Settings › Voice (docs/spec/3x-talk.md §9.1–§9.3): the section's page list and its three pages. Voice Conversation
// holds this iPhone's own rows (Voice Model, How Voice Works, Send Memo on Release, Voice Diagnostics); Speech to Text and Text to
// Speech draw the gateway's fields with the generic renderer, one provider's fields at a time, with Read Replies Aloud
// (this iPhone) first on Text to Speech. The pages open with or without the gateway's settings.

import SwiftUI
import UIKit

@MainActor enum VoiceSettingsScreens {
    static func openSection(router: SettingsRouter) { router.push(makeSection(router: router)) }

    /// The Voice page list (also where "Voice Settings…" lands).
    static func makeSection(router: SettingsRouter) -> UIViewController {
        SettingsPageController(title: "Voice", VoiceSectionView(router: router))
    }

    static func makePage(_ page: ConfigPage, router: SettingsRouter) -> UIViewController? {
        guard page.section == "voice" else { return nil }
        let store = router.gatewaySettings?.configStore
        let controller: UIViewController
        switch page.id {
        case "conversation":
            controller = SettingsPageController(title: page.title, VoiceConversationPage(router: router))
        case "transcription":
            let made = SettingsPageController(title: page.title, VoiceFieldsPage(page: page, store: store, router: router, readsReplies: false))
            made.onDisappear = { store?.flush() }
            controller = made
        case "speech":
            let made = SettingsPageController(title: page.title, VoiceFieldsPage(page: page, store: store, router: router, readsReplies: true))
            made.onDisappear = { store?.flush() }
            controller = made
        default:
            return nil
        }
        return controller
    }

    /// The iPhone-voice notice's Fix… (§7.7): Settings opens on this bot's Text to Speech page with its provider picker
    /// on top. A bot with its own profile edits that profile's settings (`?profile=`); the default bot the gateway's.
    static func openTextToSpeech(profile: String, client: any GatewayClient, botName: String, from presenter: UIViewController) {
        guard let model = TalkWiring.model, let page = ConfigCatalog.page("voice.speech") else { return }
        var top = presenter
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        SettingsScreens.presentSettings(from: top, services: model) { navigation in
            guard let root = navigation.viewControllers.first as? SettingsRootController else { return }
            let router = root.router
            let own = profile.isEmpty || profile == "default"
            let store = own ? router.gatewaySettings?.configStore
                : GatewayConfigStore(api: GatewaySettingsAPI(client: client, profile: profile), readOnly: model.readOnlyGateway)
            let made = SettingsPageController(title: page.title, VoiceFieldsPage(page: page, store: store, router: router, readsReplies: true,
                                                                                  botName: own ? nil : botName))
            made.onDisappear = { store?.flush() }
            var controllers: [UIViewController] = [makeSection(router: router), made]
            if let store, let editor = ConfigScreens.makeField("tts.provider", store: store, router: router) {
                controllers.append(editor)
                Task { await store.load() }
            }
            router.push(controllers)
        }
    }

    static func openDiagnostics(router: SettingsRouter) {
        let model = VoiceDiagnosticsModel(services: router.services)
        let page = SettingsPageController(title: "Voice Diagnostics", VoiceDiagnosticsView(model: model))
        page.onDisappear = { model.pageLeft() }
        router.push(page)
    }
}

// MARK: - The section

struct VoiceSectionView: View {
    let router: SettingsRouter

    var body: some View {
        List { Group {
            Section {
                ForEach(VoiceSettingsCatalog.section.pages) { page in
                    ValueRow(title: page.title, value: nil, systemImage: page.symbol) { ConfigScreens.open(page: page, router: router) }
                        .accessibilityIdentifier("config-page.\(page.key)")
                }
            } footer: { HQSectionFooter {
                // UX study 2026-10-21 #50: Voice sits under On Your Gateway, so this says which parts are this device's.
                Text("Talking with your bots, and the voices that listen and answer. Speech to Text and Text to Speech are saved on \(HostWord.phrase); Voice Conversation, Read Replies Aloud and the \(DeviceWord.name)’s own voice are kept on this \(DeviceWord.name).")
            } }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        // [mac] Stress test 2026-10-28 #98: the Voice Model header sat 9 pt under the Desktop Look bar.
        .contentMargins(.top, MacInset.top(otherwise: 0), for: .scrollContent)
        .task { await router.gatewaySettings?.configStore?.load() }
        .accessibilityIdentifier("config-section.voice")
    }
}

/// A row that opens something: a title, a line that says what, and a chevron.
struct VoiceHintRow: View {
    var title: String
    var hint: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                    Text(hint).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                SettingsChevron()  // [mac] Stress test 2026-10-28 #51: no › on the Mac
            }
            .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Voice Conversation

struct VoiceConversationPage: View {
    let router: SettingsRouter
    @State private var sendOnRelease = MemoController.shared.sendOnRelease
    @State private var engine = TalkController.chosenEngine
    @State private var liveWords = LiveWords.isOn   // [live words]
    @State private var liveWordsReadiness = LiveWords.readiness
    @State private var betterWords = ParakeetWords.isOn   // [more accurate words]
    @State private var betterWordsReadiness = ParakeetWords.readiness
    @State private var wordFixes = WordFixes.all.count

    /// [gpt-live] This device's choice, else the gateway's `voice.voice_chat_mode`.
    private var shownEngine: TalkEngine {
        if let engine { return engine }
        guard let config = router.gatewaySettings?.configStore?.config else { return .standard }
        return TalkEngine(mode: ConfigText.text(ConfigPath.get(config, "voice.voice_chat_mode")))
    }

    var body: some View {
        List { Group {
            Section {
                ForEach(TalkEngine.allCases, id: \.self) { choice in
                    Button {
                        Haptics.play(.selection)
                        engine = choice
                        TalkController.chosenEngine = choice
                    } label: {
                        HStack(alignment: DeviceWord.isMac ? .firstTextBaseline : .center, spacing: DeviceWord.isMac ? MacForm.radioGap : 16) {   // [mac] Stress test 2026-10-28 #51 (round 6): the radio on the first line, not centred on the hint; round 7: the one radio gap
                            HQRadioMark(selected: shownEngine == choice)   // [mac] Stress test 2026-10-28 #51: a leading radio on the Mac
                            VStack(alignment: .leading, spacing: 3) {
                                Text(VoiceSettingsCatalog.engineTitle(choice)).foregroundStyle(Color.hqLabel)
                                Text(VoiceSettingsCatalog.engineHint(choice)).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            HQCheckMark(selected: shownEngine == choice)
                        }
                        .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                        .contentShape(Rectangle())
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(shownEngine == choice ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("voice.settings.engine.\(choice.rawValue)")
                    .hqRadioRow()   // [mac] Stress test 2026-10-28 #51 (round 6)
                }
            } header: { HQSectionLabel {
                Text("Voice Model")
            } } footer: { HQSectionFooter {
                Text(VoiceSettingsCatalog.engineNote)
            } }
            LiveVoiceSection(engine: shownEngine, router: router)   // [voice picker]
            Section {
                VoiceHintRow(title: "How Voice Works", hint: VoiceSettingsCatalog.howHint) {
                    guard let presenter = router.presenter else { return }
                    TalkIntroSheet.present(.info, name: "your bot", from: presenter)
                }
                .accessibilityIdentifier("voice.settings.how")
            } header: { HQSectionLabel {
                // Stress test 2026-10-28 #98, round 2 (both): every section on the page is named, not only the first.
                Text("Help")
            } } footer: { HQSectionFooter {
                // UX study #112: one line under the row, not a paragraph above it; How Voice Works explains the rest.
                Text(VoiceSettingsCatalog.conversationNote).accessibilityIdentifier("voice.settings.note")
            } }
            Section {
                SwitchRow(title: VoiceSettingsCatalog.liveWordsTitle, subtitle: VoiceSettingsCatalog.liveWordsHint, isOn: Binding(
                    get: { liveWords },
                    set: { on in
                        Haptics.play(.selection)
                        liveWords = on
                        UserDefaults.standard.set(on, forKey: LiveWords.settingKey)
                        LiveWords.prepare()
                    }))
                    .accessibilityIdentifier("voice.settings.live-words")
                if liveWords {
                    SwitchRow(title: VoiceSettingsCatalog.betterWordsTitle, subtitle: VoiceSettingsCatalog.betterWordsHint, isOn: Binding(
                        get: { betterWords },
                        set: { on in
                            Haptics.play(.selection)
                            betterWords = on
                            ParakeetWords.setOn(on)
                        }))
                        .accessibilityIdentifier("voice.settings.better-words")
                }
                ValueRow(title: VoiceSettingsCatalog.wordFixesTitle, value: VoiceSettingsCatalog.wordFixesValue(wordFixes)) {
                    router.push(VoiceSettingsCatalog.wordFixesTitle, WordFixesPage(router: router))
                }
                .accessibilityIdentifier("voice.settings.word-fixes")
            } header: { HQSectionLabel {
                Text("Live Words")
            } } footer: { HQSectionFooter {
                // With the larger model listening, Apple's engine (and whether it can run here) no longer matters.
                Text([VoiceSettingsCatalog.liveWordsNote(on: liveWords, readiness: betterWords && betterWordsReadiness == .ready ? .unknown : liveWordsReadiness),
                      VoiceSettingsCatalog.betterWordsNote(on: liveWords && betterWords, readiness: betterWordsReadiness)]
                    .compactMap { $0 }.joined(separator: " "))
                    .accessibilityIdentifier("voice.settings.live-words-note")
            } }
            .onReceive(NotificationCenter.default.publisher(for: LiveWords.readinessChanged)) { _ in
                liveWordsReadiness = LiveWords.readiness
                betterWordsReadiness = ParakeetWords.readiness
            }
            .onReceive(NotificationCenter.default.publisher(for: WordFixes.changed)) { _ in wordFixes = WordFixes.all.count }
            Section {
                SwitchRow(title: "Send Memo on Release", subtitle: VoiceSettingsCatalog.sendOnReleaseHint, isOn: Binding(
                    get: { sendOnRelease },
                    set: { on in
                        Haptics.play(.selection)
                        sendOnRelease = on
                        UserDefaults.standard.set(on, forKey: MemoController.sendOnReleaseKey)
                    }))
                    .accessibilityIdentifier("voice.settings.send-on-release")
            } header: { HQSectionLabel {
                Text("Voice Memos")
            } } footer: { HQSectionFooter {
                Text(VoiceSettingsCatalog.memoNote(sendOnRelease: sendOnRelease))
                    .accessibilityIdentifier("voice.settings.memo-note")
            } }
            Section {
                VoiceHintRow(title: "Voice Diagnostics", hint: VoiceSettingsCatalog.diagnosticsHint) {
                    VoiceSettingsScreens.openDiagnostics(router: router)
                }
                .accessibilityIdentifier("voice.settings.diagnostics")
            } header: { HQSectionLabel {
                Text("Diagnostics")
            } }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        // [mac] Stress test 2026-10-28 #98: the Voice Model header sat 9 pt under the Desktop Look bar.
        .contentMargins(.top, MacInset.top(otherwise: 0), for: .scrollContent)
        .task { await router.gatewaySettings?.configStore?.load() }
        .onReceive(NotificationCenter.default.publisher(for: TalkController.engineChanged)) { _ in
            engine = TalkController.chosenEngine
        }
        .accessibilityIdentifier("config-page.voice.conversation.list")
    }
}

// MARK: - Speech to Text, Text to Speech

struct VoiceFieldsPage: View {
    let page: ConfigPage
    let store: GatewayConfigStore?
    let router: SettingsRouter
    /// Text to Speech starts with this iPhone's Read Replies Aloud.
    let readsReplies: Bool
    /// A bot's own profile (Fix… on the iPhone-voice notice): its name says whose voice this is.
    var botName: String? = nil
    @State private var readRepliesAloud = TalkController.readsRepliesAloud
    @State private var replyVoice = PhoneVoiceChoice.current()
    /// Only compact voices are installed for this person's language. Filled by the page's task: reading the voices
    /// here froze the app for most of a second the first time (Mac polish #34).
    @State private var suggestsBetterVoice = false
    /// The Voice row's value: Automatic, or the installed voice picked for the iPhone's voice (tester).
    @State private var phoneVoiceLabel = PhoneVoicePreference.automatic

    /// The gateway's Text to Speech fields show under the Voice choice (its footer says "the provider below").
    private var hasProvider: Bool {
        guard let store, store.config != nil else { return false }
        let hidden = VoiceSettingsCatalog.hiddenNow(on: page, config: store.config)
        return store.fields(page).contains { !hidden.contains($0.key) }
    }

    var body: some View {
        List { Group {
            if readsReplies {
                Section {
                    SwitchRow(title: "Read Replies Aloud", isOn: Binding(
                        get: { readRepliesAloud },
                        set: { on in
                            Haptics.play(.selection)
                            readRepliesAloud = on
                            TalkController.readsRepliesAloud = on
                        }))
                        .accessibilityIdentifier("voice.settings.read-replies")
                } header: { HQSectionLabel {
                    // Stress test 2026-10-28 #98, round 2 (both): named like the Voice section under it.
                    Text("Read Aloud")
                } } footer: { HQSectionFooter {
                    Text(VoiceSettingsCatalog.readRepliesHint)
                } }
                // This iPhone: which voice reads replies (§7.7). Never written to the gateway's tts.provider.
                Section {
                    ForEach(PhoneVoiceChoice.allCases, id: \.self) { choice in
                        Button {
                            Haptics.play(.selection)
                            replyVoice = choice
                            PhoneVoiceChoice.set(choice)
                        } label: {
                            HQOptionRowLabel(title: choice.title, selected: replyVoice == choice)   // [mac] Stress test 2026-10-28 #51: a leading radio on the Mac
                            .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                            .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(replyVoice == choice ? .isSelected : [])
                        .accessibilityIdentifier("voice.settings.reply-voice.\(choice.rawValue)")
                        .hqRadioRow()   // [mac] Stress test 2026-10-28 #51 (round 6)
                    }
                } header: { HQSectionLabel {
                    Text("Voice")
                } } footer: { HQSectionFooter {
                    // Stress test 2026-10-28 #96, round 2 (both): one paragraph, not two.
                    Text(PhoneVoiceChoice.footer(providerBelow: hasProvider,
                                                 betterVoiceHint: suggestsBetterVoice ? PhoneVoiceWords.enhancedHint : nil))
                        .accessibilityIdentifier(suggestsBetterVoice ? "voice.settings.enhanced-hint" : "voice.settings.reply-voice.footer")
                } }
                // Which installed voice the iPhone's voice reads with: Automatic follows Spoken Content (as Speak does).
                Section {
                    ValueRow(title: "Voice", value: phoneVoiceLabel) {
                        router.push(PhoneVoicePage.title, PhoneVoicePage())
                    }
                    .accessibilityIdentifier("voice.settings.phone-voice")
                } header: { HQSectionLabel {
                    Text(PhoneVoiceChoice.phone.title)
                } }
            }
            if let botName, !botName.isEmpty {
                Section {
                    Text("These Text to Speech settings are \(botName)’s own.")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                        .padding(.vertical, 2)
                        .accessibilityIdentifier("voice.settings.bot-scope")
                }
            }
            if let store {
                VoiceGatewayFields(page: page, store: store, router: router, alone: !readsReplies && botName == nil,
                                   firstHeader: readsReplies ? PhoneVoiceChoice.computer.title : nil)
            } else {
                Section {
                    Text("Connect to your gateway to change these settings.")
                        .foregroundStyle(Color.hqLabel2)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("voice.settings.no-gateway")
                }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .hqMacListHeight()   // [mac] Stress test 2026-10-31 (#9 again): Speech to Text's empty state centred, not near the top
        .contentMargins(.top, MacInset.top(otherwise: 0), for: .scrollContent)   // [mac] Stress test 2026-10-28 #98
        .saveFailureFeedback(store?.failure?.text)
        .task { await store?.load() }
        .task {
            guard readsReplies else { return }
            let candidates = await PhoneVoiceList.load()
            suggestsBetterVoice = PhoneVoicePicker.suggestsBetterVoice(candidates: candidates)
            phoneVoiceLabel = PhoneVoicePreference.label(PhoneVoicePreference.current(), candidates: candidates)
        }
        .onReceive(NotificationCenter.default.publisher(for: PhoneVoicePreference.changed)) { _ in
            phoneVoiceLabel = PhoneVoicePreference.label(PhoneVoicePreference.current(), candidates: PhoneVoiceList.ifRead() ?? [])
        }
        .refreshable { await store?.load(force: true) }
        .onReceive(NotificationCenter.default.publisher(for: TalkController.readRepliesAloudChanged)) { _ in
            readRepliesAloud = TalkController.readsRepliesAloud
        }
        .onReceive(NotificationCenter.default.publisher(for: PhoneVoiceChoice.changed)) { _ in
            replyVoice = PhoneVoiceChoice.current()
        }
        .accessibilityIdentifier("config-page.\(page.key).list")
    }
}

/// The gateway's fields of one voice page: the failure banner, the load state, then the fields in a few sections. A
/// provider's fields show only while that provider is selected; the ElevenLabs voice has its own picker.
struct VoiceGatewayFields: View {
    let page: ConfigPage
    let store: GatewayConfigStore
    let router: SettingsRouter
    /// The gateway's fields are all the page has (Speech to Text): with none, the page's empty state.
    var alone = false
    /// Stress test 2026-10-28 #98, round 2 (both): under this device's named sections (Text to Speech), the first of
    /// the gateway's sections is named too.
    var firstHeader: String? = nil

    var body: some View {
        ConfigFailureSection(store: store)
        if store.config == nil {
            if case .failed(let text) = store.phase {
                LoadFailureSection(title: "Couldn’t Load Settings", text: text) { Task { await store.load(force: true) } }
            } else {
                LoadingSection(text: "Loading settings…")
            }
        } else {
            let hidden = VoiceSettingsCatalog.hiddenNow(on: page, config: store.config)
            let fields = store.fields(page).filter { !hidden.contains($0.key) }
            // Stress test 2026-10-28 #96 (both): a row card stood in for an empty state. Alone on its page (Speech to
            // Text) it is the app's empty state. Round 2: under this device's rows (Text to Speech) nothing is said —
            // the page has content, and the Voice footer already says where the voice comes from.
            if fields.isEmpty, alone {
                Section {
                    ContentUnavailableView {
                        UnavailableTitle("Nothing to Change", systemImage: "waveform")
                    } description: {
                        Text("Hermes has no \(page.title) settings to change.").hqMacFont(MacType.emptyBodyFont)
                    }
                    .listRowBackground(Color.clear)
                    // [mac] Stress test 2026-10-28 round 6: the page's empty state as every other, in both looks:
                    // centred a little above the middle with no card (a bordered card near the top in the Desktop
                    // Look, floating in the iOS look).
                    .hqMacEmptyPlacement()
                    .hqMacListedEmptyState(above: 40)
                    .accessibilityIdentifier("voice.settings.empty")
                }
            }
            // UX study #48: one inset list in a few sections (the provider and its fields together), not a card per
            // field. A switch says what it does on its second line; another field's description ends its section.
            let sections = VoiceSettingsCatalog.sections(fields, key: \.key, closesSection: Self.hasFooter)
            ForEach(sections, id: \.first?.key) { section in
                Section {
                    ForEach(section) { field in row(field) }
                } header: {
                    if let firstHeader, section.first?.key == sections.first?.first?.key { HQSectionLabel { Text(firstHeader) } }
                } footer: { HQSectionFooter {
                    if let last = section.last, Self.hasFooter(last), let description = last.description { Text(description) }
                } }
            }
        }
    }

    private static func hasFooter(_ field: ConfigFieldModel) -> Bool { field.control != .toggle && field.description != nil }

    @ViewBuilder private func row(_ field: ConfigFieldModel) -> some View {
        if field.key == "tts.elevenlabs.voice_id" {
            ValueRow(title: field.label, value: ElevenLabsVoices.shared.label(for: ConfigText.text(field.value))) {
                let editor = SettingsPageController(title: field.label, ElevenLabsVoicePage(store: store, services: router.services))
                editor.onDisappear = { store.flush() }
                router.push(editor)
            }
            .accessibilityIdentifier("config-field.\(field.key)")
        } else {
            ConfigFieldRow(field: field, store: store, router: router, subtitle: field.control == .toggle ? field.description : nil)
        }
    }
}

// MARK: - The ElevenLabs voice (labels shown, ids stored)

/// The voices of the gateway's ElevenLabs account, read once per Settings visit.
@MainActor @Observable final class ElevenLabsVoices {
    static let shared = ElevenLabsVoices()

    enum Phase: Equatable { case idle, loading, loaded, unavailable }
    private(set) var phase = Phase.idle
    private(set) var voices: [VoiceGateway.Voice] = []

    func label(for id: String) -> String {
        if id.isEmpty { return "Not Set" }
        return voices.first { $0.id == id }?.label ?? id
    }

    func load(client: (any GatewayClient)?, force: Bool = false) async {
        guard let client, phase != .loading, force || phase == .idle else { return }
        phase = .loading
        if let list = await VoiceGateway.elevenLabsVoices(client: client) {
            voices = list
            phase = .loaded
            AppLog.trace("settings", "ElevenLabs voices loaded: \(list.count)")
        } else {
            voices = []
            phase = .unavailable
            AppLog.note("settings", "ElevenLabs voices unavailable")
        }
    }

    func reset() {
        voices = []
        phase = .idle
    }
}

struct ElevenLabsVoicePage: View {
    static let key = "tts.elevenlabs.voice_id"
    let store: GatewayConfigStore
    let services: any AppServices
    @State private var text = ""
    @State private var started = false
    private var voices: ElevenLabsVoices { ElevenLabsVoices.shared }

    private var current: String { ConfigText.text(store.field(Self.key)?.value) }
    private var client: (any GatewayClient)? { (services as? AppModel)?.client }

    var body: some View {
        List { Group {
            ConfigFailureSection(store: store)
            // Your named voices first; a custom voice's ID below them (UX study #49).
            if voices.phase == .loading {
                LoadingSection(text: "Loading your voices…")
            } else if !voices.voices.isEmpty {
                Section {
                    ForEach(voices.voices, id: \.id) { voice in
                        Button {
                            Haptics.play(.selection)
                            store.set(Self.key, .string(voice.id))
                            text = voice.id
                        } label: {
                            HQOptionRowLabel(title: voice.label, selected: voice.id == current)   // [mac] Stress test 2026-10-28 #51: a leading radio on the Mac
                            .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                            .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(voice.id == current ? .isSelected : [])
                        .accessibilityIdentifier("config-option.\(voice.id)")
                        .hqRadioRow()   // [mac] Stress test 2026-10-28 #51 (round 6)
                    }
                }
            }
            Section {
                TextField("Voice ID", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(commit)
                    .submitLabel(.done)
                    .accessibilityIdentifier("config-editor.field")
            } header: { HQSectionLabel {
                Text("Custom Voice ID")
            } } footer: { HQSectionFooter {
                switch voices.phase {
                case .unavailable: Text("Your gateway couldn’t list your ElevenLabs voices. Type a voice ID.")
                case .loaded where voices.voices.isEmpty: Text("Your ElevenLabs account has no voices yet. Type a voice ID.")
                default: Text("Pick one of your voices above, or type the ID of another ElevenLabs voice.")
                }
            } }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .saveFailureFeedback(store.failure?.text)
        .onAppear {
            guard !started else { return }
            started = true
            text = current
        }
        .task { await voices.load(client: client) }
        .refreshable { await voices.load(client: client, force: true) }
        .onDisappear(perform: commit)
        .accessibilityIdentifier("config-editor.\(Self.key)")
    }

    private func commit() {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard typed != current else { return }
        store.set(Self.key, .string(typed))
    }
}

// MARK: - Word Fixes [live words]

/// Settings › Voice › Voice Conversation › Word Fixes (spec 3x-live-words §5): what this device writes instead of what
/// it heard. Fixes come from memos fixed in review (`WordFixes.learn`) or Add Word Fix; a swipe, a right-click or the
/// Mac's red minus removes one.
struct WordFixesPage: View {
    let router: SettingsRouter
    @State private var fixes = WordFixes.all
    @State private var confirmingRemoveAll = false

    var body: some View {
        List { Group {
            Section {
                ForEach(fixes, id: \.heard) { fix in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(fix.meant).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                            Text(VoiceSettingsCatalog.wordFixHeard(fix.heard)).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        MacRemoveButton(identifier: "voice.word-fixes.remove.\(fix.heard)") { remove(fix) }
                    }
                    .hqRowPadding(4)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("voice.word-fixes.\(fix.heard)")
                    // A mouse has no swipe: the same Delete on a right-click (and a touch and hold).
                    .contextMenu { Button("Delete", systemImage: "trash", role: .destructive) { remove(fix) } }
                }
                .onDelete { offsets in
                    for fix in offsets.map({ fixes[$0] }) { remove(fix) }
                }
                Button {
                    router.push(VoiceSettingsCatalog.addWordFixTitle, AddWordFixPage { router.navigation?.popViewController(animated: true) })
                } label: {
                    MacAddRowLabel(title: VoiceSettingsCatalog.addWordFixTitle + "…")
                }
                .accessibilityIdentifier("voice.word-fixes.add")
            } footer: { HQSectionFooter {
                Text(fixes.isEmpty ? VoiceSettingsCatalog.wordFixesEmpty : VoiceSettingsCatalog.wordFixesNote)
                    .accessibilityIdentifier("voice.word-fixes.note")
            } }
            if !fixes.isEmpty {
                Section {
                    Button("Remove All Word Fixes…", role: .destructive) { confirmingRemoveAll = true }
                        .accessibilityIdentifier("voice.word-fixes.remove-all")
                }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .contentMargins(.top, MacInset.top(otherwise: 0), for: .scrollContent)
        .onReceive(NotificationCenter.default.publisher(for: WordFixes.changed)) { _ in fixes = WordFixes.all }
        .confirmationDialog("Remove all \(fixes.count) word fixes?", isPresented: $confirmingRemoveAll, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) {
                Haptics.play(.selection)
                WordFixes.removeAll()
            }
        } message: {
            Text("Words you say are written as this \(DeviceWord.name) hears them until you fix them again.")
        }
        .accessibilityIdentifier("voice.word-fixes")
    }

    private func remove(_ fix: WordFix) {
        Haptics.play(.selection)
        WordFixes.remove(heard: fix.heard)
    }
}

/// Add Word Fix: what this device hears, and what to write instead.
struct AddWordFixPage: View {
    var done: () -> Void
    @State private var heard = ""
    @State private var meant = ""
    @FocusState private var focused: Bool

    private var canSave: Bool {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines), m = meant.trimmingCharacters(in: .whitespacesAndNewlines)
        return !h.isEmpty && !m.isEmpty && h != m
    }

    var body: some View {
        Form {
            Section {
                TextField("Heard as (e.g. clawed code)", text: $heard)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused)
                    .accessibilityIdentifier("voice.word-fix.heard")
                TextField("Write it as (e.g. Claude Code)", text: $meant)
                    .autocorrectionDisabled()
                    .onSubmit { if canSave { save() } }
                    .accessibilityIdentifier("voice.word-fix.meant")
            } footer: { HQSectionFooter {
                Text(VoiceSettingsCatalog.addWordFixNote)
            } }
            Section {
                Button("Save") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
                    .accessibilityIdentifier("voice.word-fix.save")
            }
        }
        .hqGroupedPage()
        .onAppear { focused = true }
    }

    private func save() {
        guard canSave else { return }
        Haptics.play(.selection)
        WordFixes.add(WordFix(heard: heard, meant: meant))
        AppLog.trace("talk", "word fix added in Settings (\(WordFixes.all.count) kept)")
        done()
    }
}
