import Foundation
import Testing
@testable import HermesHQNative

/// UX study 2026-10-19 #0, #2: Bot Info shows the description once; Edit Bot says what an empty Title means.
@Suite struct BotInfoWordsTests {
    @Test func theHeaderLeavesOutTheRoleAboutAlreadyShows() {
        #expect(BotInfoWords.headerRole(name: "Ivy", role: "Plans my week", about: " Plans my week ") == nil)
        #expect(BotInfoWords.headerRole(name: "Ivy", role: "Research Lead", about: "Reads papers for me") == "Research Lead")
        #expect(BotInfoWords.headerRole(name: "Ivy", role: "Research Lead", about: nil) == "Research Lead")
    }

    @Test func theHeaderLeavesOutARoleThatIsTheName() {
        #expect(BotInfoWords.headerRole(name: "Ivy", role: "ivy", about: nil) == nil)
        #expect(BotInfoWords.headerRole(name: "Ivy", role: "  ", about: nil) == nil)
        #expect(BotInfoWords.headerRole(name: "Ivy", role: nil, about: "Plans my week") == nil)
    }

    @Test func theTitleFooterNamesTheUsualName() {
        #expect(BotInfoWords.titleFooter(defaultName: "Hermes") == "Leave blank to use Hermes.")
    }

    /// Brain's Instructions row (developer name SOUL.md, kept out of the words users see): plain words, the bot's
    /// own name, and that an edit reaches only its next chat.
    @Test func theInstructionsFooterNamesTheBotAndWhenItTakesEffect() {
        #expect(BotInfoWords.instructionsFooter(botName: "Ivy") == "What Ivy is told about who it is and how to work. Changes apply to its next chat.")
        #expect(!BotInfoWords.instructionsFooter(botName: "Ivy").localizedCaseInsensitiveContains("soul"))
    }

    /// [botinfo-chats] Owner 2026-11-03 (menu/nav review): Bot Info › Chats' read row marks the bot's own chat (its dot
    /// on Bots), never its other chats, so it names the Bot Chat; a chat's ⋯ keeps "Mark as Read" for that one chat.
    @Test func theReadRowNamesTheBotChatAndDiffersFromTheChatMenu() {
        #expect(BotInfoWords.readTitle(unread: true) == "Mark Bot Chat as Read")
        #expect(BotInfoWords.readTitle(unread: false) == "Mark Bot Chat as Unread")
        let chatMenu = ChatMenuModel.rows(ChatMenuState()).map(\.title)
        #expect(chatMenu.contains("Mark as Unread"), "the chat ⋯ keeps its words: \(chatMenu)")
        #expect(!chatMenu.contains(BotInfoWords.readTitle(unread: false)))
        #expect(!BotInfoWords.readTitle(unread: true).contains("All"), "it doesn't touch the bot's other chats")
    }

    /// [botinfo-chats] All Chats with <bot> closes the sheet onto another tab: its line says which.
    @Test func allChatsSaysWhereItLands() {
        #expect(BotInfoWords.allChatsSubtitle == "Opens in Sessions")
    }
}
