// Three small things Hermes 0.22.5 has that the desktop app shows (polish sweep 2026-10-24, hermes-gaps):
// - Context before the first turn: `session.context_breakdown` estimates how full the chat is when `session.usage`
//   has no `context_max` yet (a chat just resumed in this gateway process).
// - Running commands: `process.list` (the chat's background processes) and `process.kill` (one of them), instead of
//   /stop's kill-all.
// - Message reactions (Tapbacks): `message.react`, and the reactions transcript rows carry in `display_metadata`.
// Old gateways without a method keep working: the feature hides when the method is unknown (-32601).

import Foundation

// MARK: - Context estimate

nonisolated enum ContextEstimate {
    /// `session.context_breakdown`'s answer as usage with only the context fields; nil without a `context_max`.
    /// The figure is an estimate unless the gateway says it came from the provider (`context_estimated: false`).
    static func decode(_ json: JSONValue?) -> SessionUsage? {
        guard let decoded = SessionUsage.decode(json), let max = decoded.contextMax, max > 0 else { return nil }
        var usage = SessionUsage()
        usage.contextMax = max
        usage.contextUsed = decoded.contextUsed
        usage.contextPercent = decoded.contextPercent
        usage.contextEstimated = decoded.contextEstimated ?? true
        return usage
    }
}

nonisolated extension SessionUsage {
    /// The reported usage, with the estimate's context fields when the report has no context of its own. nil only
    /// when both are nil.
    static func shown(_ usage: SessionUsage?, estimate: SessionUsage?) -> SessionUsage? {
        guard let estimate, (usage?.contextMax ?? 0) <= 0 else { return usage }
        var merged = usage ?? SessionUsage()
        merged.contextMax = estimate.contextMax
        merged.contextUsed = estimate.contextUsed
        merged.contextPercent = estimate.contextPercent
        merged.contextEstimated = estimate.contextEstimated ?? true
        return merged
    }
}

// MARK: - Running commands

/// One of the chat's background processes as `process.list` reports it.
nonisolated struct BackgroundProcess: Hashable, Sendable, Identifiable {
    var id: String
    var command: String
    var status: String
    var uptimeSeconds: Int?
    var exitCode: Int?
    var tail: String

    var isRunning: Bool { status == "running" }

    /// The command's first line ("npm test"); "Background command" when it has none.
    var title: String {
        let first = command.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return first.isEmpty ? "Background command" : first
    }

    /// "Running · 3m" (or "Running" while the time is unknown).
    var detail: String {
        guard isRunning else { return exitCode.map { "Exited (code \($0))" } ?? "Exited" }
        return uptimeSeconds.map { "Running · \(Self.duration($0))" } ?? "Running"
    }

    /// The last two lines it printed, each at most 160 characters.
    var tailLines: String {
        let lines = tail.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.suffix(2).map { $0.count > 160 ? String($0.prefix(159)) + "…" : $0 }.joined(separator: "\n")
    }

    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        let m = (s % 3600) / 60
        return m == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(m)m"
    }

    /// `process.list`'s `processes`; rows without an id are left out.
    static func list(_ json: JSONValue?) -> [BackgroundProcess] {
        (json?["processes"]?.array ?? json?.array ?? []).compactMap { entry in
            guard let id = entry["session_id"]?.nonEmptyString ?? entry["id"]?.nonEmptyString else { return nil }
            let uptime: Int? = {
                guard case .number(let n)? = entry["uptime_seconds"], n.isFinite, n >= 0 else { return nil }
                return Int(n)
            }()
            return BackgroundProcess(id: id, command: entry["command"]?.string ?? "", status: entry["status"]?.string ?? "running",
                                     uptimeSeconds: uptime, exitCode: entry["exit_code"]?.int,
                                     tail: entry["output_tail"]?.string ?? entry["output_preview"]?.string ?? "")
        }
    }
}

// MARK: - Message reactions

/// One emoji reaction on a message: one per author (Tapback rules). `author` is "user" (you) or "agent" (the bot);
/// any other author is kept and drawn, never treated as yours.
nonisolated struct MessageReaction: Hashable, Sendable {
    var emoji: String
    var author: String
    var at: Double?

    var isMine: Bool { author == "user" }
}

/// One badge on a bubble: an emoji, how many reacted with it, and whether one of them is yours.
nonisolated struct ReactionChip: Hashable, Sendable {
    var emoji: String
    var count: Int
    var mine: Bool
}

nonisolated enum MessageReactions {
    /// The six iOS Tapbacks, in Apple's order (the desktop's QUICK_REACTIONS).
    static let quick = ["❤️", "👍", "👎", "😂", "‼️", "❓"]

    /// The Tapback's name for the menu and VoiceOver.
    static func name(_ emoji: String) -> String {
        switch emoji {
        case "❤️": "Heart"
        case "👍": "Thumbs Up"
        case "👎": "Thumbs Down"
        case "😂": "Ha Ha"
        case "‼️": "Exclamation Marks"
        case "❓": "Question Mark"
        default: emoji
        }
    }

    /// A reactions list, leniently: an array of `{emoji, author, at}`; anything malformed is skipped, and an author
    /// that appears twice keeps its newest. At most 64.
    static func decode(_ json: JSONValue?) -> [MessageReaction] {
        guard case .array(let items)? = json else { return [] }
        var out: [MessageReaction] = []
        for item in items.prefix(500) {
            guard let emoji = item["emoji"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !emoji.isEmpty,
                  emoji.count <= 16 else { continue }
            let author = item["author"]?.string?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let at: Double? = { if case .number(let n)? = item["at"], n.isFinite { return n }; return nil }()
            out = merge(out, [MessageReaction(emoji: emoji, author: author.isEmpty ? "user" : author, at: at)])
        }
        return Array(out.prefix(64))
    }

    /// The reactions a transcript row carries: `reactions` on the row, else inside `display_metadata` (an object, or
    /// a JSON string from an older backend).
    static func fromRow(_ row: [String: JSONValue]) -> [MessageReaction] {
        if let direct = row["reactions"], case .array = direct { return decode(direct) }
        guard let meta = row["display_metadata"]?.looseObject else { return [] }
        return decode(meta["reactions"])
    }

    /// Two lists as one: per author, the later one wins (by `at`; `b` wins a tie or a missing time). Order is the
    /// order authors first reacted.
    static func merge(_ a: [MessageReaction], _ b: [MessageReaction]) -> [MessageReaction] {
        var out = a
        for r in b {
            if let i = out.firstIndex(where: { $0.author == r.author }) {
                if (out[i].at ?? -.infinity) <= (r.at ?? .infinity) { out[i] = r }
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// The local half of a Tapback (the gateway's own rule): one per author; the same emoji again, or nil, removes it.
    static func applying(_ reactions: [MessageReaction], emoji: String?, author: String = "user", at: Double? = nil) -> [MessageReaction] {
        let previous = reactions.first { $0.author == author }
        let without = reactions.filter { $0.author != author }
        guard let emoji, previous?.emoji != emoji else { return without }
        return without + [MessageReaction(emoji: emoji, author: author, at: at ?? Date().timeIntervalSince1970)]
    }

    /// Badges in the order their emoji first appear.
    static func chips(_ reactions: [MessageReaction]) -> [ReactionChip] {
        var out: [ReactionChip] = []
        for r in reactions {
            if let i = out.firstIndex(where: { $0.emoji == r.emoji }) {
                out[i].count += 1
                out[i].mine = out[i].mine || r.isMine
            } else {
                out.append(ReactionChip(emoji: r.emoji, count: 1, mine: r.isMine))
            }
        }
        return out
    }

    /// VoiceOver's words for a message's badges: "Reactions: Heart from you, Thumbs Up from Ivy".
    static func spoken(_ reactions: [MessageReaction], bot: String) -> String {
        let parts = reactions.map { "\(name($0.emoji)) from \($0.isMine ? "you" : bot)" }
        return "Reactions: " + parts.joined(separator: ", ")
    }
}

/// Settings › Chat › Message Reactions (the web's `hermes.desktop.reactions.v1`, default Off). Off hides the React
/// menu; reactions already on messages still show.
nonisolated enum MessageReactionsPref {
    static let key = "hqn.reactions"
    /// Set once the person has used the switch: only then is the choice written to the gateway's config (so a
    /// default never overwrites what the desktop app set).
    static let touchedKey = "hqn.reactions.touched"
    static let didChange = Notification.Name("hqn.reactions.changed")
    static let configKey = "display.message_reactions"

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            UserDefaults.standard.set(true, forKey: touchedKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static var touched: Bool { UserDefaults.standard.bool(forKey: touchedKey) }

    /// What this device last wrote to each bot (`<gateway>|<profile>` → on), so the switch goes to a bot once per value
    /// and not on every chat open (log study 2026-10-28: 188 writes in a day for one flip of the switch).
    static let writtenKey = "hqn.reactions.written"
    static func written(_ bot: String) -> Bool? {
        (UserDefaults.standard.dictionary(forKey: writtenKey) as? [String: Bool])?[bot]
    }
    static func noteWritten(_ bot: String, _ on: Bool) {
        var all = UserDefaults.standard.dictionary(forKey: writtenKey) as? [String: Bool] ?? [:]
        all[bot] = on
        UserDefaults.standard.set(all, forKey: writtenKey)
    }
}
