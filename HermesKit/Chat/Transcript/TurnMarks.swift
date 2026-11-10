// [transcript] How long a turn took (docs/spec/3x-transcript.md §6.6, row L363), and the newest message a reader
// has seen in each chat (§4.1, row L329). Marks are remembered per chat scope so a resync or a relaunch keeps them
// and another chat with the same message ids never gets them (`S/fe-convo-r3.ts` turn marks, r4-105;
// `S/fe-convo-r5.ts` r5-86).

import Foundation

nonisolated enum TurnDuration {
    /// "4s", "1m 12s", "1h 3m"; nil under one second (unknown is shown as nothing, never as a guess).
    static func short(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 1 else { return nil }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    /// "Took 1 minute 12 seconds".
    static func spoken(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 1 else { return nil }
        let total = Int(seconds.rounded())
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        var parts: [String] = []
        if total >= 3600 { parts.append(unit(total / 3600, "hour")) }
        if total >= 60, (total % 3600) / 60 > 0 { parts.append(unit((total % 3600) / 60, "minute")) }
        if total < 3600, total % 60 > 0 { parts.append(unit(total % 60, "second")) }
        return "Took " + parts.joined(separator: " ")
    }
}

/// Duration marks by "<chat scope>\u{1}<message id>": 200 kept across all chats, oldest out first, in `UserDefaults`.
nonisolated final class TurnMarkStore: @unchecked Sendable {
    static let shared = TurnMarkStore(defaults: .standard)
    static let limit = 200
    private static let key = "hqn.transcript.turnMarks.v1"

    private let lock = NSLock()
    private let defaults: UserDefaults?
    /// Oldest first.
    private var order: [String] = []
    private var seconds: [String: Double] = [:]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        guard let stored = defaults?.array(forKey: Self.key) as? [[String: Any]] else { return }
        for entry in stored {
            guard let k = entry["k"] as? String, let s = entry["s"] as? Double, seconds[k] == nil else { continue }
            order.append(k); seconds[k] = s
        }
    }

    private static func key(_ scope: String, _ messageId: String) -> String { scope + "\u{1}" + messageId }

    func set(_ value: Double, scope: String, messageId: String) {
        guard value.isFinite, value >= 0, !scope.isEmpty, !messageId.isEmpty else { return }
        lock.lock()
        let k = Self.key(scope, messageId)
        if seconds[k] != nil { order.removeAll { $0 == k } }
        seconds[k] = value
        order.append(k)
        while order.count > Self.limit { seconds[order.removeFirst()] = nil }
        let snapshot: [[String: Any]] = order.map { ["k": $0, "s": seconds[$0] ?? 0] }
        lock.unlock()
        defaults?.set(snapshot, forKey: Self.key)
    }

    func seconds(scope: String, messageId: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return seconds[Self.key(scope, messageId)]
    }

    /// A reply that was live ("local-…") got its stored id on a resync: the mark follows it.
    func move(scope: String, from old: String, to new: String) {
        guard old != new, let value = seconds(scope: scope, messageId: old) else { return }
        set(value, scope: scope, messageId: new)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return order.count
    }
}

/// What the reader last saw of each chat (120 chats kept): the newest message's id, and where they were.
nonisolated struct SeenMark: Equatable, Sendable {
    var newestID: String
    /// How many messages the chat had (to find the first unseen one when ids changed on a resync).
    var count: Int
    var at: Date
}

nonisolated final class SeenStore: @unchecked Sendable {
    static let shared = SeenStore(defaults: .standard)
    static let limit = 120
    private static let key = "hqn.transcript.seen.v1"

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private var order: [String] = []
    private var marks: [String: SeenMark] = [:]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        guard let stored = defaults?.array(forKey: Self.key) as? [[String: Any]] else { return }
        for entry in stored {
            guard let k = entry["k"] as? String, let id = entry["id"] as? String, marks[k] == nil else { continue }
            order.append(k)
            marks[k] = SeenMark(newestID: id, count: entry["n"] as? Int ?? 0,
                                at: Date(timeIntervalSince1970: entry["at"] as? Double ?? 0))
        }
    }

    func mark(_ chat: String, newestID: String, count: Int, now: Date = Date()) {
        guard !chat.isEmpty, !newestID.isEmpty else { return }
        lock.lock()
        if marks[chat] != nil { order.removeAll { $0 == chat } }
        marks[chat] = SeenMark(newestID: newestID, count: count, at: now)
        order.append(chat)
        while order.count > Self.limit { marks[order.removeFirst()] = nil }
        let snapshot: [[String: Any]] = order.compactMap { k in
            marks[k].map { ["k": k, "id": $0.newestID, "n": $0.count, "at": $0.at.timeIntervalSince1970] }
        }
        lock.unlock()
        defaults?.set(snapshot, forKey: Self.key)
    }

    func mark(for chat: String) -> SeenMark? {
        lock.lock(); defer { lock.unlock() }
        return marks[chat]
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return order.count
    }

    enum Landing: Equatable, Sendable {
        /// Nothing new (or nothing known): open as today (the newest end, or the restored place).
        case usual
        /// Replies the reader has not seen: the first of them is the message at this index.
        case unseen(firstIndex: Int)
    }

    /// Where a reopened chat lands. `ids`: the chat's message ids, oldest first; `roles`: true where the message is the
    /// bot's (an unseen run starts at a reply, not at your own message).
    static func landing(mark: SeenMark?, ids: [String], incoming: [Bool]) -> Landing {
        guard let mark, let newest = ids.last, newest != mark.newestID else { return .usual }
        let start: Int
        if let seen = ids.lastIndex(of: mark.newestID) { start = seen + 1 }
        else if mark.count > 0, mark.count < ids.count { start = mark.count }
        else { return .usual }
        guard start < ids.count else { return .usual }
        guard let first = (start..<ids.count).first(where: { $0 < incoming.count && incoming[$0] }) else { return .usual }
        return .unseen(firstIndex: first)
    }
}
