// Reopening the last chat on launch (the web app's nav-persistence.ts, build 240: PHONE_CHAT_KEY, phoneChatRestorable,
// forgetCrashedScreen). The chat on show when the app left the foreground is remembered per gateway account with the
// tab it was opened from; a cold launch puts it back over that tab's list (Back returns there), unless:
//   - the gateway's "Reopen last chat on launch" (`display.resume_last_session`) is off — the last answer read is kept
//     per account, absent counts as on (`!== false`, appearance-settings.tsx);
//   - the run before ended with a chat on screen in the foreground (a crash, or iOS ending it there): the "on screen"
//     marker set while a chat shows and cleared on every trip to the background was still there at launch, so that
//     screen may crash again on the same data (P-21) and the lists show instead;
//   - its bot is gone, or its session is no longer listed (deleted, archived), or its page tab is gone.
// A launch draft never moves here: native drafts belong to their own chat (AttachmentCenter keys), so the restored
// chat's draft comes back with it, and there is no blank launch composer for one to be typed into.

import Foundation

/// The chat left on show and where it was opened from (web `PhoneChat`).
nonisolated struct RememberedChat: Codable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable { case bots, sessions, page }
    var origin: Origin
    /// The bot (profile) the chat belongs to.
    var profile: String
    /// The chat's stored session id; nil for a bot's chat that had no Bot Chat yet (reopened through its bot).
    var storedId: String?
    /// The bot's own chat (opened from its Bots row, a tap or an alert): reopened through the bot as a row tap opens it,
    /// so it is the bot's current Bot Chat (Bot Chats are never on the Sessions list).
    var botChat: Bool
    /// `.page`: the tab it was opened on (its `HQTab` tag, 2…; the same number as its place before tabs could move) and
    /// that tab's identity ("tab-jobs", "tab-artifacts", …).
    var pageTab: Int? = nil
    var pageKind: String? = nil
}

/// Why a launch did (`reopen`) or did not put the last chat back. The raw values go into the log.
nonisolated enum LaunchChatDecision: Equatable, Sendable {
    case reopen(RememberedChat)
    case skip(Reason)

    enum Reason: String, Sendable {
        case nothing = "no chat was on show"
        case crashed = "the last run ended with that chat on screen"
        case resumeOff = "Reopen last chat on launch is off"
        case botGone = "its bot is gone"
        case sessionGone = "its chat is no longer listed"
        case pageGone = "its page tab is gone"
    }

    /// The decision for `chat` (web `phoneChatRestorable`, with the native owner being the account the record is kept
    /// under). `bot(profile)`: the bot exists; `listed(profile, id)`: the gateway still lists that chat for that bot;
    /// `page(tab, kind)`: that tab is still there.
    static func decide(_ chat: RememberedChat?, crashed: Bool, resume: Bool, bot: (String) -> Bool,
                       listed: (String, String) -> Bool, page: (Int, String) -> Bool) -> LaunchChatDecision {
        guard let chat else { return .skip(.nothing) }
        if crashed { return .skip(.crashed) }
        if !resume { return .skip(.resumeOff) }
        if chat.origin == .page {
            guard let tab = chat.pageTab, let kind = chat.pageKind, page(tab, kind) else { return .skip(.pageGone) }
        }
        if chat.botChat { return bot(chat.profile) ? .reopen(chat) : .skip(.botGone) }
        guard let id = chat.storedId, !id.isEmpty, listed(chat.profile, id) else { return .skip(.sessionGone) }
        return .reopen(chat)
    }
}

/// The remembered chat (per account), the reopen preference (per account) and the "chat on screen" marker, in
/// UserDefaults under `launchChat.`. Main actor.
final class LaunchChatMemory {
    static let shared = LaunchChatMemory()
    static let prefix = "launchChat."
    private static let markerKey = prefix + "onScreen"

    private let defaults: UserDefaults
    /// Accounts whose remembered chat was dropped at this launch because the run before ended with it on screen.
    private(set) var crashedAccounts: Set<String> = []
    private var launched = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private static func chatKey(_ account: String) -> String { prefix + "chat." + account }
    private static func resumeKey(_ account: String) -> String { prefix + "resume." + account }

    /// First thing at launch, before this run can set the marker: a marker still set means the run before ended (crash,
    /// or killed in the foreground) with that account's chat on screen. Its record is dropped and the marker cleared.
    func launch() {
        guard !launched else { return }
        launched = true
        guard let account = defaults.string(forKey: Self.markerKey) else { return }
        defaults.removeObject(forKey: Self.markerKey)
        defaults.removeObject(forKey: Self.chatKey(account))
        crashedAccounts.insert(account)
        AppLog.note("restore", "the last run ended with a chat on screen: it is not reopened")
    }

    func crashed(account: String) -> Bool { crashedAccounts.contains(account) }

    /// The chat left on show for `account` (nil: a list or page was).
    func recall(account: String) -> RememberedChat? {
        guard let data = defaults.data(forKey: Self.chatKey(account)) else { return nil }
        return try? JSONDecoder().decode(RememberedChat.self, from: data)
    }

    /// The screen on show for `account`: the chat (or nil). While the app is in the foreground a chat on show also sets
    /// the marker, which a trip to the background clears.
    func remember(_ chat: RememberedChat?, account: String, foreground: Bool) {
        if let chat, let data = try? JSONEncoder().encode(chat) {
            if defaults.data(forKey: Self.chatKey(account)) != data { defaults.set(data, forKey: Self.chatKey(account)) }
        } else if defaults.object(forKey: Self.chatKey(account)) != nil {
            defaults.removeObject(forKey: Self.chatKey(account))
        }
        let marker = chat != nil && foreground ? account : nil
        if defaults.string(forKey: Self.markerKey) != marker { defaults.set(marker, forKey: Self.markerKey) }
    }

    /// The app left the foreground cleanly: no screen of this run counts as crashed any more.
    func wentToBackground() {
        if defaults.object(forKey: Self.markerKey) != nil { defaults.removeObject(forKey: Self.markerKey) }
    }

    /// `display.resume_last_session` as last read from `account`'s gateway; on until read off.
    func resume(account: String) -> Bool { defaults.object(forKey: Self.resumeKey(account)) as? Bool ?? true }

    func setResume(_ on: Bool, account: String) { defaults.set(on, forKey: Self.resumeKey(account)) }

    /// `display.resume_last_session` from a `GET /api/config` answer: only `false` turns it off (web `!== false`).
    nonisolated static func resume(config: JSONValue?) -> Bool {
        if case .bool(false)? = config?["display"]?["resume_last_session"] { return false }
        return true
    }

    /// Sign Out: the account's remembered chat and preference go with its other caches.
    func forget(account: String) {
        defaults.removeObject(forKey: Self.chatKey(account))
        defaults.removeObject(forKey: Self.resumeKey(account))
        if defaults.string(forKey: Self.markerKey) == account { defaults.removeObject(forKey: Self.markerKey) }
    }

    /// Every account (a DEBUG reset to a clean first run).
    func forgetAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) { defaults.removeObject(forKey: key) }
        crashedAccounts = []
    }
}
