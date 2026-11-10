// "Record Voice Note" for Shortcuts, Siri and the Action Button (docs/spec/3x-intents.md §5; a port of build 240's
// W:ios/App/App/VoiceNoteIntent.swift:7-41 and its App Shortcut, W:ios/App/App/HermesUIPages.swift:362-366).
//
// The type names here are what iOS stored for every shortcut made under the web app (DECISION I1): `VoiceNoteBot`,
// `VoiceNoteBotQuery`, `RecordVoiceNoteIntent`, and the parameter `bot`. Do not rename them.
//
// Nothing here is main-actor isolated (§3.3): the system calls the queries off the main thread, and they only read the
// stored catalog (`VoiceBotCatalog`, UserDefaults). `perform()` hops to the main actor to hand the request to the runtime.

import AppIntents
import Foundation

nonisolated struct VoiceNoteBot: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Bot")
    static let defaultQuery = VoiceNoteBotQuery()
    let id: String
    let name: String
    let key: String
    let account: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(id: String, name: String, key: String, account: String) {
        self.id = id; self.name = name; self.key = key; self.account = account
    }

    init(_ record: VoiceBotRecord) {
        self.init(id: record.id, name: record.name, key: record.key, account: record.account)
    }
}

nonisolated struct VoiceNoteBotQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [VoiceNoteBot] {
        identifiers.compactMap { VoiceBotCatalog.resolve(id: $0).map(VoiceNoteBot.init) }
    }

    func suggestedEntities() async throws -> [VoiceNoteBot] {
        VoiceBotCatalog.bots().map(VoiceNoteBot.init)
    }
}

// Not marked `nonisolated` like its neighbours: the compiler refuses that word on a type with a wrapped mutable property
// (`@Parameter`). Conforming to `AppIntent`, a `Sendable` protocol, already takes the type out of the module's default
// main-actor isolation (checked: a nonisolated function can make one and read its statics).
struct RecordVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Voice Memo"
    static let description: IntentDescription? = IntentDescription("Open your selected bot’s chat and start recording a voice memo.")
    /// DECISION I2: the app comes forward at once (what `openAppWhenRun = true` did before the iOS 26 SDK).
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Bot") var bot: VoiceNoteBot

    static var parameterSummary: some ParameterSummary { Summary("Record a voice memo for \(\.$bot)") }

    @MainActor func perform() async throws -> some IntentResult {
        IntentsEvents.note("perform RecordVoiceNoteIntent " + (VoiceBotCatalog.profile(key: bot.key) ?? bot.key))
        // The stored catalog decides, not what the shortcut remembers of the bot.
        guard let selected = VoiceBotCatalog.resolve(id: bot.id) else {
            AppLog.note("intents", "Record Voice Memo shortcut: bot not in the catalog")
            throw VoiceNoteError.unavailableBot
        }
        VoiceNoteRequestStore(defaults: .standard).enqueue(account: selected.account, key: selected.key, name: selected.name)
        IntentsRuntime.shared.kick()        // a no-op until the app is on screen and signed in; the request waits a minute
        AppLog.note("intents", "Record Voice Memo shortcut: queued")
        return .result()
    }
}

/// "Open Bot Chat" (DECISION I17, a native addition): the bot's chat on the Action Button, in Spotlight and in Siri. A
/// new discoverable type beside the hidden `DispatchOpenBotIntent` (I1, I12), whose stored identity it leaves alone; it
/// picks from the same catalog as Record Voice Memo and opens through the same route as Open Bot.
struct OpenBotChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Bot Chat"
    static let description: IntentDescription? = IntentDescription("Open your selected bot’s chat.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Bot") var bot: VoiceNoteBot

    static var parameterSummary: some ParameterSummary { Summary("Open the chat with \(\.$bot)") }

    @MainActor func perform() async throws -> some IntentResult {
        IntentsEvents.note("perform OpenBotChatIntent " + (VoiceBotCatalog.profile(key: bot.key) ?? bot.key))
        // The stored catalog decides, in this sign-in only (the legacy id carries the epoch and the account rule).
        guard let selected = VoiceBotCatalog.resolve(id: bot.id), let epoch = ShortcutPolicy.epoch(),
              QuickActions.openBot(legacyId: epoch + ":bot:" + selected.key) else {
            AppLog.note("intents", "Open Bot Chat shortcut: unavailable")
            throw VoiceNoteError.unavailableBot
        }
        AppLog.note("intents", "Open Bot Chat shortcut: opened")
        return .result()
    }
}

nonisolated enum VoiceNoteError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    case unavailableBot

    var errorDescription: String? { IntentsText.refreshBots() }
    var localizedStringResource: LocalizedStringResource { "\(IntentsText.refreshBots())" }
}

/// The App Shortcuts: listed in the Shortcuts app, Spotlight and Settings › Action Button without any setup.
nonisolated struct HQAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecordVoiceNoteIntent(),
                    // "Voice memo", the chat's word; the older "voice note" phrases still work for people who learned them.
                    phrases: ["Record a voice memo in \(.applicationName)",
                              // DECISION I3: one entry per bot, which is what makes a roster change visible in the pickers.
                              "Record a voice memo for \(\.$bot) in \(.applicationName)",
                              "Record a voice note in \(.applicationName)",
                              "Record a voice note for \(\.$bot) in \(.applicationName)"],
                    shortTitle: "Record Voice Memo", systemImageName: "mic.fill")
        // DECISION I17: one entry per bot, as I3 does for memos.
        AppShortcut(intent: OpenBotChatIntent(),
                    phrases: ["Open a bot chat in \(.applicationName)",
                              "Open \(\.$bot) in \(.applicationName)"],
                    shortTitle: "Open Bot Chat", systemImageName: "bubble.left.fill")
        // [ask-bot] Tester, 2026-11-08: send to a bot (and get its reply) from a shortcut, without opening the app.
        AppShortcut(intent: AskBotIntent(),
                    phrases: ["Ask a bot in \(.applicationName)",
                              "Ask \(\.$bot) in \(.applicationName)"],
                    shortTitle: "Ask Bot", systemImageName: "paperplane.fill")
    }
}

/// What the intents did, for the DEBUG state file (`IntentsDebugHooks`); nothing in a release build.
@MainActor enum IntentsEvents {
    static var sink: ((String) -> Void)?
    static func note(_ event: String) { sink?(event) }
}
