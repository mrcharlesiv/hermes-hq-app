// [activity] Which of each bot's chats run a turn: the Bots row says "Working…" while its own Bot Chat is one of them
// (BotStore.setWorkingChats). A chat counts by its stored id, or "" while it has none yet (a chat being made). A turn
// sent before the chat's id came back started under "" and ended under the id, so "" stayed and the bot said
// "Working…" after it was done (2026-11-03, a tile asked of a new chat). The id moves the turn across when it comes.

import Foundation

nonisolated struct TurnWorking: Equatable {
    /// Profile → stored ids of its chats running a turn ("" = not stored yet).
    private(set) var byProfile: [String: Set<String>] = [:]

    mutating func set(profile: String, storedId: String?, running: Bool) {
        let key = storedId ?? ""
        if running { byProfile[profile, default: []].insert(key) } else { byProfile[profile]?.remove(key) }
        if byProfile[profile]?.isEmpty == true { byProfile[profile] = nil }
    }

    /// A chat of `profile` running a turn got its stored id: the turn counts under it from now on, so its end (said
    /// under the id) clears it. False when nothing ran unstored.
    mutating func resolved(profile: String, storedId: String) -> Bool {
        guard byProfile[profile]?.remove("") != nil else { return false }
        byProfile[profile, default: []].insert(storedId)
        return true
    }

    func busy(_ profile: String) -> Set<String> { byProfile[profile] ?? [] }
    func isIdle(_ profile: String) -> Bool { byProfile[profile] == nil }
}
