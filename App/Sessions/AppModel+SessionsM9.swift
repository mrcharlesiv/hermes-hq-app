// [sessions-m9] What the Sessions page asks of the app beyond its own store (docs/spec/3x-sessions.md §5.6).

import Foundation

extension AppModel: SessionsBotReads {
    /// Mark All as Read also acknowledges every bot's own chat, with the call its Bots row's Mark as Read makes
    /// (device-local), so the app's badge reaches zero as it does on the web (`acknowledgeAllKnownBotChats`).
    func markAllBotChatsRead() {
        guard let botStore else { return }
        for bot in botStore.bots where bot.unread { botStore.markRead(bot) }
    }
}
