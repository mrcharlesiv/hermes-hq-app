import Foundation

// [updates] Everything that happens between two real messages besides their words — finished helpers and background
// tasks, /bg and /btw answers, other bots' messages and this bot's messages to them, scheduled runs, a reply's finished
// work line, notes such as "Model changed to …" — folds into one centred line: "From Hermes · 3 more", led by the most
// useful one, with their faces and glyphs before it. A tap opens a card under it with one row per member (each opens on
// its words); a run of one opens on its words directly (owner, 2026-10-27: "very minimal, not in your way at all …
// never a thing that creates clutter"; 2026-10-28: "they all must be properly designed and automatically grouped
// together so that they do not create clutter … we can't have them stacked on top of each other").
//
// Runs are found from the rows, not the messages: every small row between two real rows is in one run, whichever
// message drew it. A run can start in the tail of a reply (its last small rows), cover messages that draw only small
// rows (or nothing, like a silent reply to a delivery), and end in the head of another reply (its work line and its
// "To Hermes" rows above its first words). A reply's own real rows keep their places.
//
// [idle] A day line (a new day, or 30 minutes' quiet) ends a run unless the message after it draws only small rows: a
// bot left alone for a week stacked "Inbox watch", "Background update" and their dates down the chat, one per day (owner,
// 2026-11-10: "If a bot is idle like this I'd like to group these together"). The run's day line then names its first
// and last days ("Oct 26 – Nov 6"), the lines inside it go, and its card's rows say their days. A message that draws
// nothing (a silent reply to a scheduled run) draws no day line either: its time alone stood as a line of its own.
//
// [files] A reply that did its work and said nothing draws a work line and, when it changed files, their card. The card
// was a real row, so a long turn of such replies between helpers' deliveries stacked a card and a line for each (owner,
// 2026-11-10, Otto's chat: "way too busy … all of that should be summed up into one"). The card of a reply whose other
// rows all fold joins the run, and every card of one run is one member, "5 files changed", which opens on its files
// (each opens the file) and Review Changes. A reply with words keeps its card under them, and so does a wordless reply
// that stands by itself (its line and its card, nothing else in the run).
//
// The line belongs to the run's first small row's message (`<message id>|grp`, or the row's own id for a run of one).
// Region rebuilds widen to every message a run touches (`widen`), so the line always counts what follows it. A run
// longer than `reach` messages each way is cut there in a region rebuild (a full build isn't): its line may count short
// until the chat is drawn again. A day of hourly jobs is about 50 messages, so this is accepted.
//
// [exchange] Once the bot starts talking with another bot after your message ("To Home", "From Home"), its own replies
// to you join the run too while the talk goes on: a reply folds when the bot wrote to (or heard from) another bot after
// it and then replied again. A back-and-forth of a dozen short updates ("I've asked Home…", "Home confirmed…",
// "Correction: …") folds into "With Home · 18 messages" (owner, 2026-10-29: "the entire exchange needs to be in the
// little expandable things … none of it mattered until the final message"). Its replies before the talk began keep
// their bubbles, and so does every reply after the bots' last message: the answer to what you asked is one of those.
// Your message ends a talk, and so does a scheduled job's report: the turn it starts is about something else (owner,
// 2026-10-29, build 464 kept only "the last reply", which was about the weekly review a job reported at 1:01, and the
// answer about the flowers folded away: "never got an actual response from Hermes … I call that a big fail").
// The bot's first reply after your message stays too when it's long (`answerLength`): that's the answer, and the
// talk it starts is follow-up (owner, 2026-10-31, the answer about voice to text folded behind Otto's and Inbox's).
// A reply written to the other bot ("Thanks, Otto. …", right after Otto's message) folds whatever follows it and
// however long it is: it was never an answer to you (`Rows.writesToBot`; owner, 2026-11-11).

nonisolated struct UpdatesGroup: Hashable {
    enum Mark: Hashable {
        case glyph(ChatGlyph)
        case face(ChatSender)
    }
    /// At most three, most useful first: other bots' faces, then glyphs.
    var marks: [Mark]
    /// "3 more", after the lead; nil for a group of one.
    var tail: String?
    var count: Int
    /// The line opens (a group of one with nothing behind its words doesn't).
    var opens: Bool
    /// The members' words before their colons, oldest first (VoiceOver: "4 updates: From Hermes, To Hermes, …").
    var titles: [String] = []
}

/// [updates] One member of an opened group: a row of the inset card under the line (UpdateMemberCell.swift). The card is
/// made of these rows, so opening a member rebuilds one row.
nonisolated struct UpdateMemberRow {
    /// The card's top and bottom rows round their outer corners.
    var first: Bool
    var last: Bool
    var mark: UpdatesGroup.Mark
    /// "From Hermes", "Helper finished", "Delegated 1 task · 1 helper", "Model changed to GPT-6".
    var title: String
    /// The member's message time, trailing on the title's line.
    var time: Date?
    /// [idle] Its day before the time ("Nov 2", "Yesterday") when the group spans days.
    var day: String? = nil
    /// The words after the title, as one paragraph (two lines show); empty for a note.
    var preview: String
    /// What it opens on: the whole message or report (`BackgroundResults.opened`); empty when it opens nothing.
    var full: String
    /// A process's log: only written-out addresses are links (`.addresses`), not Markdown.
    var process = false
    /// A note: its title may wrap to two lines.
    var notice = false
    var expanded: Bool
    /// A reply's work line: its steps (one opens its sheet; several list in the row once it is open) and its thought.
    var steps: [ToolCall] = []
    var thought: String? = nil
    /// The update as its own row (Copy, Read Aloud and Share read its words); nil for a work line or a note.
    var result: BackgroundResultRow? = nil
    /// [files] "5 files changed": the files, listed once it is open (one opens the file), then Review Changes.
    var files: [ChangedFile] = []

    /// A tap shows more: its steps (one step: the step's sheet), its files, or its whole words when they say more than
    /// the preview (the layout also opens one whose preview is cut short).
    var opens: Bool { !steps.isEmpty || thought != nil || !files.isEmpty || (!full.isEmpty && full != preview) }
}

nonisolated enum UpdateGroups {
    /// A small row's place: its message's index and the row's index among the rows that message draws alone.
    struct Member: Hashable {
        var message: Int
        var row: Int
    }

    /// A run of small rows between two real rows, oldest first.
    struct Group: Equatable {
        var members: [Member]
        var head: Member { members[0] }
        /// The messages the run touches, from its first member's to its last's.
        var span: ClosedRange<Int> { members[0].message...members[members.count - 1].message }
    }

    /// The runs a build draws and which small rows they hold.
    struct Plan {
        var groups: [Group] = []
        var byMember: [Member: Int] = [:]
        func group(_ m: Member) -> Group? { byMember[m].map { groups[$0] } }
    }

    /// Each message's rows as it draws them alone, made once per build (the plan, the line, its members and the build
    /// itself all read them).
    final class Rows {
        let input: ChatRowBuilder.Input
        private var made: [Int: [ChatRow]] = [:]
        init(_ input: ChatRowBuilder.Input) { self.input = input }
        func at(_ i: Int) -> [ChatRow] {
            if let known = made[i] { return known }
            var rows: [ChatRow] = []
            ChatRowBuilder.appendRows(for: input.messages[i], at: i, input: input, into: &rows)
            made[i] = rows
            return rows
        }

        /// The row folds into a run: a small row, or one of the bot's replies inside a talk with another bot.
        func small(_ m: Member) -> Bool { UpdateGroups.isSmall(at(m.message)[m.row]) || interim(m) || foldsFiles(m) }

        /// [files] The files card of a reply whose other rows all fold (its work line, or nothing at all): it folds too.
        func foldsFiles(_ m: Member) -> Bool {
            let own = at(m.message)
            guard own[m.row].changedFiles != nil else { return false }
            return own.indices.allSatisfy { r in
                r == m.row || UpdateGroups.isSmall(own[r]) || interim(Member(message: m.message, row: r))
            }
        }

        private var interims: [Member: Bool] = [:]

        /// [exchange] One of this bot's replies to you inside a talk with another bot: a message between the bots before it
        /// (since your last message) and, after it, another such message that the bot then replied to (ahead of your
        /// next message). Each way the search stops where a talk ends (`endsTalk`) or `reach` messages out, so a region
        /// rebuild finds what a full build does.
        func interim(_ m: Member) -> Bool {
            if let known = interims[m] { return known }
            let found = findInterim(m)
            interims[m] = found
            return found
        }

        private func findInterim(_ m: Member) -> Bool {
            guard input.room == nil, UpdateGroups.isBotsReply(at(m.message)[m.row]) else { return false }
            if writesToBot(m.message) { return true }
            if answersYou(m) { return false }
            let messages = input.messages
            var talked = false, answered = false
            ahead: for i in m.message..<min(messages.count, m.message + UpdateGroups.reach + 1) {
                for (r, row) in at(i).enumerated() where i > m.message || r > m.row {
                    if UpdateGroups.endsTalk(row) { break ahead }
                    if UpdateGroups.isBotTalk(row) { talked = true }
                    if talked, UpdateGroups.isBotsReply(row) { answered = true; break ahead }
                }
            }
            guard answered else { return false }
            for i in stride(from: m.message, through: max(0, m.message - UpdateGroups.reach), by: -1) {
                let own = at(i)
                for row in own[..<(i == m.message ? m.row : own.count)].reversed() {
                    if UpdateGroups.endsTalk(row) { return false }
                    if UpdateGroups.isBotTalk(row) { return true }
                }
            }
            return false
        }

        private var toBot: [Int: Bool] = [:]

        /// [exchange] The reply is written to the bot whose message it answers, not to you: that bot's message is the
        /// last thing before it (a work line or a note between them aside) and its first words speak to that bot by
        /// name ("Thanks, Otto. Your diagnosis was right…"). Hermes hands such a reply back to the bot that wrote; as a
        /// bubble it read as an answer to you (owner, 2026-11-11: "a message to a bot made it in to the chat instead of
        /// the little pill"). A reply that only answers a bot's message keeps its bubble: it may be the news that bot
        /// brought you ("The flowers are at the door"). A reply still being written stays a bubble until it ends.
        func writesToBot(_ message: Int) -> Bool {
            if let known = toBot[message] { return known }
            let found = findWritesToBot(message)
            toBot[message] = found
            return found
        }

        private func findWritesToBot(_ message: Int) -> Bool {
            guard !input.messages[message].isStreaming,
                  let first = at(message).first(where: UpdateGroups.isBotsReply), case .bubble(let b) = first.kind else { return false }
            for i in stride(from: message - 1, through: max(0, message - 8), by: -1) {
                for row in at(i).reversed() {
                    guard case .backgroundResult(let from) = row.kind, UpdateGroups.isBotTalk(row) else {
                        if UpdateGroups.isSmall(row), !UpdateGroups.endsTalk(row) { continue }
                        return false
                    }
                    guard !from.sentTo else { return false }
                    let title = BackgroundResults.split(from.title).head
                    let names = [from.face?.name, from.face?.profile, title.hasPrefix("From ") ? String(title.dropFirst(5)) : nil]
                    return BotDMs.speaksTo(names.compactMap { $0 }, in: b.text)
                }
            }
            return false
        }

        /// [exchange] See `UpdateGroups.answerLength`.
        private func answersYou(_ m: Member) -> Bool {
            guard case .bubble(let b) = at(m.message)[m.row].kind, b.text.count >= UpdateGroups.answerLength else { return false }
            for i in stride(from: m.message, through: max(0, m.message - UpdateGroups.reach), by: -1) {
                let own = at(i)
                for row in own[..<(i == m.message ? m.row : own.count)].reversed() {
                    if UpdateGroups.endsTalk(row) { return true }
                    if UpdateGroups.isBotsReply(row) { return false }
                }
            }
            return false
        }
    }

    /// [exchange] The bot's first reply after your message, when it's long enough to be the answer itself, not a note
    /// that it asked another bot ("I've asked Home…" folds). Hermes answered "Voice to text model still sucks" in 1,472
    /// characters, then two shorter replies came as Otto and Inbox wrote back; build 534 folded the answer into "With Otto
    /// and Inbox · 6 messages" (owner, 2026-10-31: "never got a response in the chat").
    static let answerLength = 600

    /// How far past a range the run search reaches each way (a day of hourly jobs is about 50 messages).
    static let reach = 160

    /// A row that folds into a run's line: an update, a note, a reply's finished work line. A live work line ("Helper
    /// working…", "Working") stays a row of its own until it settles.
    static func isSmall(_ row: ChatRow) -> Bool {
        switch row.kind {
        case .backgroundResult, .notice: return true
        case .toolRun(let t): return t.line != nil && !t.live
        default: return false
        }
    }

    /// [exchange] A bubble of yours, or a scheduled job's report: either ends a talk between bots.
    static func endsTalk(_ row: ChatRow) -> Bool {
        switch row.kind {
        case .bubble(let b): return b.mine
        case .backgroundResult(let b): return b.cron
        default: return false
        }
    }

    /// [exchange] A bubble of this chat's own bot (not a room member's).
    static func isBotsReply(_ row: ChatRow) -> Bool {
        if case .bubble(let b) = row.kind { return !b.mine && b.sender == nil }
        return false
    }

    /// [exchange] This bot writing to another bot ("To Home"), or another bot's message to it ("From Home").
    static func isBotTalk(_ row: ChatRow) -> Bool {
        if case .backgroundResult(let b) = row.kind { return b.sentTo || (b.delivery && !b.cron) }
        return false
    }

    /// A /btw answer that opened as it landed (SideTasks.swift) is what was asked for: it stands as a run of its own,
    /// open, between the runs on either side, until it is folded; then it joins them.
    static func standsAlone(_ row: ChatRow) -> Bool {
        if case .backgroundResult(let b) = row.kind { return b.aside && b.expanded && b.group == nil }
        return false
    }

    /// A small row that joins the rows beside it into one run.
    private static func joinsRun(_ m: Member, rows: Rows) -> Bool { rows.small(m) && !standsAlone(rows.at(m.message)[m.row]) }

    /// The expansion key (and row id) of a group's line: its first row's message's id, or, when a real row splits that
    /// message's small rows into two runs ("To Hermes", the reply's words, "To Hermes" twice), the later run's first
    /// row's id, so no two lines share one.
    static let lineSuffix = "|grp"
    static func key(_ group: Group, rows: Rows) -> String {
        let own = rows.at(group.head.message)
        let message = rows.input.messages[group.head.message].id
        let splits = (0..<group.head.row).contains { rows.small(Member(message: group.head.message, row: $0)) }
        return splits ? own[group.head.row].id + lineSuffix : message + lineSuffix
    }

    /// A day line goes above `messages[b]` (the build's own rule, against the last timed message before it that draws
    /// something; one that draws nothing has no line).
    static func dayBreak(before b: Int, input: ChatRowBuilder.Input, rows: Rows) -> Bool {
        let messages = input.messages
        guard b > 0, let tb = messages[b].timestamp, !rows.at(b).isEmpty else { return false }
        var scan = b - 1
        while scan >= 0, scan >= b - 64 {
            if let ta = messages[scan].timestamp, !rows.at(scan).isEmpty {
                return ChatRowBuilder.needsDayBreak(previous: ta, current: tb, datesOnly: input.fewerTimes)
            }
            scan -= 1
        }
        return false
    }

    /// [idle] Every row the message draws joins a run: a day line above it doesn't end the run it continues.
    private static func wholly(_ i: Int, rows: Rows) -> Bool {
        rows.at(i).indices.allSatisfy { joinsRun(Member(message: i, row: $0), rows: rows) }
    }

    /// [idle] A run's first and last member's times when they fall on different days (its day line names both, its
    /// card's rows their days); nil for a run within one day.
    static func days(_ group: Group, input: ChatRowBuilder.Input) -> (first: Date, last: Date)? {
        let times = group.members.compactMap { input.messages[$0.message].timestamp }
        guard let first = times.min(), let last = times.max(), LocalDay.number(first) != LocalDay.number(last) else { return nil }
        return (first, last)
    }

    /// Every run touching `messages[range]`, found row by row.
    static func plan(_ input: ChatRowBuilder.Input, range: Range<Int>, rows: Rows) -> Plan {
        let messages = input.messages
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= messages.count else { return Plan() }
        // A run crosses from message a to a + 1 when a ends with a small row (or draws nothing) and a + 1 starts with one
        // (or draws nothing), with no day line between them unless a + 1 draws only small rows ([idle]).
        func endsSmall(_ i: Int) -> Bool { rows.at(i).indices.last.map { joinsRun(Member(message: i, row: $0), rows: rows) } ?? true }
        func startsSmall(_ i: Int) -> Bool { rows.at(i).indices.first.map { joinsRun(Member(message: i, row: $0), rows: rows) } ?? true }
        func joins(_ a: Int) -> Bool {
            endsSmall(a) && startsSmall(a + 1) && (!dayBreak(before: a + 1, input: input, rows: rows) || wholly(a + 1, rows: rows))
        }
        var start = range.lowerBound
        while start > 0, range.lowerBound - start < reach, joins(start - 1) { start -= 1 }
        var end = range.upperBound - 1
        while end + 1 < messages.count, end - (range.upperBound - 1) < reach, joins(end) { end += 1 }

        var plan = Plan()
        var run: [Member] = []
        func close() {
            // [files] One wordless reply by itself keeps its card under its line: the card folds only into a run that
            // holds more than its own reply.
            if Set(run.map(\.message)).count == 1 { run.removeAll { rows.at($0.message)[$0.row].changedFiles != nil } }
            guard !run.isEmpty else { return }
            for m in run { plan.byMember[m] = plan.groups.count }
            plan.groups.append(Group(members: run))
            run = []
        }
        for i in start...end {
            if i > start, dayBreak(before: i, input: input, rows: rows), !wholly(i, rows: rows) { close() }
            for (r, row) in rows.at(i).enumerated() {
                if standsAlone(row) {
                    close()
                    run = [Member(message: i, row: r)]
                    close()
                } else if rows.small(Member(message: i, row: r)) {
                    run.append(Member(message: i, row: r))
                } else {
                    close()
                }
            }
        }
        close()
        return plan
    }

    /// [exchange] The line a folded row is in and its card row's id, to open both (Find landing on a folded reply); nil
    /// when the row draws on its own.
    static func opening(rowId: String, message index: Int, input: ChatRowBuilder.Input) -> (line: String, member: String)? {
        guard input.messages.indices.contains(index) else { return nil }
        let rows = Rows(input)
        guard let r = rows.at(index).firstIndex(where: { $0.id == rowId }),
              let group = plan(input, range: index..<(index + 1), rows: rows).group(Member(message: index, row: r)),
              group.members.count > 1 else { return nil }
        return (key(group, rows: rows), rowId + memberSuffix)
    }

    /// `range` grown to cover every message of any run it touches (a rebuild must redraw the run's line). The message
    /// on each side counts too, looked through those that draw nothing: a run that ends there now may have reached into
    /// the range before this change (its line still counts the rows the range no longer draws).
    static func widen(_ range: ClosedRange<Int>, input: ChatRowBuilder.Input) -> ClosedRange<Int> {
        let rows = Rows(input)
        let count = input.messages.count
        var a = range.lowerBound, b = range.upperBound
        if a > 0 { a -= 1 }
        while a > 0, range.lowerBound - a < reach, rows.at(a).isEmpty { a -= 1 }
        if b + 1 < count { b += 1 }
        while b + 1 < count, b - range.upperBound < reach, rows.at(b).isEmpty { b += 1 }
        // [exchange] And the bot's replies before the range that it can fold: those after the last message between the
        // bots that the bot replied to (since the talk began). A message to another bot and a reply after it in the
        // range fold them all.
        if input.room == nil {
            var scan = range.lowerBound - 1, replied = false
            look: while scan >= 0, range.lowerBound - scan <= reach {
                for row in rows.at(scan).reversed() {
                    if endsTalk(row) || (replied && isBotTalk(row)) { break look }
                    if isBotsReply(row) { a = min(a, scan); replied = true }
                }
                scan -= 1
            }
        }
        let plan = plan(input, range: a..<(b + 1), rows: rows)
        var lo = range.lowerBound, hi = range.upperBound
        for g in plan.groups where g.span.overlaps(a...b) {
            lo = min(lo, g.span.lowerBound)
            hi = max(hi, g.span.upperBound)
        }
        return lo...hi
    }

    // MARK: The line

    private struct Item {
        /// The row's own id ("<message>|bg"): a run of one keeps it, so it opens as it did before it was grouped.
        var id: String
        /// The row as it draws on its own.
        var original: ChatRow
        var message: Int
        /// Its whole title ("From Hermes: Alex asks for …").
        var title: String
        var mark: UpdatesGroup.Mark
        var rank: Int
    }

    /// Which one leads the line, and the order of the marks: another bot's words, this bot's words to it, finished work,
    /// a scheduled run, the reply's work line, a note (owner, 2026-10-28: "when a bot messages another bot, it needs to
    /// like show that bot's face and then just say like to that bot or from that bot").
    static func rank(_ row: ChatRow) -> Int {
        switch row.kind {
        case .backgroundResult(let b): return b.sentTo ? 4 : b.delivery ? 5 : b.cron ? 2 : 3
        case .toolRun: return 1
        case .activity(.changedFiles): return 2   // [files] ahead of the work line that made them
        default: return 0
        }
    }

    private static func items(_ group: Group, rows: Rows) -> [Item] {
        let all: [Item] = group.members.compactMap { member in
            let row = rows.at(member.message)[member.row]
            switch row.kind {
            case .backgroundResult(let b):
                return Item(id: row.id, original: row, message: member.message, title: b.title,
                            mark: b.face.map { .face($0) } ?? .glyph(b.glyph), rank: rank(row))
            case .toolRun(let t):
                guard let line = t.line else { return nil }
                return Item(id: row.id, original: row, message: member.message, title: line.title, mark: .glyph(line.glyph), rank: 1)
            case .notice(let text):
                return Item(id: row.id, original: row, message: member.message, title: text, mark: .glyph(.note), rank: 0)
            case .activity(.changedFiles(let c)):
                return Item(id: row.id, original: row, message: member.message, title: ChangedFiles.title(c.files.count),
                            mark: .glyph(.file), rank: rank(row))
            case .bubble:
                // [exchange] The bot's own reply to you, under its name and face.
                let input = rows.input
                return Item(id: row.id, original: row, message: member.message, title: input.speakerName,
                            mark: input.ownFace.map { .face($0) } ?? .glyph(.message), rank: -1)
            default:
                return nil
            }
        }
        return summed(all, input: rows.input)
    }

    /// [files] Every files card of the run as one member, where the last of them was: a file changed by two replies is
    /// one row with both replies' edits and lines. It keeps the last card's id (its expansion key) and message.
    private static func summed(_ all: [Item], input: ChatRowBuilder.Input) -> [Item] {
        let cards = all.indices.filter { all[$0].original.changedFiles != nil }
        guard cards.count > 1, let last = cards.last else { return all }
        var order: [String] = []
        var byPath: [String: ChangedFile] = [:]
        for i in cards {
            for file in all[i].original.changedFiles?.files ?? [] {
                if var known = byPath[file.path] {
                    known.added += file.added
                    known.removed += file.removed
                    known.edits += file.edits
                    byPath[file.path] = known
                } else {
                    order.append(file.path)
                    byPath[file.path] = file
                }
            }
        }
        let files = order.compactMap { byPath[$0] }
        var out = all
        let row = ActivityRows.changedFilesRow(id: all[last].id, messageId: all[last].original.messageId, files: files, input: input)
        out[last] = Item(id: row.id, original: row, message: all[last].message, title: ChangedFiles.title(files.count),
                         mark: .glyph(.file), rank: rank(row))
        for i in cards.dropLast().reversed() { out.remove(at: i) }
        return out
    }

    /// [exchange] "With Home", "With Home and App", "With 3 bots" (as "From Home" and "To Home" read; short enough to
    /// keep its count at the largest text): the other bots of a run that holds the bot's replies, in the order they came in.
    private static func talkedWith(_ all: [Item]) -> String? {
        guard all.contains(where: { $0.original.isBubble }) else { return nil }
        var names: [String] = []
        for item in all {
            guard isBotTalk(item.original), case .backgroundResult(let b) = item.original.kind else { continue }
            let name = b.face.map { BackgroundResults.botName($0.name) }
                ?? head(b.title).replacingOccurrences(of: #"^(From|To) "#, with: "", options: .regularExpression)
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        switch names.count {
        case 0: return nil
        case 1: return "With " + names[0]
        case 2: return "With \(names[0]) and \(names[1])"
        default: return "With \(names.count) bots"
        }
    }

    /// The words a member shows on the line and leads its card row with: those before the title's colon.
    private static func head(_ title: String) -> String { BackgroundResults.split(title).head }

    /// What the run draws: its centred line, then (opened) a card row per member.
    static func rows(_ group: Group, input: ChatRowBuilder.Input, rows: Rows) -> [ChatRow] {
        let all = items(group, rows: rows)
        guard !all.isEmpty else { return [] }
        if all.count == 1 { return [alone(all[0].original)] }
        let id = key(group, rows: rows)
        let expanded = input.expanded.contains(id)
        // The newest of the highest rank leads; the marks follow the same order, no face or glyph twice.
        let ordered = all.enumerated()
            .sorted { a, b in a.element.rank != b.element.rank ? a.element.rank > b.element.rank : a.offset > b.offset }
            .map(\.element)
        var marks: [UpdatesGroup.Mark] = []
        let talk = talkedWith(all)
        for item in ordered where marks.count < 3 && !marks.contains(where: { same($0, item.mark) }) {
            // [exchange] The chat's own face isn't one of a talk's marks: the line is about the bots it talked with.
            if talk != nil, item.original.isBubble { continue }
            marks.append(item.mark)
        }
        // Only the words before the title's colon show; the rest opens with the member's row.
        var row = BackgroundResultRow(title: short(talk ?? head(ordered[0].title)), result: "", process: false, expanded: expanded)
        let titles = all.map { head($0.title).components(separatedBy: " · ")[0] }
        // Every one from (or to) the same bot: "From Hermes · 2 messages", not "· 1 more", which reads as something else.
        let sameBot = all.allSatisfy { $0.rank >= 4 } && Set(titles).count == 1
        // [exchange] A talk counts its messages: the bot's replies and the messages between the bots.
        let said = all.filter { $0.original.isBubble || isBotTalk($0.original) }.count
        let tail = talk != nil ? "\(said) messages" : sameBot ? "\(all.count) messages" : "\(all.count - 1) more"
        row.group = UpdatesGroup(marks: marks, tail: tail, count: all.count, opens: true, titles: titles)
        var h = Hasher()
        for item in all { RowHash.add(item.title, to: &h) }
        h.combine(row.group)
        h.combine(expanded)
        var out = [ChatRow(id: id, messageId: input.messages[group.head.message].id, scope: input.scope, fingerprint: h.finalize(),
                           kind: .backgroundResult(row), gapAbove: ChatMetrics.turnGap, variant: expanded ? 1 : 0)]
        guard expanded else { return out }
        let dated = days(group, input: input) != nil
        for (n, item) in all.enumerated() {
            out.append(member(item, first: n == 0, last: n == all.count - 1, dated: dated, input: input))
        }
        return out
    }

    /// Two marks that draw the same: a bot's face once, however its sender record was made.
    private static func same(_ a: UpdatesGroup.Mark, _ b: UpdatesGroup.Mark) -> Bool {
        switch (a, b) {
        case (.face(let x), .face(let y)): return x.key == y.key
        default: return a == b
        }
    }

    /// A count held to its noun ("1 task", "2 commands"): a no-break space, so a preview never breaks between them
    /// (review 2026-10-28: "delegated 1" / "task · 1 helper").
    static func counted(_ words: String) -> String {
        words.replacingOccurrences(of: #"(\d) "#, with: "$1\u{00A0}", options: .regularExpression)
    }

    /// A member row's id: its own row's id and this (it is also the member's expansion key).
    static let memberSuffix = "|in"

    private static func member(_ item: Item, first: Bool, last: Bool, dated: Bool, input: ChatRowBuilder.Input) -> ChatRow {
        let id = item.id + memberSuffix
        let expanded = input.expanded.contains(id)
        let m = input.messages[item.message]
        var row = UpdateMemberRow(first: first, last: last, mark: item.mark, title: head(item.title), time: m.timestamp,
                                  preview: "", full: "", expanded: expanded)
        if dated, let t = m.timestamp { row.day = ChatRowBuilder.dayName(t, now: input.now) }
        switch item.original.kind {
        case .backgroundResult(var b):
            b.expanded = false
            b.group = nil
            let opened = SpacedText.repair(BackgroundResults.opened(title: b.title, result: b.result))
            row.full = opened
            row.preview = preview(opened, process: b.process)
            row.process = b.process
            row.result = b
        case .toolRun(let t):
            guard let line = t.line else { break }
            row.title = line.title
            row.steps = t.tools
            row.thought = line.thought
            let parts = line.title.components(separatedBy: " · ")
            if parts[0].hasPrefix("Worked "), !t.tools.isEmpty {
                // A timed work line: its title is the time alone ("Worked for 8s"), so its time stays beside it; the
                // preview says what its steps did, then its helpers ("Edited overview.md, ran 2 commands, delegated 1 task
                // · 1 helper"). The line's own "3 steps" goes: it counted the helpers apart and disagreed with the list.
                row.title = parts[0]
                let extras = parts.dropFirst().filter { $0.range(of: #"^\d+ steps?$"#, options: .regularExpression) == nil }
                row.preview = counted(([ChatRunSummary.summarize(t.tools, live: false)] + extras).joined(separator: " · "))
            } else if t.tools.count > 1 {
                // A work line's preview is what its steps did, when there is more than one ("Ran 2 commands, delegated 1 task").
                let summary = ChatRunSummary.summarize(t.tools, live: false)
                row.preview = counted(line.title.hasPrefix(summary) ? (line.meta ?? "") : summary)
            }
        case .notice:
            row.notice = true
        case .activity(.changedFiles(let c)):
            // [files] Its names are the preview; opened, a row per file.
            row.files = c.files
            row.preview = c.files.map(\.name).joined(separator: ", ")
        case .bubble(let b):
            // [exchange] The bot's reply: its words open formatted, as an update's do; Copy and Read Aloud read them.
            let words = SpacedText.repair(b.text)
            row.full = words
            row.preview = preview(words)
            row.result = BackgroundResultRow(title: item.title, result: words, process: false, expanded: false)
        default:
            break
        }
        var h = Hasher()
        RowHash.add(row.title, to: &h)
        RowHash.add(row.full, to: &h)
        RowHash.add(row.preview, to: &h)
        h.combine(row.mark)
        h.combine(row.time)
        h.combine(row.day)
        for call in row.steps { h.combine(call.id); h.combine(call.state); RowHash.add(call.title, to: &h) }
        RowHash.add(row.thought ?? "", to: &h)
        h.combine(row.files)
        var variant = Hasher()
        variant.combine(expanded)
        variant.combine(first)
        variant.combine(last)
        // The member's own message: its steps' details and Read Aloud are found by it.
        return ChatRow(id: id, messageId: m.id, scope: input.scope, fingerprint: h.finalize(), kind: .updateMember(row),
                       gapAbove: first ? 4 : 0, variant: variant.finalize())
    }

    /// A member's words as one paragraph for its two-line preview: no Markdown marks or link addresses. A process's
    /// echoed command ("> npm test") is left out, its output leads; a line that ends without a stop is set off from the
    /// next by a dash ("Check the flaky upload test — The upload test waits …"), not run into it.
    static func preview(_ text: String, process: Bool = false) -> String {
        let plain = BackgroundResults.linkWords(BackgroundResults.readable(String(text.prefix(1_200))))
        var lines = plain.components(separatedBy: .newlines)
            .map { ChatText.trimmed($0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)) }
            .filter { !$0.isEmpty }
        if process, lines.contains(where: { !$0.hasPrefix(">") }) { lines.removeAll { $0.hasPrefix(">") } }
        var out = ""
        for line in lines {
            if let last = out.last { out += ".!?:;,…".contains(last) || line.hasPrefix("•") ? " " : " — " }
            out += line
        }
        return out
    }

    /// A run of one: its own row drawn as the centred line (a lone note stays the plain note it is).
    private static func alone(_ original: ChatRow) -> ChatRow {
        var kind = original.kind
        var h = Hasher()
        h.combine(original.fingerprint)
        switch original.kind {
        case .backgroundResult(let b):
            let line = alone(b, expanded: b.expanded)
            kind = .backgroundResult(line)
            h.combine(line.group)
        case .toolRun(var t):
            // A reply's work line: its glyph before its words, centred; it opens on its steps (one opens its sheet).
            guard let line = t.line else { return original }
            t.group = UpdatesGroup(marks: [.glyph(line.glyph)], tail: nil, count: 1, opens: !t.tools.isEmpty || line.thought != nil)
            kind = .toolRun(t)
            h.combine(t.group)
        default:
            return original
        }
        return ChatRow(id: original.id, messageId: original.messageId, scope: original.scope, fingerprint: h.finalize(), kind: kind,
                       gapAbove: original.gapAbove, variant: original.variant)
    }

    /// A line of its own as a run of one draws it: centred, the words before its colon, its face or glyph before them.
    static func alone(_ b: BackgroundResultRow, marks: [UpdatesGroup.Mark]? = nil, expanded: Bool) -> BackgroundResultRow {
        var row = b
        let (words, rest) = BackgroundResults.split(b.title)
        row.title = short(words) + (rest.isEmpty ? "" : ": " + rest)
        let opens = !BackgroundResults.opened(title: row.title, result: row.result).isEmpty
        row.expanded = expanded && opens
        row.group = UpdatesGroup(marks: marks ?? [b.face.map { .face($0) } ?? .glyph(b.glyph)], tail: nil, count: 1, opens: opens,
                                 titles: [short(words)])
        return row
    }

    /// A short line reads as a note between messages, not a row across the chat: its words stop at about 44 letters.
    private static func short(_ title: String) -> String {
        let t = ChatText.trimmed(title)
        guard t.count > 44 else { return t }
        var cut = String(t.prefix(43))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 24 { cut = String(cut[..<space]) }
        return cut.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }
}

nonisolated extension BackgroundResultRow {
    /// The line's glyph when it has no face.
    var glyph: ChatGlyph { cron ? .clock : delivery ? .message : aside ? .aside : note ? .note : process ? .terminal : .subagent }
}
