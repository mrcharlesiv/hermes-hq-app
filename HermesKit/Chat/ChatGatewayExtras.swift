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
    /// [background] The folder it runs in (`process.list`'s `cwd`), for the row's detail when its command has no `cd`.
    var cwd: String? = nil
    /// [background] When the process started (epoch seconds parsed from `process.list`'s `started_at`).
    var startedAt: Double? = nil
    /// [background] OS process id when `process.list` reports it.
    var pid: Int? = nil
    /// [background] Patterns the gateway is watching this job's output for (`watch_patterns`).
    var watchPatterns: [String] = []
    /// [background] The watch pattern that matched, if any (`watch_hit`).
    var watchHit: String? = nil
    /// [background] When the job last printed output (epoch seconds), if the gateway reports `last_output_at`.
    var lastOutputAt: Double? = nil
    /// [background] The bot's own sentence before the call that started it (`BackgroundJobWords.botWords`), filled in
    /// by the chat from its transcript; nil when the bot said nothing or the call is out of the loaded history.
    var botWords: String? = nil
    /// [background] Fuller context from the bot's paragraph before starting the job, when longer than `botWords`.
    var botNote: String? = nil
    /// [background] The full command recovered from the chat's `terminal` tool call when `process.list` clipped it.
    var fullCommand: String? = nil

    var isRunning: Bool { status == "running" }

    /// The fullest command available: the transcript's untruncated command when recovered, else `process.list`'s.
    var effectiveCommand: String { fullCommand ?? command }

    /// [background] The row's name: the bot's # comment, its own words, an agent's prompt, or the program and folder.
    var headline: String { BackgroundJobWords.headline(command: effectiveCommand, botWords: botWords) }
    /// [background] Who runs it and where ("Claude Code · goals-2"); nil when the name says it all.
    var detailLine: String? { BackgroundJobWords.detail(command: effectiveCommand, cwd: cwd, headline: headline) }
    /// [background] The newest output line, else an honest quiet line ("No output for 1h 22m").
    var statusLine: String { lastLine.isEmpty ? BackgroundJobWords.quietLine(command: effectiveCommand, uptimeSeconds: uptimeSeconds) : lastLine }

    /// The job's name (`BackgroundTaskText.title`): its leading `# comment`, else the program it runs and its folder
    /// ("npm test", "make · app" for `cd ~/app && make`), not a bare `cd …`; "Background command" when it has none.
    var title: String {
        let name = BackgroundTaskText.title(command: effectiveCommand)
        return name == "background process" ? "Background command" : name
    }

    /// [background] The row's line while the job has printed nothing: where its output goes when it writes to a file.
    var quietLine: String { BackgroundTaskText.quietLine(command: effectiveCommand) }

    /// "Running · 3m" (or "Running" while the time is unknown).
    var detail: String {
        guard isRunning else { return exitCode.map { "Exited (code \($0))" } ?? "Exited" }
        return uptimeSeconds.map { "Running · \(Self.duration($0))" } ?? "Running"
    }

    /// `tail` with ANSI escape sequences stripped, carriage-return overwrites collapsed, and outer blank lines trimmed.
    var cleanedTail: String { Self.cleanOutput(tail) }

    /// Non-empty trimmed lines from `cleanedTail`, in order.
    var outputLines: [String] {
        cleanedTail.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The last two lines it printed, each at most 160 characters.
    var tailLines: String {
        outputLines.suffix(2).map { $0.count > 160 ? String($0.prefix(159)) + "…" : $0 }.joined(separator: "\n")
    }

    /// [background] Up to two non-empty lines immediately before `lastLine`, for the list row's multi-line preview.
    var earlierPreviewLines: [String] {
        let lines = outputLines
        guard lines.count > 1 else { return [] }
        return lines.dropLast().suffix(2).map { $0.count > 160 ? String($0.prefix(159)) + "…" : $0 }
    }

    /// [background] The shelf chip's words: "Background task · 6m" for one (its time while known), "2 background tasks"
    /// for more. nil with none.
    static func chipWords(_ running: [BackgroundProcess]) -> String? {
        switch running.count {
        case 0: return nil
        case 1: return running[0].uptimeSeconds.map { "Background task · \(duration($0))" } ?? "Background task"
        default: return "\(running.count) background tasks"
        }
    }

    /// [background] The newest line it printed (for the shelf's row), at most 160 characters; "" when it printed none.
    var lastLine: String {
        guard let last = outputLines.last else { return "" }
        return last.count > 160 ? String(last.prefix(159)) + "…" : last
    }

    /// Live elapsed seconds: `uptime_seconds` counted forward locally from `observedAt`, else `started_at` fallback.
    func elapsedSeconds(observedAt: Double?, now: Double) -> Int? {
        if let uptime = uptimeSeconds {
            guard let observedAt else { return uptime }
            return max(0, uptime + max(0, Int((now - observedAt).rounded(.down))))
        }
        if let startedAt { return max(0, Int((now - startedAt).rounded(.down))) }
        return nil
    }

    /// When this job started: `started_at` when reported, else derived from `uptime_seconds` at `observedAt`.
    func startDate(observedAt: Double?) -> Date? {
        if let startedAt { return Date(timeIntervalSince1970: startedAt) }
        if let uptime = uptimeSeconds, let observedAt { return Date(timeIntervalSince1970: observedAt - Double(uptime)) }
        return nil
    }

    /// Short freshness phrase for when output last changed ("Updated just now", "Updated 2m ago").
    static func freshnessWords(since timestamp: Double, now: Double) -> String {
        let age = max(0, Int((now - timestamp).rounded(.down)))
        return age < 5 ? "Updated just now" : "Updated \(duration(age)) ago"
    }

    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        let m = (s % 3600) / 60
        return m == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(m)m"
    }

    /// Strips ANSI CSI/OSC escape sequences, normalizes progress-bar `\r` overwrites, and trims outer blank lines.
    static func cleanOutput(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if text.contains("\u{1B}") {
            text = ansiEscape.replacingMatches(in: text, with: "")
        }
        if text.contains("\r") {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                guard line.contains("\r") else { return String(line) }
                let parts = line.split(separator: "\r", omittingEmptySubsequences: true)
                return parts.last.map(String.init) ?? ""
            }.joined(separator: "\n")
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static let ansiEscape = try! NSRegularExpression(pattern: #"\x1B(?:\[[0-9;?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])"#)

    /// Parses a numeric epoch or ISO 8601 date-time string (with or without timezone and fractional seconds).
    static func parseTimestamp(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        if case .number(let n) = value, n.isFinite, n > 0 { return n }
        guard let raw = value.nonEmptyString?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: raw) { return d.timeIntervalSince1970 }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d.timeIntervalSince1970 }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            local.dateFormat = format
            if let d = local.date(from: raw) { return d.timeIntervalSince1970 }
        }
        return nil
    }

    /// `process.list`'s `processes`; rows without an id are left out.
    static func list(_ json: JSONValue?) -> [BackgroundProcess] {
        (json?["processes"]?.array ?? json?.array ?? []).compactMap { entry in
            guard let id = entry["session_id"]?.nonEmptyString ?? entry["id"]?.nonEmptyString else { return nil }
            let uptime: Int? = {
                guard case .number(let n)? = entry["uptime_seconds"], n.isFinite, n >= 0 else { return nil }
                return Int(n)
            }()
            let patterns = entry["watch_patterns"]?.array?.compactMap(\.nonEmptyString) ?? []
            return BackgroundProcess(id: id, command: entry["command"]?.string ?? "", status: entry["status"]?.string ?? "running",
                                     uptimeSeconds: uptime, exitCode: entry["exit_code"]?.int,
                                     tail: entry["output_tail"]?.string ?? entry["output_preview"]?.string ?? "",
                                     cwd: entry["cwd"]?.nonEmptyString,
                                     startedAt: parseTimestamp(entry["started_at"]),
                                     pid: entry["pid"]?.int,
                                     watchPatterns: patterns,
                                     watchHit: entry["watch_hit"]?.nonEmptyString,
                                     lastOutputAt: parseTimestamp(entry["last_output_at"]))
        }
    }
}

private nonisolated extension NSRegularExpression {
    func replacingMatches(in string: String, with template: String) -> String {
        stringByReplacingMatches(in: string, range: NSRange(string.startIndex..., in: string), withTemplate: template)
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
