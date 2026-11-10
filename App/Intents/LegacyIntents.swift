// The two intents builds 26–28 offered, kept so shortcuts made then keep running (docs/spec/3x-intents.md §6; a port
// of W:ios/App/App/HermesUIPages.swift:316-361). Neither is discoverable: they show in no action list and in no
// search, and only run from a shortcut that already contains them.
//
// The type names are what iOS stored (DECISION I1): `DispatchBotEntity`, `DispatchBotQuery`, `DispatchMemoIntent`,
// `DispatchOpenBotIntent`, and the parameter `bot`. They are identifiers, never shown. Do not rename them.

import AppIntents
import Foundation

nonisolated struct DispatchBotEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bot"      // as build 240 wrote it (the metadata matches)
    static let defaultQuery = DispatchBotQuery()
    /// `epoch + ":bot:" + key`: only good inside the sign-in it was made in.
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

// (The two intents below are plain `struct`s for the reason given at `RecordVoiceNoteIntent`.)

nonisolated struct DispatchBotQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [DispatchBotEntity] {
        let wanted = Set(identifiers)
        return ShortcutPolicy.legacyEntities().filter { wanted.contains($0.id) }.map { DispatchBotEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [DispatchBotEntity] {
        ShortcutPolicy.legacyEntities().map { DispatchBotEntity(id: $0.id, name: $0.name) }
    }

    func entities(matching string: String) async throws -> [DispatchBotEntity] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}

struct DispatchOpenBotIntent: AppIntent {
    static let isDiscoverable = false
    static let title: LocalizedStringResource = "Open Bot"
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Bot") var bot: DispatchBotEntity

    @MainActor func perform() async throws -> some IntentResult {
        IntentsEvents.note("perform DispatchOpenBotIntent")
        // DECISION I12: it opens the bot's chat (in build 240 the catalog was always empty, so it could only fail).
        guard QuickActions.openBot(legacyId: bot.id) else {
            AppLog.note("intents", "legacy shortcut Open Bot: unavailable")
            throw DispatchShortcutError.unavailable
        }
        AppLog.note("intents", "legacy shortcut Open Bot: opened")
        return .result()
    }
}

struct DispatchMemoIntent: AppIntent {
    // Existing shortcuts keep this identity; new ones use Record Voice Note.
    static let isDiscoverable = false
    static let title: LocalizedStringResource = "Send a Memo to Bot"
    // DECISION I11: intent metadata is extracted at build time and cannot read the display name.
    static let description: IntentDescription? = IntentDescription("Opens the chat and starts a voice memo. You review or send it in Hermes HQ.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Bot") var bot: DispatchBotEntity

    @MainActor func perform() async throws -> some IntentResult {
        IntentsEvents.note("perform DispatchMemoIntent")
        guard let selected = ShortcutPolicy.legacyBot(id: bot.id) else {
            AppLog.note("intents", "legacy shortcut Send a Memo: unavailable")
            throw DispatchShortcutError.unavailable
        }
        VoiceNoteRequestStore(defaults: .standard).enqueue(account: selected.account, key: selected.key, name: selected.name)
        IntentsRuntime.shared.kick()
        AppLog.note("intents", "legacy shortcut Send a Memo: queued")
        return .result()
    }
}

nonisolated enum DispatchShortcutError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    case unavailable

    var errorDescription: String? { IntentsText.legacyUnavailable() }
    var localizedStringResource: LocalizedStringResource { "\(IntentsText.legacyUnavailable())" }
}
