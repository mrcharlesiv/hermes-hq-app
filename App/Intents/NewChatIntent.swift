// [shortcut-new-chat] "New Chat" for Shortcuts, Siri and the Action Button: a new chat with the bot you pick, in the
// project you pick (owner 2026-11-20: "an iOS shortcut that opens a session with whatever bot you want in whatever
// project you want"). It starts the chat the way a project's New Chat does (`SessionsOrganizer.newChat(inProject:)`):
// in the project's folder, the project given to the bot first when the bot doesn't have it yet. No project: a plain
// new chat with the bot, in its own folder.
//
// The same thing as a link, for a shortcut's Open URL step or another app: `<scheme>://new-chat?bot=<profile or
// name>&project=<folder or name>` (`NewChatLink`), handled by SceneDelegate.open.

import AppIntents
import UIKit

nonisolated struct ShortcutProject: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Project")
    static let defaultQuery = ShortcutProjectQuery()
    /// The project's folder (its key).
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(id)") }

    init(_ record: ProjectShortcutRecord) {
        id = record.key
        name = record.name
    }
}

nonisolated struct ShortcutProjectQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ShortcutProject] {
        let all = ProjectShortcutCatalog.projects()
        return identifiers.compactMap { id in all.first { $0.key == id }.map(ShortcutProject.init) }
    }

    func suggestedEntities() async throws -> [ShortcutProject] {
        ProjectShortcutCatalog.projects().map(ShortcutProject.init)
    }

    func entities(matching string: String) async throws -> [ShortcutProject] {
        ProjectShortcutCatalog.projects().filter {
            $0.name.localizedCaseInsensitiveContains(string) || $0.key.localizedCaseInsensitiveContains(string)
        }.map(ShortcutProject.init)
    }
}

// A plain `struct` for the reason given at `RecordVoiceNoteIntent`.
struct NewChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New Chat"
    static let description: IntentDescription? = IntentDescription(
        "Start a new chat with your selected bot, in the project you choose. Leave Project empty for a chat in the bot’s own folder.",
        categoryName: "Chat")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Bot") var bot: VoiceNoteBot?
    @Parameter(title: "Project") var project: ShortcutProject?
    // [shortcuts] Owner 2026-11-20 picked "First message for New Chat": the chat opens with these words sent.
    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true)) var message: String?
    @Parameter(title: "Send Message", default: true) var sendMessage: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("New chat with \(\.$bot) in \(\.$project)") {
            \.$message
            \.$sendMessage
        }
    }

    @MainActor func perform() async throws -> some IntentResult {
        let target: VoiceNoteBot
        if let bot {
            target = bot
        } else if let fallback = ShortcutDefaultBot.resolved() {
            target = VoiceNoteBot(fallback)
        } else {
            target = try await $bot.requestValue("Which bot?")
        }
        IntentsEvents.note("perform NewChatIntent " + (VoiceBotCatalog.profile(key: target.key) ?? target.key))
        guard let selected = VoiceBotCatalog.resolve(id: target.id), let profile = VoiceBotCatalog.profile(key: selected.key) else {
            AppLog.note("intents", "New Chat shortcut: bot not in the catalog")
            throw VoiceNoteError.unavailableBot
        }
        if let project, !ProjectShortcutCatalog.projects().contains(where: { $0.key == project.id }) {
            AppLog.note("intents", "New Chat shortcut: project not in the catalog")
            throw NewChatShortcutError.unavailableProject
        }
        let words = message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? message : nil
        let link = NewChatLink(bot: profile, project: project?.id, message: words, send: sendMessage)
        // The app comes forward first (a cold launch has no tabs yet): the chat opens once they are up.
        Task { @MainActor in await NewChatRouter.open(link) }
        AppLog.note("intents", "New Chat shortcut: queued\(project == nil ? "" : " in a project")")
        return .result()
    }
}

/// [shortcuts] "Talk to Bot" (owner 2026-11-20 picked "Talk to a bot"): the bot's chat opens and a hands-free
/// conversation starts there, as the bot's Talk tile does (`TalkWiring.startTalking`).
struct TalkToBotIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Bot"
    static let description: IntentDescription? = IntentDescription("Open your selected bot’s chat and start a hands-free voice conversation.",
                                                                   categoryName: "Chat")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Bot") var bot: VoiceNoteBot?

    static var parameterSummary: some ParameterSummary { Summary("Talk to \(\.$bot)") }

    @MainActor func perform() async throws -> some IntentResult {
        let target: VoiceNoteBot
        if let bot {
            target = bot
        } else if let fallback = ShortcutDefaultBot.resolved() {
            target = VoiceNoteBot(fallback)
        } else {
            target = try await $bot.requestValue("Which bot?")
        }
        IntentsEvents.note("perform TalkToBotIntent " + (VoiceBotCatalog.profile(key: target.key) ?? target.key))
        guard let selected = VoiceBotCatalog.resolve(id: target.id), let profile = VoiceBotCatalog.profile(key: selected.key) else {
            AppLog.note("intents", "Talk to Bot shortcut: bot not in the catalog")
            throw VoiceNoteError.unavailableBot
        }
        Task { @MainActor in await NewChatRouter.talk(profile) }
        AppLog.note("intents", "Talk to Bot shortcut: queued")
        return .result()
    }
}

nonisolated enum NewChatShortcutError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    case unavailableProject

    var errorDescription: String? { "That project isn’t in Hermes HQ any more. Open Sessions so the list updates, then pick the project again." }
    var localizedStringResource: LocalizedStringResource { "\(errorDescription ?? "")" }
}

@MainActor enum NewChatRouter {
    /// Test seam for confirming `<scheme>://talk` triggered by an external URL; nil uses the standard UIAlertController.
    static var confirmExternalTalk: (@MainActor (_ botName: String, _ root: MainTabController) async -> Bool)?

    /// A `new-chat` or `talk` link arriving via an external URL (`SceneDelegate.open`). False: not one.
    /// External URLs NEVER auto-send messages, NEVER create projects on unknown paths, and ALWAYS ask before starting voice.
    static func handle(_ url: URL) -> Bool {
        let parsed = DeepLink.parse(url, scheme: AppIdentity.current.urlScheme)
        // [shortcuts] <scheme>://talk?bot=<profile or name>: Talk to Bot as an external link (must confirm mic first).
        if case .other(kind: "talk", _, let params)? = parsed,
           let bot = params.last(where: { $0.key == "bot" })?.value.trimmingCharacters(in: .whitespacesAndNewlines), !bot.isEmpty {
            AppLog.note("link", "talk")
            Task { await talk(bot, confirmFirst: true) }
            return true
        }
        guard let link = NewChatLink.parse(parsed) else { return false }
        AppLog.note("link", "new chat")
        Task { await open(link.forExternalURL, external: true) }
        return true
    }

    enum Outcome: Equatable { case opened, noTabs, noBot, kept }

    /// Opens the new chat once the tabs and the roster are up (a shortcut may have launched the app): up to 10 s each.
    /// When `external` is true (invoked from a URL scheme outside the app), auto-sending is forced off (`send = false`)
    /// so the message is only prefilled as a draft, and unknown project paths are skipped instead of calling `projects.create`.
    @discardableResult static func open(_ link: NewChatLink, external: Bool = false) async -> Outcome {
        let effective = external ? link.forExternalURL : link
        guard let root = await tabs() else {
            AppLog.note("intents", "new chat: no tabs (signed out?)")
            return .noTabs
        }
        // A cold launch the shortcut ran on: the last chat is not reopened over (or instead of) this one.
        MainTabController.launchRestorePending = false
        root.launchChatWatch = nil
        guard let profile = await bot(effective.bot, root: root) else {
            AppLog.note("intents", "new chat: no such bot")
            notice("Hermes HQ has no bot named “\(effective.bot)”.", root: root)
            return .noBot
        }
        guard await root.clearForRoute() else { return .kept }
        let sessions = root.sessionsViewController
        sessions.loadViewIfNeeded()
        guard let organizer = sessions.organizer else { return .noTabs }
        let before = root.chatOnShow
        if let wanted = effective.project {
            if external {
                if let key = await existingProjectKey(wanted, profile: profile, organizer: organizer) {
                    let holders = organizer.store?.projectHolders(key: key) ?? []
                    if holders.contains(where: { $0.profile == profile })
                        || (!holders.isEmpty && holders.allSatisfy({ $0.project.isAuto == true })) {
                        organizer.newChat(inProject: key, profile: profile)
                    } else if let existingRoot = holders.first?.project.root {
                        // Match the existing saved project's folder without silently calling `projects.create`.
                        organizer.newChat(profile: profile, folder: existingRoot)
                    } else {
                        organizer.newChat(profile: profile)
                    }
                    AppLog.note("intents", "new chat: external link opened in an existing project")
                } else {
                    AppLog.note("intents", "new chat: external link skipped unknown project")
                    organizer.newChat(profile: profile)
                }
            } else {
                let key = await projectKey(wanted, profile: profile, organizer: organizer)
                organizer.newChat(inProject: key, profile: profile)
                AppLog.note("intents", "new chat: opened in a project")
            }
        } else {
            organizer.newChat(profile: profile)
            AppLog.note("intents", "new chat: opened")
        }
        if let words = effective.message { await deliver(words, send: effective.send, root: root) { $0 !== before } }
        return .opened
    }

    /// [quick-actions] A Send a Message tile with Open the Chat on (DECISION I22): the bot's own chat through Open Bot
    /// Chat's opener (`IntentsHost.openBotChat`), then the words sent as typed words are, as New Chat's first message.
    @discardableResult static func send(_ words: String, inBotChatOf wanted: String) async -> Outcome {
        guard let root = await tabs() else { return .noTabs }
        MainTabController.launchRestorePending = false
        root.launchChatWatch = nil
        guard let profile = await bot(wanted, root: root), let bot = root.services.bots.first(where: { $0.id == profile }) else {
            notice("Hermes HQ has no bot named “\(wanted)”.", root: root)
            return .noBot
        }
        let opened = await Result.of { try await IntentsRuntime.shared.host?.openBotChat(bot) }
        guard case .success(.some(_)) = opened else {
            if case .failure(let error) = opened, error is IntentsKept { return .kept }
            AppLog.note("intents", "send in bot chat: the chat didn’t open")
            return .noTabs
        }
        await deliver(words, send: true, root: root) { LiveIntentsChat.botProfile($0) == profile }
        return .opened
    }

    /// [shortcuts] The new chat's first message: sent as typed words are (or left in its box), once the chat is the
    /// one on show with its push finished: up to 8 s (a project the bot was given first takes a round trip).
    /// [coding-pr-review] Also the PR card's Ask to Merge: `wanted` picks the chat (the one it opened, by stored id).
    /// Returns whether the chat came up.
    @discardableResult
    static func deliver(_ words: String, send: Bool, root: MainTabController, wanted: (ChatViewController) -> Bool) async -> Bool {
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(100))
            guard let chat = root.chatOnShow, wanted(chat), chat.viewIfLoaded?.window != nil,
                  chat.navigationController?.transitionCoordinator == nil else { continue }
            if send {
                chat.sendFromCard(words, display: words)
                AppLog.note("intents", "new chat: first message sent (\(words.count) chars)")
            } else {
                chat.composer.text = words
                AppLog.note("intents", "new chat: first message in the box (\(words.count) chars)")
            }
            return true
        }
        AppLog.note("intents", "new chat: the chat never came up for its first message")
        return false
    }

    /// [shortcuts] Talk to Bot: the tabs and the roster as a new chat waits for them, then the Talk tile's road.
    /// When `confirmFirst` is true (external URL scheme), asks explicit user confirmation before activating the microphone.
    @discardableResult static func talk(_ wanted: String, confirmFirst: Bool = false) async -> Outcome {
        guard let root = await tabs() else { return .noTabs }
        MainTabController.launchRestorePending = false
        root.launchChatWatch = nil
        guard let profile = await bot(wanted, root: root), let bot = root.services.bots.first(where: { $0.id == profile }) else {
            notice("Hermes HQ has no bot named “\(wanted)”.", root: root)
            return .noBot
        }
        guard await root.clearForRoute() else { return .kept }
        if confirmFirst {
            let allowed = await confirmTalk(botName: bot.name, root: root)
            guard allowed else {
                AppLog.note("intents", "talk: external link declined by user")
                return .kept
            }
        }
        root.select(.bots)
        root.botsViewController.navigationController?.popToRootViewController(animated: false)
        TalkWiring.startTalking(with: bot, from: root.botsViewController)
        AppLog.note("intents", "talk: started")
        return .opened
    }

    static func externalTalkPrompt(botName: String) -> (title: String, message: String, action: String) {
        ("Start voice conversation with \(botName)?",
         "A link asked to open your microphone and start a live voice conversation with \(botName).",
         "Start Talking")
    }

    private static func confirmTalk(botName: String, root: MainTabController) async -> Bool {
        if let confirmExternalTalk { return await confirmExternalTalk(botName, root) }
        let prompt = externalTalkPrompt(botName: botName)
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: prompt.title, message: prompt.message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: prompt.action, style: .default) { _ in continuation.resume(returning: true) })
            (FailureAlert.topmost(root) ?? root).present(alert, animated: true)
        }
    }

    /// The bot a link names: its profile, else its shown name (any case).
    private static func bot(_ wanted: String, root: MainTabController) async -> String? {
        for step in 0..<50 {
            let bots = root.services.bots
            if let hit = bots.first(where: { $0.id == wanted }) ?? bots.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
                return hit.id
            }
            // The roster answered and the bot isn't in it.
            if root.services.botsLoaded, step >= 5 { return nil }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    /// Resolves `wanted` ONLY against existing saved projects (never fabricating a folder key for an unknown path).
    private static func existingProjectKey(_ wanted: String, profile: String, organizer: SessionsOrganizer) async -> String? {
        organizer.store?.loadProjects(also: [profile])
        for _ in 0..<30 {
            if let store = organizer.store {
                let records = ProjectShortcutCatalog.records(store.newChatEntries(), account: "")
                if let hit = ProjectShortcutCatalog.resolve(wanted, in: records) { return hit.key }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return ProjectShortcutCatalog.resolve(wanted, in: ProjectShortcutCatalog.projects())?.key
    }

    /// The project's key in the Sessions store: its folder or name as the store has it now. On a cold launch the
    /// projects load after the list, so it waits up to 6 s for the one named; one never found is taken as a folder
    /// (the organizer then gives it to the bot, named after the folder).
    private static func projectKey(_ wanted: String, profile: String, organizer: SessionsOrganizer) async -> String {
        if let existing = await existingProjectKey(wanted, profile: profile, organizer: organizer) { return existing }
        return SessionProjects.folderKey(wanted)
    }

    private static func notice(_ message: String, root: MainTabController) {
        let alert = UIAlertController(title: "Couldn’t Start a New Chat", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        (FailureAlert.topmost(root) ?? root).present(alert, animated: true)
    }

    /// The tabs once they are on screen: up to 10 s (as `WidgetRouter`). [quick-actions] The page's opener waits the same.
    static func tabs() async -> MainTabController? {
        for _ in 0..<50 {
            if let root = MainTabController.current, root.view.window != nil { return root }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return MainTabController.current
    }
}
