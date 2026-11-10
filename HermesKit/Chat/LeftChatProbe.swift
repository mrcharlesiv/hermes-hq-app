// [diagnostics] "I have to back out of a bot chat for the response to show" (owner, 2026-10-14). When a chat left within
// the last 3 minutes opens again and its first read holds a reply the gateway saved before the screen left that the
// screen never showed, the log says so with what the old screen was doing (link, turn, cursor, frames it set aside,
// scroll). The state lives beside the chat (a weak table), as ChatReconnectState does.

import Foundation

@MainActor final class LeftChatProbe {
    /// Frames `receive` set aside: another runtime's with no resume in flight, and ones at or under the seq cursor.
    var foreign = 0
    var stale = 0
    /// `sessions.changed` ticks the chat heard, and reads a reply finished on another runtime asked for.
    var changed = 0
    var foreignReads = 0
    /// The screen's own words at the moment it left (following, unseen count), set by the chat screen.
    var screenNote: String?

    private struct Left {
        var at: Date
        var replies: Set<String>
        var state: String
    }

    private static let table = NSMapTable<LiveChatSession, LeftChatProbe>.weakToStrongObjects()
    private static var left: [String: Left] = [:]
    static let window: TimeInterval = 180

    static func of(_ chat: LiveChatSession) -> LeftChatProbe {
        if let probe = table.object(forKey: chat) { return probe }
        let probe = LeftChatProbe()
        table.setObject(probe, forKey: chat)
        return probe
    }

    /// What identifies a reply across reads: its row id, the start of its words and the end of them. A long tool-heavy
    /// turn can fold differently live than in a history read (the 2026-10-24 log: a fold headed by an empty tool-call
    /// row, flagged on three reopens with 0 unseen), so any one of these matching counts as shown.
    nonisolated static func replyKeys(_ message: ChatMessage) -> [String] {
        guard message.role == .assistant else { return [] }
        var keys = message.rowId.map { ["row:\($0)"] } ?? []
        let text = ChatText.flat(message.plainText)
        if !text.isEmpty { keys += ["start:" + text.prefix(80), "end:" + text.suffix(80)] }
        return keys
    }

    /// The replies a fresh read holds that the screen that left did not show and that were finished before it left
    /// (2 s of clock slack), as indexes into `fresh`. A folded reply carries its first row's time, so its end is the next
    /// message's time, or for the newest one the newest row the read saw (`newestStored`, server seconds). Build 312's
    /// log: 2 of the 3 reports checked against state.db were turns that finished after the screen left.
    nonisolated static func missed(fresh: [ChatMessage], shown: Set<String>, leftAt: Date, newestStored: Double?) -> [Int] {
        let cutoff = leftAt.addingTimeInterval(-2)
        return fresh.indices.filter { i in
            let keys = replyKeys(fresh[i])
            guard !keys.isEmpty, shown.isDisjoint(with: keys), fresh[i].timestamp != nil else { return false }
            let next = fresh[(i + 1)...].lazy.compactMap(\.timestamp).first
            guard let end = next ?? newestStored.map(Date.init(timeIntervalSince1970:)) else { return false }
            return end < cutoff
        }
    }

    static func chatLeft(_ chat: LiveChatSession) {
        guard let id = chat.readSessionId else { return }
        let probe = of(chat)
        let ago = chat.turn.lastEventAt.map { String(format: "%.0f s", Date().timeIntervalSince($0)) } ?? "never"
        var state = "link \(chat.connection), busy \(chat.turn.busy), runtime \(chat.runtimeSessionId == nil ? "none" : "bound")"
        state += ", seq \(chat.lastSeq.map(String.init) ?? "none"), last frame \(ago), parking \(chat.parking) (\(chat.parked.count) held)"
        state += ", set aside \(probe.foreign) foreign / \(probe.stale) stale, heard \(probe.changed) changed, \(probe.foreignReads) foreign reads"
        if let note = probe.screenNote { state += ", \(note)" }
        left[id] = Left(at: Date(), replies: Set(chat.messages.flatMap(replyKeys)), state: state)
        left = left.filter { Date().timeIntervalSince($0.value.at) < window }
    }

    /// The open's first read is in: compare with what the screen that left showed.
    static func chatOpened(_ chat: LiveChatSession) {
        guard let id = chat.readSessionId, let before = left.removeValue(forKey: id),
              Date().timeIntervalSince(before.at) < window else { return }
        let found = missed(fresh: chat.messages, shown: before.replies, leftAt: before.at, newestStored: chat.newestStoredAt)
        guard !found.isEmpty else { return }
        let ago = Int(Date().timeIntervalSince(before.at))
        // Which ones, content-free: row id and place from the newest, so a report can be looked up in state.db.
        let which = found.map { i in
            let row = chat.messages[i].rowId.map { "row \($0)" } ?? "unsaved"
            let began = chat.messages[i].timestamp.map { "started \(Int(before.at.timeIntervalSince($0))) s before" } ?? ""
            return "\(row), \(chat.messages.count - 1 - i) from newest, \(began)"
        }.joined(separator: "; ")
        AppLog.note("chat", "reopen found \(found.count) reply(ies) the screen missed, left \(ago) s ago [\(which)]: \(before.state)")
    }
}
