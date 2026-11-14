import UIKit

// The chat's display rows: messages flattened into bubbles, tool rows, thought rows, day separators, notices and
// marks (spec 03 §10, spec 06 §2–§3). Pure value types built from `ChatMessage`s on any thread.

nonisolated struct ChatRow: @unchecked Sendable {
    enum Kind {
        case bubble(BubbleRow)
        case toolRun(ToolRunRow)
        case thought(ThoughtRow)
        /// A day separator at this message time; `now` decides "Today" / "Yesterday" (the label is made at layout
        /// time, off the main thread, and its day number is part of the row's fingerprint). [idle] `until`: the last day
        /// of an update group under it that spans days ("Oct 26 – Nov 6").
        case day(Date, now: Date, until: Date? = nil)
        case notice(String)
        /// A finished subagent or background process: one line ("Subagent Task Completed: <goal>") that opens on its
        /// result, as the desktop's BackgroundResult (system-message.tsx).
        case backgroundResult(BackgroundResultRow)
        /// [updates] One member of an opened update group: a row of the card under its line (UpdateGroups.swift).
        case updateMember(UpdateMemberRow)
        case error(ErrorRow)
        /// "Stopped" / "Interrupted" under a reply.
        case caption(String)
        /// "Stopped before <bot> replied"; `retry`: it offers Try Again (`ChatRowBuilder.retryPrompt(forStoppedAt:)`).
        case stoppedEarly(String, retry: Bool)
        /// The waiting capsule before any reply text.
        case waiting(WaitingRow)
        /// Under your bubble, trailing: "Delivery Unconfirmed · Check" (a button) / "Checking Delivery…" (spec 06 §5.6.4).
        case sendState(SendStateRow)
        /// The action row under the latest settled reply: Copy (spec 06 §2.5, M1).
        case actions(ActionsRow)
        /// [questions] The approval card, the clarify note and the settled Q&A (App/Questions/PromptRows.swift).
        case prompt(PromptRow)
        /// MENUS (spec 1x §8.4): a slash command's output row — its command and what it answered.
        case slashOutput(command: String, output: String)
        /// [activity] Tool bubbles, the delegate card, the generated image (docs/spec/1x-activity.md §10.2, §11).
        case activity(ActivityRowKind)
        /// Tapback badges under a message's last bubble, on its side (ChatGatewayExtras.swift).
        case reactions(ReactionsRow)
    }

    /// Stable across content changes: "<message id>|<what>".
    let id: String
    let messageId: String
    /// The chat the row belongs to ("<account>|<profile>|<stored session>"). Message ids repeat across bots and
    /// gateways ("stored-row-12-assistant" exists in every profile's state.db), so every cache key carries it.
    let scope: String
    /// Hash of this row's own content (its text, tool calls, labels): a finished part keeps its fingerprint while a
    /// later part of the same message streams, so its cached layout and attributed text are reused.
    let fingerprint: Int
    var kind: Kind
    /// Space above this row (to the row drawn above it). Negative pulls a tool row into its neighbour's padding.
    var gapAbove: CGFloat
    /// Hash of everything besides content that changes the row's layout (corners, tail, time, expansion, gap).
    var variant: Int

    var isBubble: Bool { if case .bubble = kind { return true } else { return false } }
}

nonisolated struct BubbleRow {
    var mine: Bool
    var text: String
    /// Bot text is markdown; yours is inline markdown and code fences only (`UserMarkdown`, DECISION 2026-10-26).
    var markdown: Bool
    var partIndex: Int
    var joinsAbove: Bool
    var joinsBelow: Bool
    var tail: Bool
    /// The run's time (formatted "9:14 AM" at layout time), only on the bubble that ends a run.
    var time: Date?
    /// [a11y] Fewer Timestamps leaves your run's last bubble without a drawn time; VoiceOver still reads this one.
    var spokenTime: Date? = nil
    var pending: Bool
    var streaming: Bool
    /// "You" or the bot's name on a message's first bubble (VoiceOver: "Ivy said: …", once per reply); nil after.
    var speaker: String?
    /// Your long message shows in full ("Show More" was tapped); otherwise it clamps at 10 lines (spec 06 §2.1).
    var expanded: Bool = false
    /// Code blocks (by block index) opened past their 120 pt clamp (spec 06 §2.6).
    var openCode: Set<Int> = []
    /// Your voice memo: its header ("Voice Memo") over the transcript, which is `text` (never the MEDIA directive).
    var memoTitle: String? = nil
    /// [attachments] Photos (album at the top) and file rows inside the bubble (docs/spec/1x-attachments.md §7.3).
    var media: [MediaItem] = []
    var files: [FileItem] = []
    /// [attachments] The chat's media context, for a reply's markdown media (`#media:` links, images).
    var mediaContext: MediaContext? = nil
    /// [attachments] Reply pictures the gateway refused (path → their row's words): drawn as file rows.
    var mediaUnavailable: [String: String] = [:]
    /// [attachments] Reply pictures' pixel sizes learnt by loading them (`MessageAttachment.sizeKey` → size).
    var mediaSizes: [String: MediaPixelSize] = [:]
    /// VOICE: your voice memo as an audio message (play, waveform, length, speed, transcript), spec 1x-voice §5.
    var memo: MemoBubbleInfo? = nil
    // [groups] Another sender's bubble (a room member, a delivery; docs/spec/3x-groups.md §7.12): its name on the run's
    // first bubble, its 28 pt face by the last. `byline`: the chat's own bot named once another sender has spoken.
    var sender: ChatSender? = nil
    var showsSenderName = false
    var showsSenderFace = false
    var byline: String? = nil
    /// [transcript] A cron delivery's job, named after its bot on the bubble's name line ("Scout · Morning brief").
    var job: String? = nil
    /// Incoming bubbles of this chat leave the face column free (it has sender-carrying messages).
    var senderInset = false
    /// The chat's own bot, for the face before its byline.
    var bylineSender: ChatSender? = nil
}

nonisolated struct ReactionsRow {
    /// Your message (the badges hug the trailing edge) or the bot's (leading).
    var mine: Bool
    var chips: [ReactionChip]
    /// VoiceOver's words ("Reactions: Heart from you").
    var spoken: String
}

nonisolated struct ActionsRow {
    /// What Copy puts on the pasteboard: the reply's text.
    var copyText: String
    /// [transcript] How long the turn took ("6s", "1m 12s"), at the row's trailing edge; nil when unknown.
    var duration: String? = nil
    /// VoiceOver's words for it ("Took 1 minute 12 seconds").
    var durationSpoken: String? = nil
}

nonisolated struct SendStateRow {
    var text: String
    /// Red, and a button ("Check") — off while the check runs.
    var actionable: Bool
}

nonisolated struct ToolRunRow {
    var tools: [ToolCall]
    /// The run is the live tail of a streaming reply (present tense, pulsing glyph).
    var live: Bool
    var expanded: Bool
    /// Wording, glyph and meta are made at layout time (off the main thread): `ChatRunSummary`.
    /// Tool Call Style › One Line: this row is the whole reply's line ("Worked for 42s · 5 steps").
    var line: OneLineRow? = nil
    /// [updates] The settled line alone between two real rows: drawn centred, as an update group's line.
    var group: UpdatesGroup? = nil
}

/// One Line (Tool Call Style): what a reply did, as one line above its words. Opened, it shows the reply's thought
/// (when reasoning is shown) above every step.
nonisolated struct OneLineRow {
    var title: String
    var glyph: ChatGlyph
    var thought: String?
    /// "5 steps" at the trailing end while it works or when no time is known (the title doesn't say it then).
    var meta: String? = nil
}

nonisolated struct ThoughtRow {
    var text: String
    var title: String
    var live: Bool
    var expanded: Bool
}

nonisolated struct BackgroundResultRow {
    var title: String
    var result: String
    /// A background process (terminal glyph) rather than a subagent.
    var process: Bool
    var expanded: Bool
    /// [groups] A message another bot delivered into this chat (message glyph); `result` is its whole text.
    var delivery = false
    /// [transcript] A cron run's report (clock glyph); `result` is its whole text.
    var cron = false
    /// A /btw answer (a speech bubble with a question mark); a /bg result keeps the subagent's glyph.
    var aside = false
    /// [restated] A note of Hermes's own about the chat, not work that finished (a circled i).
    var note = false
    /// [botdm] The other bot of a bot-to-bot message (its sender, or who this chat's bot wrote to): its face in
    /// place of the glyph.
    var face: ChatSender? = nil
    /// [botdm] This chat's bot wrote to `face` ("To Hermes"), rather than the other bot writing here ("From Hermes").
    var sentTo = false
    /// [updates] The centred line that stands for a run of these (UpdateGroups.swift); nil for a row of its own.
    var group: UpdatesGroup? = nil
}

nonisolated struct ErrorRow {
    var title: String
    var reason: String
    /// The raw error, for Copy Details.
    var details: String
    /// Retry is the card's primary (spec 06 §5.6.1, M1): the newest turn, nothing running, its prompt right above it.
    var retry: Bool = false
    /// [transcript] §6.1: a usage limit or a model that can't start offers "Choose a Model" as the card's button.
    var chooseModel: Bool = false
}

/// [toolnow] Which part of a running reply the thinking row speaks for.
nonisolated enum ToolNowRows {
    /// The reply's newest drawn part is a step or a thought (it isn't writing): the thinking row stays under it.
    static func working(_ m: ChatMessage) -> Bool {
        guard m.role == .assistant else { return false }
        for part in m.parts.reversed() {
            switch part {
            case .text(let t): if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            case .reasoning(let t): if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            case .tool(let call): if !(ChatRunSummary.isSilent(call.name) && call.state != .failed) { return true }
            }
        }
        return false
    }

    /// The thinking row is drawn under `m` (the chat's running reply, a style that shows it).
    static func speaksFor(_ m: ChatMessage, input: ChatRowBuilder.Input) -> Bool {
        input.isRunning && input.messages.last?.id == m.id && working(m) && !ActivityRows.suppressesWaiting(m, input: input)
    }

    /// At the Bottom (owner, 2026-10-28): while the turn runs, the reply draws no One Line row ("Using 2 tools" at the
    /// top of the screen said the step a second time); its line comes once the turn is done. Held for the whole turn,
    /// not only while a step runs, so the line doesn't come and go above words as the reply writes between steps.
    static func holdsLine(_ m: ChatMessage, input: ChatRowBuilder.Input) -> Bool {
        input.activity.style == .bottom && input.isRunning && m.role == .assistant && input.messages.last?.id == m.id
    }

    /// The step the row names: the reply's newest step, running or just finished, until the reply writes. A finished
    /// one stays through the thinking after it (owner, 2026-10-27: the row never showed a step; on the phone 60% of
    /// steps ended in under a second and the thinking between them took ~4 s, so it said "is thinking…" nearly always).
    static func latest(_ m: ChatMessage?) -> ToolCall? {
        guard let m, m.role == .assistant, working(m) else { return nil }
        for part in m.parts.reversed() {
            switch part {
            case .tool(let call) where !ChatRunSummary.isSilent(call.name): return call
            case .tool, .reasoning: continue
            case .text(let t): if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            }
        }
        return nil
    }
}

nonisolated struct WaitingRow {
    /// "Ivy is thinking…" ([thinking] owner, 2026-10-27; was "Waiting for <model>", spec 06 §3.4); the cell adds a timer
    /// as time passes.
    var label: String
    /// What the line says after 60 s with no step running: "Ivy is still working…" once the turn has run steps, else
    /// "Ivy is still thinking…" (owner, 2026-10-29: "No reply yet" read as if the turn had failed). Nil keeps `label`.
    var longLabel: String? = nil
    /// When this turn started waiting (first seen), for the timer.
    var since: Date
    /// [groups] A room's typing row: the member's face beside the capsule, the label as it is (no timer words).
    var sender: ChatSender? = nil
    var plain = false
    /// [thinking] The chat's own bot: its small face leads the typing dots (not in a room's typing row).
    var bot: ChatSender? = nil
    /// [toolnow] The label names the step that runs ("Ivy is running npm test…"): a long one never turns into
    /// `longLabel`.
    var doing = false
    /// The turn has steps: a tap opens them all in the Steps sheet (owner, 2026-10-29: the row wasn't clickable).
    var opensSteps = false
}

/// [groups] What a room adds to the rows (docs/spec/3x-groups.md §7.13): typing rows and the state under your sends.
nonisolated struct RoomRowsInput: Sendable {
    var typing: [RoomTyping] = []
    /// Message id → the last failure's reason.
    var undelivered: [String: String] = [:]
    var retrying: Set<String> = []
}

/// Content hashes for row fingerprints. Hashing the UTF-8 bytes is much cheaper than `String.hash`, which normalises.
nonisolated enum RowHash {
    static func add(_ text: String, to hasher: inout Hasher) {
        var text = text
        hasher.combine(text.utf8.count)
        text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }

    /// Big strings that only grow or get replaced (tool arguments, which can hold a whole file): the length and both
    /// ends, so a 200 KB argument costs the same as a short one on every streamed update.
    static func addSampled(_ text: String, to hasher: inout Hasher) {
        guard text.utf8.count > 4096 else { add(text, to: &hasher); return }
        var text = text
        hasher.combine(text.utf8.count)
        text.withUTF8 { buffer in
            hasher.combine(bytes: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: buffer.prefix(1024))))
            hasher.combine(bytes: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: buffer.suffix(1024))))
        }
    }

    static func of(_ parts: String...) -> Int {
        var hasher = Hasher()
        for part in parts { add(part, to: &hasher) }
        return hasher.finalize()
    }
}

/// When each waiting turn was first seen (the web's `createTurnAnnouncements`), so the wait timer survives row rebuilds.
nonisolated enum TurnClock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var starts: [String: Date] = [:]

    static func start(_ turn: String, now: Date = Date()) -> Date {
        lock.lock(); defer { lock.unlock() }
        if let known = starts[turn] { return known }
        if starts.count > 256 { starts.removeAll() }
        starts[turn] = now
        return now
    }
}

nonisolated enum ChatRowBuilder {
    struct Input {
        var messages: [ChatMessage]
        var isRunning: Bool
        var botName: String
        /// [external-turn] Another Hermes process runs this turn (`isRunning` is set too): the newest reply's step line
        /// reads in the present tense, as a streaming reply's does, though its rows come from the stored transcript.
        var externalWorking = false
        var expanded: Set<String>
        var now: Date = Date()
        /// The chat's cache scope (see `ChatRow.scope`).
        var scope: String = ""
        /// The model answering; nil when unknown. ([thinking] The waiting row names the bot now, not the model.)
        var modelName: String? = nil
        /// [questions] The chat's open requests as rows (spec 1x §4.2, §4.4); nil = none.
        var prompts: PromptRowsInput? = nil
        /// [attachments] Per-message photos/files and generated images, snapshotted with the messages.
        var media: ChatMediaSnapshot = .empty
        /// [activity] Tool Call Style, After Reply › Hide, reasoning flags and timing, live subagents (ActivityRows.swift).
        var activity = ActivityRowsInput()
        /// Fewer Timestamps: day lines only at a date change, times only under the bot's replies.
        var fewerTimes = false
        /// [groups] Set for a room: typing rows, "Not Delivered".
        var room: RoomRowsInput? = nil
        /// The chat's own bot as a sender, for the face before its name when other senders have spoken.
        var ownFace: ChatSender? = nil
        /// [transcript] Seconds the turn took, by the id of the reply it ended in (§6.6); only turns this device saw run.
        var turnSeconds: [String: Double] = [:]
        /// What a finished subagent / background process reported, by the id of its timeline note.
        var backgroundResults: [String: String] = [:]
        /// [botdm] The bots a `message_agent` call can name (`DeliveryRoster.seats`).
        var bots: [DeliveryMessages.Seat] = []
        /// [transcript] An edit tool's diff, by its call id (`ChatToolDetails.inlineDiff`; §12, n20 F10): the files
        /// card and a landed edit's inline preview both read these, not `ToolDiffStore`, which nothing here does.
        var diffs: [String: String] = [:]
        /// [drafts] The chat's draft cards: which are answered, your edits, the one being edited (PromptRows.draftRow).
        var drafts = DraftRowsInput()

        var speakerName: String {
            let name = botName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? "Hermes" : name
        }
    }

    /// Rows for every message, oldest first.
    static func build(_ input: Input) -> [ChatRow] {
        build(input, range: 0..<input.messages.count)
    }

    /// Rows for `messages[range]`, oldest first (plus the waiting capsule when the range reaches the newest message).
    /// One message on each side is read as context (runs, tails, day separators, gaps), so a region can be rebuilt
    /// without touching the rows around it.
    static func build(_ input: Input, range: Range<Int>) -> [ChatRow] {
        let messages = input.messages
        let lower = max(0, min(range.lowerBound, messages.count))
        let upper = max(lower, min(range.upperBound, messages.count))
        // The context reaches back past messages that draw nothing (a silent reply to a delivery): the gap rules read
        // the row above, and a rebuild from the message after one must still see it.
        // [updates] Each message's own rows are made once per build: the runs, their lines and the rows below read them.
        let made = UpdateGroups.Rows(input)
        var contextStart = max(0, lower - 1)
        for _ in 0..<8 where contextStart > 0 && contextStart < lower {
            guard made.at(contextStart).isEmpty else { break }
            contextStart -= 1
        }
        let contextEnd = min(messages.count, upper + 1)
        // [updates] Runs of small rows between real rows: one centred line each. The context reaches back to the start of
        // a run it is in, so the row above the range is the one a full build draws there (its line, not nothing).
        let groups = UpdateGroups.plan(input, range: contextStart..<contextEnd, rows: made)
        if contextStart < lower, let first = made.at(contextStart).indices.first,
           let run = groups.group(UpdateGroups.Member(message: contextStart, row: first)) {
            contextStart = min(contextStart, run.head.message)
        }
        var rows: [ChatRow] = []
        var owners: [Int] = []          // message index per row (-1 = waiting)
        rows.reserveCapacity((contextEnd - contextStart) * 2 + 1)
        var lastTimed: Date? = nil
        // The last timed message before the context start (for the day separator rule).
        var scan = contextStart - 1
        while scan >= 0, scan >= contextStart - 64 {
            if let t = messages[scan].timestamp, !made.at(scan).isEmpty { lastTimed = t; break }
            scan -= 1
        }
        let today = LocalDay.number(input.now)
        // [idle] A run that spans day lines draws none inside it; the one over it, when it leads its message, names the
        // run's first and last days.
        var insideRun = Set<Int>()
        var runDays: [Int: Date] = [:]
        for g in groups.groups where g.span.count > 1 {
            insideRun.formUnion(g.span.dropFirst())
            if g.head.row == 0, let days = UpdateGroups.days(g, input: input) { runDays[g.head.message] = days.last }
        }
        for index in contextStart..<contextEnd {
            let m = messages[index]
            let before = rows.count
            // A message that draws nothing draws no day line, and the next one is measured from the one before it.
            if let t = m.timestamp, !made.at(index).isEmpty {
                // [idle] A run over days names them even where its first day is the last message's (Fewer Timestamps).
                let until = runDays[index]
                if needsDayBreak(previous: lastTimed, current: t, datesOnly: input.fewerTimes) || until != nil,
                   !insideRun.contains(index) {
                    var h = Hasher()
                    h.combine(t.timeIntervalSince1970)
                    h.combine(today)
                    h.combine(until)
                    rows.append(ChatRow(id: "\(m.id)|day", messageId: m.id, scope: input.scope, fingerprint: h.finalize(),
                                        kind: .day(t, now: input.now, until: until), gapAbove: rows.isEmpty ? 0 : ChatMetrics.turnGap,
                                        variant: 0))
                }
                lastTimed = t
            }
            for (r, row) in made.at(index).enumerated() {
                let here = UpdateGroups.Member(message: index, row: r)
                guard let group = groups.group(here) else { rows.append(row); continue }
                // [updates] The run's first small row draws its line (and, opened, its card's rows); the others draw there.
                if group.head == here { rows += UpdateGroups.rows(group, input: input, rows: made) }
            }
            owners.append(contentsOf: Array(repeating: index, count: rows.count - before))
        }
        // Waiting capsule: the turn runs and nothing of the reply is visible yet. [questions] Not while the turn waits on
        // the user (an open question or approval): the header says "Waiting for your reply" (verify round 1: a reopened
        // chat showed "Waiting for <model>" over the question card).
        let waitsOnUser: Bool = {
            guard let prompts = input.prompts else { return false }
            if prompts.approval != nil { return true }
            switch prompts.clarifyNote {
            case .asked?, .undelivered?: return true
            default: return false
            }
        }()
        if upper == messages.count, input.isRunning, !waitsOnUser, let last = messages.last {
            let replyVisible = last.role == .assistant && rows.last?.messageId == last.id
            // [activity] In Header (and tool progress off) draw no steps: the status line says what runs (§10.4).
            // [toolnow] It stays under a reply that is still working (a step runs, or it thinks between steps), and names
            // the newest step; it goes once the reply is writing.
            if last.role == .user || (last.role == .assistant && (!replyVisible || ToolNowRows.working(last))
                                      && !ActivityRows.suppressesWaiting(last, input: input)) {
                rows.append(waitingRow(input: input))
                owners.append(-1)
            }
        }
        // [groups] A room's typing rows: one per member answering now, at the newest end.
        let typing = upper == messages.count ? (input.room?.typing ?? []) : []
        for (n, who) in typing.enumerated() {
            var hasher = Hasher()
            hasher.combine(who)
            let since = TurnClock.start("room-typing|\(input.scope)|\(who.sender?.key ?? "")")
            rows.append(ChatRow(id: "typing|\(who.sender?.key ?? String(n))", messageId: "waiting", scope: input.scope,
                                fingerprint: hasher.finalize(),
                                kind: .waiting(WaitingRow(label: who.label, since: since, sender: who.sender, plain: true)),
                                gapAbove: ChatMetrics.turnGap, variant: 0))
            owners.append(-1)
        }
        if upper == lower && !(upper == messages.count && (input.isRunning || !typing.isEmpty)) { return [] }
        applyRunsAndGaps(&rows, messages: messages, from: contextStart, ownName: input.speakerName,
                         ownFace: input.ownFace, fewerTimes: input.fewerTimes)
        // [updates] No action row under the newest reply any more (owner, 2026-10-27): Copy is in its hold menu and the
        // time is on its Worked line.
        // [questions] The approval card (and a question note with no running part) at the newest end.
        if upper == messages.count {
            for row in PromptRows.tail(input) {
                rows.append(row)
                owners.append(-1)
            }
        }
        var out: [ChatRow] = []
        out.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() where (owners[i] >= lower && owners[i] < upper) || (owners[i] == -1) {
            out.append(row)
        }
        return out
    }

    private static func waitingRow(input: Input) -> ChatRow {
        let turn = input.messages.last(where: { $0.role == .user })?.id ?? input.messages.first?.id ?? "pending"
        // [thinking] The bot by name, not the model (owner, 2026-10-27: "Waiting for <model>" said nothing useful).
        // [toolnow] The newest step, in a few words ("Ivy is reading package.json…"), else "is thinking…" (before the first).
        let call = ToolNowRows.latest(input.messages.last)
        let step = call.map { call in
            // A message to another bot names it as the roster does ("messaging Ivy", not its handle).
            guard call.name == BotDMs.tool, let target = ToolArgs.parse(call.argsText)["target"]?.string else { return ToolNow.phrase(call) }
            return "messaging " + ToolNow.short(BotDMs.sender(target, roster: input.bots).name)
        }
        let label = ActivityRows.waitingLabel("\(input.speakerName) is \(step ?? "thinking")…", input: input)   // [activity] §8.2
        // No face on it (owner, 2026-10-27): the typing dots and the words only.
        var row = WaitingRow(label: label, since: TurnClock.start(turn))
        // Only a running step keeps its own words past 60 s; a finished one held through a long think doesn't.
        row.doing = call?.state == .running
        let turnStart = (input.messages.lastIndex(where: { $0.role == .user }) ?? -1) + 1
        row.opensSteps = input.messages[turnStart...].contains { m in
            m.role == .assistant && m.parts.contains { if case .tool(let c) = $0 { return !ChatRunSummary.isSilent(c.name) } else { return false } }
        }
        // A provider's own wait line ("Retrying in 8s…") stays as it is.
        if input.activity.providerWait?.isEmpty ?? true {
            row.longLabel = "\(input.speakerName) is still \(call == nil ? "thinking" : "working")…"
        }
        return ChatRow(id: "waiting", messageId: "waiting", scope: input.scope,
                       fingerprint: RowHash.of(label + "|" + (row.longLabel ?? "") + (row.opensSteps ? "|steps" : "")),
                       kind: .waiting(row), gapAbove: ChatMetrics.turnGap, variant: 0)
    }

    // MARK: Per message

    static func appendRows(for m: ChatMessage, at index: Int, input: Input, into rows: inout [ChatRow]) {
        switch m.role {
        case .system:
            let text = m.parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // MENUS (spec 1x §8.4): slash output rows draw as their own kind.
            if SlashOutputRow.isSlashRow(m), let slash = SlashOutputRow.parse(text) {
                rows.append(ChatRow(id: "\(m.id)|slash", messageId: m.id, scope: input.scope, fingerprint: RowHash.of(text),
                                    kind: .slashOutput(command: slash.command, output: slash.output), gapAbove: ChatMetrics.turnGap,
                                    variant: 0))
                return
            }
            // /btw and /bg results (SideTasks.swift): one line that opens on the answer, as a finished subagent's, its
            // Markdown drawn as the reply's (Mac polish #25: the bold and code were dropped).
            if SideTaskRow.isSideRow(m), let side = SideTaskRow.parse(text) {
                let id = "\(m.id)|bg"
                let expanded = input.expanded.contains(id)
                var h = Hasher()
                RowHash.add(text, to: &h)
                h.combine(expanded)
                var row = BackgroundResultRow(title: side.title, result: BackgroundResults.clipped(side.result), process: false,
                                              expanded: expanded)
                row.aside = side.kind == .btw
                rows.append(ChatRow(id: id, messageId: m.id, scope: input.scope, fingerprint: h.finalize(), kind: .backgroundResult(row),
                                    gapAbove: ChatMetrics.turnGap, variant: expanded ? 1 : 0))
                return
            }
            let stored = input.backgroundResults[m.id]
            if !text.isEmpty, let result = stored ?? m.report.map(BackgroundResults.log) {
                let id = "\(m.id)|bg"
                let expanded = input.expanded.contains(id)
                var h = Hasher()
                RowHash.add(text, to: &h)
                RowHash.add(result, to: &h)
                h.combine(expanded)
                var row = BackgroundResultRow(title: BackgroundResults.plainTitle(text), result: result,
                                              process: BackgroundResults.isProcess(text), expanded: expanded)
                row.note = text == TimelineNotes.restatedTitle
                // [updates] Another bot's message filed as an update: the line names the bot, the card opens on its words.
                if let bot = BackgroundResults.fromBot(result) {
                    // [botdm] With that bot's face and roster name, as a delivery's line.
                    let sender = DeliverySender.parse(result).map { DeliveryMessages.sender(for: $0, roster: input.bots) }
                    // "From Hermes", as a delivery's line reads (owner, 2026-10-28: "to that bot or from that bot").
                    row.title = "From " + BackgroundResults.botName(sender?.name ?? bot.name)
                    row.result = bot.body
                    row.delivery = true
                    row.face = sender
                    h.combine(sender)
                }
                rows.append(ChatRow(id: id, messageId: m.id, scope: input.scope, fingerprint: h.finalize(), kind: .backgroundResult(row),
                                    gapAbove: ChatMetrics.turnGap, variant: expanded ? 1 : 0))
                return
            }
            // A silent run says nothing, and a turn Hermes picked up again after a restart needs no note ([updates] owner,
            // 2026-10-27; was: only a silent run that didn't answer you, 2026-10-18).
            if text.hasSuffix(Hydration.silentRunText) || text == Hydration.autoContinueText { return }   // "<job>: Nothing to report…" too
            if !text.isEmpty {
                rows.append(ChatRow(id: "\(m.id)|notice", messageId: m.id, scope: input.scope, fingerprint: RowHash.of(text),
                                    kind: .notice(text), gapAbove: ChatMetrics.turnGap, variant: 0))
            }
        case .user:
            let text = m.parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
            let attachments = input.media.attachments[m.id] ?? []                                     // [attachments]
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && m.parts.isEmpty && attachments.isEmpty { return }
            if let sender = m.sender, m.job == nil {
                // [groups] A delivery from another bot (§7.12): one line, "From Inbox: <its words>", that opens on the
                // whole message, as a finished subagent's row. Drawn as bubbles they filled the chat (owner, 2026-10-18).
                // [updates] "From": the line names the direction, as "To Hermes" does (owner, 2026-10-28).
                let id = "\(m.id)|dl"
                let expanded = input.expanded.contains(id)
                let title = DeliveryRows.title(sender: "From " + BackgroundResults.botName(sender.name), text: text)
                var h = Hasher()
                RowHash.add(title, to: &h)
                RowHash.add(text, to: &h)
                h.combine(expanded)
                h.combine(sender)
                var row = BackgroundResultRow(title: title, result: BackgroundResults.readable(text), process: false, expanded: expanded)
                row.delivery = true
                row.face = sender                                                                        // [botdm]
                rows.append(ChatRow(id: id, messageId: m.id, scope: input.scope, fingerprint: h.finalize(),
                                    kind: .backgroundResult(row), gapAbove: ChatMetrics.turnGap, variant: expanded ? 1 : 0))
                return
            }
            if m.job != nil, text.hasSuffix(Hydration.silentRunText) { return }   // [updates] a silent scheduled run
            if let sender = m.sender, let job = m.job {
                // [transcript] A cron run: one line, "Inbox watch: 1 new inbound email", that opens on the whole report,
                // as a delivery's row. Drawn as a bubble its report filled the chat (owner, 2026-10-23).
                let id = "\(m.id)|cr"
                let expanded = input.expanded.contains(id)
                let title = DeliveryRows.title(sender: CronDeliveries.jobName(job, bot: sender.name),
                                               text: CronDeliveries.withoutJobLead(text, job: job))
                var h = Hasher()
                RowHash.add(title, to: &h)
                RowHash.add(text, to: &h)
                h.combine(expanded)
                var row = BackgroundResultRow(title: title, result: BackgroundResults.readable(text), process: false, expanded: expanded)
                row.cron = true
                rows.append(ChatRow(id: id, messageId: m.id, scope: input.scope, fingerprint: h.finalize(),
                                    kind: .backgroundResult(row), gapAbove: ChatMetrics.turnGap, variant: expanded ? 1 : 0))
                return
            }
            if !attachments.isEmpty {
                rows.append(ChatMediaRows.userBubble(m, text: text, attachments: attachments, input: input))   // [attachments]
            } else if let memo = VoiceMemo.parse(text) {
                // A voice memo: an audio message with its transcript in your bubble (VOICE, spec 1x-voice §5), anything
                // typed with it as the next bubble.
                let memoId = "\(m.id)|b0"
                let info = MemoBubbleInfo.make(memo, pending: m.isPending, failed: m.error != nil,
                                               open: input.expanded.contains(memoId))
                var bubble = BubbleRow(mine: true, text: info.wordsText, markdown: false, partIndex: 0, joinsAbove: false,
                                       joinsBelow: false, tail: false, time: nil, pending: m.isPending, streaming: false,
                                       speaker: "You", expanded: true)
                bubble.memo = info
                var hasher = Hasher()
                hasher.combine(bubbleFingerprint(bubble.text, mine: true, speaker: "You"))
                hasher.combine(info)
                rows.append(ChatRow(id: memoId, messageId: m.id, scope: input.scope, fingerprint: hasher.finalize(),
                                    kind: .bubble(bubble), gapAbove: ChatMetrics.turnGap, variant: 0))
                if !memo.rest.isEmpty {
                    let id = "\(m.id)|b1"
                    rows.append(ChatRow(id: id, messageId: m.id, scope: input.scope,
                                        fingerprint: bubbleFingerprint(memo.rest, mine: true, speaker: nil),
                                        kind: .bubble(BubbleRow(mine: true, text: memo.rest, markdown: true, partIndex: 1,
                                                                joinsAbove: false, joinsBelow: false, tail: false, time: nil,
                                                                pending: m.isPending, streaming: false, speaker: nil,
                                                                expanded: input.expanded.contains(id))),
                                        gapAbove: ChatMetrics.turnGap, variant: 0))
                }
            } else {
                let id = "\(m.id)|b0"
                // [drafts] Your answer to a draft card reads "Send it": the card above shows the words that went.
                let text = DraftCards.bubbleWords(text) ?? text
                rows.append(ChatRow(id: id, messageId: m.id, scope: input.scope, fingerprint: bubbleFingerprint(text, mine: true, speaker: "You"),
                                    kind: .bubble(BubbleRow(mine: true, text: text, markdown: true, partIndex: 0, joinsAbove: false,
                                                            joinsBelow: false, tail: false, time: nil, pending: m.isPending,
                                                            streaming: false, speaker: "You",
                                                            expanded: input.expanded.contains(id))),
                                    gapAbove: ChatMetrics.turnGap, variant: 0))
            }
            appendReactions(m, mine: true, input: input, into: &rows)
            if let room = input.room, room.undelivered[m.id] != nil || room.retrying.contains(m.id) {
                // [groups] No member took this send (§7.13): "Not Delivered" and Try Again, "Sending…" while it is retried.
                let trying = room.retrying.contains(m.id)
                let words = trying ? "Sending…" : "Not Delivered · Try Again"
                rows.append(ChatRow(id: "\(m.id)|send", messageId: m.id, scope: input.scope, fingerprint: RowHash.of(words),
                                    kind: .sendState(SendStateRow(text: words, actionable: !trying)), gapAbove: 2, variant: 0))
            } else if m.error != nil {
                // The send may not have reached the gateway (spec 04 §2.5): say so under the bubble, with a read-only Check.
                let checking = input.expanded.contains(ChatRowBuilder.checkingKey(m.id))
                let words = checking ? "Checking Delivery…" : "Delivery Unconfirmed · Check"
                rows.append(ChatRow(id: "\(m.id)|send", messageId: m.id, scope: input.scope, fingerprint: RowHash.of(words),
                                    kind: .sendState(SendStateRow(text: words, actionable: !checking)), gapAbove: 2, variant: 0))
            } else if m.isPending, let sent = m.timestamp, input.now.timeIntervalSince(sent) >= ChatRowBuilder.sendingDelay {
                // Nothing for the first 2 s of a send, then "Sending…" (spec 06 §5.6.4, `SENDING_DELAY`).
                let words = "Sending…"
                rows.append(ChatRow(id: "\(m.id)|send", messageId: m.id, scope: input.scope, fingerprint: RowHash.of(words),
                                    kind: .sendState(SendStateRow(text: words, actionable: false)), gapAbove: 2, variant: 0))
            }
        case .assistant:
            appendAssistant(m, at: index, input: input, into: &rows)
        }
    }

    /// The message's Tapback badges, when it has any (shown whether or not Message Reactions is on).
    private static func appendReactions(_ m: ChatMessage, mine: Bool, input: Input, into rows: inout [ChatRow]) {
        guard !m.reactions.isEmpty else { return }
        let chips = MessageReactions.chips(m.reactions)
        let row = ReactionsRow(mine: mine, chips: chips, spoken: MessageReactions.spoken(m.reactions, bot: input.speakerName))
        var h = Hasher()
        h.combine(mine)
        h.combine(chips)
        rows.append(ChatRow(id: "\(m.id)|react", messageId: m.id, scope: input.scope, fingerprint: h.finalize(),
                            kind: .reactions(row), gapAbove: 2, variant: 0))
    }

    /// A silent run's "Nothing to report" line shows only when the run answers something you sent (the message before
    /// it is yours). After anything else (another bot's message, a scheduled job's card, a subagent's or background
    /// process's result) the bot is quietly taking note, and the line is left out (owner, 2026-10-18 and 2026-10-19).
    static func answersANote(at index: Int, input: Input) -> Bool {
        guard index > 0, index - 1 < input.messages.count else { return true }
        let before = input.messages[index - 1]
        return !(before.role == .user && before.sender == nil)
    }

    /// A bubble's content: its text, side and speaker (the speaker only feeds VoiceOver, but a renamed bot must
    /// reach the cell).
    static func bubbleFingerprint(_ text: String, mine: Bool, speaker: String?, unavailable: [String: String] = [:],
                                  sizes: [String: MediaPixelSize] = [:]) -> Int {
        var hasher = Hasher()
        RowHash.add(text, to: &hasher)
        hasher.combine(mine)
        hasher.combine(speaker)
        // [attachments] only the refused paths this text names re-measure it
        for path in unavailable.keys.sorted() where text.contains(MediaTags.displayName(path)) { hasher.combine(path) }
        // [attachments] and the message's pictures' learnt sizes
        for key in sizes.keys.sorted() { hasher.combine(key); hasher.combine(sizes[key]) }
        return hasher.finalize()
    }

    /// The opened code blocks of one bubble ("<row id>#c<block index>" entries of the expanded set).
    private static func openCode(_ rowId: String, _ expanded: Set<String>) -> Set<Int> {
        guard !expanded.isEmpty else { return [] }
        var out: Set<Int> = []
        let prefix = rowId + "#c"
        for entry in expanded where entry.hasPrefix(prefix) {
            if let i = Int(entry.dropFirst(prefix.count)) { out.insert(i) }
        }
        return out
    }

    private static func appendAssistant(_ m: ChatMessage, at index: Int, input: Input, into rows: inout [ChatRow]) {
        let before = rows.count
        var run: [ToolCall] = []
        var runStart = 0
        var spoke = false
        /// A real step (one the bot went off to do, drawn, folded or hidden) since the last words: the next words are a
        /// new message, as on Telegram (kwojt 2026-11-14: a long turn's progress notes read as one long bubble).
        var workedSinceWords = false
        // [transcript] Every edit call this reply made, however its step draws (or doesn't): the files card reads
        // these once the reply has settled, regardless of Tool Call Style or After Reply › Hide (§12, n20 F10).
        var editCalls: [(call: ToolCall, args: [String: JSONValue], diff: String?)] = []
        // [tasks] Its `tasks_add` (and `tasks_update`) calls: "Added to Tasks" under the settled reply, however its steps draw.
        var addedTasks: [ToolCall] = []
        // Index of the last part that draws something (a tool run is live only while it is the message's tail).
        let lastVisiblePart = m.parts.lastIndex(where: { part in
            switch part {
            case .text(let t): return !ReasoningTags.isBlank(t)
            case .reasoning(let t): return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .tool(let call): return !(ChatRunSummary.isSilent(call.name) && call.state != .failed)
            }
        }) ?? -1

        // [activity] Which step blocks this reply draws (In Header, After Reply › Hide; docs/spec/1x-activity.md §10).
        let stepsHidden = ActivityRows.stepsHidden(m, at: index, input: input)
        // One Line: the reply's steps and thoughts gather here and draw as one line above its first row.
        let oneLine = ToolCallSettings.folds(input.activity.style)
        var folded: [ToolCall] = []
        /// [updates] One Line: the subagents of the reply's delegate cards, said on its line instead of a card each.
        var helpers: [ToolCards.DelegateRow] = []
        var thoughts: [String] = []
        var firstThought: Int?

        // [transcript] Under a landed edit's own row (Rows, Bubbles only — One Line/At the Bottom have no such row:
        // §12 DECISION): its first changed lines, straight after the row they belong to.
        func appendEditPreview(_ run: [ToolCall]) {
            guard run.count == 1, let call = run.first, call.state == .done, ChangedFiles.isEditTool(call.name),
                  let diff = input.diffs[call.id], !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let path = ChangedFiles.path(args: ToolArgs.parse(call.argsText), diff: diff) else { return }
            if let preview = ActivityRows.diffPreviewRow(call, path: path, diff: diff, message: m, input: input) { rows.append(preview) }
        }

        func flushRun(endingAt end: Int) {
            guard !run.isEmpty else { return }
            if oneLine && !run.contains(where: { $0.name == "clarify" }) {   // clarify stays its own row (§11.4)
                folded += run
                run = []
                return
            }
            let live = m.isStreaming && end >= lastVisiblePart
            let id = "\(m.id)|t\(run[0].id.isEmpty ? String(runStart) : run[0].id)"
            if ActivityRows.bubbles(run, input: input) {        // [activity] Bubbles: the run as a tool bubble
                rows.append(ActivityRows.toolBubbleRow(id: "\(m.id)|tb\(run[0].id.isEmpty ? String(runStart) : run[0].id)",
                                                       message: m, tools: run, input: input))
                appendEditPreview(run)
                run = []
                return
            }
            rows.append(toolRow(id: id, message: m, tools: run, live: live, expanded: input.expanded.contains(id), scope: input.scope))
            appendEditPreview(run)
            run = []
        }

        for (i, part) in m.parts.enumerated() {
            switch part {
            case .text(let raw):
                // [attachments] a generated image's path repeated in the prose shows once (docs/spec/1x-attachments.md §7.7)
                let text = ChatMediaRows.droppingEchoes(raw, generated: input.media.generated[m.id])
                // Silent: runs chain over it. Words that are only hidden thinking (`<think>…</think>`) draw nothing either.
                if ReasoningTags.isBlank(text) { continue }
                flushRun(endingAt: i - 1)
                // Words with only silent things between them (a to-do update, hidden thinking) are one bubble: the reply
                // reads as one message, not a stack of fragments. Words the bot wrote before going back to work (a
                // progress note, then steps) are their own bubble, in every style, stacked tight with the next.
                defer { workedSinceWords = false }
                if !workedSinceWords, let last = rows.indices.last, last >= before, rows[last].messageId == m.id,
                   case .bubble(var joined) = rows[last].kind, !joined.mine, joined.memo == nil,
                   joined.media.isEmpty {                     // a picture card isn't words: they get their own bubble
                    joined.text += "\n\n" + text
                    joined.streaming = m.isStreaming
                    let prior = rows[last]
                    rows[last] = ChatRow(id: prior.id, messageId: m.id, scope: input.scope,
                                         fingerprint: bubbleFingerprint(joined.text, mine: false, speaker: joined.speaker,
                                                                        unavailable: input.media.unavailable, sizes: joined.mediaSizes),
                                         kind: .bubble(joined), gapAbove: prior.gapAbove, variant: prior.variant)
                    continue
                }
                let id = "\(m.id)|b\(i)"
                let speaker = spoke ? nil : (m.sender?.name ?? input.speakerName)   // [groups] a member's own name
                var bubble = BubbleRow(mine: false, text: text, markdown: true, partIndex: i,
                                       joinsAbove: false, joinsBelow: false, tail: false, time: nil,
                                       pending: false, streaming: m.isStreaming,
                                       speaker: speaker,
                                       openCode: openCode(id, input.expanded))
                bubble.mediaContext = input.media.context                                                  // [attachments]
                bubble.mediaUnavailable = input.media.unavailable
                bubble.mediaSizes = input.media.replySizes[m.id] ?? [:]
                bubble.sender = m.sender                                                                   // [groups]
                rows.append(ChatRow(id: id, messageId: m.id, scope: input.scope,
                                    fingerprint: bubbleFingerprint(text, mine: false, speaker: speaker, unavailable: input.media.unavailable,
                                                                   sizes: bubble.mediaSizes),
                                    kind: .bubble(bubble),
                                    gapAbove: ChatMetrics.turnGap, variant: 0))
                spoke = true
            case .reasoning(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if !ActivityRows.drawsThought(stepsHidden: stepsHidden, input: input) { continue }     // [activity] §9.4
                if oneLine {
                    thoughts.append(trimmed)
                    if firstThought == nil { firstThought = i }
                    continue
                }
                flushRun(endingAt: i - 1)
                let live = m.isStreaming && i >= lastVisiblePart
                let id = "\(m.id)|r\(i)"
                let expanded = input.expanded.contains(id)
                let title = ActivityRows.thoughtTitle(m, part: i, live: live, input: input)       // [activity] "Thought for 7s"
                var h = Hasher()
                RowHash.add(trimmed, to: &h)
                h.combine(title)
                h.combine(live)
                rows.append(ChatRow(id: id, messageId: m.id, scope: input.scope, fingerprint: h.finalize(),
                                    kind: .thought(ThoughtRow(text: trimmed, title: title, live: live, expanded: expanded)),
                                    gapAbove: ChatMetrics.turnGap, variant: expanded ? 1 : 0))
            case .tool(let call):
                // [transcript] Collected whatever its disposition (the card ignores Tool Call Style and Hide Steps).
                if ChangedFiles.isEditTool(call.name) {
                    editCalls.append((call: call, args: ToolArgs.parse(call.argsText), diff: input.diffs[call.id]))
                }
                if call.name == "tasks_add" || call.name == "tasks_update" { addedTasks.append(call) }
                if call.name == BotDMs.tool, let sent = BotDMRows.sent(m, call: call, part: i, input: input) {
                    flushRun(endingAt: i - 1)                                                              // [botdm]
                    rows.append(sent)
                    continue
                }
                if call.name == "image_generate", let card = ChatMediaRows.generatedRow(m, call: call, input: input) {
                    flushRun(endingAt: i - 1)                                                              // [attachments]
                    // Pictures made one after another, nothing drawn between, are one stack you swipe through.
                    if let last = rows.indices.last, last >= before, let stacked = ChatMediaRows.stacking(card, onto: rows[last]) {
                        rows[last] = stacked
                    } else {
                        rows.append(card)
                    }
                    continue
                }
                // [drafts] A draft for review is its card, whatever Tool Call Style and Hide Steps say.
                if call.name == DraftCards.tool, let card = PromptRows.draftRow(call, message: m, input: input) {
                    flushRun(endingAt: i - 1)
                    rows.append(card)
                    continue
                }
                if ChatRunSummary.isSilent(call.name) && call.state != .failed { continue }
                workedSinceWords = true
                // [questions] A clarify part: the question note while it runs, the settled Q&A once answered.
                if let prompt = PromptRows.clarifyRow(call, message: m, input: input) {
                    flushRun(endingAt: i - 1)
                    rows.append(prompt)
                    continue
                }
                // [activity] Cards drawn in place, hidden steps, `display.tool_progress` off (§10.6, §11).
                switch ActivityRows.disposition(call, in: m, stepsHidden: stepsHidden, input: input) {
                case .skip: continue
                case .card(let card):
                    flushRun(endingAt: i - 1)
                    if oneLine, case .activity(.delegate(let d)) = card.kind {
                        // [updates] No bordered card per subagent: the line says "2 helpers working", then
                        // "Worked for 42s · 2 helpers"; opened, the call is one of its steps (owner, 2026-10-27).
                        folded.append(call)
                        helpers += d.rows
                        continue
                    }
                    rows.append(card)
                    continue
                case .step: break
                }
                if ChatRunSummary.standsAlone(call.name) || ChatRunSummary.isSilent(call.name) {
                    flushRun(endingAt: i - 1)
                    run = [call]; runStart = i
                    flushRun(endingAt: i)
                    continue
                }
                if run.isEmpty { runStart = i }
                run.append(call)
            }
        }
        flushRun(endingAt: m.parts.count - 1)
        // At the Bottom: no line above a reply while its turn runs; the thinking row names its steps (ToolNowRows.holdsLine).
        if oneLine, !folded.isEmpty || !thoughts.isEmpty, !ToolNowRows.holdsLine(m, input: input) {
            rows.insert(oneLineRow(m, steps: folded, thoughts: thoughts, firstThought: firstThought,
                                   lastVisiblePart: lastVisiblePart, input: input, helpers: helpers), at: before)
        }

        if rows.count > before { appendReactions(m, mine: false, input: input, into: &rows) }
        // [transcript] "N files changed", once the reply has settled (§12, n20 F10): after the reactions a message's
        // other rows end in, so it reads as the turn's own last word.
        if let card = ActivityRows.changedFilesRow(m, edits: editCalls, input: input) { rows.append(card) }
        if let card = ActivityRows.tasksAddedRow(m, calls: addedTasks, input: input) { rows.append(card) }   // [tasks]
        let produced = rows.count > before
        let name = input.speakerName
        if let error = m.error, !input.expanded.contains(ChatRowBuilder.dismissedErrorKey(m.id)) {
            var title = "\(name) couldn’t finish this reply"
            var retry = retryPrompt(forErrorAt: index, input: input) != nil
            var chooseModel = false
            var reason = errorReason(error, retry: retry, bot: name)
            // [transcript] A failure the app knows reads in the web's words (usage limit, model can't start, busy
            // gateway, cut-off reply; docs/spec/3x-transcript.md §6.1); no "retry" words on a card without Retry.
            if let known = TurnErrors.copy(error, at: m.timestamp) {
                title = known.title
                switch known.primary {
                case .chooseModel: chooseModel = true; retry = false
                case .newChat: retry = false          // the body names the action; a Retry would fail again
                case .retry: break
                }
                reason = (retry || chooseModel) ? known.body : TurnErrors.withoutRetryWords(known.body)
            }
            var h = Hasher()
            RowHash.add(title, to: &h)
            RowHash.add(reason, to: &h)
            RowHash.add(error, to: &h)
            h.combine(retry)
            h.combine(chooseModel)
            rows.append(ChatRow(id: "\(m.id)|err", messageId: m.id, scope: input.scope, fingerprint: h.finalize(),
                                kind: .error(ErrorRow(title: title, reason: reason, details: error, retry: retry, chooseModel: chooseModel)),
                                gapAbove: 8, variant: 0))
        } else if m.silentNote {
            // [updates] A run that did its steps and had nothing to say: its steps are the whole of it (the "Nothing to
            // report" note is gone, owner 2026-10-27).
        } else if m.interrupted {
            if produced {
                rows.append(ChatRow(id: "\(m.id)|stopped", messageId: m.id, scope: input.scope, fingerprint: RowHash.of("Stopped"),
                                    kind: .caption("Stopped"), gapAbove: 4, variant: 0))
            } else {
                let text = "Stopped before \(name) replied"
                let retry = retryPrompt(forStoppedAt: index, input: input) != nil
                rows.append(ChatRow(id: "\(m.id)|stopped", messageId: m.id, scope: input.scope, fingerprint: RowHash.of(text + (retry ? "|retry" : "")),
                                    kind: .stoppedEarly(text, retry: retry), gapAbove: ChatMetrics.turnGap, variant: 0))
            }
        }
    }

    /// One Line: the reply's line. While it works, its latest step ("Running a command", "Thinking"); once it has
    /// moved on to writing or is done, "Worked for 42s · 5 steps" when the time is known (this device saw it run), else
    /// what it did ("Explored 2 files, ran 3 commands").
    static func oneLineRow(_ m: ChatMessage, steps: [ToolCall], thoughts: [String], firstThought: Int?, lastVisiblePart: Int,
                           input: Input, helpers: [ToolCards.DelegateRow] = []) -> ChatRow {
        let id = "\(m.id)|line"
        let latest = lastVisiblePart >= 0 && lastVisiblePart < m.parts.count ? m.parts[lastVisiblePart] : nil
        let working: Bool = {
            let externalTail = input.externalWorking && m.id == input.messages.last?.id   // [external-turn]
            guard m.isStreaming || externalTail, let latest else { return false }
            if case .text = latest { return false }
            return true
        }()
        var title: String
        var glyph: ChatGlyph
        var meta: String?
        let helping = helpers.filter { $0.status.isLive }
        if !helping.isEmpty {
            // [updates] Subagents at work, even after the reply has written: what they are, not a card each.
            if helping.count == 1 {
                let goal = ChatText.trimmed(helping[0].goal)
                title = "Helper working" + (goal.isEmpty ? "" : ": " + (goal.count > 40 ? String(goal.prefix(39)) + "…" : goal))
            } else {
                title = "\(helping.count) helpers working"
            }
            glyph = .subagent
        } else if working, case .reasoning? = latest {
            title = "Thinking"
            glyph = .thinking
        } else if working, let step = steps.last, ToolNowRows.speaksFor(m, input: input) {
            // [toolnow] The thinking row under it names the step that runs; this line doesn't say it twice.
            title = "Working"
            glyph = ChatRunSummary.glyph(forSummary: ChatRunSummary.summarize([step], live: true))
            if steps.count > 1 { meta = "\(steps.count) steps" }
        } else if working, let step = steps.last {
            title = ChatRunSummary.summarize([step], live: true)   // still working: present tense between steps too
            glyph = ChatRunSummary.glyph(forSummary: title)
            if steps.count > 1 { meta = "\(steps.count) steps" }   // a long run reads as getting on
        } else if steps.isEmpty {
            title = ActivityRows.thoughtTitle(m, part: firstThought ?? 0, live: false, input: input)
            glyph = .thinking
        } else {
            let timed = steps.allSatisfy { $0.durationSeconds != nil }
            let seconds = input.turnSeconds[m.id] ?? (timed ? steps.reduce(0) { $0 + ($1.durationSeconds ?? 0) } : nil)
            if let seconds {
                let whole = Int(seconds.rounded())
                title = whole < 1 ? "Worked briefly" : "Worked for \(SubagentRules.formatElapsed(whole))"
                // [updates] The helpers are counted apart, not as steps.
                let own = steps.count - (helpers.isEmpty ? 0 : steps.filter { $0.name == "delegate_task" }.count)
                if own > 1 { title += " · \(own) steps" }
            } else {
                title = ChatRunSummary.summarize(steps, live: false)
                // The summary can be cut short on its one line; the count sits apart, where it never is.
                if steps.count > 1 { meta = "\(steps.count) steps" }
            }
            glyph = .worked
            if !helpers.isEmpty {
                let words = helpers.count == 1 ? "1 helper" : "\(helpers.count) helpers"
                if meta == nil { title += " · " + words } else { meta = (meta ?? "") + " · " + words }
                let failed = helpers.filter { $0.status == .failed }.count
                if failed > 0 { title += " · \(failed) failed" }
            }
        }
        let live = working || !helping.isEmpty
        let thought = thoughts.isEmpty ? nil : thoughts.joined(separator: "\n\n")
        let expanded = input.expanded.contains(id)
        var content = Hasher()
        for t in steps {
            content.combine(t.id)
            content.combine(t.name)
            content.combine(t.state)
            RowHash.add(t.title, to: &content)
            if let args = t.argsText { RowHash.addSampled(args, to: &content) } else { content.combine(-1) }
            if let summary = t.summary { RowHash.addSampled(summary, to: &content) } else { content.combine(-1) }
        }
        RowHash.add(title, to: &content)
        RowHash.add(thought ?? "", to: &content)
        RowHash.add(meta ?? "", to: &content)
        content.combine(glyph)
        content.combine(live)
        for h in helpers { content.combine(h.status) }
        var row = ToolRunRow(tools: steps, live: live, expanded: expanded)
        row.line = OneLineRow(title: title, glyph: glyph, thought: thought, meta: meta)
        return ChatRow(id: id, messageId: m.id, scope: input.scope, fingerprint: content.finalize(), kind: .toolRun(row),
                       gapAbove: ChatMetrics.turnGap, variant: expanded ? 1 : 0)
    }

    private static func toolRow(id: String, message m: ChatMessage, tools: [ToolCall], live: Bool, expanded: Bool,
                                scope: String) -> ChatRow {
        var content = Hasher()
        for t in tools {
            content.combine(t.id)
            content.combine(t.name)
            content.combine(t.state)
            RowHash.add(t.title, to: &content)
            if let args = t.argsText { RowHash.addSampled(args, to: &content) } else { content.combine(-1) }
            if let summary = t.summary { RowHash.addSampled(summary, to: &content) } else { content.combine(-1) }
        }
        content.combine(live)
        var variant = Hasher()
        variant.combine(expanded)
        return ChatRow(id: id, messageId: m.id, scope: scope, fingerprint: content.finalize(),
                       kind: .toolRun(ToolRunRow(tools: tools, live: live, expanded: expanded)),
                       gapAbove: ChatMetrics.turnGap, variant: variant.finalize())
    }

    /// How long a send waits before "Sending…" shows under it (spec 06 §5.6.4).
    static let sendingDelay: TimeInterval = 2

    /// The `expanded` entry that hides a message's error card (its ✕, spec 06 §5.6.1). Screen-only state.
    static func dismissedErrorKey(_ messageId: String) -> String { "\(messageId)|err-dismissed" }
    /// The `expanded` entry for a delivery Check in flight under your message.
    static func checkingKey(_ messageId: String) -> String { "\(messageId)|checking" }

    /// The error card's second line (spec 06 §5.6.1): a short raw error (≤ 160 characters, one line) is the reason
    /// itself; anything longer gets the generic wording, and the raw text stays behind Details. A card without Retry
    /// drops the retry wording (`withoutRetryWords`). `bot`: the chat's bot, which the card names (not the software).
    static func errorReason(_ error: String, retry: Bool = false, bot: String = "Hermes") -> String {
        let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Hermes ended this turn without a reply." {
            // `no_reply` (spec 06 §5.6.2): the gateway's sentence always says Hermes; the card says which bot.
            return retry ? "\(bot) ended this turn without a reply. \(DeviceWord.Tap) Try Again to send it again." : "\(bot) ended this turn without a reply."
        }
        // The app's own stand-in when the gateway sent no words: it says "Hermes" under a title that names the bot.
        let ownFallback = trimmed == "Hermes couldn't finish this turn." || trimmed == "Hermes couldn’t finish this turn."
        if !ownFallback && trimmed.count <= 160 && !trimmed.contains(where: \.isNewline) { return trimmed }
        return retry ? "Something went wrong while \(bot) was replying. Try again, or copy the details if it keeps happening."
            : "Something went wrong while \(bot) was replying. Copy the details if it keeps happening."
    }

    /// The prompt the error card at `index` sends again, when it offers Retry (spec 06 §5.6.1, M1 DECISION): the card is
    /// the newest message, nothing runs, and the message right above it is its own prompt (a refused send's card follows
    /// the previous reply instead: its words went back to the composer, so it offers none).
    static func retryPrompt(forErrorAt index: Int, input: Input) -> String? {
        let messages = input.messages
        guard !input.isRunning, index == messages.count - 1, index > 0 else { return nil }
        let prompt = messages[index - 1]
        guard prompt.role == .user, prompt.error == nil, !prompt.isPending else { return nil }
        return wordsOnly(prompt, input: input)
    }

    /// The prompt a "Stopped before <bot> replied" row's Try Again sends again: the same rule as the error card's, so
    /// only the newest turn offers it, and never while a reply runs (an older stopped row resent a prompt from far up
    /// the chat, and Try Again did nothing at all while a turn ran).
    static func retryPrompt(forStoppedAt index: Int, input: Input) -> String? {
        let messages = input.messages
        guard !input.isRunning, index == messages.count - 1, index > 0, messages[index].interrupted else { return nil }
        guard let prompt = messages[..<index].last(where: { $0.role == .user && $0.sender == nil }),
              !prompt.isPending else { return nil }
        return wordsOnly(prompt, input: input)
    }

    /// A prompt Try Again can send as it was: words, with no photos or files (only the words could go again, and a
    /// Try Again that quietly dropped the pictures would ask a different question).
    private static func wordsOnly(_ prompt: ChatMessage, input: Input) -> String? {
        guard (input.media.attachments[prompt.id] ?? []).isEmpty else { return nil }
        let text = prompt.plainText
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    // MARK: Runs, corners, tails, times, gaps

    /// Two messages join a run: both bubble senders of the same role, each within 300 s of the one before.
    static func joins(_ a: ChatMessage, _ b: ChatMessage) -> Bool {
        guard a.role == b.role, a.role != .system else { return false }
        guard a.sender?.key == b.sender?.key else { return false }   // [groups] a run is one sender's
        guard a.reactions.isEmpty else { return false }              // its badges sit under it: the run ends there
        guard let ta = a.timestamp, let tb = b.timestamp else { return true }
        return tb.timeIntervalSince(ta) <= ChatMetrics.runSeconds
    }

    private static func applyRunsAndGaps(_ rows: inout [ChatRow], messages: [ChatMessage], from contextStart: Int, ownName: String = "",
                                         ownFace: ChatSender? = nil, fewerTimes: Bool = false) {
        guard !rows.isEmpty else { return }
        // Message index by id, for the messages in play.
        var position: [String: Int] = [:]
        position.reserveCapacity(messages.count - contextStart)
        for i in contextStart..<messages.count { position[messages[i].id] = i }

        // Last bubble row of each message.
        var lastBubbleRow: [String: Int] = [:]
        for (r, row) in rows.enumerated() where row.isBubble { lastBubbleRow[row.messageId] = r }
        // [groups] A chat with any sender-carrying message loaded keeps the face column free on every incoming bubble;
        // its own bot is named again at the start of a run once another sender has spoken (§7.12).
        // Deliveries and cron runs are one-line rows (`DeliveryRows`), not bubbles: only room members count.
        let firstSender = messages.firstIndex { $0.sender != nil && $0.role != .user }

        for r in rows.indices {
            guard case .bubble(var bubble) = rows[r].kind, let mi = position[rows[r].messageId] else { continue }
            let message = messages[mi]
            // Joins with the row above / below: an adjacent bubble on the same side in the same message or run.
            if r > 0, case .bubble(let above) = rows[r - 1].kind, above.mine == bubble.mine,
               let ai = position[rows[r - 1].messageId], ai == mi || (ai == mi - 1 && joins(messages[ai], message)) {
                bubble.joinsAbove = true
            }
            if r + 1 < rows.count, case .bubble(let below) = rows[r + 1].kind, below.mine == bubble.mine,
               let bi = position[rows[r + 1].messageId], bi == mi || (bi == mi + 1 && joins(message, messages[bi])) {
                bubble.joinsBelow = true
            }
            // Tail and time: the last bubble of the run's last message.
            let nextJoins = mi + 1 < messages.count && joins(message, messages[mi + 1])
            let isRunEnd = !nextJoins
            // Fewer Timestamps: your bubbles carry no time; the reply under them does.
            let endsRun = isRunEnd && lastBubbleRow[message.id] == r
            if endsRun && !(fewerTimes && bubble.mine) {
                bubble.tail = true
                bubble.time = message.timestamp
            } else {
                bubble.tail = false
                bubble.time = nil
            }
            bubble.spokenTime = endsRun && fewerTimes && bubble.mine ? message.timestamp : nil
            if let firstSender, !bubble.mine {
                bubble.senderInset = true
                bubble.showsSenderName = bubble.sender != nil && !bubble.joinsAbove
                bubble.showsSenderFace = bubble.sender != nil && !bubble.joinsBelow
                bubble.byline = bubble.sender == nil && !bubble.joinsAbove && mi > firstSender ? ownName : nil
                bubble.bylineSender = bubble.byline == nil ? nil : ownFace
            }
            rows[r].kind = .bubble(bubble)
            rows[r].gapAbove = bubble.joinsAbove ? ChatMetrics.runGap : ChatMetrics.turnGap
            var hasher = Hasher()
            hasher.combine(bubble.joinsAbove); hasher.combine(bubble.joinsBelow); hasher.combine(bubble.tail)
            hasher.combine(bubble.time); hasher.combine(bubble.pending); hasher.combine(bubble.expanded)
            hasher.combine(bubble.openCode)
            if let spoken = bubble.spokenTime { hasher.combine(spoken) }   // only when set: other rows keep their layouts
            hasher.combine(bubble.memoTitle)
            hasher.combine(bubble.memo)   // VOICE
            // A settled reply's code is highlighted: its layout (same geometry, new colours) is made again once.
            hasher.combine(bubble.streaming)
            // [groups] Only when set: chats without senders keep the layouts they had.
            if bubble.senderInset {
                hasher.combine(bubble.sender); hasher.combine(bubble.showsSenderName); hasher.combine(bubble.showsSenderFace)
                hasher.combine(bubble.byline); hasher.combine(bubble.bylineSender)
            }
            // [transcript] The job on the name line, wherever the bubble sits; only when set, so other chats keep
            // the layouts they had.
            if let job = bubble.job { hasher.combine(job) }
            rows[r].variant = hasher.finalize()
        }
        // Gaps for blocks: rows after a day separator sit on its padding; adjacent tool rows read as one list.
        for r in rows.indices {
            if r == 0 { continue }
            if case .day = rows[r - 1].kind { rows[r].gapAbove = 0; continue }
            if case .day = rows[r].kind { rows[r].gapAbove = 0; continue }
            switch (rows[r - 1].kind, rows[r].kind) {
            case (.toolRun, .toolRun), (.thought, .toolRun), (.toolRun, .thought), (.thought, .thought):
                if rows[r - 1].messageId == rows[r].messageId { rows[r].gapAbove = -6 }
            case (.backgroundResult, .backgroundResult):
                // Deliveries and background notes one after another read as one list (owner, 2026-10-18).
                rows[r].gapAbove = -6
            default:
                break
            }
        }
        ActivityRows.applyBubbleJoins(&rows, messages: messages, from: contextStart)      // [activity] tool bubbles join runs
    }

    // MARK: Time and day labels (run.ts)

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
    private static let dayYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("yMMMd")
        return f
    }()

    /// "9:14 AM" in the device's locale and hour cycle.
    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    /// A day separator goes at the first timed message, a local date change, or after a gap of 30 minutes (only the
    /// date change with `datesOnly`, Fewer Timestamps).
    static func needsDayBreak(previous: Date?, current: Date, datesOnly: Bool = false) -> Bool {
        guard let previous else { return true }
        if datesOnly { return LocalDay.number(previous) != LocalDay.number(current) }
        return current.timeIntervalSince(previous) >= ChatMetrics.dayGapSeconds || LocalDay.number(previous) != LocalDay.number(current)
    }

    /// The separator's words: "Today 9:14 AM", "Yesterday 9:14 AM", "Sep 26 9:14 AM" (year added when not this year).
    static func dayLabel(_ current: Date, now: Date) -> String {
        "\(dayName(current, now: now)) \(clock(current))"
    }

    /// "Today", "Yesterday", "Sep 26" (year added when not this year).
    static func dayName(_ current: Date, now: Date) -> String {
        let cal = Calendar.autoupdatingCurrent
        if cal.isDate(current, inSameDayAs: now) { return "Today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(current, inSameDayAs: y) { return "Yesterday" }
        if cal.component(.year, from: current) == cal.component(.year, from: now) { return dayFormatter.string(from: current) }
        return dayYearFormatter.string(from: current)
    }

    /// [idle] The day line over an update group that spans days: "Oct 26 – Nov 6", "Nov 2 – Today".
    static func dayRange(_ first: Date, _ last: Date, now: Date) -> String {
        "\(dayName(first, now: now)) – \(dayName(last, now: now))"
    }

    /// Kept for callers that want the old combined test-and-label.
    static func dayLabel(previous: Date?, current: Date, now: Date) -> String? {
        needsDayBreak(previous: previous, current: current) ? dayLabel(current, now: now) : nil
    }
}

/// Local calendar day numbers without Calendar's cost (one time zone lookup per UTC day, cached). A UTC day that holds a
/// clock change (daylight saving) keeps the instant it happens and the offset after it, so a message near midnight on
/// that night lands on its own day; the cache is forgotten when the time zone changes (travel, Settings).
nonisolated enum LocalDay {
    private struct Day { var offset: Int; var change: Double?; var offsetAfter: Int }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var days: [Int: Day] = [:]
    nonisolated(unsafe) private static let zoneObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: .NSSystemTimeZoneDidChange, object: nil, queue: nil) { _ in LocalDay.reset() }

    /// `zone`: a fixed time zone (tests), worked out without the cache; nil is the phone's own.
    static func number(_ date: Date, zone fixed: TimeZone? = nil) -> Int {
        _ = zoneObserver
        let zone = fixed ?? .autoupdatingCurrent
        let t = date.timeIntervalSince1970
        let utcDay = Int((t / 86_400).rounded(.down))
        lock.lock()
        let cached = fixed == nil ? days[utcDay] : nil
        lock.unlock()
        let day: Day
        if let cached { day = cached } else {
            let start = Date(timeIntervalSince1970: Double(utcDay) * 86_400)
            let offset = zone.secondsFromGMT(for: start)
            var change: Double?
            var after = offset
            if let next = zone.nextDaylightSavingTimeTransition(after: start), next.timeIntervalSince1970 < Double(utcDay + 1) * 86_400 {
                change = next.timeIntervalSince1970
                after = zone.secondsFromGMT(for: next)
            }
            day = Day(offset: offset, change: change, offsetAfter: after)
            if fixed == nil {
                lock.lock()
                if days.count > 4096 { days.removeAll() }
                days[utcDay] = day
                lock.unlock()
            }
        }
        let offset = day.change.map { t >= $0 ? day.offsetAfter : day.offset } ?? day.offset
        return Int(((t + Double(offset)) / 86_400).rounded(.down))
    }

    /// The time zone changed: every cached day goes.
    static func reset() {
        lock.lock()
        days.removeAll()
        lock.unlock()
    }
}
