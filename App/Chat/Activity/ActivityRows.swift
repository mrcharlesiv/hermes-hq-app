import UIKit

// The transcript side of the activity stream (docs/spec/1x-activity.md §9–§11): which step blocks a reply draws in each
// Tool Call Style (Rows, Bubbles, In Header) and After Reply › Hide, the thought rows' words ("Thought for 7s"), and the
// rows this stream adds — Telegram-style tool bubbles, the `delegate_task` card and the generated-image frame. Pure
// value code, built and measured off the main thread like every other row. `ChatRowBuilder` calls in at the places
// marked `[activity]`.

/// Everything the row builder needs from the activity stream (a snapshot taken with the rows' input).
nonisolated struct ActivityRowsInput: @unchecked Sendable {
    var style: ToolCallStyle = .rows
    /// After Reply › Hide (never in In Header).
    var hideSteps = false
    /// Replies whose hidden steps were brought back (Show Steps), by message id.
    var revealed: Set<String> = []
    /// Replies whose steps are fading out right now: still drawn until the fold removes them.
    var folding: Set<String> = []
    /// Replies whose action row waits for their fold's removal (a reply that just turned done).
    var holdingActions: Set<String> = []
    var showReasoning = true
    var toolProgressOff = false
    /// Measured reasoning seconds by message id and part index.
    var reasoningSeconds: [String: [Int: Double]] = [:]
    /// The chat's subagents, for the delegate card's live rows.
    var subagents: [SubagentProgress] = []
    /// The explained provider wait for the waiting capsule.
    var providerWait: String?
    /// The chat's profile and stored session (the generated image's download).
    var profile = ""
    /// The newest message when a hidden goal continuation went out (`StepRules.isWorking`).
    var turnAnchor: String?
    /// Generated images whose good path wouldn't load: drawn as the "Open image: …" link row (§11.3).
    var failedImages: Set<String> = []
}

// MARK: - Row kinds

nonisolated enum ActivityRowKind {
    case toolBubble(ToolBubbleRow)
    case delegate(DelegateCardRow)
    case image(ImageCardRow)
    /// [transcript] "N files changed" (docs/spec/3x-transcript.md §12, n20 F10).
    case changedFiles(ChangedFilesRow)
    /// [transcript] A landed edit's first changed lines, under its row (Rows and Bubbles only).
    case diffPreview(DiffPreviewRow)
    /// [tasks] "Added to Tasks" under a reply whose bot put tasks on your list (mockup 4-chat).
    case tasksAdded(TasksAddedRow)
}

/// [tasks] The tasks a reply's `tasks_add` calls added, each with its "You & Hermes · Tomorrow" line.
nonisolated struct TasksAddedRow {
    var messageId: String
    var tasks: [AddedTask]
    var lines: [String]
    /// Undo took them back (this run of the app).
    var undone: Bool
    /// [tasks] No task added: the bot took a part of yours ("<Bot> Is Helping", no Undo — it would delete your task).
    var helping = false
    /// The reply's bot ("Hermes"): its steps' name, and "Ask Hermes to Help".
    var botName = "Hermes"
}

nonisolated struct ToolBubbleLine: Hashable {
    var callId: String
    var line: ToolLine
    var failed: Bool
    var running: Bool
    /// "Shell" (terminal) / "Python" (execute_code) over the code block.
    var language: String?
}

nonisolated struct ToolBubbleRow {
    var lines: [ToolBubbleLine]
    /// Lines folded into "⋯ N earlier steps" (0 when all show).
    var earlier: Int
    var joinsAbove = false
    var joinsBelow = false
    var tail = false
    var time: Date?
    /// The calls, by id, for the step sheet.
    var calls: [ToolCall]
}

nonisolated struct DelegateCardRow {
    var toolId: String
    var rows: [ToolCards.DelegateRow]
}

nonisolated struct ImageCardRow {
    var toolId: String
    var path: String?
    /// Width / height of the frame.
    var ratio: Double
    var running: Bool
    var profile: String
    /// The path wouldn't load: the frame collapses to the link row (tap retries).
    var failed = false
}

/// [transcript] "N files changed", under a settled reply (docs/spec/3x-transcript.md §12, n20 F10): a row per file,
/// five then "Show all N files"; a file's own row opens its current text, Review opens the chat's Changes page.
nonisolated struct ChangedFilesRow {
    var messageId: String
    /// First-touched order (`ChangedFiles.derive`); each path exactly as its edit tool reported it (may be relative).
    var files: [ChangedFile]
    /// "Show all N files" was tapped.
    var showAll: Bool
}

/// [transcript] A landed edit's first changed lines, drawn under its row in Rows and Bubbles (One Line / At the
/// Bottom have no per-call row to hang it from: §12 DECISION). "Show all changes" opens the step sheet's diff.
nonisolated struct DiffPreviewRow {
    /// Kept whole (not just its id): "Show all changes" opens the step sheet the same way a tool bubble's line does.
    var call: ToolCall
    /// The path exactly as the edit tool reported it (may be relative; resolved only when opened).
    var path: String
    var added: Int
    var removed: Int
    var lines: [ChangedFiles.PreviewLine]
    var more: Bool
}

nonisolated extension ChatRow {
    /// A bot bubble or a tool bubble: which side it sits on (nil for every other row).
    var bubbleSide: Bool? {
        switch kind {
        case .bubble(let b): return b.mine
        case .activity(.toolBubble): return false
        default: return nil
        }
    }

    /// Rows that fold away with After Reply › Hide: tool runs, thoughts and tool bubbles (not cards — a diff preview
    /// is a step's detail and folds with it, but the "N files changed" card is a result and stays).
    var isStepBlock: Bool {
        switch kind {
        case .toolRun(let t): return !t.tools.contains { ToolCards.isCardTool($0.name) }
        case .thought, .activity(.toolBubble), .activity(.diffPreview): return true
        default: return false
        }
    }
}

// MARK: - Building

nonisolated enum ActivityRows {
    enum Disposition {
        /// Draw nothing for this call.
        case skip
        /// Draw this row in its place (it ends the run before it).
        case card(ChatRow)
        /// The style's step (run row, bubble line).
        case step
    }

    /// Whether `m`'s step blocks are not drawn: In Header always; Hide once the reply is done (not after Show Steps,
    /// and not while the fold still fades them).
    static func stepsHidden(_ m: ChatMessage, at index: Int, input: ChatRowBuilder.Input) -> Bool {
        let a = input.activity
        if a.style == .header { return true }
        guard a.hideSteps, !a.revealed.contains(m.id), !a.folding.contains(m.id) else { return false }
        let working = StepRules.isWorking(m, at: index, in: input.messages, running: input.isRunning, turnAnchor: a.turnAnchor)
        return StepRules.state(m.parts, working: working) == .done
    }

    /// While the newest reply's steps fade out, its action row waits: it lands in the fold's one removal and moves once,
    /// with the slide (a separate arrival glided the reply up and the slide then pushed it back down).
    static func holdsActions(_ reply: ChatMessage, input: ChatRowBuilder.Input) -> Bool {
        input.activity.holdingActions.contains(reply.id)
    }

    /// The message the action row belongs under: the newest one, past any model-fallback notices that came after the
    /// reply (a notice doesn't take Copy away from the reply above it, §8.3).
    static func latestReplyIndex(_ messages: [ChatMessage]) -> Int? {
        var i = messages.count - 1
        while i > 0, messages[i].role == .system, messages[i].id.hasPrefix(ProviderWait.noticeIdPrefix) { i -= 1 }
        return i >= 0 ? i : nil
    }

    /// No waiting capsule under a reply that has started: In Header keeps its steps and thoughts out of the transcript
    /// (the status line under the name says what runs), and so does `display.tool_progress` off for its run tools — the
    /// capsule would otherwise sit there, "Waiting for <model>", through the whole tool run (§10.4, §10.6;
    /// M:tool-calls-hide-when-done.md: the web's loading rows were hidden in In Header).
    static func suppressesWaiting(_ last: ChatMessage, input: ChatRowBuilder.Input) -> Bool {
        guard last.role == .assistant, !last.parts.isEmpty else { return false }
        if input.activity.style == .header { return true }
        guard input.activity.toolProgressOff else { return false }
        return last.parts.allSatisfy { if case .tool = $0 { return true } else { return false } }
    }

    /// Whether `m` belongs to the chat's latest turn (after the last prompt, or after a hidden continuation's anchor).
    static func inLatestTurn(_ m: ChatMessage, input: ChatRowBuilder.Input) -> Bool {
        let messages = input.messages
        guard let index = messages.lastIndex(where: { $0.id == m.id }) else { return false }
        var start = messages.lastIndex { $0.role == .user } ?? -1
        if let anchor = input.activity.turnAnchor, let a = messages.lastIndex(where: { $0.id == anchor }) { start = max(start, a) }
        return index > start
    }

    static func drawsThought(stepsHidden: Bool, input: ChatRowBuilder.Input) -> Bool {
        !stepsHidden && input.activity.showReasoning
    }

    /// "Thinking" while open; "Thought for 7s" / "Thought briefly" when measured; "Thought" from history.
    static func thoughtTitle(_ m: ChatMessage, part: Int, live: Bool, input: ChatRowBuilder.Input) -> String {
        if live { return "Thinking" }
        guard let seconds = input.activity.reasoningSeconds[m.id]?[part] else { return "Thought" }
        let whole = Int(seconds)
        return whole == 0 ? "Thought briefly" : "Thought for \(SubagentRules.formatElapsed(whole))"
    }

    static func disposition(_ call: ToolCall, in m: ChatMessage, stepsHidden: Bool, input: ChatRowBuilder.Input) -> Disposition {
        // `clarify` belongs to the questions stream: a card in every style, never folded or hidden (§11.4).
        if call.name == "clarify" { return .step }
        if call.name == "delegate_task" || call.name == "image_generate" {
            if call.state == .running || call.card != nil, let row = cardRow(call, in: m, input: input) { return .card(row) }
            // Failed outright, or settled without a result: the generic step.
        }
        if stepsHidden { return .skip }
        if input.activity.toolProgressOff, call.state != .failed, !ChatRunSummary.isFileEdit(call.name) { return .skip }
        return .step
    }

    /// Bubbles turns a run into a tool bubble; a run holding `clarify` stays the questions stream's row.
    static func bubbles(_ run: [ToolCall], input: ChatRowBuilder.Input) -> Bool {
        input.activity.style == .bubbles && !run.contains { $0.name == "clarify" }
    }

    // MARK: Tool bubble (§10.2)

    static let bubbleShownLines = 8

    static func toolBubbleRow(id: String, message m: ChatMessage, tools: [ToolCall], input: ChatRowBuilder.Input) -> ChatRow {
        let all = tools.map { call -> ToolBubbleLine in
            let line = ToolLines.line(call)
            let language = line.code == nil ? nil : (call.name == "execute_code" ? "Python" : "Shell")
            return ToolBubbleLine(callId: call.id, line: line, failed: call.state == .failed, running: call.state == .running,
                                  language: language)
        }
        let showAll = input.expanded.contains(id)
        var lines = all
        var earlier = 0
        if !showAll && all.count > bubbleShownLines {
            earlier = all.count - (bubbleShownLines - 1)
            lines = Array(all.suffix(bubbleShownLines - 1))
        }
        var h = Hasher()
        h.combine(lines)
        h.combine(earlier)
        let row = ToolBubbleRow(lines: lines, earlier: earlier, calls: tools)
        return ChatRow(id: id, messageId: m.id, scope: input.scope, fingerprint: h.finalize(), kind: .activity(.toolBubble(row)),
                       gapAbove: ChatMetrics.turnGap, variant: 0)
    }

    // MARK: Cards (§11)

    /// The delegate card's live inputs are mirrored in `ChatActivityController.CardKey`: grow it if this reads more.
    static func cardRow(_ call: ToolCall, in m: ChatMessage, input: ChatRowBuilder.Input) -> ChatRow? {
        switch call.name {
        case "delegate_task":
            // Bounded per value at the source; a text cut short anyway still gives its goals (tolerant scan).
            var goals = ToolCards.delegateGoals(.object(ToolArgs.parse(call.argsText)))
            if case .delegate(let cardGoals, _, _)? = call.card, goals.isEmpty { goals = cardGoals }
            let base = ToolCards.rows(goals: goals, card: call.card, hasResult: call.card != nil, toolCallId: call.id)
            // The chat's live children belong to the running call or the latest turn's card; an earlier turn's card
            // (one task, done) would otherwise take a new single child by its index. Stand-ins match by id anywhere.
            let current = call.state == .running || inLatestTurn(m, input: input)
            let prefix = "delegate-tool:\(call.id):"
            let live = current ? input.activity.subagents : input.activity.subagents.filter { $0.id.hasPrefix(prefix) }
            let rows = ToolCards.merge(base, live: live, toolCallId: call.id)
            guard !rows.isEmpty else { return nil }
            var h = Hasher()
            for r in rows {
                h.combine(r.goal); h.combine(r.status); h.combine(r.activity.last); h.combine(r.model); h.combine(r.durationSeconds)
                h.combine(r.startedAt)
            }
            return ChatRow(id: "\(m.id)|dg\(call.id)", messageId: m.id, scope: input.scope, fingerprint: h.finalize(),
                           kind: .activity(.delegate(DelegateCardRow(toolId: call.id, rows: rows))), gapAbove: 8, variant: 0)
        case "image_generate":
            var path: String?
            var ratio = ToolCards.imageRatio(aspect: ToolCards.aspectHint(call.argsText), pixelWidth: nil, pixelHeight: nil)
            if case .image(let p, let aspect, let w, let hh)? = call.card {
                path = p
                ratio = ToolCards.imageRatio(aspect: aspect ?? ToolCards.aspectHint(call.argsText), pixelWidth: w, pixelHeight: hh)
            }
            let failed = path.map { input.activity.failedImages.contains($0) } ?? false
            var h = Hasher()
            h.combine(path); h.combine(ratio); h.combine(call.state == .running); h.combine(failed)
            return ChatRow(id: "\(m.id)|im\(call.id)", messageId: m.id, scope: input.scope, fingerprint: h.finalize(),
                           kind: .activity(.image(ImageCardRow(toolId: call.id, path: path, ratio: ratio, running: call.state == .running,
                                                              profile: input.activity.profile, failed: failed))),
                           gapAbove: 8, variant: 0)
        default:
            return nil
        }
    }

    // MARK: Changed files (§12, n20 F10)

    /// Under a settled reply that changed files: the card. A result, not a step — Tool Call Style and After Reply ›
    /// Hide don't touch it — but it waits for the same fold that removes the step rows above it (hideSteps on), so
    /// it never lands a beat early and bounces them (§10.5; DECISION, n20 F10: `holdingActions` stood for the action
    /// row this reply no longer has — `folding` is today's fold, and gating on it keeps the card and the steps'
    /// removal in the same apply).
    ///
    /// "Show all N files" is this row's own `expanded` entry — the same `chatCellToggle(rowId:)` every other
    /// show-more row (e.g. `ToolBubbleRow`'s "⋯ N earlier steps") already uses, so the generic toggle path works
    /// with no extra wiring.
    static func changedFilesRow(_ m: ChatMessage, edits: [(call: ToolCall, args: [String: JSONValue], diff: String?)],
                                input: ChatRowBuilder.Input) -> ChatRow? {
        guard !m.isStreaming, !input.activity.folding.contains(m.id), !edits.isEmpty else { return nil }
        let files = ChangedFiles.derive(calls: edits)
        guard !files.isEmpty else { return nil }
        let id = "\(m.id)|files"
        let showAll = input.expanded.contains(id)
        var h = Hasher()
        for f in files { h.combine(f.path); h.combine(f.name); h.combine(f.added); h.combine(f.removed) }
        h.combine(showAll)
        return ChatRow(id: id, messageId: m.id, scope: input.scope, fingerprint: h.finalize(),
                       kind: .activity(.changedFiles(ChangedFilesRow(messageId: m.id, files: files, showAll: showAll))),
                       gapAbove: 8, variant: showAll ? 1 : 0)
    }

    /// Under a landed edit's own row (Rows, Bubbles): its first changed lines. Diffs come from `ToolDetail.inlineDiff`
    /// (§12 DECISION: not `ToolDiffStore`, which nothing here reads); nil when there is none to show (a running or
    /// failed call, or one this device never saw a diff for).
    static func diffPreviewRow(_ call: ToolCall, path: String, diff: String, message m: ChatMessage, input: ChatRowBuilder.Input) -> ChatRow? {
        let (lines, more) = ChangedFiles.preview(diff)
        guard !lines.isEmpty else { return nil }
        let stats = ChangedFiles.lineStats(diff)
        var h = Hasher()
        h.combine(call.id); h.combine(path); h.combine(lines); h.combine(more); h.combine(stats.added); h.combine(stats.removed)
        return ChatRow(id: "\(m.id)|diff\(call.id)", messageId: m.id, scope: input.scope, fingerprint: h.finalize(),
                       kind: .activity(.diffPreview(DiffPreviewRow(call: call, path: path, added: stats.added,
                                                                   removed: stats.removed, lines: lines, more: more))),
                       gapAbove: 4, variant: 0)
    }

    // MARK: Added to Tasks ([tasks], mockup 4-chat)

    /// Under a settled reply whose bot added tasks: the card (a result, as the files card: Tool Call Style and Hide
    /// Steps don't touch it).
    static func tasksAddedRow(_ m: ChatMessage, calls: [ToolCall], input: ChatRowBuilder.Input) -> ChatRow? {
        guard !m.isStreaming else { return nil }
        var tasks: [AddedTask] = []
        var helped: [AddedTask] = []
        for call in calls where call.state == .done {
            guard case .tasksAdded(let found)? = call.card else { continue }
            if call.name == "tasks_update" {
                // [tasks] 0.9.33: it changes a task this reply added (the bot took its part right after adding it),
                // or it is the bot taking a part of a task of yours that was already on the list.
                for later in found {
                    if let i = tasks.firstIndex(where: { $0.id == later.id }) { tasks[i] = tasks[i].updated(by: later) }
                    else if let i = helped.firstIndex(where: { $0.id == later.id }) { helped[i] = helped[i].updated(by: later) }
                    else if later.tookPart { helped.append(later) }
                }
            } else {
                tasks += found.filter { a in !tasks.contains { $0.id == a.id } }
            }
        }
        let helping = tasks.isEmpty
        if helping { tasks = helped }
        guard !tasks.isEmpty else { return nil }
        let own = input.activity.profile
        let name: (String?) -> String = { profile in
            let id = profile ?? own
            if id == own || id.isEmpty { return input.speakerName }
            return input.bots.first { $0.profile == id }?.name ?? (id == "default" ? "Hermes" : id.capitalized)
        }
        let lines = tasks.map { TodoCardWords.line($0, now: input.now, botName: name) }
        let undone = !helping && tasks.allSatisfy { TodoUndone.contains($0.id) }
        let botName = name(nil)
        var h = Hasher()
        h.combine(tasks); h.combine(lines); h.combine(undone); h.combine(helping); h.combine(botName)
        return ChatRow(id: "\(m.id)|tasks", messageId: m.id, scope: input.scope, fingerprint: h.finalize(),
                       kind: .activity(.tasksAdded(TasksAddedRow(messageId: m.id, tasks: tasks, lines: lines, undone: undone,
                                                                 helping: helping, botName: botName))),
                       gapAbove: 8, variant: 0)
    }

    // MARK: Runs (tool bubbles join the bot bubbles around them)

    /// After the bubbles' own pass: tool bubbles join adjacent bot bubbles of the same run (square corners where they
    /// meet), and the run's last bubble — text or tool — carries the tail and the time (§10.2).
    static func applyBubbleJoins(_ rows: inout [ChatRow], messages: [ChatMessage], from contextStart: Int) {
        guard rows.contains(where: { if case .activity(.toolBubble) = $0.kind { return true } else { return false } }) else { return }
        var position: [String: Int] = [:]
        for i in contextStart..<messages.count { position[messages[i].id] = i }
        func sameRun(_ a: Int, _ b: Int) -> Bool {
            guard let ia = position[rows[a].messageId], let ib = position[rows[b].messageId] else { return false }
            if ia == ib { return true }
            let (lo, hi) = ia < ib ? (ia, ib) : (ib, ia)
            return hi == lo + 1 && ChatRowBuilder.joins(messages[lo], messages[hi])
        }
        var lastBubbleRow: [String: Int] = [:]
        for (r, row) in rows.enumerated() where row.bubbleSide != nil { lastBubbleRow[row.messageId] = r }
        for r in rows.indices {
            guard let side = rows[r].bubbleSide, !side, let mi = position[rows[r].messageId] else { continue }
            let joinsAbove = r > 0 && rows[r - 1].bubbleSide == false && sameRun(r - 1, r)
            let joinsBelow = r + 1 < rows.count && rows[r + 1].bubbleSide == false && sameRun(r, r + 1)
            let message = messages[mi]
            let nextJoins = mi + 1 < messages.count && ChatRowBuilder.joins(message, messages[mi + 1])
            let tail = !nextJoins && lastBubbleRow[message.id] == r
            switch rows[r].kind {
            case .bubble(var b):
                guard b.joinsAbove != joinsAbove || b.joinsBelow != joinsBelow || b.tail != tail else { continue }
                b.joinsAbove = joinsAbove
                b.joinsBelow = joinsBelow
                b.tail = tail
                b.time = tail ? message.timestamp : nil
                rows[r].kind = .bubble(b)
                rows[r].gapAbove = joinsAbove ? ChatMetrics.runGap : ChatMetrics.turnGap
                var hasher = Hasher()
                hasher.combine(b.joinsAbove); hasher.combine(b.joinsBelow); hasher.combine(b.tail)
                hasher.combine(b.time); hasher.combine(b.pending); hasher.combine(b.expanded)
                hasher.combine(b.openCode)
                hasher.combine(b.memoTitle)
                hasher.combine(b.streaming)
                rows[r].variant = hasher.finalize()
            case .activity(.toolBubble(var t)):
                t.joinsAbove = joinsAbove
                t.joinsBelow = joinsBelow
                t.tail = tail
                t.time = tail ? message.timestamp : nil
                rows[r].kind = .activity(.toolBubble(t))
                rows[r].gapAbove = joinsAbove ? ChatMetrics.runGap : ChatMetrics.turnGap
                var hasher = Hasher()
                hasher.combine(joinsAbove); hasher.combine(joinsBelow); hasher.combine(tail); hasher.combine(t.time)
                rows[r].variant = hasher.finalize()
            default:
                break
            }
        }
    }

    /// The waiting capsule's words: an explained provider wait replaces "Waiting for <model>" (§8.2).
    static func waitingLabel(_ fallback: String, input: ChatRowBuilder.Input) -> String {
        guard let wait = input.activity.providerWait, !wait.isEmpty else { return fallback }
        return wait
    }
}

// MARK: - Layout

nonisolated struct ToolBubbleLineLayout: @unchecked Sendable {
    var callId: String
    var text: TextKitLayout
    var textFrame: CGRect
    /// ≥ 44 pt, centred on the line (targets of neighbouring lines overlap).
    var tapFrame: CGRect
    var running: Bool
    var failed: Bool
    /// The code block (frame, head row, clamped code), when the call has code.
    var blockFrame: CGRect?
    var head: TextKitLayout?
    var headFrame: CGRect = .zero
    var code: TextKitLayout?
    var codeFrame: CGRect = .zero
    var accessibility: String
}

nonisolated struct ToolBubbleLayout: @unchecked Sendable {
    var frame: CGRect
    var shape: BubbleShape.Key
    var lines: [ToolBubbleLineLayout]
    /// "⋯ N earlier steps" (tap shows all).
    var more: TextKitLayout?
    var moreFrame: CGRect = .zero
    var timeText: String?
    var timeFrame: CGRect = .zero
}

nonisolated struct DelegateCardLayout: @unchecked Sendable {
    struct Row: @unchecked Sendable {
        var frame: CGRect
        var status: ToolCards.RowStatus
        var goal: TextKitLayout
        var goalFrame: CGRect
        var meta: TextKitLayout?
        var metaFrame: CGRect
        /// Where the live elapsed timer sits (trailing, tabular), when the row is live.
        var timerFrame: CGRect?
        var startedAt: Double?
        var glyphFrame: CGRect
        var agentFrame: CGRect
        /// The one-line activity window (the ticker clips to it).
        var activityFrame: CGRect
        var activity: String?
        var accessibility: String
    }
    var rows: [Row]
    var font: UIFont
    var activityFont: UIFont
}

nonisolated struct ImageCardLayout: @unchecked Sendable {
    var frame: CGRect
    var path: String?
    var running: Bool
    var profile: String
    /// The link row "Open image: <name>" instead of the frame (a good path that wouldn't load).
    var failed = false
}

/// [transcript] "N files changed" (§12, n20 F10). Look: one filled card, as an opened One Line card — the summary
/// and "Review ›" on its top line, a hairline-ruled row per file, "Show All N Files" as its last row.
nonisolated struct ChangedFilesLayout: @unchecked Sendable {
    nonisolated struct FileRow: @unchecked Sendable {
        var frame: CGRect
        /// The path exactly as the edit tool reported it (resolved only when opened).
        var path: String
        var nameFrame: CGRect
        var name: String
        var statsFrame: CGRect
        var stats: NSAttributedString
        var glyphFrame: CGRect
        var glyph: String
        var glyphColor: UIColor
        var accessibility: String
    }
    /// The filled card behind the header and every row (cell coordinates, as every frame here).
    var cardFrame: CGRect
    /// The whole strip: tap opens Review (the chat's Changes page); its own leading text ("3 files changed") and
    /// trailing "Review ›" are drawn within it at a fixed inset — no sub-frame carried for either.
    var headerFrame: CGRect
    var headerTitle: String
    var font: UIFont
    var rows: [FileRow]
    var showAllFrame: CGRect?
    var showAllTitle: String?
}

/// [transcript] A landed edit's first changed lines (§12, n20 F10): one monospaced block, added/removed lines washed
/// edge to edge (`MarkdownRenderer.lineWash`, as a diff reads on the Changes page), "Show all changes" when there is
/// more than the preview holds.
nonisolated struct DiffPreviewLayout: @unchecked Sendable {
    var frame: CGRect
    var headerFrame: CGRect
    var header: NSAttributedString
    var text: TextKitLayout
    var textFrame: CGRect
    var moreFrame: CGRect?
    var moreText: TextKitLayout?
}

/// [tasks] "Added to Tasks": one filled card (as the files card) — the green header, a row per task (circle, title,
/// who · due), and Open Tasks / Undo on its last row.
nonisolated struct TasksAddedLayout: @unchecked Sendable {
    /// [tasks] A together task's step under its row (frames in the row's own space).
    nonisolated struct StepLine: @unchecked Sendable {
        var markFrame: CGRect
        var textFrame: CGRect
        var statusFrame: CGRect
        var step: TodoCardWords.Step
    }
    nonisolated struct Line: @unchecked Sendable {
        var frame: CGRect
        var id: String
        var circleFrame: CGRect
        var titleFrame: CGRect
        var title: String
        var detailFrame: CGRect
        var detail: String
        var steps: [StepLine] = []
        /// "+2 more steps" (`nil` when every step shows).
        var moreFrame: CGRect?
        var more = 0
    }
    var cardFrame: CGRect
    var headerFrame: CGRect
    var undone: Bool
    var font: UIFont
    var detailFont: UIFont
    var lines: [Line]
    var footerFrame: CGRect
    /// "<Bot> Is Helping" (no Undo).
    var helping = false
    var botName = "Hermes"
    /// "✦ Ask Hermes to Help" above the footer, for one task of yours alone.
    var helpFrame: CGRect?
}

nonisolated enum ActivityLayout: @unchecked Sendable {
    case toolBubble(ToolBubbleLayout)
    case delegate(DelegateCardLayout)
    case image(ImageCardLayout)
    case changedFiles(ChangedFilesLayout)
    case diffPreview(DiffPreviewLayout)
    case tasksAdded(TasksAddedLayout)
}

nonisolated enum ActivityLayouts {
    static func make(_ kind: ActivityRowKind, row: ChatRow, width: CGFloat, style: ChatStyle) -> RowLayout {
        switch kind {
        case .toolBubble(let t): return toolBubble(t, row: row, width: width, style: style)
        case .delegate(let d): return delegate(d, row: row, width: width, style: style)
        case .image(let i): return image(i, row: row, width: width, style: style)
        case .changedFiles(let c): return changedFiles(c, row: row, width: width, style: style)
        case .diffPreview(let d): return diffPreview(d, row: row, width: width, style: style)
        case .tasksAdded(let t): return tasksAdded(t, row: row, width: width, style: style)
        }
    }

    // MARK: Added to Tasks ([tasks])

    private static func tasksAdded(_ t: TasksAddedRow, row: ChatRow, width: CGFloat, style: ChatStyle) -> RowLayout {
        let columnW = min(TextLayout.replyWidth(width), 360)
        let font = HQFont.face(ofSize: (16 * style.body.pointSize / 17).rounded())
        let detailFont = HQFont.face(ofSize: (13 * style.body.pointSize / 17).rounded())
        let lineH = ceil(font.lineHeight), detailH = ceil(detailFont.lineHeight)
        let pad: CGFloat = 14
        let left = ChatMetrics.sideInset
        let top = max(0, row.gapAbove)
        let headerH = max(40, ceil(font.lineHeight) + 18)
        let headerFrame = CGRect(x: left + pad, y: top, width: columnW - 2 * pad, height: headerH)
        var y = top + headerH
        let circle = ceil(max(22, font.pointSize * 1.4))
        var lines: [TasksAddedLayout.Line] = []
        let stepH = detailH + 8
        for (i, task) in t.tasks.prefix(8).enumerated() {
            let (steps, more) = TodoCardWords.steps(task, botName: t.botName)
            let headH = max(52, 10 + lineH + 2 + detailH + 10)
            let stepsH = steps.isEmpty ? 0 : CGFloat(steps.count + (more > 0 ? 1 : 0)) * stepH + 8
            let rowH = headH + stepsH
            let textX = left + pad + circle + 12
            let textW = max(40, left + columnW - pad - textX)
            let block = lineH + 2 + detailH
            let textY = y + ((headH - block) / 2).rounded()
            var line = TasksAddedLayout.Line(frame: CGRect(x: left, y: y, width: columnW, height: rowH), id: task.id,
                               circleFrame: CGRect(x: left + pad, y: y + ((headH - circle) / 2).rounded(), width: circle, height: circle),
                               titleFrame: CGRect(x: textX, y: textY, width: textW, height: lineH), title: task.title,
                               detailFrame: CGRect(x: textX, y: textY + lineH + 2, width: textW, height: detailH),
                               detail: i < t.lines.count ? t.lines[i] : "")
            // [tasks] Its steps, under the title's column: a mark, the words, and the bot's "Started" at the right.
            var stepY = headH - 4
            let mark = ceil(detailFont.pointSize * 1.05)
            let statusFont = HQFont.face(ofSize: detailFont.pointSize, weight: .semibold)  // the cell draws it semibold
            for step in steps {
                let statusW = step.status.isEmpty ? 0 : ceil((step.status as NSString).size(withAttributes: [.font: statusFont]).width)
                let wordsX = textX - left + mark + 8
                let wordsW = max(40, columnW - pad - wordsX - (statusW > 0 ? statusW + 10 : 0))
                line.steps.append(.init(markFrame: CGRect(x: textX - left, y: stepY + ((stepH - mark) / 2).rounded(), width: mark, height: mark),
                                        textFrame: CGRect(x: wordsX, y: stepY + ((stepH - detailH) / 2).rounded(), width: wordsW, height: detailH),
                                        statusFrame: CGRect(x: columnW - pad - statusW, y: stepY + ((stepH - detailH) / 2).rounded(), width: statusW, height: detailH),
                                        step: step))
                stepY += stepH
            }
            if more > 0 {
                line.moreFrame = CGRect(x: textX - left + mark + 8, y: stepY + ((stepH - detailH) / 2).rounded(), width: textW, height: detailH)
                line.more = more
            }
            lines.append(line)
            y += rowH
        }
        var helpFrame: CGRect?
        if !t.helping, !t.undone, TodoCardWords.offersHelp(t.tasks) {
            helpFrame = CGRect(x: left, y: y, width: columnW, height: 46)
            y += 46
        }
        let footerFrame = CGRect(x: left, y: y, width: columnW, height: 46)
        y += 46
        let cardFrame = CGRect(x: left, y: top, width: columnW, height: y - top)
        return RowLayout(height: ceil(y + 2), content: .activity(.tasksAdded(TasksAddedLayout(
            cardFrame: cardFrame, headerFrame: headerFrame, undone: t.undone, font: font, detailFont: detailFont,
            lines: lines, footerFrame: footerFrame, helping: t.helping, botName: t.botName, helpFrame: helpFrame))))
    }

    // MARK: Tool bubble

    static func codeFont(_ style: ChatStyle) -> UIFont {
        HQFont.monoFace(ofSize: (15 * style.body.pointSize / 17).rounded(), weight: .regular)
    }

    private static func toolBubble(_ t: ToolBubbleRow, row: ChatRow, width: CGFloat, style: ChatStyle) -> RowLayout {
        let bubbleW = TextLayout.maxBubbleWidth(mine: false, width: width, style: style)
        let padH: CGFloat = 12, padV: CGFloat = 8
        let textW = bubbleW - 2 * padH
        let lineH = style.bodyLineHeight
        let para = MarkdownRenderer.paragraphStyle(lineHeight: lineH, font: style.body, spacingBefore: 0)
        let baseline = MarkdownRenderer.baselineOffset(lineHeight: lineH, font: style.body)
        let footnote = HQFont.preferred(.footnote, compatibleWith: UITraitCollection(preferredContentSizeCategory: style.category))
        var y = padV
        var lines: [ToolBubbleLineLayout] = []
        var more: TextKitLayout?
        var moreFrame = CGRect.zero
        if t.earlier > 0 {
            let text = NSAttributedString(string: "⋯ \(t.earlier) earlier step\(t.earlier == 1 ? "" : "s")", attributes: [
                .font: style.body, .foregroundColor: ChatPalette.tintText, .paragraphStyle: para, .baselineOffset: baseline,
            ])
            let tk = TextKitLayout(text, width: textW)
            more = tk
            moreFrame = CGRect(x: padH, y: y, width: textW, height: tk.size.height)
            y += tk.size.height
        }
        for entry in t.lines {
            let color = entry.failed ? ChatPalette.red : (entry.running && entry.line.code == nil ? ChatPalette.label2 : ChatPalette.label)
            let text = NSMutableAttributedString(string: "\(entry.line.emoji) \(entry.line.text)", attributes: [
                .font: style.body, .foregroundColor: color, .paragraphStyle: para, .baselineOffset: baseline,
            ])
            if entry.failed {
                text.append(NSAttributedString(string: "  Failed", attributes: [
                    .font: footnote, .foregroundColor: ChatPalette.red, .paragraphStyle: para, .baselineOffset: baseline,
                ]))
            }
            let tk = TextKitLayout(text, width: textW)
            let textFrame = CGRect(x: padH, y: y, width: textW, height: tk.size.height)
            y += tk.size.height
            var layout = ToolBubbleLineLayout(callId: entry.callId, text: tk, textFrame: textFrame, tapFrame: .zero,
                                              running: entry.running, failed: entry.failed,
                                              accessibility: [entry.line.text, entry.line.code, entry.failed ? "Failed" : nil,
                                                              entry.running ? "running" : nil].compactMap { $0 }.joined(separator: ": "))
            if let code = entry.line.code {
                // The block: 4 above, 2 below; padding 4 10 6 12; head row then the code clamped to 2 lines.
                let accent = ChatPalette.tintText
                let subheadline = HQFont.preferred(.subheadline,
                                                       compatibleWith: UITraitCollection(preferredContentSizeCategory: style.category))
                let head = NSMutableAttributedString(string: entry.language ?? "Shell", attributes: [
                    .font: HQFont.face(ofSize: subheadline.pointSize, weight: .semibold),
                    .foregroundColor: accent,
                ])
                head.append(NSAttributedString(string: "\u{2003}\u{2003}", attributes: [.font: style.body]))
                head.append(NSAttributedString(string: "</>", attributes: [
                    .font: HQFont.monoFace(ofSize: footnote.pointSize, weight: .regular), .foregroundColor: accent,
                ]))
                let headTK = TextKitLayout(head, width: nil)
                let font = codeFont(style)
                let codeLine = (font.pointSize * 1.35).rounded(.up)
                let codePara = NSMutableParagraphStyle()
                codePara.minimumLineHeight = codeLine
                codePara.maximumLineHeight = codeLine
                codePara.lineBreakMode = .byCharWrapping
                let codeText = NSAttributedString(string: code, attributes: [
                    .font: font, .foregroundColor: ChatPalette.label, .paragraphStyle: codePara,
                    .baselineOffset: (codeLine - font.lineHeight) / 4,
                ])
                let maxCodeW = textW - 12 - 10
                let codeTK = TextKitLayout(codeText, width: maxCodeW)
                let codeH = min(codeTK.size.height, codeLine * 2)
                let contentW = max(headTK.size.width, min(codeTK.size.width, maxCodeW))
                let blockY = y + 4
                let headFrame = CGRect(x: 12, y: 4, width: headTK.size.width, height: headTK.size.height)
                let codeFrame = CGRect(x: 12, y: headFrame.maxY + 2, width: maxCodeW, height: codeH)
                let blockH = codeFrame.maxY + 6
                layout.blockFrame = CGRect(x: padH, y: blockY, width: min(textW, contentW + 12 + 10), height: blockH)
                layout.head = headTK
                layout.headFrame = headFrame
                layout.code = codeTK
                layout.codeFrame = codeFrame
                y = blockY + blockH + 2
            }
            let lineBottom = layout.blockFrame?.maxY ?? textFrame.maxY
            let span = lineBottom - textFrame.minY
            let tapH = max(44, span)
            layout.tapFrame = CGRect(x: 0, y: textFrame.minY - (tapH - span) / 2, width: bubbleW, height: tapH)
            lines.append(layout)
        }
        // The time on the run's last bubble (its own line under the last block when there is code there).
        var timeText: String?
        var timeFrame = CGRect.zero
        var timeShift: CGFloat = 0
        if let time = t.time {
            let text = ChatRowBuilder.clock(time)
            let size = (text as NSString).size(withAttributes: [.font: style.time])
            timeText = text
            // Clear of a round corner (Theme › Bubble Corners).
            timeShift = ChatMetrics.timeShift(mine: false, joinsBelow: t.joinsBelow, tail: t.tail)
            let lastLineMaxX = lines.last.map { $0.blockFrame == nil ? $0.textFrame.minX + $0.text.lastLineMaxX : .greatestFiniteMagnitude } ?? 0
            if lastLineMaxX + ChatMetrics.timeReserveGap + size.width > bubbleW - ChatMetrics.timeTrailing - timeShift {
                y += style.timeLineHeight + timeShift
            }
            timeFrame = CGRect(x: bubbleW - ChatMetrics.timeTrailing - timeShift - ceil(size.width), y: 0, width: ceil(size.width),
                               height: style.timeLineHeight)
        }
        let bubbleH = ceil(y + padV)
        if timeText != nil { timeFrame.origin.y = bubbleH - ChatMetrics.timeBottom - timeShift - timeFrame.height }
        let gap = max(0, row.gapAbove)
        let frame = CGRect(x: ChatMetrics.sideInset, y: gap, width: bubbleW, height: bubbleH)
        let shape = BubbleShape.Key(width: bubbleW, height: bubbleH, mine: false, joinsAbove: t.joinsAbove, joinsBelow: t.joinsBelow, tail: t.tail)
        let layout = ToolBubbleLayout(frame: frame, shape: shape, lines: lines, more: more, moreFrame: moreFrame,
                                      timeText: timeText, timeFrame: timeFrame)
        return RowLayout(height: gap + bubbleH, content: .activity(.toolBubble(layout)))
    }

    // MARK: Delegate card (§11.2)

    static func delegateFont(_ style: ChatStyle) -> UIFont {
        HQFont.face(ofSize: (14 * style.body.pointSize / 17).rounded())
    }

    private static func delegate(_ d: DelegateCardRow, row: ChatRow, width: CGFloat, style: ChatStyle) -> RowLayout {
        let font = delegateFont(style)
        let activityFont = HQFont.face(ofSize: font.pointSize)
        let tabular = HQFont.monoDigitFace(ofSize: font.pointSize, weight: .regular)
        let lineH = ceil(font.lineHeight)
        let columnW = TextLayout.replyWidth(width)
        let pad: CGFloat = 12
        var y = max(0, row.gapAbove)
        var rows: [DelegateCardLayout.Row] = []
        for r in d.rows {
            let live = r.status.isLive
            var meta: [String] = []
            if let model = r.model, !model.isEmpty { meta.append(model) }
            if !live, let seconds = r.durationSeconds { meta.append(ToolCards.formatDurationSeconds(seconds)) }
            let metaTK: TextKitLayout? = meta.isEmpty ? nil : TextKitLayout(NSAttributedString(string: meta.joined(separator: " · "), attributes: [
                .font: font, .foregroundColor: ChatPalette.label2,
            ]), width: nil)
            let glyph: CGFloat = 14
            let agent: CGFloat = 12
            let timerW: CGFloat = live ? ceil(("00:00" as NSString).size(withAttributes: [.font: tabular]).width) : 0
            let innerW = columnW - 2 * pad
            let metaW = min(metaTK?.size.width ?? 0, innerW * 0.45)
            let trailing = (metaW > 0 ? metaW + 8 : 0) + (timerW > 0 ? timerW + 8 : 0) + agent + 4
            let goalW = max(40, innerW - glyph - 6 - trailing)
            let goalPara = NSMutableParagraphStyle()
            goalPara.lineBreakMode = .byTruncatingTail
            let goalTK = TextKitLayout(NSAttributedString(string: r.goal, attributes: [
                .font: font, .foregroundColor: ChatPalette.label, .paragraphStyle: goalPara,
            ]), width: 100_000)
            let rowTop = y
            // Frames inside the row's own box.
            let line1Y = pad
            let goalFrame = CGRect(x: pad + glyph + 6, y: line1Y, width: goalW, height: lineH)
            var x = goalFrame.maxX + 8
            let metaFrame = CGRect(x: x, y: line1Y, width: metaW, height: lineH)
            if metaW > 0 { x += metaW + 8 }
            let timerFrame: CGRect? = live ? CGRect(x: x, y: line1Y, width: timerW, height: lineH) : nil
            let agentFrame = CGRect(x: columnW - pad - agent, y: line1Y + (lineH - agent) / 2, width: agent, height: agent)
            let activityLineH = ceil(activityFont.lineHeight)
            let activity = r.activity.last
            let hasActivity = activity != nil || live
            let activityFrame = CGRect(x: pad + 20, y: line1Y + lineH + 2, width: innerW - 20, height: hasActivity ? activityLineH : 0)
            let rowH = pad + lineH + (hasActivity ? 2 + activityLineH : 0) + pad
            let status: String = {
                switch r.status {
                case .running, .queued: return "running"
                case .completed: return "done"
                case .failed: return "failed"
                case .interrupted: return "stopped"
                case .dispatched: return "running in the background"
                }
            }()
            rows.append(.init(frame: CGRect(x: ChatMetrics.sideInset, y: rowTop, width: columnW, height: rowH), status: r.status,
                              goal: goalTK, goalFrame: goalFrame, meta: metaTK, metaFrame: metaFrame, timerFrame: timerFrame,
                              startedAt: r.startedAt, glyphFrame: CGRect(x: pad, y: line1Y + (lineH - glyph) / 2, width: glyph, height: glyph),
                              agentFrame: agentFrame, activityFrame: activityFrame, activity: activity,
                              accessibility: ([r.goal, status] + meta + (activity.map { [$0] } ?? [])).joined(separator: ", ")))
            y += rowH + 6
        }
        let height = ceil(y - 6 + 2)
        return RowLayout(height: height, content: .activity(.delegate(DelegateCardLayout(rows: rows, font: font, activityFont: activityFont))))
    }

    // MARK: Generated image (§11.3)

    private static func image(_ i: ImageCardRow, row: ChatRow, width: CGFloat, style: ChatStyle) -> RowLayout {
        let maxW = TextLayout.maxBubbleWidth(mine: false, width: width, style: style)
        let gap = max(0, row.gapAbove)
        if i.failed {
            // The one deliberate size change: the frame collapses to a 44 pt link row (tap retries).
            return RowLayout(height: ceil(gap + 44), content: .activity(.image(ImageCardLayout(
                frame: CGRect(x: ChatMetrics.sideInset, y: gap, width: maxW, height: 44), path: i.path, running: false,
                profile: i.profile, failed: true))))
        }
        let maxH = TextLayout.screenHeight * 0.55
        var w = maxW
        var h = (w / CGFloat(max(0.1, i.ratio))).rounded()
        if h > maxH {
            h = maxH
            w = (h * CGFloat(i.ratio)).rounded()
        }
        return RowLayout(height: ceil(gap + h + 2), content: .activity(.image(ImageCardLayout(
            frame: CGRect(x: ChatMetrics.sideInset, y: gap, width: w, height: h), path: i.path, running: i.running, profile: i.profile))))
    }

    // MARK: Changed files (§12, n20 F10)

    /// A new file ("+", nothing removed) is green, a deleted one ("−", nothing added) is red, else the tint (edited).
    private static func fileGlyph(_ file: ChangedFile) -> (name: String, color: UIColor) {
        if file.added > 0, file.removed == 0 { return ("plus.square", ChatPalette.green) }
        if file.removed > 0, file.added == 0 { return ("minus.square", ChatPalette.red) }
        return ("pencil.line", ChatPalette.tint)
    }

    /// "+12 −3" (a real minus sign, as the Changes page), coloured: the Changes page itself keeps these muted, but a
    /// card scanned at a glance reads its red and green faster (owner's rule: colour is never the only signal — the
    /// glyph and the sign already say which — so this is additive, not load-bearing).
    private static func fileStats(added: Int, removed: Int, edits: Int = 1, font: UIFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if edits > 1 {
            out.append(NSAttributedString(string: "\(edits) edits  ", attributes: [.font: font, .foregroundColor: ChatPalette.label2]))
        }
        if added > 0 { out.append(NSAttributedString(string: "+\(added)", attributes: [.font: font, .foregroundColor: ChatPalette.green])) }
        if removed > 0 {
            if out.length > 0 { out.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            out.append(NSAttributedString(string: "−\(removed)", attributes: [.font: font, .foregroundColor: ChatPalette.red]))
        }
        if added == 0, removed == 0 { out.append(NSAttributedString(string: "+0", attributes: [.font: font, .foregroundColor: ChatPalette.green])) }
        return out
    }

    static let changedFilesShown = 5

    /// Look: one filled card, as an opened One Line card (`contentCardFill`, hairline-ruled rows): the summary and
    /// "Review ›" on its top line (the whole line is Review's button — owner, 2026-10-29: "the old glyph on the header
    /// row sat on the cells' words", so it draws nothing but its two labels), a row per file with its glyph, name and
    /// +/−, and "Show All N Files" as the last row (as One Line's "Show All N Steps").
    private static func changedFiles(_ c: ChangedFilesRow, row: ChatRow, width: CGFloat, style: ChatStyle) -> RowLayout {
        let columnW = TextLayout.replyWidth(width)
        let font = delegateFont(style)
        let lineH = ceil(font.lineHeight)
        let pad: CGFloat = 12
        let left = ChatMetrics.sideInset
        let top = max(0, row.gapAbove)
        let rowH = max(44, ChatMetrics.stepPadV * 2 + lineH)   // each a tap target of its own
        let headerFrame = CGRect(x: left + pad, y: top, width: columnW - 2 * pad, height: rowH)
        var y = top + rowH
        let shown = c.showAll ? c.files : Array(c.files.prefix(changedFilesShown))
        let glyphSize = ceil(max(16, font.pointSize))   // follows the text size, as a step's glyph
        var rows: [ChangedFilesLayout.FileRow] = []
        for file in shown {
            let stats = fileStats(added: file.added, removed: file.removed, edits: file.edits, font: font)
            let statsW = ceil(stats.size().width)
            let glyphFrame = CGRect(x: left + pad, y: y + ((rowH - glyphSize) / 2).rounded(), width: glyphSize, height: glyphSize)
            let nameX = glyphFrame.maxX + 8
            let statsFrame = CGRect(x: left + columnW - pad - statsW, y: y + ((rowH - lineH) / 2).rounded(), width: statsW, height: lineH)
            let nameW = max(40, statsFrame.minX - 10 - nameX)
            let (glyph, color) = fileGlyph(file)
            let counts = MoreWorkspaceRoot.counts(added: file.added, removed: file.removed)
            rows.append(.init(frame: CGRect(x: left, y: y, width: columnW, height: rowH), path: file.path,
                              nameFrame: CGRect(x: nameX, y: statsFrame.minY, width: nameW, height: lineH), name: file.name,
                              statsFrame: statsFrame, stats: stats, glyphFrame: glyphFrame, glyph: glyph, glyphColor: color,
                              accessibility: "\(file.name), " + (file.edits > 1 ? "\(file.edits) edits, " : "") + counts))
            y += rowH
        }
        var showAllFrame: CGRect?
        var showAllTitle: String?
        if !c.showAll && c.files.count > changedFilesShown {
            showAllFrame = CGRect(x: left, y: y, width: columnW, height: rowH)
            showAllTitle = "Show All \(c.files.count) Files"
            y += rowH
        }
        let cardFrame = CGRect(x: left, y: top, width: columnW, height: y - top)
        return RowLayout(height: ceil(y + 2), content: .activity(.changedFiles(ChangedFilesLayout(
            cardFrame: cardFrame, headerFrame: headerFrame, headerTitle: ChangedFiles.title(c.files.count),
            font: font, rows: rows, showAllFrame: showAllFrame, showAllTitle: showAllTitle))))
    }

    // MARK: Diff preview (§12, n20 F10)

    /// The preview's monospaced block: each line's "+"/"−"/" " prefix coloured, added/removed lines washed edge to
    /// edge behind the whole row (`MarkdownRenderer.lineWash`, as `WorkspaceTextPage` washes a diff).
    private static func diffPreviewText(_ lines: [ChangedFiles.PreviewLine], font: UIFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lineH = (font.pointSize * 1.3).rounded(.up)
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = lineH
        para.maximumLineHeight = lineH
        // A long line wraps at a word, its later lines starting under the text, not under the "+"/"−" (screenshot
        // review of the n20 revisit, 2026-10-31: character wrapping split "warning" as "wa / rning").
        para.lineBreakMode = .byWordWrapping
        para.headIndent = ceil(("+" as NSString).size(withAttributes: [.font: font]).width)
        for (i, line) in lines.enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
            switch line.kind {
            case .added:
                attributes[.foregroundColor] = ChatPalette.green
                attributes[.backgroundColor] = ChatPalette.green.withAlphaComponent(0.12)
                attributes[.lineWash] = true
            case .removed:
                attributes[.foregroundColor] = ChatPalette.red
                attributes[.backgroundColor] = ChatPalette.red.withAlphaComponent(0.12)
                attributes[.lineWash] = true
            case .context:
                attributes[.foregroundColor] = ChatPalette.label2
            }
            out.append(NSAttributedString(string: line.text, attributes: attributes))
            if i < lines.count - 1 { out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: para])) }
        }
        return out
    }

    private static func diffPreview(_ d: DiffPreviewRow, row: ChatRow, width: CGFloat, style: ChatStyle) -> RowLayout {
        let columnW = TextLayout.replyWidth(width)
        let gap = max(0, row.gapAbove)
        let pad: CGFloat = 10
        let headerFont = delegateFont(style)
        let header = NSMutableAttributedString(string: ChangedFiles.basename(d.path), attributes: [
            .font: HQFont.face(ofSize: headerFont.pointSize, weight: .semibold), .foregroundColor: ChatPalette.label,
        ])
        header.append(NSAttributedString(string: "  "))
        header.append(fileStats(added: d.added, removed: d.removed, font: headerFont))
        let headerTK = TextKitLayout(header, width: columnW - 2 * pad)
        let headerFrame = CGRect(x: ChatMetrics.sideInset + pad, y: gap + pad, width: columnW - 2 * pad, height: headerTK.size.height)
        let font = codeFont(style)
        let text = diffPreviewText(d.lines, font: font)
        let textTK = TextKitLayout(text, width: columnW - 2 * pad)
        let textFrame = CGRect(x: ChatMetrics.sideInset + pad, y: headerFrame.maxY + 6, width: columnW - 2 * pad, height: textTK.size.height)
        var y = textFrame.maxY
        var moreFrame: CGRect?
        var moreTK: TextKitLayout?
        if d.more {
            let tk = TextKitLayout(NSAttributedString(string: "Show all changes", attributes: [
                .font: headerFont, .foregroundColor: ChatPalette.tintText,
            ]), width: nil)
            moreTK = tk
            moreFrame = CGRect(x: ChatMetrics.sideInset + pad, y: y + 8, width: tk.size.width, height: tk.size.height)
            y = moreFrame!.maxY
        }
        let height = ceil(y + pad)
        return RowLayout(height: height, content: .activity(.diffPreview(DiffPreviewLayout(
            frame: CGRect(x: ChatMetrics.sideInset, y: gap, width: columnW, height: height - gap),
            headerFrame: headerFrame, header: header, text: textTK, textFrame: textFrame,
            moreFrame: moreFrame, moreText: moreTK))))
    }
}
