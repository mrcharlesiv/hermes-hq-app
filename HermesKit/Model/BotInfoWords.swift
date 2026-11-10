// Bot Info and Edit Bot words chosen from state (UX study 2026-10-19 #0, #2). Pure, so the choices are unit-tested
// without SwiftUI.

import Foundation

nonisolated enum BotInfoWords {
    /// The header's line under the name: the role, only when it says something the name does not and is not the same
    /// text About shows below (the role is usually the description, which About already shows in full).
    static func headerRole(name: String, role: String?, about: String?) -> String? {
        let title = (role ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.lowercased() != name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        let text = (about ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return title == text ? nil : title
    }

    /// Edit Bot's footer under Display Name: an empty field means no custom title, so the bot keeps its usual name.
    static func titleFooter(defaultName: String) -> String {
        "Leave blank to use \(defaultName)."
    }

    /// Brain's Instructions row footer (Bot Info and More › Bot Profiles): plain words for what the file developers
    /// call SOUL.md actually is, and that an edit does not reach a chat already running.
    static func instructionsFooter(botName: String) -> String {
        "What \(botName) is told about who it is and how to work. Changes apply to its next chat."
    }

    /// [botinfo-chats] Bot Info › Chats' read row marks only the bot's own chat (its dot on Bots: BotStore.markRead /
    /// markUnread touch the canonical session ids), never its other chats, so it names the Bot Chat. "Mark All as
    /// Read" would promise more than it does. A chat's ⋯ keeps "Mark as Read" for that one chat (owner 2026-11-03).
    static func readTitle(unread: Bool) -> String {
        unread ? "Mark Bot Chat as Read" : "Mark Bot Chat as Unread"
    }

    /// [botinfo-chats] All Chats with <bot> closes the sheet and switches to the Sessions tab, so its line says where
    /// it lands rather than wearing a chevron that promises a page inside the sheet (owner 2026-11-03).
    static let allChatsSubtitle = "Opens in Sessions"
}
