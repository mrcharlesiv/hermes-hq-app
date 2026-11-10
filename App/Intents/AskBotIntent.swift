// "Ask Bot" for Shortcuts and Siri: sends a message (and files) to a bot's chat without opening the app, and can wait
// for the reply and hand it to the shortcut's next step. Tester, 2026-11-08: "a 'send message to bot' shortcut,
// similar to 'Ask' in the official app ... my use case is a daily automation shortcut to export data from an app and send
// it to my bot." Owner, same day: build it (DECISION I17 said no "Send Message to Bot"; this lifts it).
//
// The system may run this with no window and no `AppModel` (a background launch), so it sends the way the Share
// extension does (`ShareSender`): its own connection, the Keychain's sign-in, the bot's Bot Chat from `AskRoster`. The
// app, if it is running, sees the message and the reply arrive in that chat like any other.

import AppIntents
import Foundation
import UniformTypeIdentifiers

/// The bots Ask Bot can reach, with their Bot Chats: a `ShareRoster` kept in the app's own defaults (the native identity
/// has no App Group), written whenever the Bots list changes. Names and routing ids only, never a message or a secret.
nonisolated enum AskRoster {
    static let key = "hq.intents.askRoster"

    static func read(_ defaults: UserDefaults = .standard) -> ShareRoster? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ShareRoster.self, from: $0) }
    }

    static func save(_ roster: ShareRoster, _ defaults: UserDefaults = .standard) {
        guard roster != read(defaults), let data = try? JSONEncoder().encode(roster) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }

    /// The roster for `bots`, signed in as `stored` (no pictures: nothing here draws a face).
    static func make(bots: [Bot], stored: StoredAccount, limit: Int) -> ShareRoster {
        let listed = ShareRosterRows.bots(ShareRosterRows.rows(bots), account: stored.key).map {
            ShareBot(key: $0.key, name: $0.name, profile: $0.profile, session: $0.session, lastActive: $0.lastActive)
        }
        return ShareRoster(account: stored.key, url: stored.url, username: stored.username, limitBytes: limit, bots: listed, savedAt: 0)
    }
}

struct AskBotIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Bot"
    static let description: IntentDescription? = IntentDescription(
        "Send a message, and any files, to your selected bot’s chat without opening Hermes HQ. Turn on Wait for Reply to get the bot’s answer for the next action.",
        categoryName: "Chat")
    /// Runs without bringing the app forward: the point of an automation.
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Bot") var bot: VoiceNoteBot
    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true)) var message: String
    @Parameter(title: "Files", supportedContentTypes: [.item]) var files: [IntentFile]?
    @Parameter(title: "Wait for Reply", default: true) var waitForReply: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$bot) \(\.$message)") {
            \.$files
            \.$waitForReply
        }
    }

    /// How long Wait for Reply waits before saying the bot is still on it.
    static let replyWait: Double = 120

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        await MainActor.run { IntentsEvents.note("perform AskBotIntent " + (VoiceBotCatalog.profile(key: bot.key) ?? bot.key)) }
        guard let record = VoiceBotCatalog.resolve(id: bot.id), let profile = VoiceBotCatalog.profile(key: record.key) else {
            throw VoiceNoteError.unavailableBot
        }
        let roster = AskRoster.read()
        guard let target = roster?.bots.first(where: { $0.profile == profile }) else { throw AskBotError.words(.noRoster, bot: record.name) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ask-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let attachments = try Self.stage(files ?? [], in: folder)
        let request = ShareRequest(bot: target, message: message, attachments: attachments,
                                   limit: roster?.limitBytes ?? ShareRules.defaultLimitBytes, replyWait: waitForReply ? Self.replyWait : 0)
        let result: ShareResult
        do {
            result = try await ShareSender().send(request, roster: roster)
        } catch let failure as ShareFailure {
            AppLog.note("intents", "Ask Bot shortcut: \(failure.name)")
            throw AskBotError.words(failure, bot: target.name)
        }
        AppLog.note("intents", "Ask Bot shortcut: sent (\(result.status))\(result.reply.map { " reply \(AskBotError.logName($0))" } ?? "")")
        switch result.reply {
        case nil:
            return .result(value: "", dialog: "Sent to \(target.name).")
        case .text(let text):
            return .result(value: text, dialog: IntentDialog(stringLiteral: text.isEmpty ? "\(target.name) finished without a written reply." : text))
        case .asking:
            throw AskBotError.message("\(target.name) is asking you something. Open Hermes HQ to answer.")
        case .stillWorking:
            throw AskBotError.message("\(target.name) got your message and is still working on it. The reply will be in the chat.")
        case .failed(let said):
            throw AskBotError.message(said.isEmpty ? "\(target.name) couldn’t finish replying. Open the chat in Hermes HQ to see why." : said)
        }
    }

    /// The shortcut's files, copied where the sender reads them (a photo as an image, anything else as a file).
    private static func stage(_ files: [IntentFile], in folder: URL) throws -> [ShareAttachment] {
        guard !files.isEmpty else { return [] }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try files.enumerated().map { index, file in
            let type = file.type ?? file.filename.split(separator: ".").last.flatMap { UTType(filenameExtension: String($0)) }
            let fallback = "file-\(index + 1)" + (type?.preferredFilenameExtension.map { "." + $0 } ?? "")
            let name = ShareRules.safeName(file.filename.isEmpty ? fallback : file.filename)
            let url = folder.appendingPathComponent("\(index)-" + name)
            do { try file.data.write(to: url) } catch { throw AskBotError.words(.unreadable(name), bot: "") }
            let image = type.map { $0.conforms(to: .image) } ?? false
            return ShareAttachment(kind: image ? .image : .file, file: url, name: name)
        }
    }
}

nonisolated enum AskBotError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    case message(String)

    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
    var localizedStringResource: LocalizedStringResource { "\(errorDescription ?? "")" }

    /// The sender's failure in a shortcut's words (its own copy talks about sharing).
    static func words(_ failure: ShareFailure, bot: String) -> AskBotError {
        let name = bot.isEmpty ? "this bot" : bot
        return switch failure {
        case .signedOut: .message("Open Hermes HQ and sign in to your gateway, then run the shortcut again.")
        case .needsApp: .message("Open Hermes HQ once to finish updating, then run the shortcut again.")
        case .noRoster, .otherAccount: .message("Open Hermes HQ once so it knows your bots, then run the shortcut again.")
        case .locked: .message("Unlock your \(DeviceWord.name) so Hermes HQ can read your sign-in.")
        case .keychain: .message("Hermes HQ couldn’t read your sign-in. Open Hermes HQ, then run the shortcut again.")
        case .noChat: .message("Open \(name)’s chat in Hermes HQ once, then run the shortcut again.")
        case .nothingToSend: .message("There’s nothing to send. Add a message or a file.")
        case .refused(let detail) where detail.isEmpty: .message("Your gateway didn’t accept the message.")
        case .unconfirmed: .message("Hermes HQ couldn’t confirm the message arrived. Check \(name)’s chat before running the shortcut again.")
        case .cancelled: .message("Sending was cancelled.")
        default: .message(failure.message)
        }
    }

    static func logName(_ reply: ShareReply) -> String {
        switch reply {
        case .text(let text): "text \(text.count) chars"
        case .asking: "asking"
        case .stillWorking: "still working"
        case .failed: "failed"
        }
    }
}
