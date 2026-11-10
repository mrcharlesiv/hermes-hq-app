// [offline] Which saved chat tails to read ahead of a tap, in the web app's order (docs/spec/3x-offline.md §6.10,
// `src/open-warm.ts`): the chat the next launch would reopen, pinned bots, the other bots by newest activity, the
// first 15 rows of the Sessions list, then hidden bots. One entry per chat. Pure.

import Foundation

nonisolated enum WarmOrder {
    struct Target: Hashable, Sendable {
        var profile: String
        var storedId: String
    }

    struct Candidate: Equatable, Sendable {
        var target: Target
        /// The chat's last activity as its list knows it (nil = unknown: only a tail never saved is read).
        var lastActive: Date?
    }

    /// The chat the next launch would reopen: its bot, and its stored id when it is not the bot's own chat.
    struct LastChat: Equatable, Sendable {
        var profile: String
        var storedId: String?
    }

    static let sessionRows = 15

    static func order(lastChat: LastChat?, bots: [Bot], sessions: [SessionSummary]) -> [Candidate] {
        var out: [Candidate] = []
        var seen = Set<Target>()
        func add(_ profile: String, _ storedId: String?, _ lastActive: Date?) {
            guard let storedId, !storedId.isEmpty, !profile.isEmpty else { return }
            let target = Target(profile: profile, storedId: storedId)
            guard seen.insert(target).inserted else { return }
            out.append(Candidate(target: target, lastActive: lastActive))
        }
        func newestFirst(_ a: Bot, _ b: Bot) -> Bool { (a.lastActive ?? .distantPast) > (b.lastActive ?? .distantPast) }
        if let lastChat {
            let bot = bots.first { $0.id == lastChat.profile }
            let stored = lastChat.storedId ?? bot?.canonicalSessionId
            let active = sessions.first { $0.id == stored && $0.profile == lastChat.profile }?.lastActive
                ?? (stored == bot?.canonicalSessionId ? bot?.lastActive : nil)
            add(lastChat.profile, stored, active)
        }
        let shown = bots.filter { !$0.hidden }
        for bot in shown.filter(\.pinned).sorted(by: { a, b in
            let x = a.pinOrder ?? Int.max, y = b.pinOrder ?? Int.max
            return x != y ? x < y : newestFirst(a, b)
        }) { add(bot.id, bot.canonicalSessionId, bot.lastActive) }
        for bot in shown.filter({ !$0.pinned }).sorted(by: newestFirst) { add(bot.id, bot.canonicalSessionId, bot.lastActive) }
        for row in sessions.prefix(sessionRows) { add(row.profile, row.id, row.lastActive) }
        for bot in bots.filter(\.hidden).sorted(by: newestFirst) { add(bot.id, bot.canonicalSessionId, bot.lastActive) }
        return out
    }
}
